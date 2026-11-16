import Testing
import AppKit
import MinivuCore
@testable import Minivu

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`. All of them
// under AppWindowTests: they share the process-wide `Perf` recording with
// the window suites, and a benchmark beside another would time both.

extension AppWindowTests {
    /// Opening a folder: each step on its own, then the browser model end to
    /// end, at 1,000, 10,000 and 20,000 files; the window's part; the first
    /// screen of thumbnails; the header reads a filter or a rating sort
    /// starts; the flat view of a tree; and Find shown in the browser.
    @MainActor @Suite(.serialized) struct FolderOpenBenchmark {
        static let sizes = Bench.quick ? [200, 1_000] : [1_000, 10_000, 20_000]

        /// A folder of one-byte photos (listing, healing and marks never
        /// decode), a quarter rated, in a catalog on disk that also has rows
        /// for files minivu's Replace sent to the Trash.
        struct Fixture {
            let folder: URL
            let catalogFile: URL
            /// Rows under the Trash, half of whose files have since gone.
            let trashRows: Int
        }

        func folder(_ count: Int, in scratch: ScratchFolder) throws -> Fixture {
            let folder = try scratch.folder("Photos \(count)")
            let urls = (0..<count).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
            let byte = Data([0])
            for url in urls { FileManager.default.createFile(atPath: url.path, contents: byte) }
            // The first heal of a launch lstats every Trash row the catalog
            // has not stamped missing. A scratch folder whose path holds
            // "/.Trash" stands in for the Trash: the catalog knows it by path.
            let trash = try scratch.folder(".Trash \(count)")
            let trashed = (0..<max(10, count / 20)).map { trash.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
            for url in trashed { FileManager.default.createFile(atPath: url.path, contents: byte) }
            let file = scratch.url.appendingPathComponent("catalog-\(count).sqlite")
            do {
                let catalog = try Catalog(url: file)
                catalog.setRating(3, for: urls.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
                catalog.setRating(2, for: trashed)
            }
            // Emptied from the Trash since.
            for (i, url) in trashed.enumerated() where i % 2 == 1 { try FileManager.default.removeItem(at: url) }
            return Fixture(folder: folder, catalogFile: file, trashRows: trashed.count)
        }

        /// A new connection to a copy of the fixture's catalog as it was
        /// made: a first heal stamps the gone Trash rows, and a later first
        /// heal of the same file would no longer look at them.
        func freshCatalog(_ fixture: Fixture) throws -> Catalog {
            let copy = fixture.catalogFile.deletingLastPathComponent()
                .appendingPathComponent("run-\(UUID().uuidString).sqlite")
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: fixture.catalogFile.path + suffix) {
                try FileManager.default.copyItem(atPath: fixture.catalogFile.path + suffix, toPath: copy.path + suffix)
            }
            return try Catalog(url: copy)
        }

        func model(catalog: Catalog, marks: FileMarksCache, order: FileSortOrder = FileSortOrder()) -> BrowserModel {
            BrowserModel(sortOrder: order, invalidate: { _ in }, watchesFolder: false, catalog: catalog, fileMarksCache: marks)
        }

        /// Copies of the photo folder's photos and RAW files, `count` of
        /// them in `folder`, round robin.
        func realPhotos(_ count: Int, in folder: URL) throws {
            let sources = try FileManager.default.contentsOfDirectory(at: try #require(Bench.folder),
                                                                       includingPropertiesForKeys: nil)
                .filter { ImageFormats.kind(of: $0) == .raster || ImageFormats.kind(of: $0) == .raw }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            try #require(!sources.isEmpty)
            for i in 0..<count {
                let source = sources[i % sources.count]
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(
                    String(format: "IMG_%05d.%@", i, source.pathExtension)))
            }
        }

        @Test(.enabled(if: Bench.enabled)) func folderOpen() async throws {
            let scratch = try ScratchFolder()
            for count in Self.sizes {
                let fixture = try folder(count, in: scratch)
                let folder = fixture.folder
                let catalog = try Catalog(url: fixture.catalogFile)
                let suite = "folder\(count)"

                // The steps, as the listing runs them off the main thread.
                var contents: FolderContents?
                try Bench.measure(suite, "list") { contents = try FolderListing.contents(of: folder) }
                let images = try #require(contents).images
                // A launch's first heal, with its Trash scan: a new catalog
                // connection each run. Then the heals after it.
                var fresh: Catalog?
                try Bench.measure(suite, "healFirst", warmups: 0, extra: "trash_rows=\(fixture.trashRows)",
                                  setup: { fresh = try freshCatalog(fixture) }) {
                    fresh?.heal(folder: folder)
                }
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

                // End to end through the model: first with a new catalog
                // connection (its first heal scans the Trash rows) and a
                // file-marks cache that knows nothing, as the first folder
                // after a launch; then reloads. Not a launch itself: the
                // launch benchmarks time its other phases.
                var model: BrowserModel?
                try await Bench.measure(suite, "openFreshCatalog", warmups: 0, runs: Bench.runs(5),
                                        extra: "trash_rows=\(fixture.trashRows)", setup: {
                    model = self.model(catalog: try freshCatalog(fixture), marks: FileMarksCache())
                }) {
                    model?.navigate(to: folder)
                    await model?.work?.value
                }
                let shown = try #require(model)
                #expect(shown.entries.count == count)
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

        /// The shown window's part: what the main thread does when a big
        /// folder arrives, the grid's reload, layout and drawing among it.
        @Test(.enabled(if: Bench.enabled)) func folderOpenInTheWindow() async throws {
            _ = NSApplication.shared
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let scratch = try ScratchFolder()
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            controller.showWindow(nil)
            for count in Self.sizes {
                let fixture = try folder(count, in: scratch)
                let empty = try scratch.folder("Empty \(count)")
                // Only the big folder's: each run's recording starts after
                // the empty folder is shown.
                var finishes: [Double] = []
                let monitor = Bench.MainThreadMonitor()
                try await Bench.measure("folder\(count)", "openInWindow", runs: Bench.runs(5), extra: {
                    String(format: "finish_ms=%.2f %@", Bench.median(finishes), monitor.stopText(runs: Bench.runs(5)))
                }(), setup: {
                    controller.open(folder: empty)
                    await controller.model.work?.value
                    Bench.display(controller.window)
                    Perf.startRecording()
                }, timing: monitor.counting) {
                    controller.open(folder: fixture.folder)
                    await controller.model.work?.value
                    Bench.display(controller.window)
                    finishes += Perf.stopRecording().durations["folder.finish"] ?? []
                }
                #expect(controller.model.entries.count == count)
            }
        }

        /// From opening a folder of photos in a shown window to every
        /// visible cell showing its thumbnail, drawn: cold (photos never
        /// thumbnailed, so decoded, encoded and written to the store) and
        /// warm (the same folder again, its thumbnails in memory). The 24 MP
        /// photo when there is one, else a flat 1800 x 1200 JPEG.
        @Test(.enabled(if: Bench.enabled)) func firstScreenOfThumbnails() async throws {
            _ = NSApplication.shared
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let scratch = try ScratchFolder()
            let one = try Bench.jpeg ?? scratch.jpeg("one.jpg", width: 1800, height: 1200)
            let count = Bench.size(200, quick: 30)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            controller.showWindow(nil)
            let grid = controller.grid
            let empty = try scratch.folder("Empty")
            func settled() -> Bool {
                let visible = grid.collectionView.visibleItems()
                return !visible.isEmpty && visible.allSatisfy { ($0 as? ThumbnailCell)?.isThumbnailSettled ?? true }
            }
            var folder = empty, round = 0
            for (label, isCold) in [("firstScreenCold", true), ("firstScreenWarm", false)] {
                var fills: [Double] = [], decodes = 0, visible = 0
                let monitor = Bench.MainThreadMonitor()
                try await Bench.measure("grid", label, runs: Bench.runs(5), extra: {
                    String(format: "fill_signpost_ms=%.1f visible=%d decodes_per_run=%.1f %@", Bench.median(fills), visible,
                           Double(decodes) / Double(Bench.runs(5) + 1), monitor.stopText(runs: Bench.runs(5)))
                }(), setup: {
                    controller.open(folder: empty)
                    await controller.model.work?.value
                    Bench.display(controller.window)
                    if isCold || round == 0 {
                        round += 1
                        folder = try scratch.folder("Photos \(round)")
                        _ = try Bench.clones(of: one, count: count, in: folder)
                    }
                    Perf.startRecording()
                }, timing: monitor.counting) {
                    controller.open(folder: folder)
                    await controller.model.work?.value
                    Bench.display(controller.window)
                    #expect(await Bench.waitUntil { settled() })
                    Bench.display(controller.window)
                    let recording = Perf.stopRecording()
                    fills += recording.durations["grid.fillScreen"] ?? []
                    decodes += recording.durations["thumb.decode"]?.count ?? 0
                    visible = grid.collectionView.visibleItems().count
                }
            }
        }

        /// What reading headers costs a folder of real photos: the metadata
        /// filter (at least 4000 px wide) with the catalog's cache empty,
        /// and the sort by rating over files with no catalog row, whose
        /// marks are read from the files. Both read in chunks off the main
        /// thread, each chunk a filter and a grid update on it.
        @Test(.enabled(if: Bench.jpeg != nil)) func filterAndRatingSortReadHeaders() async throws {
            let scratch = try ScratchFolder()
            let count = Bench.size(1_000, quick: 40)
            let folder = try scratch.folder("Photos")
            try realPhotos(count, in: folder)
            let suite = "folder\(count)Photos"
            var criteria = MetadataCriteria()
            criteria.minimumWidth = 4000

            var model: BrowserModel?
            var chunks: [Double] = [], applies: [Double] = []
            var monitor = Bench.MainThreadMonitor()
            try await Bench.measure(suite, "metadataFilterOpen", runs: Bench.runs(5), extra: {
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "chunks_per_open=%.1f chunk_ms=%.1f applyFilter_main_ms=%.2f shown=%d %@",
                              Double(chunks.count) / runs, Bench.median(chunks), applies.reduce(0, +) / runs,
                              model?.entries.count ?? 0, monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                let fresh = self.model(catalog: .inMemory(), marks: FileMarksCache())
                fresh.metadataFilter = criteria
                model = fresh
                Perf.startRecording()
            }, timing: monitor.counting) {
                let shown = try #require(model)
                shown.navigate(to: folder)
                await shown.work?.value
                await shown.filterMetadataWork?.value
                let recording = Perf.stopRecording()
                chunks += recording.durations["folder.metadataChunk"] ?? []
                applies += recording.durations["folder.applyFilter"] ?? []
            }
            #expect(!chunks.isEmpty)

            chunks = []
            applies = []
            monitor = Bench.MainThreadMonitor()
            try await Bench.measure(suite, "ratingSortOpen", runs: Bench.runs(5), extra: {
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "chunks_per_open=%.1f chunk_ms=%.1f applyFilter_main_ms=%.2f %@",
                              Double(chunks.count) / runs, Bench.median(chunks), applies.reduce(0, +) / runs,
                              monitor.stopText(runs: Bench.runs(5)))
            }(), setup: {
                model = self.model(catalog: .inMemory(), marks: FileMarksCache(), order: FileSortOrder(key: .rating))
                Perf.startRecording()
            }, timing: monitor.counting) {
                let shown = try #require(model)
                shown.navigate(to: folder)
                await shown.work?.value
                // Each read is scheduled on the main queue and chains on the
                // one before: wait until no newer one has started.
                var reading: Task<Void, Never>?
                repeat {
                    await Bench.mainQueueTurn()
                    reading = shown.fileMarksWork
                    await reading?.value
                    await Bench.mainQueueTurn()
                } while shown.fileMarksWork != reading
                let recording = Perf.stopRecording()
                chunks += recording.durations["folder.fileMarksChunk"] ?? []
                applies += recording.durations["folder.applyFilter"] ?? []
            }
            #expect(!chunks.isEmpty)
        }

        /// The flat view of a tree of 200 folders of 100 photos: the walk,
        /// the partial lists shown every 250 ms while it runs, and the end.
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
            var model = self.model(catalog: .inMemory(), marks: FileMarksCache())
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
                model = self.model(catalog: .inMemory(), marks: FileMarksCache())
                model.flatView = true
            }, timing: monitor.counting) {
                model.navigate(to: scratch.url)
                await model.work?.value
            }
        }

        /// Find across folders, as the browser shows its results: a
        /// condition on the pixel width over real photos, so every header is
        /// read, with the partial lists sorted and shown every 250 ms. Cold
        /// with a new catalog each run, then with the catalog that cached
        /// the headers.
        @Test(.enabled(if: Bench.jpeg != nil)) func findInTheBrowser() async throws {
            let scratch = try ScratchFolder()
            let folders = Bench.size(20, quick: 2), perFolder = Bench.size(50, quick: 10)
            for f in 0..<folders { try realPhotos(perFolder, in: try scratch.folder("Trip \(f)")) }
            var criteria = MetadataCriteria()
            criteria.minimumWidth = 4000
            let list = VirtualList(kind: .search(SearchQuery(scope: scratch.url, criteria: criteria)), title: "Find")
            var catalog = Catalog.inMemory()
            var model = self.model(catalog: catalog, marks: FileMarksCache())
            for (label, isCold) in [("metadataCold", true), ("metadataCached", false)] {
                Perf.startRecording()
                let monitor = Bench.MainThreadMonitor()
                try await Bench.measure("findInBrowser\(folders * perFolder)", label, runs: Bench.runs(5), extra: {
                    let recording = Perf.stopRecording()
                    let runs = Double(Bench.runs(5) + 1)
                    return String(format: "filter_ms=%.1f header_reads_per_run=%.0f partials_per_run=%.1f "
                                      + "partial_main_ms=%.2f matches=%d %@",
                                  recording.total("search.filter") / runs,
                                  Double(recording.durations["filter.metadataRead"]?.count ?? 0) / runs,
                                  Double(recording.durations["flat.showPartial"]?.count ?? 0) / runs,
                                  recording.total("flat.showPartial") / runs, model.entries.count,
                                  monitor.stopText(runs: Bench.runs(5)))
                }(), setup: {
                    if isCold { catalog = Catalog.inMemory() }
                    model = self.model(catalog: catalog, marks: FileMarksCache())
                }, timing: monitor.counting) {
                    model.show(list: list)
                    await model.work?.value
                }
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

        /// A browser window, shown, as the user has it.
        func shownBrowser() -> BrowserWindowController {
            let controller = BrowserWindowController()
            controller.showWindow(nil)
            return controller
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
                        return String(format: "item_ms=%.3f catalog_ms_each=%.3f transactions_per_file=%.2f "
                                          + "notifications_per_file=%.2f catalogChanged_main_ms=%.2f %@",
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
                        await Bench.mainQueueTurn()
                    }
                }
            }
        }

        /// The same with a browser window showing the destination, whose
        /// model reads marks again for every notification, to the grid
        /// drawn with every file in it.
        @Test(.enabled(if: Bench.enabled)) func moveIntoAShownFolder() async throws {
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let count = Bench.size(1_000, quick: 50)
            let scratch = try ScratchFolder()
            let controller = shownBrowser()
            defer { controller.window?.close() }
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
                Bench.display(controller.window)
            }, timing: monitor.counting) {
                let files = (0..<count).map { source.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)) }
                _ = await FileTransfer.run(FileTransfer.Request(files: files, destination: destination, isMove: true),
                                           window: nil)
                await Bench.mainQueueTurn()
                #expect(await Bench.waitUntil { controller.model.entries.count == count })
                Bench.display(controller.window)
            }
        }

        /// Batch Rename of 1,000 files through the window, as the sheet's
        /// Rename button runs it, to the grid drawn with the new names.
        @Test(.enabled(if: Bench.enabled)) func batchRename() async throws {
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let count = Bench.size(1_000, quick: 50)
            let scratch = try ScratchFolder()
            let controller = shownBrowser()
            defer { controller.window?.close() }
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
                Bench.display(controller.window)
            }, timing: monitor.counting) {
                let requests = (0..<count).map {
                    BatchRenamer.Request(url: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)),
                                         newName: String(format: "Holiday %04d.jpg", $0))
                }
                controller.performBatchRename(requests, actionName: BatchRenameModel.actionName(count: count))
                await controller.batchWork?.value
                #expect(await Bench.waitUntil { controller.model.entries.first?.name.hasPrefix("Holiday") == true })
                Bench.display(controller.window)
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
            let controller = shownBrowser()
            defer { controller.window?.close() }
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
                Bench.display(controller.window)
            }, timing: monitor.counting) {
                controller.moveToTrash(nil)
                #expect(await Bench.waitUntil { controller.model.entries.count == total - selected })
                Bench.display(controller.window)
            }
        }

        /// Writes queued behind each other: twenty photo-sized files
        /// replaced at once through the write queue, as a Save, marks
        /// written into files and a Batch Convert might all queue together.
        /// How long a write waits for its turn, and the whole.
        @Test(.enabled(if: Bench.enabled)) func writeQueueContention() async throws {
            let scratch = try ScratchFolder()
            let count = Bench.size(20, quick: 4)
            let data = Data(count: 8_000_000)
            var round = 0
            Perf.startRecording()
            try await Bench.measure("files", "writeQueue\(count)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let queued = recording.durations["write.queued"] ?? []
                return String(format: "queued_ms=%.1f queued_max_ms=%.1f job_ms=%.1f mb_each=8", Bench.median(queued),
                              queued.max() ?? 0, Bench.median(recording.durations["write.job"] ?? []))
            }()) {
                round += 1
                let folder = try scratch.folder("Writes \(round)")
                let jobs = (0..<count).map { i in
                    let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
                    return FileWriteQueue.shared.enqueue(replacing: [url]) {
                        try await BlockingWork.run { try SafeFileWriter.write(data, to: url) }
                    }
                }
                for job in jobs { _ = try await job.value }
            }
        }
    }
}
