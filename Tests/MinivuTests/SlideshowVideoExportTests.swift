import Testing
import AppKit
import AVFoundation
import MinivuCore
import MinivuRender
@testable import Minivu

/// Export Slideshow Video: the remembered choices, the plan made from
/// Settings > Slideshow, and whole exports written, read back with
/// AVFoundation (never played), cancelled and replaced.
@MainActor @Suite struct SlideshowVideoExportTests {
    /// Red, green and blue pictures.
    static func pictures(in folder: URL) throws -> [FolderEntry] {
        try [("a.png", 1.0, 0.0, 0.0), ("b.png", 0.0, 1.0, 0.0), ("c.png", 0.0, 0.0, 1.0)].map { name, r, g, b in
            try ContactSheetTests.png(name, in: folder, r, g, b, width: 160, height: 90)
        }
    }

    /// Two seconds of a quiet tone as a WAV file, written, never played.
    static func tone(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<88_200 { samples[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        return url
    }

    /// One second a slide, half-second transitions: five seconds for three.
    static var quickShow: SlideshowSettings {
        var settings = SlideshowSettings()
        settings.interval = 1
        settings.transitionDuration = 0.5
        settings.transition = .fixed(.push)
        return settings
    }

    /// 320 × 180 at 24 frames a second, as "Screen size" on a tiny screen.
    static var smallVideo: SlideshowVideoSettings {
        var settings = SlideshowVideoSettings()
        settings.resolution = .screen
        settings.frameRate = 24
        return settings
    }

    static let tinyScreen = CGSize(width: 320, height: 180)

    @Test func choicesAreRememberedAndRepaired() throws {
        let scratch = ScratchDefaults("minivu-slideshow-video-tests")
        defer { scratch.remove() }
        let store = SlideshowVideoSettingsStore(defaults: scratch.defaults)
        #expect(store.settings == SlideshowVideoSettings())
        var settings = store.settings
        settings.codec = .hevc
        settings.container = .mov
        settings.frameRate = 60
        settings.resolution = .uhd4K
        store.settings = settings
        #expect(SlideshowVideoSettingsStore(defaults: scratch.defaults).settings == settings)

        // A frame rate the dialog doesn't offer, and a codec from a later
        // version, load as the defaults; the rest is kept.
        let edited = #"{"resolution":"hd720","frameRate":25,"codec":"av1","quality":"high"}"#
        scratch.defaults.set(Data(edited.utf8), forKey: SlideshowVideoSettingsStore.key)
        let repaired = SlideshowVideoSettingsStore(defaults: scratch.defaults).settings
        #expect(repaired.resolution == .hd720 && repaired.frameRate == 30 && repaired.codec == .h264)
        #expect(repaired.quality == .high && repaired.container == .mp4)
        #expect(repaired.format(screen: nil) == SlideshowVideoFormat(width: 1280, height: 720, frameRate: 30,
                                                                    codec: .h264, container: .mp4, quality: .high))
    }

    @Test func playsInTheSlideshowsOrder() {
        var generator = SystemRandomNumberGenerator()
        // In order from the chosen picture, round to the one before it.
        #expect(SlideshowVideoPlanner.order(count: 5, start: 2, shuffled: false, generator: &generator) == [2, 3, 4, 0, 1])
        #expect(SlideshowVideoPlanner.order(count: 0, start: 0, shuffled: false, generator: &generator) == [])
        // Shuffled: the chosen picture first, each once.
        let shuffled = SlideshowVideoPlanner.order(count: 20, start: 7, shuffled: true, generator: &generator)
        #expect(shuffled.first == 7 && shuffled.sorted() == Array(0..<20))

        let fixed = SlideshowVideoPlanner.transitions(count: 3, choice: .fixed(.iris), generator: &generator)
        #expect(fixed == [.crossFade, .iris, .iris])
        let random = SlideshowVideoPlanner.transitions(count: 50, choice: .random, generator: &generator)
        #expect(random.first == .crossFade)
        #expect(zip(random.dropFirst(), random.dropFirst(2)).allSatisfy { $0 != $1 })
        #expect(Set(random).count > 3)
    }

