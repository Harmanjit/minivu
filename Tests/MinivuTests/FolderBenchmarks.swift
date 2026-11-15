import Testing
import AppKit
import MinivuCore
@testable import Minivu

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

/// Opening a folder: each step on its own, then the browser model end to
/// end, at 1,000, 10,000 and 20,000 files; and the flat view of a tree.
@MainActor @Suite(.serialized) struct FolderOpenBenchmark {
    static let sizes = Bench.quick ? [200, 1_000] : [1_000, 10_000, 20_000]

    /// `count` one-byte photos in a folder of their own (listing, healing
    /// and marks never decode), a quarter rated in a catalog on disk.
    func folder(_ count: Int, in scratch: ScratchFolder) throws -> (folder: URL, catalogFile: URL) {
        let folder = try scratch.folder("Photos \(count)")
        let urls = (0..<count).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
        let byte = Data([0])
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: byte) }
        let file = scratch.url.appendingPathComponent("catalog-\(count).sqlite")
        let catalog = try Catalog(url: file)
        catalog.setRating(3, for: urls.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
        return (folder, file)
    }

    func model(catalog: Catalog, marks: FileMarksCache) -> BrowserModel {
        BrowserModel(invalidate: { _ in }, watchesFolder: false, catalog: catalog, fileMarksCache: marks)
    }

    @Test(.enabled(if: Bench.enabled)) func folderOpen() async throws {
        let scratch = try ScratchFolder()
        for count in Self.sizes {
            let (folder, catalogFile) = try folder(count, in: scratch)
            let catalog = try Catalog(url: catalogFile)
            let suite = "folder\(count)"

            // The steps, as the listing runs them off the main thread.
            var contents: FolderContents?
            try Bench.measure(suite, "list") { contents = try FolderListing.contents(of: folder) }
            let images = try #require(contents).images
            try Bench.measure(suite, "heal") { catalog.heal(folder: folder) }
            var rows: [String: Catalog.Marks] = [:]
            try Bench.measure(suite, "marks") { rows = BrowserModel.marksByKey(images, in: catalog) }
            // The lstat pass over files without a row: a cache that has
            // never read them (every launch), then one that has.
            var cache = FileMarksCache()
            try Bench.measure(suite, "fileMarksCold", setup: { cache = FileMarksCache() }) {
                _ = BrowserModel.cachedFileMarks(images, without: rows, in: cache)
            }
            for image in images where rows[image.name] == nil { _ = cache.marks(for: image.url) }
            try Bench.measure(suite, "fileMarksWarm") { _ = BrowserModel.cachedFileMarks(images, without: rows, in: cache) }
            let marks = BrowserModel.shownMarks(rows: rows, files: [:])
            for key in [SortKey.name, .modified, .rating] {
                try Bench.measure(suite, "sort_\(key.rawValue)") {
                    _ = FolderSnapshot(contents: try #require(contents), order: FileSortOrder(key: key), marks: marks)
                }
            }

            // End to end through the model: the cold launch (a new catalog
            // connection, whose first heal scans the Trash's rows, and a
            // file-marks cache that knows nothing), then reloads.
            var model: BrowserModel?
            try await Bench.measure(suite, "openColdLaunch", warmups: 0, runs: Bench.runs(5), setup: {
                model = self.model(catalog: try Catalog(url: catalogFile), marks: FileMarksCache())
            }) {
                model?.navigate(to: folder)
                await model?.work?.value
            }
            let shown = try #require(model)
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure(suite, "reload", runs: Bench.runs(7), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(7) + 1)
                return String(format: "finish_ms=%.2f applyFilter_ms=%.2f %@ entries=%d",
                              recording.total("folder.finish") / runs, recording.total("folder.applyFilter") / runs,
                              monitor.stopText(runs: Bench.runs(7)), shown.entries.count)
            }(), timing: monitor.counting) {
                shown.reload()
                await shown.work?.value
            }
        }
    }

    /// The window's grid included: what the main thread does when a big
    /// folder arrives (the grid's reload and first layout among it).
    @Test(.enabled(if: Bench.enabled)) func folderOpenInTheWindow() async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
        defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
        let scratch = try ScratchFolder()
        let controller = BrowserWindowController()
        defer { controller.window?.close() }
        _ = controller.grid.view
        for count in Self.sizes {
            let (folder, _) = try folder(count, in: scratch)
            let empty = try scratch.folder("Empty \(count)")
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure("folder\(count)", "openInWindow", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                // Every other finish is the empty folder's, which comes first.
                let finishes = recording.durations["folder.finish"] ?? []
                let big = finishes.indices.filter { $0 % 2 == 1 }.map { finishes[$0] }.sorted()
                return String(format: "finish_ms_median=%.2f %@", big.isEmpty ? 0 : big[big.count / 2], monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                controller.open(folder: empty)
                await controller.model.work?.value
            }, timing: monitor.counting) {
                controller.open(folder: folder)
                await controller.model.work?.value
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            }
        }
    }

    /// The flat view of a tree of 200 folders of 100 photos: the walk, the
    /// partial lists shown every 250 ms while it runs, and the end.
    @Test(.enabled(if: Bench.enabled)) func flatViewOfATree() async throws {
        let scratch = try ScratchFolder()
        let folders = Bench.size(200, quick: 10)
        let byte = Data([0])
        for f in 0..<folders {
            let folder = try scratch.folder("Day \(f)")
            for i in 0..<100 {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG_\(i).jpg").path, contents: byte)
            }
        }
        var model = BrowserModel(invalidate: { _ in }, watchesFolder: false, catalog: .inMemory(),
                                 fileMarksCache: FileMarksCache())
        Perf.startRecording()
        let monitor = Bench.MainThreadMonitor()
        try await Bench.measure("flat\(folders * 100)", "open", runs: Bench.runs(5), extra: {
            let recording = Perf.stopRecording()
            let runs = Double(Bench.runs(5) + 1)
            return String(format: "partials_per_open=%.1f partial_main_ms=%.2f partial_sort_ms=%.2f finish_ms=%.2f %@",
                          Double(recording.durations["flat.showPartial"]?.count ?? 0) / runs,
                          recording.total("flat.showPartial") / runs, recording.total("flat.partialSort") / runs,
                          recording.total("folder.finish") / runs, monitor.stopText(runs: Bench.runs(5)))
        }(), setup: {
            model = BrowserModel(invalidate: { _ in }, watchesFolder: false, catalog: .inMemory(),
                                 fileMarksCache: FileMarksCache())
            model.flatView = true
        }, timing: monitor.counting) {
            model.navigate(to: scratch.url)
            await model.work?.value
        }
    }
}

