import AppKit
import Observation
import MinivuCore
import MinivuRender

/// The state of the Batch Convert sheet: the settings being chosen, the
/// destination folder, and the first output's name as a preview.
///
/// Options are kept per format while the sheet is open, as Save As keeps
/// them, so switching JPEG → PNG → JPEG doesn't lose a quality setting; a
/// format not chosen yet in this sheet starts from what Save As last used
/// for it.
@MainActor @Observable final class BatchConvertModel {
    let entries: [FolderEntry]
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let saveOptions: SaveOptionsStore
    @ObservationIgnored let probe: BatchFileProbe

    var settings: BatchConvertSettings {
        didSet { if settings != oldValue { schedulePreview() } }
    }
    /// The pattern for output names, kept while "Keep names" is chosen so
    /// switching back finds it again.
    var pattern: RenamePattern {
        didSet {
            guard pattern != oldValue else { return }
            if usesPattern { settings.naming = .pattern(pattern) }
        }
    }
    var usesPattern: Bool {
        didSet {
            guard usesPattern != oldValue else { return }
            settings.naming = usesPattern ? .pattern(pattern) : .keep
        }
    }

    /// The chosen folder, resolved from its bookmark, for showing its name.
    private(set) var chosenFolder: URL?
    /// Its security-scoped bookmark, kept rather than made again when the
    /// popup goes back to the folder: under the sandbox a scoped bookmark can
    /// only be made while the folder is open to the app, which a folder
    /// remembered from an earlier session no longer is.
    @ObservationIgnored private var chosenBookmark: Data?
    /// "IMG_0001.NEF → IMG_0001.jpg", or why the first file can't convert.
    private(set) var previewText = ""
    private(set) var previewProblem: String?

    @ObservationIgnored private var optionsByFormat: [ExportFormat: ExportOptions] = [:]
    @ObservationIgnored private var previewGeneration = 0
    /// For tests: the preview in flight.
    @ObservationIgnored private(set) var previewWork: Task<Void, Never>?

    init(entries: [FolderEntry], store: BatchStore = BatchStore(), saveOptions: SaveOptionsStore? = nil,
         probe: BatchFileProbe = .system) {
        let saveOptions = saveOptions ?? SaveOptionsStore(defaults: store.defaults)
        var settings = store.convertSettings
            ?? BatchConvertSettings(options: saveOptions.options(for: saveOptions.lastFormat ?? .jpeg))
        var folder: URL?
        var folderBookmark: Data?
        if case .chosenFolder(let bookmark) = settings.destination {
            if let resolved = Self.resolveRefreshing(bookmark) {
                folder = resolved.url
                folderBookmark = resolved.bookmark
                settings.destination = .chosenFolder(bookmark: resolved.bookmark)
            } else {
                // The folder has gone (or can't be reached): start beside the
                // originals rather than fail on Convert.
                settings.destination = .besideOriginals
            }
        }
        self.entries = entries
        self.store = store
        self.saveOptions = saveOptions
        self.probe = probe
        if case .pattern(let saved) = settings.naming {
            pattern = saved
            usesPattern = true
        } else {
            pattern = store.convertPattern
            usesPattern = false
        }
        self.settings = settings
        chosenFolder = folder
        chosenBookmark = folderBookmark
        schedulePreview()
    }

    // MARK: - Format

    var format: ExportFormat {
        get { settings.options.format }
        set {
            guard newValue != settings.options.format else { return }
            optionsByFormat[settings.options.format] = settings.options
            settings.options = optionsByFormat[newValue] ?? saveOptions.options(for: newValue)
        }
    }

    /// Quality as the slider shows it, 1...100.
    var qualityPercent: Double {
        get { (settings.options.quality * 100).rounded() }
        set { settings.options.quality = min(max(newValue.rounded(), 1), 100) / 100 }
    }

    // MARK: - Destination

    var usesChosenFolder: Bool {
        if case .chosenFolder = settings.destination { return true }
        return false
    }