    @Test func planFollowsTheSlideshowSettings() throws {
        let scratch = try ScratchFolder()
        var entries = try Self.pictures(in: scratch.url)
        let broken = try scratch.file("broken.png", bytes: 10)
        entries.insert(try #require(FolderEntry(url: broken)), at: 1)
        var settings = Self.quickShow
        settings.caption = .name
        var generator = SystemRandomNumberGenerator()
        let plan = SlideshowVideoPlanner.plan(images: entries, start: 2, settings: settings, music: [],
                                              enlargeSmallImages: true, display: DisplaySettings(),
                                              generator: &generator)
        // From the chosen picture round to the start; the unreadable file is left out.
        #expect(plan.slides.map(\.url.lastPathComponent) == ["b.png", "c.png", "a.png"])
        #expect(plan.slides.map(\.caption) == ["b.png", "c.png", "a.png"])
        #expect(plan.slides.map(\.transition) == [.crossFade, .push, .push])
        #expect(plan.interval == 1 && plan.transitionDuration == 0.5 && plan.enlargeSmallImages)
        #expect(SlideshowVideoPlanner.duration(count: 3, settings: settings, frameRate: 24) == 5)
    }

    @Test func exportsTheShowWithItsMusic() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        var settings = Self.quickShow
        settings.caption = .name
        settings.musicEnabled = true
        settings.playlist = [try #require(SlideshowPlaylistResolver.item(for: try Self.tone(in: scratch.url)))]
        let destination = output.appendingPathComponent("Trip Slideshow.mp4")
        var written: [URL] = []
        var reported: [Double] = []
        let released = SlideshowVideoURLs()
        let placed = try await SlideshowVideoExport.export(
            images: entries, start: 0, slideshow: settings, video: Self.smallVideo, screen: Self.tinyScreen,
            destination: destination, cancel: CancellationFlag(), enlargeSmallImages: true,
            display: DisplaySettings(),
            releaseMusic: { urls in released.append(urls); SlideshowPlaylistResolver.release(urls) },
            refreshBookmarks: { _ in }, didWrite: { written.append($0) },
            progress: { reported.append($0) })
        #expect(placed == destination && written == [destination])
        // Only the video in the folder: the scratch file was moved, not copied.
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["Trip Slideshow.mp4"])
        // The music's access is given back once the video is written.
        #expect(released.count == 1)

        let asset = AVURLAsset(url: destination)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 320, height: 180))
        #expect(abs(try await asset.load(.duration).seconds - 5) < 0.01)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await audio.load(.timeRange).duration.seconds - 5) < 0.1)
        await Task.yield()
        #expect(reported.isEmpty || reported.last! <= 1)
    }

    @Test func replacesTheChosenFile() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        let trash = try scratch.folder("Trash")
        let destination = output.appendingPathComponent("Show.mov")
        try Data("old".utf8).write(to: destination)
        var video = Self.smallVideo
        video.container = .mov
        _ = try await SlideshowVideoExport.export(
            images: entries, start: 0, slideshow: Self.quickShow, video: video, screen: Self.tinyScreen,
            destination: destination, cancel: CancellationFlag(), display: DisplaySettings(),
            trash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("old.mov")) },
            didWrite: { _ in })
        #expect(try Data(contentsOf: trash.appendingPathComponent("old.mov")) == Data("old".utf8))
        #expect(try await AVURLAsset(url: destination).load(.duration).seconds > 4)
    }

    @Test func cancellingLeavesNoFile() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        let destination = output.appendingPathComponent("Show.mp4")
        let cancel = CancellationFlag()
        // The second slide's decode presses Cancel, as the button would mid-way.
        let decodes = SlideshowVideoURLs()
        await #expect(throws: CancellationError.self) {
            _ = try await SlideshowVideoExport.export(
                images: entries, start: 0, slideshow: Self.quickShow, video: Self.smallVideo,
                screen: Self.tinyScreen, destination: destination, cancel: cancel, display: DisplaySettings(),
                decode: { url, size, settings in
                    decodes.append([url])
                    if decodes.count == 2 { cancel.cancel() }
                    return try SlideshowVideoWriter.defaultDecode(url, size, settings)
                }, didWrite: { _ in Issue.record("nothing is placed") })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    /// Planning reads every file's header; Cancel stops it part way, and
    /// the export then writes nothing.
    @Test func planningStopsWhenCancelled() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        var generator = SystemRandomNumberGenerator()
        var read = 0
        let plan = SlideshowVideoPlanner.plan(images: entries, start: 0, settings: Self.quickShow, music: [],
                                              enlargeSmallImages: true, display: DisplaySettings(),
                                              isReadable: { _ in read += 1; return true },
                                              isCancelled: { read >= 2 }, generator: &generator)
        // The third header is never read, and nothing is planned once cancelled.
        #expect(read == 2 && plan.slides.isEmpty)

        let output = try scratch.folder("Out")
        let cancel = CancellationFlag()
        cancel.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await SlideshowVideoExport.export(
                images: entries, start: 0, slideshow: Self.quickShow, video: Self.smallVideo,
                screen: Self.tinyScreen, destination: output.appendingPathComponent("Show.mp4"), cancel: cancel,
                display: DisplaySettings(),
                decode: { _, _, _ in Issue.record("nothing is decoded"); throw CancellationError() },
                didWrite: { _ in Issue.record("nothing is placed") })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    /// Internal storage only (DESIGN.md 1): a folder on another volume is
    /// refused before anything is read or written.
    @Test func refusesAFolderOffTheInternalStorage() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        await #expect(throws: ExternalVolumeError(folder: output)) {
            _ = try await SlideshowVideoExport.export(
                images: entries, start: 0, slideshow: Self.quickShow, video: Self.smallVideo,
                screen: Self.tinyScreen, destination: output.appendingPathComponent("Show.mp4"),
                cancel: CancellationFlag(), isAllowedVolume: { _ in false }, display: DisplaySettings(),
                decode: { _, _, _ in Issue.record("nothing is decoded"); throw CancellationError() },
                didWrite: { _ in Issue.record("nothing is placed") })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func dialogSummarisesTheShow() throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let defaults = ScratchDefaults("minivu-slideshow-video-tests")
        defer { defaults.remove() }
        let slideshowStore = SlideshowSettingsStore(defaults: defaults.defaults)
        slideshowStore.settings = Self.quickShow
        let model = SlideshowVideoModel(images: entries, start: 0, screen: Self.tinyScreen,
                                        store: SlideshowVideoSettingsStore(defaults: defaults.defaults),
                                        slideshowStore: slideshowStore)
        model.settings.resolution = .hd720
        #expect(model.summary(slideshow: slideshowStore.settings) == "3 pictures · 0:05 · 1280 × 720")
        #expect(SlideshowVideoSettingsStore(defaults: defaults.defaults).settings.resolution == .hd720)
        #expect(SlideshowVideoModel.slideshowLines(slideshowStore.settings)
                == ["Each slide for 1 s, Push transitions of 0.5 s", "In order, captions: none", "No music"])
        #expect(SlideshowVideoExport.suggestedName(for: entries, container: .mov)
                == "\(scratch.url.lastPathComponent) Slideshow.mov")
    }
}

