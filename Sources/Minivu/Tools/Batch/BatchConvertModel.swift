import AppKit
import Observation
import MinivuCore
import MinivuRender

/// The state of the Batch Convert sheet: the settings being chosen, the
/// destination folder, the first output's name as a preview, and the named
/// presets (G6): edits from the viewer or the whole sheet saved by name.
///
/// Options are kept per format while the sheet is open, as Save As keeps
/// them, so switching JPEG → PNG → JPEG doesn't lose a quality setting; a
/// format not chosen yet in this sheet starts from what Save As last used
/// for it.
///
/// Extract Pages (G17) is the same sheet in another mode: every page of
/// each file, or a range, written as separate files, with its own
/// remembered settings and a name pattern that numbers the pages.
@MainActor @Observable final class BatchConvertModel {
    enum Mode {
        case convert
        case extractPages
    }

    let entries: [FolderEntry]
    let mode: Mode
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let saveOptions: SaveOptionsStore
    @ObservationIgnored let probe: BatchFileProbe
    let presets: PresetList<BatchConvertPreset>

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
    /// The preset last chosen or saved, which the popup shows; nil is None.
    /// Changing an option afterwards doesn't change the preset until it is
    /// saved again.
    private(set) var selectedPresetID: UUID?
    /// "IMG_0001.NEF → IMG_0001.jpg", or why the first file can't convert.
    private(set) var previewText = ""
    private(set) var previewProblem: String?

    @ObservationIgnored private var optionsByFormat: [ExportFormat: ExportOptions] = [:]
    @ObservationIgnored private var previewGeneration = 0
    /// For tests: the preview in flight.
    @ObservationIgnored private(set) var previewWork: Task<Void, Never>?

