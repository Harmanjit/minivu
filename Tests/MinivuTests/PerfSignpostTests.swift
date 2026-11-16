import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// The app's own signposts and the thumbnail cache test runs use
/// (docs/feature-notes/perf.md).
@Suite struct PerfSignpostTests {
    /// A test run never thumbnails into the user's cache.
    @Test func testRunsKeepTheirThumbnailsInTheTemporaryFolder() {
        let url = AppServices.thumbnailStoreURL()
        #expect(url != ThumbnailStore.defaultURL)
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// A process's private cache is removed by the next process once the
    /// first has gone; a running one's is left alone, and so is anything
    /// else in the folder.
    @Test func privateThumbnailCachesOfEndedProcessesAreRemoved() throws {
        let t = try ScratchFolder()
        for pid: Int32 in [101, 202] {
            for suffix in ["", "-wal", "-shm"] {
                try t.file(AppServices.temporaryStoreURL(ofProcess: pid, in: t.url).lastPathComponent + suffix)
            }
        }
        try t.file("minivu-thumbnails-notes.txt")
        try t.file("other.sqlite")
        AppServices.removeTemporaryStores(in: t.url, isRunning: { $0 == 202 })
        let left = try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted()
        #expect(left == ["minivu-thumbnails-202.sqlite", "minivu-thumbnails-202.sqlite-shm", "minivu-thumbnails-202.sqlite-wal",
                         "minivu-thumbnails-notes.txt", "other.sqlite"])
    }

    /// The launch's bookmark step resolves what still resolves and leaves
    /// out a folder that has gone.
    @Test @MainActor func bookmarksResolveWithoutTheGoneFolder() throws {
        let t = try ScratchFolder()
        let kept = try t.folder("Kept"), gone = try t.folder("Gone")
        let datas = try [kept, gone].map { try $0.bookmarkData() }
        try FileManager.default.removeItem(at: gone)
        let resolved = BookmarkStore.resolve(datas, options: [])
        #expect(resolved.folders.map(\.standardizedFileURL.path) == [kept.standardizedFileURL.path])
        #expect(resolved.refreshed.count == 1)
    }
}

extension AppWindowTests {
    /// The main-thread monitor the benchmarks read counts only the timed
    /// windows, even when one busy spell runs across their edges. Serialized
    /// with the window suites: it blocks the main thread on purpose.
    @MainActor @Suite(.serialized) struct MainThreadMonitorTests {
        @Test func aBusySpellCountsOnlyInsideTheTimedWindow() async throws {
            let monitor = Bench.MainThreadMonitor()
            // Let its thread start pinging.
            try await Task.sleep(for: .milliseconds(20))
            // One unbroken 120 ms spell: 50 of setup, 30 timed, 40 after.
            usleep(50_000)
            let start = ContinuousClock.now
            monitor.counting(true)
            usleep(30_000)
            monitor.counting(false)
            // usleep may sleep longer on a busy machine: the window as it was.
            let window = Bench.milliseconds(ContinuousClock.now - start)
            usleep(40_000)
            // The ping sent before the spell is answered now.
            try await Task.sleep(for: .milliseconds(20))
            let main = monitor.stop()
            #expect(main.blocked >= window - 3 && main.blocked <= window, "counted \(main.blocked) ms of a \(window) ms window")
            #expect(main.stalls == 1)
        }

        @Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
            #expect(Bench.median([4, 1, 3, 2]) == 2.5)
            #expect(Bench.median([3, 1, 2]) == 2)
            #expect(Bench.median([]) == 0)
        }
    }
}

extension AppWindowTests {
    /// The grid's time to fill a screen and the viewer's flips are timed.
    /// Process-wide recordings, so with the other window suites.
    @MainActor @Suite(.serialized) struct PerfWindowSignpostTests {
        @Test func theGridTimesFillingAScreenAndTheViewerItsFlips() async throws {
            _ = NSApplication.shared
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 300, height: 200)
            let b = try t.jpeg("b.jpg", width: 200, height: 300)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            controller.showWindow(nil)

            Perf.startRecording()
            controller.open(folder: t.url)
            await controller.model.work?.value
            var fills = 0, finishes = 0
            await TestTiming.waitUntil {
                // Looked at without waiting for the end: stop, add up, start again.
                let recording = Perf.stopRecording()
                defer { Perf.startRecording() }
                fills += recording.durations["grid.fillScreen"]?.count ?? 0
                finishes += recording.durations["folder.finish"]?.count ?? 0
                return fills > 0
            }
            Perf.stopRecording()
            #expect(fills == 1)
            #expect(finishes >= 1)

            let entries = try [a, b].map { try #require(FolderEntry(url: $0)) }
            Perf.startRecording()
            ViewerWindowController.show(images: entries, index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.displayed?.entry == entries[0] && viewer.canvasTexture != nil }
            viewer.nextImage(nil)
            await TestTiming.waitUntil { viewer.displayed?.entry == entries[1] && viewer.canvasTexture != nil }
            let flips = Perf.stopRecording()
            #expect((flips.durations["viewer.flip"]?.count ?? 0) >= 2)
            #expect((flips.counts["file.open"] ?? 0) >= 2)
            #expect(!viewer.isLoadingPage)
        }

        /// While the benchmarks track frames, a canvas knows when its image
        /// has been drawn by the GPU, not only set; otherwise it notes
        /// nothing.
        @Test func theCanvasNotesWhichImageTheGPUFinishedDrawing() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try t.jpeg("a.jpg", width: 300, height: 200)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.displayed?.entry == entry && viewer.canvasTexture != nil }
            let canvas = viewer.canvasView
            ImageCanvasView.tracksPresentedFrames = false
            canvas.setNeedsRedraw()
            canvas.displayRefreshed()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!canvas.hasPresentedImage)

            ImageCanvasView.tracksPresentedFrames = true
            defer { ImageCanvasView.tracksPresentedFrames = false }
            canvas.setNeedsRedraw()
            canvas.displayRefreshed()
            await TestTiming.waitUntil { canvas.hasPresentedImage }
            #expect(canvas.hasPresentedImage)
        }

        /// Compare times its opening once, to every pane's photo, and each
        /// pane's load.
        @Test func compareTimesItsOpening() async throws {
            _ = NSApplication.shared
            let saved = CompareWindowController.catalog
            CompareWindowController.catalog = .inMemory()
            defer { CompareWindowController.catalog = saved }
            let t = try ScratchFolder()
            let entries = try ["a.jpg", "b.jpg"].map { try #require(FolderEntry(url: try t.jpeg($0, width: 300, height: 200))) }
            Perf.startRecording()
            CompareWindowController.show(entries: entries, allImages: entries)
            defer { CompareWindowController.current?.window?.close() }
            let controller = try #require(CompareWindowController.current)
            await TestTiming.waitUntil { controller.paneViews.allSatisfy(\.hasLoadedImage) }
            let recording = Perf.stopRecording()
            #expect(recording.durations["compare.open"]?.count == 1)
            #expect((recording.durations["compare.paneLoad"]?.count ?? 0) >= 1)
        }
    }
}
