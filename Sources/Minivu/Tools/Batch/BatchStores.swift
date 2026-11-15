import Foundation
import Observation
import MinivuCore
import MinivuRender

/// What Batch Rename and Batch Convert were last set to, so the next batch
/// starts where the last one left off, and the named presets of each (G6).
///
/// JSON in UserDefaults, which tests replace with a suite of their own.
/// Both value types decode missing fields from their defaults, so settings
/// written by an older minivu still load. Presets are kept under keys of
/// their own beside those, so the remembered settings are stored exactly as
/// before; a preset that can't be read (written by a later minivu with an
/// edit step this one doesn't know) is skipped, and the others still load.
struct BatchStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum Keys {
        static let renamePattern = "batchRenamePattern"
        static let convertSettings = "batchConvertSettings"
        /// The pattern last used for converted files' names, kept apart from
        /// Batch Rename's: renaming photos in place and naming exports for
        /// the web are different habits.
        static let convertPattern = "batchConvertPattern"
        static let convertPresets = "batchConvertPresets"
        static let renamePresets = "batchRenamePresets"
    }

    var renamePattern: RenamePattern {
        get { decode(RenamePattern.self, Keys.renamePattern) ?? RenamePattern() }
        nonmutating set { encode(newValue, Keys.renamePattern) }
    }

    var convertSettings: BatchConvertSettings? {
        get { decode(BatchConvertSettings.self, Keys.convertSettings) }
        nonmutating set { encode(newValue, Keys.convertSettings) }
    }

    var convertPattern: RenamePattern {
        get { decode(RenamePattern.self, Keys.convertPattern) ?? RenamePattern(text: "{name}") }
        nonmutating set { encode(newValue, Keys.convertPattern) }
    }

    var convertPresets: [NamedPreset<BatchConvertPreset>] {
        get { decodeEach(NamedPreset<BatchConvertPreset>.self, Keys.convertPresets) }
        nonmutating set { encode(newValue, Keys.convertPresets) }
    }

    var renamePresets: [NamedPreset<RenamePattern>] {
        get { decodeEach(NamedPreset<RenamePattern>.self, Keys.renamePresets) }
        nonmutating set { encode(newValue, Keys.renamePresets) }
    }

    /// A list decoded one element at a time, leaving out those that fail.
    private func decodeEach<T: Decodable>(_ type: T.Type, _ key: String) -> [T] {
        decode([Lenient<T>].self, key)?.compactMap(\.value) ?? []
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else { return defaults.removeObject(forKey: key) }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// One element of a stored list, nil when it can't be decoded.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A named preset of one of the batch sheets: a Batch Convert preset or a
/// Batch Rename pattern. The identifier keeps a selection while the name
/// changes.
struct NamedPreset<Value: Codable & Hashable>: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var value: Value

    init(id: UUID = UUID(), name: String, value: Value) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// A Batch Convert preset: edit steps applied to every image, and, when it
/// was saved from Batch Convert, the sheet's output options too (format,
/// size and orientation, watermark, destination and names). One saved from
/// the viewer's edits ("Save Edits as Preset…") has edits only, and choosing
/// it leaves the sheet's other options as they are.
struct BatchConvertPreset: Codable, Hashable {
    /// Only steps `BatchEdits.portable` carries.
    var edits: [EditOperation]
    /// The rest of the sheet, its own `edits` empty; nil for edits only.
    var output: BatchConvertSettings?

    init(edits: [EditOperation], output: BatchConvertSettings? = nil) {
        self.edits = edits
        self.output = output
    }

    private enum CodingKeys: String, CodingKey { case edits, output }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edits = try c.decodeIfPresent([EditOperation].self, forKey: .edits) ?? []
        output = try c.decodeIfPresent(BatchConvertSettings.self, forKey: .output)
    }
}

/// The named presets of one sheet, kept in `BatchStore` as they change:
/// save (under a new name, or over a preset of the same name), rename and
/// delete. Names are compared ignoring case, as Finder compares file names,
/// so "Web" and "web" are one preset.
///
/// Each change starts from what the store holds then, not from the list
/// read when the sheet opened: the viewer's Save Edits as Preset and a
/// Batch Convert sheet on another window can both be up, and one must not
/// write back a list that lacks what the other saved.
@MainActor @Observable final class PresetList<Value: Codable & Hashable> {
    private(set) var presets: [NamedPreset<Value>]
    @ObservationIgnored private let load: () -> [NamedPreset<Value>]
    @ObservationIgnored private let persist: ([NamedPreset<Value>]) -> Void

    init(load: @escaping () -> [NamedPreset<Value>], persist: @escaping ([NamedPreset<Value>]) -> Void) {
        presets = load()
        self.load = load
        self.persist = persist
    }

    /// Reads the store again.
    func reload() {
        let stored = load()
        if stored != presets { presets = stored }
    }

    /// The longest name kept; a longer one is cut.
    nonisolated static var maximumNameLength: Int { 80 }

    /// `name` without surrounding spaces and line breaks, at most
    /// `maximumNameLength` characters; nil when nothing is left.
    nonisolated static func cleaned(_ name: String) -> String? {
        let flat = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : String(flat.prefix(maximumNameLength))
    }

    func preset(_ id: UUID?) -> NamedPreset<Value>? {
        presets.first { $0.id == id }
    }

    func named(_ name: String) -> NamedPreset<Value>? {
        guard let name = Self.cleaned(name) else { return nil }
        return presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves `value` as `name`, replacing a preset of that name (keeping its
    /// place and identifier), else adding one at the end in name order.
    /// Nil when the name is empty.
    @discardableResult
    func save(_ value: Value, as name: String) -> NamedPreset<Value>? {
        guard let name = Self.cleaned(name) else { return nil }
        reload()
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index].name = name
            presets[index].value = value
            persist(presets)
            return presets[index]
        }
        let preset = NamedPreset(name: name, value: value)
        presets.append(preset)
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist(presets)
        return preset
    }

    /// Renames a preset; false when the name is empty or another preset has
    /// it already.
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        reload()
        guard let name = Self.cleaned(name), let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        if let other = named(name), other.id != id { return false }
        presets[index].name = name
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist(presets)
        return true
    }

    func delete(_ id: UUID) {
        reload()
        presets.removeAll { $0.id == id }
        persist(presets)
    }
}

extension PresetList where Value == BatchConvertPreset {
    /// Batch Convert's presets, in `store`.
    static func convert(_ store: BatchStore) -> PresetList {
        PresetList(load: { store.convertPresets }, persist: { store.convertPresets = $0 })
    }
}

extension PresetList where Value == RenamePattern {
    /// Batch Rename's presets, in `store`.
    static func rename(_ store: BatchStore) -> PresetList {
        PresetList(load: { store.renamePresets }, persist: { store.renamePresets = $0 })
    }
}