/// The dialog itself, which opens windows: part of the serialized window suite.
extension AppWindowTests {
    @MainActor @Suite(.serialized) struct SlideshowVideoDialogTests {
        @Test func exportGoesThroughTheDialogAndTheSavePanel() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entries = try SlideshowVideoExportTests.pictures(in: scratch.url)
            let output = try scratch.folder("Out")
            let defaults = ScratchDefaults("minivu-slideshow-video-dialog-tests")
            defer { defaults.remove() }
            let slideshowStore = SlideshowSettingsStore(defaults: defaults.defaults)
            slideshowStore.settings = SlideshowVideoExportTests.quickShow
            let videoStore = SlideshowVideoSettingsStore(defaults: defaults.defaults)
            videoStore.settings = SlideshowVideoExportTests.smallVideo

            // The save panel is replaced: the first time it is cancelled,
            // the second it names a file.
            let original = SlideshowVideoExport.chooseDestination
            defer { SlideshowVideoExport.chooseDestination = original }
            var asked: [String] = []
            var answer: URL?
            SlideshowVideoExport.chooseDestination = { name, _, _, _, completion in
                asked.append(name)
                completion(answer)
            }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let controller = SlideshowVideoController(images: entries, start: 0,
                                                      screen: SlideshowVideoExportTests.tinyScreen,
                                                      startFolder: scratch.url, store: videoStore,
                                                      slideshowStore: slideshowStore)
            controller.begin(on: window)
            #expect(window.attachedSheet === controller.sheet)
            #expect(SlideshowVideoController.controller(for: window) === controller)

