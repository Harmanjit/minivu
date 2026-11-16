import Testing
import AppKit
import MinivuCore
@testable import Minivu

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

extension AppWindowTests {
    /// The phases of a launch that the app's own code runs and a test can
    /// run in-process, one at a time, without launching the app: the
    /// sidebar's bookmarks resolved, and the browser window made and shown.
    /// The catalog and thumbnail store opens are in MinivuCoreTests, the GPU
    /// warm-up in MinivuRenderTests; the whole launch, from the kernel
    /// starting the process, is MINIVU_TRACE's stderr lines.
    @MainActor @Suite(.serialized) struct WindowLaunchBenchmark {
        /// Ten sidebar folders' bookmarks resolved and opened for access, as
        /// `BookmarkStore` does at launch. Security-scoped where the process
        /// may make them; a test process outside the sandbox may only make
        /// plain ones, resolved the same way without the scope (`scoped=`).
        @Test(.enabled(if: Bench.enabled)) func bookmarks() throws {
            let scratch = try ScratchFolder()
            let count = 10
            let folders = try (0..<count).map { try scratch.folder("Favourite \($0)") }
            let scoped = (try? folders[0].bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)) != nil
            let datas = try folders.map {
                try $0.bookmarkData(options: scoped ? .withSecurityScope : [], includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
            }
            var resolved = 0
            try Bench.measure("launch", "bookmarks\(count)", runs: Bench.runs(10),
                              extra: "scoped=\(scoped ? "yes" : "no") resolved=\(resolved)") {
                let found = BookmarkStore.resolve(datas, options: scoped ? .withSecurityScope : [])
                resolved = found.folders.count
                for folder in found.folders { folder.stopAccessingSecurityScopedResource() }
            }
            #expect(resolved == count)
        }

        /// The browser window made, shown and drawn with no folder in it,
        /// as `applicationDidFinishLaunching` shows it before the first
        /// folder is listed. The first of the process is reported apart
        /// (`first_ms`): its classes, nibs and fonts load then, as at a
        /// launch; the runs after it are a window made again.
        @Test(.enabled(if: Bench.enabled)) func browserWindowShown() throws {
            _ = NSApplication.shared
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            var samples: [Double] = []
            for _ in 0...Bench.runs(5) {
                let start = ContinuousClock.now
                let controller = BrowserWindowController()
                controller.showWindow(nil)
                Bench.display(controller.window)
                samples.append(Bench.milliseconds(ContinuousClock.now - start))
                #expect(controller.window?.isVisible == true)
                controller.window?.close()
            }
            Bench.report("launch", "browserWindowShown", Array(samples.dropFirst()),
                         String(format: "first_ms=%.1f", samples[0]))
        }
    }
}
