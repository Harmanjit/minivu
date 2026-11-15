import AppKit
import Combine
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender

/// The Export Slideshow Video dialog's choices: how the video is encoded.
/// What it shows (timing, transitions, captions, music) is Settings >
/// Slideshow, so a video and a show of the same pictures agree.
///
/// One `Codable` value, as `SlideshowSettings`: a missing or unreadable
/// field takes its default, so settings saved by another version load.
nonisolated struct SlideshowVideoSettings: Codable, Equatable, Sendable {
    var resolution: SlideshowVideoResolution = .hd1080
    var frameRate = 30
    var codec: SlideshowVideoCodec = .h264
    var container: SlideshowVideoContainer = .mp4
    var quality: SlideshowVideoQuality = .medium

    init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, codec, container, quality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SlideshowVideoSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        resolution = value(.resolution, defaults.resolution)
        frameRate = value(.frameRate, defaults.frameRate)
        codec = value(.codec, defaults.codec)
        container = value(.container, defaults.container)
        quality = value(.quality, defaults.quality)
        self = validated
    }

    /// A frame rate other than 24, 30 or 60 becomes 30.
    var validated: SlideshowVideoSettings {
        var copy = self
        if !SlideshowVideoFormat.frameRates.contains(frameRate) { copy.frameRate = 30 }
        return copy
    }

    /// The encoder's format, for a screen of `screen` pixels (`.screen`).
    func format(screen: CGSize?) -> SlideshowVideoFormat {
        let size = resolution.pixelSize(screen: screen)
        return SlideshowVideoFormat(width: Int(size.width), height: Int(size.height), frameRate: validated.frameRate,
                                    codec: codec, container: container, quality: quality)
    }
}

/// Where the dialog's choices live: one key in a defaults store the caller
/// picks, so tests never touch the user's.
final class SlideshowVideoSettingsStore {
    nonisolated static let key = "slideshowVideoSettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: SlideshowVideoSettings {
        get {
            defaults.data(forKey: Self.key)
                .flatMap { try? JSONDecoder().decode(SlideshowVideoSettings.self, from: $0) } ?? SlideshowVideoSettings()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: Self.key) }
        }
    }
}

/// Turns Settings > Slideshow and a list of pictures into the plan of a
/// video: the order a show would play them in, the transition into each,
/// and the captions.
nonisolated enum SlideshowVideoPlanner {
    /// One pass of the show from `start`, as a looping show plays it before
    /// it repeats: shuffled with the starting picture first, or in order
    /// from it round to the one before it.
    static func order(count: Int, start: Int, shuffled: Bool,
                      generator: inout some RandomNumberGenerator) -> [Int] {
        let sequence = SlideshowSequence(count: count, start: start, shuffled: shuffled, loops: true,
                                         generator: &generator)
        let order = sequence.order
        guard order.indices.contains(sequence.position) else { return order }
        return Array(order[sequence.position...] + order[..<sequence.position])
    }

    /// The transition into each of `count` slides. A random choice never
    /// repeats the one before, as in the live show. The first slide fades in
    /// from black whatever is chosen (`SlideshowVideoTimeline`).
    static func transitions(count: Int, choice: SlideshowSettings.TransitionChoice,
                            generator: inout some RandomNumberGenerator) -> [SlideshowTransition] {
        var previous: SlideshowTransition?
        return (0..<count).map { index in
            guard index > 0 else { return .crossFade }
            switch choice {
            case .fixed(let transition):
                return transition
            case .random:
                let next = SlideshowTransition.random(after: previous, using: &generator)
                previous = next
                return next
            }
        }
    }

    /// The plan for `images` from `start`. Pictures `isReadable` turns down
    /// (no image in the file, as a show would find when it came to them) are
    /// left out. Reads each file's header, and metadata for captions that
    /// need it, so call it off the main thread. Stops early, with the slides
    /// planned so far, once `isCancelled` says so: a folder of thousands of
    /// pictures takes a while.
    static func plan(images: [FolderEntry], start: Int, settings: SlideshowSettings, music: [URL],
                     enlargeSmallImages: Bool, display: DisplaySettings,
                     isReadable: (URL) -> Bool = { ImageDecoder.info(for: $0) != nil },
                     summary: (URL) -> MetadataSummary? = { MetadataReader.summary(for: $0) },
                     isCancelled: () -> Bool = { false },
                     generator: inout some RandomNumberGenerator) -> SlideshowVideoPlan {
        var ordered: [FolderEntry] = []
        for index in order(count: images.count, start: start, shuffled: settings.order == .shuffle,
                           generator: &generator) {
            if isCancelled() { break }
            if isReadable(images[index].url) { ordered.append(images[index]) }
        }
        let kinds = transitions(count: ordered.count, choice: settings.transition, generator: &generator)
        let style = settings.caption
        var slides: [SlideshowVideoPlan.Slide] = []
        for (entry, kind) in zip(ordered, kinds) {
            if isCancelled() { break }
            let summary = SlideshowCaptionText.needsMetadata(style) ? summary(entry.url) : nil
            slides.append(SlideshowVideoPlan.Slide(url: entry.url, transition: kind,
                                                   caption: SlideshowCaptionText.text(style: style, name: entry.name,
                                                                                      modified: entry.modified,
                                                                                      summary: summary)))
        }
        return SlideshowVideoPlan(slides: slides, interval: settings.interval,
                                  transitionDuration: settings.transitionDuration,
                                  enlargeSmallImages: enlargeSmallImages, music: music, display: display)
    }

    /// The video's length for `count` pictures, for the dialog.
    static func duration(count: Int, settings: SlideshowSettings, frameRate: Int) -> TimeInterval {
        SlideshowVideoTimeline(slideCount: count, frameRate: frameRate, interval: settings.interval,
                               transitionDuration: settings.transitionDuration).duration.seconds
    }
}

