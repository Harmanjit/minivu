import AppKit
import MinivuCore

/// Where the montage sheet gets its small photos: the browser's thumbnail
/// service (already cached for a folder the user has looked at). Tests pass
/// their own.
protocol MontageThumbnailProviding {
    /// `completion` runs on the main actor with nil for a photo that can't be
    /// read. The returned closure cancels the request.
    func thumbnail(for entry: FolderEntry, pixelSize: Int,
                   completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> () -> Void
}

struct ServiceThumbnails: MontageThumbnailProviding {
    func thumbnail(for entry: FolderEntry, pixelSize: Int,
                   completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> () -> Void {
        let request = AppServices.thumbnails.request(entry, pixelSize: pixelSize, completion: completion)
        return { request.cancel() }
    }
}

/// The montage choices, remembered between uses. Its own keys, in an
/// injectable defaults domain.
struct MontageSettingsStore {
    let defaults: UserDefaults

    private enum Keys {
        static let style = "montageStyle"
        static let spacing = "montageSpacing"
        static let background = "montageBackground"
    }

    var style: MontageStyle {
        get { defaults.string(forKey: Keys.style).flatMap(MontageStyle.init) ?? .grid }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.style) }
    }

    /// Points between photos and around the edge.
    var spacing: Double {
        get { defaults.object(forKey: Keys.spacing) as? Double ?? 8 }
        nonmutating set { defaults.set(newValue, forKey: Keys.spacing) }
    }

    var background: ExportColor {
        get {
            defaults.data(forKey: Keys.background).flatMap { try? JSONDecoder().decode(ExportColor.self, from: $0) }
                ?? ExportColor(red: 0.11, green: 0.11, blue: 0.12)
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.background) }
    }
}

/// Everything the Montage Wallpaper sheet shows and does.
@MainActor @Observable final class MontageModel {
    /// A display the montage can be made for, as it was when the sheet
    /// opened.
    struct Display: Identifiable, Hashable {
        let id: Int
        let displayID: CGDirectDisplayID
        let name: String
        let points: CGSize
        let scale: CGFloat

        var pixelSize: CGSize { MontageOutput.pixelSize(points: points, backingScale: scale) }
        var title: String { "\(name) (\(Int(pixelSize.width)) × \(Int(pixelSize.height)))" }
    }

    /// `displayChoice` for a montage on every display.
    static let allDisplays = -1
    /// Longest edge of the sheet's preview, in pixels.
    static let previewLongEdge: CGFloat = 1040

    enum Phase: Equatable {
        case editing
        case working(String)
    }

    let entries: [FolderEntry]
    /// How many images the command was given, before the 200 limit.
    let offeredCount: Int
    let fromSelection: Bool
    let displays: [Display]

    var displayChoice: Int { didSet { schedulePreview() } }
    var style: MontageStyle {
        didSet { settings.style = style; schedulePreview() }
    }
    var spacing: Double {
        didSet { settings.spacing = spacing; schedulePreview() }
    }
    var background: CGColor {
        didSet {
            if let color = ExportColor(background) { settings.background = color }
            schedulePreview()
        }
    }
    private(set) var seed: UInt64
    private(set) var preview: CGImage?
    private(set) var phase: Phase = .editing
    /// Shape of each photo (width over height, upright), known once its
    /// thumbnail has arrived; 3:2 until then.
    private(set) var aspectRatios: [Double]
    private(set) var loadedCount = 0

    @ObservationIgnored private let settings: MontageSettingsStore
    @ObservationIgnored private let thumbnails: MontageThumbnailProviding
    @ObservationIgnored private var images: [Int: ImageBox] = [:]
    @ObservationIgnored private var cancels: [() -> Void] = []
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// The render in flight, for tests to await.
    @ObservationIgnored private(set) var previewWork: Task<Void, Never>?

    init(images offered: [FolderEntry], fromSelection: Bool, displays: [Display], preferredDisplay: Int,
         settings: MontageSettingsStore = MontageSettingsStore(defaults: .standard),
         thumbnails: MontageThumbnailProviding = ServiceThumbnails(), seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        entries = Array(offered.prefix(MontageLayout.maximumImages))
        offeredCount = offered.count
        self.fromSelection = fromSelection
        self.displays = displays
        displayChoice = displays.indices.contains(preferredDisplay) ? preferredDisplay : 0
        self.settings = settings
        self.thumbnails = thumbnails
        style = settings.style
        spacing = settings.spacing
        background = settings.background.cgColor
        self.seed = seed
        aspectRatios = Array(repeating: 1.5, count: entries.count)
    }

    /// The displays of this Mac, the window's screen marked as preferred.
    static func currentDisplays() -> [Display] {
        NSScreen.screens.enumerated().map { index, screen in
            Display(id: index, displayID: screen.displayID, name: screen.localizedName, points: screen.frame.size,
                    scale: screen.backingScaleFactor)
        }
    }

    /// "Montages use at most 200 photos: the first 200 of the 340 selected."
    var limitNote: String? {
        guard offeredCount > entries.count else { return nil }
        let which = fromSelection ? "selected" : "shown"
        return "A montage uses at most \(entries.count) photos: the first \(entries.count) of the "
            + "\(offeredCount.formatted()) \(which)."
    }

    /// The displays a montage is made for.
    var targets: [Display] {
        displayChoice == Self.allDisplays ? displays : displays.filter { $0.id == displayChoice }
    }