/// The grid's dimensions line: one header read per file on one queue.
@MainActor @Suite(.serialized) struct PixelSizeCacheBenchmark {
    @Test(.enabled(if: Bench.jpeg != nil)) func throughput() async throws {
        let scratch = try ScratchFolder()
        let count = Bench.size(500, quick: 20)
        let photos = try Bench.clones(of: try #require(Bench.jpeg), count: count, in: scratch.url)
        let entries = photos.compactMap(FolderEntry.init(url:))
        try await Bench.measure("pixelSizes", "read\(count)", runs: Bench.runs(5), extra: "files=\(count)") {
            let cache = PixelSizeCache()
            let left = Countdown(entries.count)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                for entry in entries {
                    _ = cache.request(entry) { _ in
                        left.count -= 1
                        if left.count == 0 { done.resume() }
                    }
                }
            }
        }
    }

    @MainActor final class Countdown {
        var count: Int
        init(_ count: Int) { self.count = count }
    }
}

extension AppWindowTests {
    /// Copying, moving, renaming and trashing many files as the browser
    /// does, with the catalog in memory (MINIVU_CATALOG=memory) and nothing
    /// ever put in the user's Trash.
    @MainActor @Suite(.serialized, .batchToolsReset) struct FilesBenchmark {
        init() { _ = NSApplication.shared }