    /// The destination as the popup shows it: beside the originals, or the
    /// chosen folder. Choosing the folder item without a folder yet does
    /// nothing here; the sheet then asks with an open panel.
    func setUsesChosenFolder(_ chosen: Bool) {
        if !chosen {
            settings.destination = .besideOriginals
        } else if chosenFolder != nil, let chosenBookmark {
            settings.destination = .chosenFolder(bookmark: chosenBookmark)
        }
    }

    /// A folder picked in the open panel. False when it can't be used.
    @discardableResult
    func choose(folder: URL) -> Bool {
        guard VolumePolicy.isAllowed(folder), let bookmark = Self.bookmark(for: folder) else { return false }
        chosenFolder = folder
        chosenBookmark = bookmark
        settings.destination = .chosenFolder(bookmark: bookmark)
        return true
    }

    nonisolated static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    /// A bookmark back to its folder, without asking the user anything or
    /// mounting a volume. The caller starts and stops access itself.
    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        resolveRefreshing(bookmark)?.url
    }

    /// `resolve`, and the bookmark to keep: a fresh one when the old one is
    /// stale (the folder was moved or renamed), made while access is open,
    /// so it keeps working in later sessions.
    nonisolated static func resolveRefreshing(_ bookmark: Data) -> (url: URL, bookmark: Data)? {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        let url = (try? URL(resolvingBookmarkData: bookmark, options: quiet.union(.withSecurityScope), relativeTo: nil,
                            bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: quiet, relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        // Under the sandbox even asking whether it exists needs the access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let kept = stale ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)) ?? bookmark : bookmark
        return (url, kept)
    }

    // MARK: - Checks and preview

    var unknownTokens: [String] {
        usesPattern ? pattern.tokens.unknown : []
    }

    var canConvert: Bool {
        !entries.isEmpty && unknownTokens.isEmpty && (!usesChosenFolder || chosenFolder != nil) && resizeProblem == nil
    }

    /// Why the size asked for can't be used, or nil. A 0 px width would
    /// otherwise make 1 px images, and 0% silently no resize at all.
    var resizeProblem: String? {
        let resize = settings.resize
        switch resize.mode {
        case .none:
            return nil
        case .percent:
            return resize.percent.isFinite && resize.percent > 0 && resize.percent <= 1000
                ? nil : "The scale must be between 0 and 1000%."
        case .longSide, .width, .height:
            return (1...BatchResize.maximumSide).contains(resize.pixels)
                ? nil : "The size must be between 1 and \(BatchResize.maximumSide.formatted()) pixels."
        }
    }

    /// "Convert 12 Images".
    var title: String {
        "Convert \(entries.count == 1 ? "1 Image" : "\(entries.count.formatted()) Images")"
    }

    /// The first file's output name, worked out as the real run would.
    func schedulePreview() {
        previewGeneration += 1
        let generation = previewGeneration
        guard let first = entries.first else { return }
        let settings = self.settings, probe = self.probe
        let folder = usesChosenFolder ? chosenFolder : nil
        let source = RenameSource(url: first.url, modified: first.modified)
        let needsMetadata = settings.pattern?.needsImageMetadata == true
        previewWork = Task { [weak self] in
            let output = await BlockingWork.run { () -> BatchOutput? in
                let input = needsMetadata ? source.withImageMetadata() : source
                let accessing = folder?.startAccessingSecurityScopedResource() ?? false
                defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
                return BatchOutputPlanner.plan([input], settings: settings, folder: folder, probe: probe).first
            }
            guard let self, generation == self.previewGeneration, let output else { return }
            self.previewText = "\(first.name)  →  \(output.destination.lastPathComponent)"
            switch output.action {
            case .fail(let reason): self.previewProblem = reason
            case .skip(let reason): self.previewProblem = "Skipped: \(reason)"
            default: self.previewProblem = nil
            }
        }
    }

    /// The settings to run with, remembered for next time.
    func commit() -> BatchConvertSettings {
        store.convertSettings = settings
        store.convertPattern = pattern
        return settings
    }
}
