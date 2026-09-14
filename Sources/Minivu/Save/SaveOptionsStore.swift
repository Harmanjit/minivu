import Foundation
import MinivuCore

/// Remembers what Save As was last set to: the options for each format, the
/// format last written and the folder last saved into.
///
/// Per format rather than one set, because the choices don't carry over:
/// quality 72 suits JPEG while HEIC looks the same at a lower number, and
/// someone who writes 16-bit TIFFs for print still wants 8-bit PNGs for the
/// web. Save (⌘S) reads the same options, so overwriting a JPEG uses the
/// quality last chosen for JPEG.
///
/// Stored as JSON in UserDefaults. `ExportOptions` decodes missing fields
/// from its defaults, so options saved by an older minivu still load.
struct SaveOptionsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum Keys {
        static func options(_ format: ExportFormat) -> String { "saveOptions.\(format.rawValue)" }
        static let lastFormat = "saveLastFormat"
        static let lastFolder = "saveLastFolder"
    }

    /// The options last used for `format`, or its defaults. The format field
    /// is always `format`, whatever was stored.
    func options(for format: ExportFormat) -> ExportOptions {
        guard let data = defaults.data(forKey: Keys.options(format)),
              var options = try? JSONDecoder().decode(ExportOptions.self, from: data) else {
            return .defaults(for: format)
        }
        options.format = format
        return options
    }

    /// Whether a save in `format` has been made before (so its options are
    /// the user's, not defaults).
    func hasRemembered(_ format: ExportFormat) -> Bool {
        defaults.data(forKey: Keys.options(format)) != nil
    }

    /// Remembers `options` for their format, and that format as the last one used.
    func remember(_ options: ExportOptions) {
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Keys.options(options.format))
        }
        defaults.set(options.format.rawValue, forKey: Keys.lastFormat)
    }

    var lastFormat: ExportFormat? {
        defaults.string(forKey: Keys.lastFormat).flatMap(ExportFormat.init(rawValue:))
    }

    /// The folder Save As last wrote into. A path, not a bookmark: the save
    /// panel may show any folder, and choosing it there is what grants the
    /// sandbox access, so nothing needs to be resolved ahead of time.
    var lastFolder: URL? {
        get { defaults.string(forKey: Keys.lastFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        nonmutating set { defaults.set(newValue?.path, forKey: Keys.lastFolder) }
    }

    /// The format Save As starts with: the file's own when minivu can write
    /// it (converting is the exception, not the rule), otherwise the one
    /// last used, otherwise JPEG.
    func initialFormat(for source: URL) -> ExportFormat {
        ExportFormat.format(for: source) ?? lastFormat ?? .jpeg
    }
}