    init(entries: [FolderEntry], mode: Mode = .convert, store: BatchStore = BatchStore(),
         saveOptions: SaveOptionsStore? = nil, probe: BatchFileProbe = .system) {
        let saveOptions = saveOptions ?? SaveOptionsStore(defaults: store.defaults)
        var settings: BatchConvertSettings
        switch mode {
        case .convert:
            settings = store.convertSettings
                ?? BatchConvertSettings(options: saveOptions.options(for: saveOptions.lastFormat ?? .jpeg))
            // Extract Pages' own choice never reaches Batch Convert's sheet.
            if case .separate = settings.pages { settings.pages = .first }
        case .extractPages:
            // PNG keeps a page's every pixel; the names number the pages.
            settings = store.extractSettings
                ?? BatchConvertSettings(options: saveOptions.options(for: .png), naming: .pattern(store.extractPattern))
            if case .separate = settings.pages {} else { settings.pages = .separate(.all) }
        }
        // A format this Mac can no longer write (AVIF without its encoder)
        // starts again from JPEG rather than fail every file.
        if !settings.options.format.isWritable { settings.options = saveOptions.options(for: .jpeg) }
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
        self.mode = mode
        self.store = store
        self.saveOptions = saveOptions
        self.probe = probe
        presets = .convert(store)
        if case .pattern(let saved) = settings.naming {
            pattern = saved
            usesPattern = true
        } else {
            pattern = mode == .convert ? store.convertPattern : store.extractPattern
            usesPattern = false
        }
        self.settings = settings
        chosenFolder = folder
        chosenBookmark = folderBookmark
        // The popup shows the preset the remembered edits came from, while
        // it is still there; otherwise None beside edits would read as none.
        if mode == .convert, let id = store.convertPresetID, presets.preset(id) != nil { selectedPresetID = id }
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

    // MARK: - Presets and edits

    /// Chooses a preset from the popup: its edits replace the sheet's, and a
    /// preset saved from Batch Convert brings its output options too. None
    /// clears the edits and leaves everything else.
    func choosePreset(_ id: UUID?) {
        guard let preset = presets.preset(id) else {
            selectedPresetID = nil
            settings.edits = []
            return
        }
        selectedPresetID = preset.id
        if let output = preset.value.output { adopt(output) }
        // Only steps a preset may carry, whatever a stored preset says.
        settings.edits = BatchEdits.portable(preset.value.edits).operations
    }

    /// Saves the sheet as it stands (edits and every option) as `name`,
    /// over a preset of that name if there is one. False for an empty name.
    @discardableResult
    func savePreset(named name: String) -> Bool {
        var output = settings
        output.edits = []
        guard let saved = presets.save(BatchConvertPreset(edits: settings.edits, output: output), as: name) else {
            return false
        }
        selectedPresetID = saved.id
        return true
    }

    /// Renames the chosen preset; false when the name is empty or taken.
    @discardableResult
    func renameSelectedPreset(to name: String) -> Bool {
        guard let id = selectedPresetID else { return false }
        return presets.rename(id, to: name)
    }

    /// Deletes the chosen preset. The sheet keeps what it took from it.
    func deleteSelectedPreset() {
        guard let id = selectedPresetID else { return }
        presets.delete(id)
        selectedPresetID = nil
    }

    func removeEdit(at index: Int) {
        guard settings.edits.indices.contains(index) else { return }
        settings.edits.remove(at: index)
    }

    /// The watermark's line in the Edits section.
    var watermarkSummary: String {
        guard let watermark = settings.watermark else { return "None" }
        switch watermark.kind {
        case .text: return "“\(watermark.text)”"
        case .image: return watermark.imageName ?? "Picture"
        }
    }

    /// Under Keep HDR, why HDR photos will be written SDR after all: the
    /// chosen colour profile or bit depth can't go with a gain map
    /// (`ImageEncoder.canWriteGainMap(_:)`). Nil when Keep HDR applies or
    /// is off.
    var hdrNote: String? {
        let options = settings.options
        guard settings.keepsHDR, ImageEncoder.canWriteGainMap(options.format),
              !ImageEncoder.canWriteGainMap(options) else { return nil }
        if options.format.supports16Bit && options.sixteenBit {
            return "HDR photos are written SDR at \(options.format.deepBitDepth ?? 16) bits: a gain map holds 8."
        }
        return "HDR photos are written SDR in \(options.colorProfile.title): a gain map needs Display P3."
    }

    /// A preset's output options, as the sheet's own: the chosen folder
    /// resolved again (or beside the originals when it has gone), the
    /// names' pattern shown, and a format this Mac can't write replaced.
    private func adopt(_ output: BatchConvertSettings) {
        var output = output
        if !output.options.format.isWritable { output.options = saveOptions.options(for: .jpeg) }
        if case .chosenFolder(let bookmark) = output.destination {
            if let resolved = Self.resolveRefreshing(bookmark) {
                chosenFolder = resolved.url
                chosenBookmark = resolved.bookmark
                output.destination = .chosenFolder(bookmark: resolved.bookmark)
            } else {
                output.destination = .besideOriginals
            }
        }
        optionsByFormat = [:]
        settings = output
        if case .pattern(let saved) = output.naming {
            pattern = saved
            usesPattern = true
        } else {
            usesPattern = false
        }
    }

    // MARK: - Checks and preview

    var unknownTokens: [String] {
        usesPattern ? pattern.tokens.unknown : []
    }

    var canConvert: Bool {
        !entries.isEmpty && unknownTokens.isEmpty && (!usesChosenFolder || chosenFolder != nil) && resizeProblem == nil
            && pageRangeProblem == nil
    }

    // MARK: - Pages

    /// Batch Convert's choice for multi-page originals: the first page, or
    /// every page.
    var convertsEveryPage: Bool {
        get { settings.pages == .all }
        set { settings.pages = newValue ? .all : .first }
    }

    /// Extract Pages' range; all pages unless a range is chosen.
    var pageRange: PageRange {
        get {
            if case .separate(let range) = settings.pages { return range }
            return .all
        }
        set { settings.pages = .separate(newValue) }
    }

    /// Extract Pages: whether a range is chosen rather than every page.
    var usesPageRange: Bool {
        get { !pageRange.isAll }
        set { pageRange = newValue ? PageRange(first: max(pageRange.first, 1), last: pageRange.last ?? max(pageRange.first, 1)) : .all }
    }

    var pageRangeProblem: String? {
        mode == .extractPages ? pageRange.problem : nil
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

    /// "Convert 12 Images", or "Extract Pages from 3 Files".
    var title: String {
        switch mode {
        case .convert:
            "Convert \(entries.count == 1 ? "1 Image" : "\(entries.count.formatted()) Images")"
        case .extractPages:
            "Extract Pages from \(entries.count == 1 ? "1 File" : "\(entries.count.formatted()) Files")"
        }
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
        switch mode {
        case .convert:
            store.convertSettings = settings
            store.convertPattern = pattern
            store.convertPresetID = selectedPresetID
        case .extractPages:
            store.extractSettings = settings
            store.extractPattern = pattern
        }
        return settings
    }
}