            // Cancel in the save panel comes back to the dialog.
            controller.export()
            #expect(SlideshowVideoController.controller(for: window) == nil)
            try await waitUntil { window.attachedSheet != nil }
            #expect(window.attachedSheet === controller.sheet)

            answer = output.appendingPathComponent("Show.mp4")
            controller.export()
            try await waitUntil { controller.work != nil }
            await controller.work?.value
            #expect(asked.count == 2 && asked.allSatisfy { $0.hasSuffix(" Slideshow.mp4") })
            #expect(controller.exported == answer)
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Show.mp4").path))
            #expect(window.attachedSheet == nil)
        }

        /// Tools > Export Slideshow Video… in the browser takes the pictures
        /// a slideshow would play, and is off while its dialog is up.
        @Test func browserCommandOpensTheDialogOnTheSlideshowsPictures() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entries = try SlideshowVideoExportTests.pictures(in: scratch.url)
            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            defer { controller.window?.close() }
            controller.open(folder: scratch.url)
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }

            let window = try #require(controller.window)
            #expect(controller.canPerformTools(.exportSlideshowVideo) == true)
            controller.exportSlideshowVideo(nil)
            let dialog = try #require(SlideshowVideoController.controller(for: window))
            defer { dialog.close() }
            // Nothing selected: every picture, from the first, as Start Slideshow plays them.
            #expect(dialog.model.images.map(\.url.lastPathComponent) == entries.map(\.url.lastPathComponent))
            #expect(dialog.model.start == 0)
            #expect(window.attachedSheet === dialog.sheet)
            #expect(controller.canPerformTools(.exportSlideshowVideo) == false)
        }

        /// Tools > Export Slideshow Video… in the viewer takes its whole list
        /// from the picture it shows, and is off while a sheet is up.
        @Test func viewerCommandOpensTheDialogOnTheWholeList() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entries = try SlideshowVideoExportTests.pictures(in: scratch.url)
            ViewerWindowController.show(images: entries, index: 1, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            let window = try #require(viewer.window)

            #expect(viewer.validateToolAction(.exportSlideshowVideo) == true)
            viewer.exportSlideshowVideo(nil)
            let dialog = try #require(SlideshowVideoController.controller(for: window))
            defer { dialog.close() }
            #expect(dialog.model.images.map(\.url) == entries.map(\.url))
            #expect(dialog.model.start == 1)
            #expect(window.attachedSheet === dialog.sheet)
            #expect(viewer.validateToolAction(.exportSlideshowVideo) == false)
            // A second command while the dialog is up stacks nothing.
            viewer.exportSlideshowVideo(nil)
            #expect(SlideshowVideoController.controller(for: window) === dialog)
        }

        /// The viewer's export leaves videos out, as its Start Slideshow
        /// does; shown on a video, the export starts at the next picture.
        @Test func viewerCommandLeavesVideosOut() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let pictures = try SlideshowVideoExportTests.pictures(in: scratch.url)
            let clip = scratch.url.appendingPathComponent("b2.mov")
            try Data([0]).write(to: clip)
            let video = try #require(FolderEntry(url: clip))
            let entries = [pictures[0], pictures[1], video, pictures[2]]
            ViewerWindowController.show(images: entries, index: 2, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            let window = try #require(viewer.window)

            viewer.exportSlideshowVideo(nil)
            let dialog = try #require(SlideshowVideoController.controller(for: window))
            defer { dialog.close() }
            #expect(dialog.model.images.map(\.url) == pictures.map(\.url))
            #expect(dialog.model.start == 2)
            #expect(viewer.validateToolAction(.startSlideshow) == false, "no full-screen show over a sheet")
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + TestTiming.limit(milliseconds: 2000)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

/// URLs collected from any thread.
final class SlideshowVideoURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[URL]] = []
    func append(_ urls: [URL]) { lock.withLock { values.append(urls) } }
    var count: Int { lock.withLock { values.count } }
}