/// Exporting a slideshow video: planning it, writing it off the main thread
/// into a scratch folder on the destination's volume, and moving the
/// finished file into place through `FileWriteQueue`, so a cancelled or
/// failed export leaves nothing at the destination.
enum SlideshowVideoExport {
    /// Writes the video of `images` from `start` with `slideshow`'s
    /// settings, encoded as `video` says, to `destination` (the file the
    /// save panel named; it already asked before replacing one). `progress`
    /// gets the fraction done on the main actor; `didWrite` is told of the
    /// file placed. Throws `CancellationError` once `cancel` is set, and
    /// `ExternalVolumeError` for a folder `isAllowedVolume` refuses (internal
    /// storage only, DESIGN.md 1), before anything is read or written.
    static func export(images: [FolderEntry], start: Int, slideshow: SlideshowSettings, video: SlideshowVideoSettings,
                       screen: CGSize?, destination: URL, cancel: CancellationFlag,
                       isAllowedVolume: @escaping @Sendable (URL) -> Bool = VolumePolicy.isAllowed,
                       enlargeSmallImages: Bool = Preferences.shared.enlargeSmallImages,
                       display: DisplaySettings = AppServices.images.settings,
                       resolveMusic: @escaping @Sendable ([SlideshowSettings.PlaylistItem]) -> ResolvedPlaylist
                           = SlideshowPlaylistResolver.resolve,
                       releaseMusic: @escaping @Sendable ([URL]) -> Void = SlideshowPlaylistResolver.release,
                       refreshBookmarks: ([UUID: Data]) -> Void = { SlideshowSettingsStore.shared.refreshPlaylistBookmarks($0) },
                       decode: @escaping SlideshowVideoWriter.Decode = SlideshowVideoWriter.defaultDecode,
                       trash: @escaping ContactSheetExport.Trasher = ContactSheetExport.systemTrash,
                       didWrite: @MainActor (URL) -> Void = SavePresenter.didWrite,
                       progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        let format = video.format(screen: screen)
        let folder = destination.deletingLastPathComponent()
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard await BlockingWork.run({ isAllowedVolume(folder) }) else { throw ExternalVolumeError(folder: folder) }

        // The songs are files the user chose in Settings, reached through
        // their bookmarks, and held only while the video is written.
        let playlist = slideshow.playsMusic
            ? await BlockingWork.run { resolveMusic(slideshow.playlist) } : ResolvedPlaylist(tracks: [], scopedURLs: [])
        defer { releaseMusic(playlist.scopedURLs) }
        if !playlist.refreshedBookmarks.isEmpty { refreshBookmarks(playlist.refreshedBookmarks) }

        let plan = await BlockingWork.run { () -> SlideshowVideoPlan in
            var generator = SystemRandomNumberGenerator()
            let music = SlideshowPlaylist(tracks: playlist.tracks, shuffled: slideshow.shuffleMusic,
                                          generator: &generator).tracks
            return SlideshowVideoPlanner.plan(images: images, start: start, settings: slideshow, music: music,
                                              enlargeSmallImages: enlargeSmallImages, display: display,
                                              isCancelled: { cancel.isCancelled }, generator: &generator)
        }
        guard !cancel.isCancelled else { throw CancellationError() }

        let scratch = try await BlockingWork.run { try ContactSheetExport.scratchFolder(for: destination) }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(destination.lastPathComponent)
        try await SlideshowVideoWriter.write(plan, format: format, to: temp, decode: decode,
                                             isCancelled: { cancel.isCancelled },
                                             progress: { fraction in Task { @MainActor in progress(fraction) } })
        guard !cancel.isCancelled else { throw CancellationError() }

        let job = FileWriteQueue.shared.enqueue(replacing: [destination]) {
            try await BlockingWork.run {
                try ContactSheetExport.place(temp, at: destination, replacing: true, trash: trash)
            }
        }
        let placed = try await job.value.value
        didWrite(placed)
        return placed
    }

    /// "Trip Slideshow.mp4", after the pictures' folder.
    static func suggestedName(for images: [FolderEntry], container: SlideshowVideoContainer) -> String {
        let folder = images.first.map { FileManager.default.displayName(atPath: $0.url.deletingLastPathComponent().path) }
        let base = folder.map { "\($0) Slideshow" } ?? "Slideshow"
        return "\(base).\(container.fileExtension)"
    }

    /// Asks where to save with a save panel as a sheet on `window`, and
    /// calls `completion` with the file, or nil when cancelled. Tests
    /// replace it, so no panel opens.
    static var chooseDestination: (_ name: String, _ container: SlideshowVideoContainer, _ startFolder: URL?,
                                   _ window: NSWindow, _ completion: @escaping (URL?) -> Void) -> Void = {
        name, container, startFolder, window, completion in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(container.typeIdentifier)].compactMap { $0 }
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let startFolder { panel.directoryURL = startFolder }
        // The panel holds its delegate weakly; the completion keeps it.
        let delegate = InternalVolumesOnly()
        panel.delegate = delegate
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(delegate) {}
            completion(response == .OK ? panel.url : nil)
        }
    }
}