        func photos(_ count: Int, in folder: URL) {
            let byte = Data(count: 2048)
            for i in 0..<count {
                FileManager.default.createFile(atPath: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i)).path,
                                               contents: byte)
            }
        }

        /// Copy and move of 100 and 1,000 files from one folder to another.
        @Test(.enabled(if: Bench.enabled)) func copyAndMove() async throws {
            for count in [Bench.size(100, quick: 20), Bench.size(1_000, quick: 50)] {
                for isMove in [false, true] {
                    let scratch = try ScratchFolder()
                    var round = 0
                    var source = scratch.url, destination = scratch.url
                    Perf.startRecording()
                    let monitor = Bench.MainThreadMonitor()
                    try await Bench.measure("files", "\(isMove ? "move" : "copy")\(count)", runs: Bench.runs(5), extra: {
                        let recording = Perf.stopRecording()
                        let runs = Double(Bench.runs(5) + 1)
                        return String(format: "item_ms=%.3f catalog_ms_each=%.3f transactions_per_file=%.2f notifications_per_file=%.2f catalogChanged_main_ms=%.2f %@",
                                      recording.total("transfer.item") / (runs * Double(count)),
                                      recording.total("transfer.catalog") / (runs * Double(count)),
                                      Double(recording.counts["sqlite.transaction"] ?? 0) / (runs * Double(count)),
                                      Double(recording.counts["catalog.didChange"] ?? 0) / (runs * Double(count)),
                                      recording.total("browser.catalogChanged") / runs, monitor.stopText(runs: Bench.runs(5)))
                    }(), setup: {
                        round += 1
                        source = try scratch.folder("From \(round)")
                        destination = try scratch.folder("To \(round)")
                        photos(count, in: source)
                    }, timing: monitor.counting) {
                        let files = (0..<count).map { source.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)) }
                        _ = await FileTransfer.run(FileTransfer.Request(files: files, destination: destination, isMove: isMove),
                                                   window: nil)
                        // The catalog's notifications reach the main thread.
                        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
                    }
                }
            }
        }

        /// The same with a browser window showing the destination, whose
        /// model reads marks again for every notification.
        @Test(.enabled(if: Bench.enabled)) func moveIntoAShownFolder() async throws {
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let count = Bench.size(1_000, quick: 50)
            let scratch = try ScratchFolder()
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            var round = 0
            var source = scratch.url, destination = scratch.url
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure("files", "move\(count)Shown", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "catalogChanged_main_ms=%.2f catalogChanged_calls=%.0f %@",
                              recording.total("browser.catalogChanged") / runs,
                              Double(recording.durations["browser.catalogChanged"]?.count ?? 0) / runs, monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                round += 1
                source = try scratch.folder("From \(round)")
                destination = try scratch.folder("To \(round)")
                photos(count, in: source)
                controller.open(folder: destination)
                await controller.model.work?.value
            }, timing: monitor.counting) {
                let files = (0..<count).map { source.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)) }
                _ = await FileTransfer.run(FileTransfer.Request(files: files, destination: destination, isMove: true),
                                           window: nil)
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
                await Bench.waitUntil { controller.model.entries.count == count }
            }
        }

        /// Batch Rename of 1,000 files through the window, as the sheet's
        /// Rename button runs it, to the grid showing the new names.
        @Test(.enabled(if: Bench.enabled)) func batchRename() async throws {
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let count = Bench.size(1_000, quick: 50)
            let scratch = try ScratchFolder()
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            var round = 0
            var folder = scratch.url
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure("files", "rename\(count)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "perform_ms=%.1f invalidate_main_ms=%.2f %@", recording.total("rename.perform") / runs,
                              recording.total("rename.invalidate") / runs, monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                round += 1
                folder = try scratch.folder("Batch \(round)")
                photos(count, in: folder)
                controller.open(folder: folder)
                await controller.model.work?.value
            }, timing: monitor.counting) {
                let requests = (0..<count).map {
                    BatchRenamer.Request(url: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)),
                                         newName: String(format: "Holiday %04d.jpg", $0))
                }
                controller.performBatchRename(requests, actionName: BatchRenameModel.actionName(count: count))
                await controller.batchWork?.value
                await Bench.waitUntil { controller.model.entries.first?.name.hasPrefix("Holiday") == true }
            }
        }

        /// Move to Trash of 100 selected files out of 1,000, through the
        /// window, with a folder in the scratch folder standing in for the
        /// Trash (the write queue's test seam).
        @Test(.enabled(if: Bench.enabled)) func moveToTrash() async throws {
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let scratch = try ScratchFolder()
            let bin = try scratch.folder("Bin")
            let savedTrash = FileWriteQueue.shared.putInTrash
            defer { FileWriteQueue.shared.putInTrash = savedTrash }
            FileWriteQueue.shared.putInTrash = { urls in
                var moved: [URL: URL] = [:]
                for url in urls {
                    let place = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: place)
                    moved[url] = place
                }
                return moved
            }
            let total = Bench.size(1_000, quick: 50), selected = Bench.size(100, quick: 10)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            var round = 0
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure("files", "trash\(selected)Of\(total)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "move_ms=%.1f catalog_ms=%.1f %@", recording.total("trash.move") / runs,
                              recording.total("trash.catalog") / runs, monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                round += 1
                let folder = try scratch.folder("Folder \(round)")
                photos(total, in: folder)
                controller.open(folder: folder)
                await controller.model.work?.value
                let chosen = controller.model.entries.prefix(selected).map(\.url)
                controller.model.setSelection(Set(chosen), lead: chosen.first)
            }, timing: monitor.counting) {
                controller.moveToTrash(nil)
                await Bench.waitUntil { controller.model.entries.count == total - selected }
            }
        }
    }
}
