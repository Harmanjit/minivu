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
        }
    }
}