    /// The display the preview shows: the chosen one, or the first of all.
    var previewDisplay: Display? { targets.first ?? displays.first }

    var isWorking: Bool { phase != .editing }

    func shuffle() {
        seed = UInt64.random(in: 1...UInt64.max)
        schedulePreview()
    }

    /// The layout inputs for `display` with the current choices, to lay out
    /// off the main thread (a mosaic of 200 photos takes a few milliseconds).
    /// Spacing is chosen in points, so it looks the same on a Retina and a
    /// standard display.
    func layoutJob(for display: Display) -> @Sendable () -> [MontageTile] {
        let style = style, aspects = aspectRatios, canvas = display.pixelSize
        let spacing = spacing * display.scale, seed = seed
        return { MontageLayout.layout(style, aspectRatios: aspects, canvas: canvas, spacing: spacing, seed: seed) }
    }

    // MARK: - Thumbnails and preview

    /// Asks for every photo's thumbnail; the preview is redrawn as they
    /// arrive (coalesced). Small photos, at most 512 px, for at most 200 of
    /// them: the preview is a few hundred points wide.
    func start() {
        guard cancels.isEmpty else { return }
        let size = entries.count <= 16 ? 512 : 256
        for (index, entry) in entries.enumerated() {
            let cancel = thumbnails.thumbnail(for: entry, pixelSize: size) { [weak self] image in
                self?.thumbnailArrived(image, at: index)
            }
            cancels.append(cancel)
        }
        if entries.isEmpty { finishLoadingIfDone() }
        schedulePreview()
    }

    func stop() {
        cancels.forEach { $0() }
        previewTask?.cancel()
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func thumbnailArrived(_ image: CGImage?, at index: Int) {
        loadedCount += 1
        if let image, image.height > 0 {
            images[index] = ImageBox(image: image)
            aspectRatios[index] = Double(image.width) / Double(image.height)
        }
        finishLoadingIfDone()
        schedulePreview()
    }

    private func finishLoadingIfDone() {
        guard loadedCount >= entries.count else { return }
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Waits until every thumbnail has arrived (or failed), since the
    /// photos' shapes decide the layout.
    func waitForThumbnails() async {
        guard loadedCount < entries.count else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Redraws the preview 50 ms after the last change, off the main thread,
    /// one render at a time: a dragged slider or 200 arriving thumbnails
    /// cost a handful of renders, not hundreds.
    func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            await self.previewWork?.value
            guard !Task.isCancelled else { return }
            self.previewWork = Task { await self.renderPreview() }
            await self.previewWork?.value
        }
    }

    private func renderPreview() async {
        guard let display = previewDisplay else { return }
        let canvas = display.pixelSize
        let fit = Self.previewLongEdge / max(canvas.width, canvas.height)
        let size = CGSize(width: (canvas.width * fit).rounded(), height: (canvas.height * fit).rounded())
        let layout = layoutJob(for: display)
        let look = MontageRenderer.Look(style: style, background: ExportColor(background) ?? .black)
        let images = self.images
        let rendered = await BlockingWork.run {
            MontageRenderer.renderPreview(tiles: layout(), canvas: canvas, size: size, look: look, images: images)
                .map(ImageBox.init)
        }
        preview = rendered?.image
    }

    // MARK: - Making the wallpaper

    /// Renders a montage for each target display and writes each into
    /// `folder`. Returns the files with the display each is for.
    func makeMontages(in folder: URL, date: Date) async throws -> [(url: URL, display: Display)] {
        phase = .working("Loading photos…")
        defer { phase = .editing }
        await waitForThumbnails()
        try Task.checkCancellation()
        let targets = self.targets
        let look = MontageRenderer.Look(style: style, background: ExportColor(background) ?? .black)
        let files = entries.map(\.url), aspects = aspectRatios
        var written: [(URL, Display)] = []
        for (number, display) in targets.enumerated() {
            phase = .working(targets.count > 1 ? "Drawing montage \(number + 1) of \(targets.count)…" : "Drawing montage…")
            let tiles = await BlockingWork.run(layoutJob(for: display))
            let image = try await MontageRenderer.render(tiles: tiles, canvas: display.pixelSize, look: look,
                                                         files: files, aspectRatios: aspects)
            try Task.checkCancellation()
            let name = MontageOutput.montageFileName(date: date, display: targets.count > 1 ? number + 1 : nil)
            written.append((try await MontageWriter.write(image, name: name, folder: folder), display))
        }
        return written
    }
}

/// Writes montages as JPEG (quality 0.9) through the file write queue.
enum MontageWriter {
    static func write(_ image: ImageBox, name: String, folder: URL) async throws -> URL {
        let options = ExportOptions(format: .jpeg, quality: 0.9, colorProfile: .original, keepMetadata: false)
        let job = FileWriteQueue.shared.enqueue {
            try await BlockingWork.run {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Decided just before writing, in the queue, so no other
                // write can take the name in between.
                let url = folder.appendingPathComponent(FileOperations.uniqueName(for: name, in: folder))
                try ImageEncoder.write(image.image, to: url, options: options, metadataSource: nil)
                return url
            }
        }
        return try await job.value.value
    }
}

extension NSScreen {
    /// The Core Graphics display this screen is, which ScreenCaptureKit and
    /// the montage's display list name screens by.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
