import AppKit
import SwiftUI
import Observation
import MinivuCore
import MinivuRender

/// The state of "Save Edits as Preset…" (G6): a photo's edits sorted into
/// the steps a Batch Convert preset carries and those it leaves out
/// (`BatchEdits.portable`), and the name to save them under.
@MainActor @Observable final class EditsPresetModel {
    let portable: BatchEdits.Portable
    var name: String
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let presets: PresetList<BatchConvertPreset>

    init(operations: [EditOperation], suggestedName: String, store: BatchStore) {
        portable = BatchEdits.portable(operations)
        name = suggestedName
        self.store = store
        presets = .convert(store)
    }

    /// "IMG_0001 Edits": the photo's name, without its extension.
    nonisolated static func suggestedName(for url: URL) -> String {
        localized(.init("\(RenameNamer.split(url.lastPathComponent).base) Edits",
                        comment: "Suggested preset name: a photo's name, then Edits"))
    }

    /// The preset the name would replace, as the store has it now (a Batch
    /// Convert sheet on another window may have saved one meanwhile).
    var existing: NamedPreset<BatchConvertPreset>? {
        guard let name = PresetList<BatchConvertPreset>.cleaned(name) else { return nil }
        return store.convertPresets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var canSave: Bool { !portable.isEmpty && PresetList<BatchConvertPreset>.cleaned(name) != nil }

    /// What stands in the way of saving, or what saving will do.
    var status: String? {
        if portable.isEmpty { return localized("None of these edits can be used on other photos, so there is nothing to save.") }
        if let existing { return localized("Replaces the edits of the preset “\(existing.name)”.") }
        return nil
    }

    /// Saves the carried steps. Over a preset of the same name, only its
    /// edits change: a preset saved from Batch Convert keeps its output
    /// options. Nil when there is nothing to save or no name.
    @discardableResult
    func save() -> NamedPreset<BatchConvertPreset>? {
        guard canSave else { return nil }
        return presets.save(BatchConvertPreset(edits: portable.operations, output: existing?.value.output), as: name)
    }
}

/// "Save Edits as Preset…" as a sheet on the viewer: the name, the steps
/// the preset will apply (with what each does differently on other photos)
/// and the steps it leaves out, each with the reason.
@MainActor final class EditsPresetSheet {
    let model: EditsPresetModel
    let window: NSWindow
    private weak var parent: NSWindow?
    private var retainedSelf: EditsPresetSheet?

    init(model: EditsPresetModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = NSHostingView(rootView: EditsPresetView(model: model,
                                                                      onCancel: { [weak self] in self?.end() },
                                                                      onSave: { [weak self] in self?.save() }))
    }

    func begin(on parent: NSWindow) {
        self.parent = parent
        retainedSelf = self
        parent.beginSheet(window, completionHandler: nil)
    }

    private func save() {
        guard model.save() != nil else { return NSSound.beep() }
        end()
    }

    private func end() {
        if let parent, window.sheetParent === parent { parent.endSheet(window) }
        window.orderOut(nil)
        retainedSelf = nil
    }
}

struct EditsPresetView: View {
    @Bindable var model: EditsPresetModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Save Edits as Preset")
                    .font(.headline)
                Text("Batch Convert applies the preset to other images: choose it under Preset in Tools > Batch Convert….")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                TextField("Name", text: $model.name)
                    .accessibilityLabel("Preset name")
                Section("Included") {
                    if model.portable.operations.isEmpty {
                        Text("Nothing").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.portable.operations.enumerated()), id: \.offset) { _, operation in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(operation.title)
                            if let note = BatchEdits.note(for: operation) {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !model.portable.leftOut.isEmpty {
                    Section("Left Out") {
                        ForEach(Array(model.portable.leftOut.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                Text(step.reason).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(localized(.init("\(step.title), left out: \(step.reason)",
                                                                comment: "VoiceOver: an edit, then why it can't be part of the preset")))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let status = model.status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(model.portable.isEmpty ? .red : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
