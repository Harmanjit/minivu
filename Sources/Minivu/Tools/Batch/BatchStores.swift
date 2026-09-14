import Foundation
import MinivuCore
import MinivuRender

/// What Batch Rename and Batch Convert were last set to, so the next batch
/// starts where the last one left off.
///
/// JSON in UserDefaults, which tests replace with a suite of their own.
/// Both value types decode missing fields from their defaults, so settings
/// written by an older minivu still load.
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

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else { return defaults.removeObject(forKey: key) }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
