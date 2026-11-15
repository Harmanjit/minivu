import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

extension Benchmarks {
    /// The catalog's folder reads: a folder's marks in one query, and healing.
    @Suite(.serialized) struct CatalogBenchmark {
        /// `count` empty photos in a folder of their own, a quarter of them
        /// rated in a catalog on disk (the app's is never in memory), which
        /// also has rows for files Replace sent to the Trash: a scratch
        /// folder whose path holds "/.Trash", as the catalog recognises the
        /// Trash by path. Half of those files have since gone (emptied).
        func folder(_ count: Int, in scratch: TemporaryFolder) throws -> (urls: [URL], file: URL, trashRows: Int) {
            let folder = try scratch.folder("Photos \(count)")
            let urls = (0..<count).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
            for url in urls { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let trash = try scratch.folder(".Trash \(count)")
            let trashed = (0..<max(10, count / 20)).map { trash.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
            for url in trashed { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = scratch.url.appendingPathComponent("catalog-\(count).sqlite")
            do {
                let catalog = try Catalog(url: file)
                catalog.setRating(3, for: urls.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
                catalog.setRating(2, for: trashed)
            }
            for (i, url) in trashed.enumerated() where i % 2 == 1 { try FileManager.default.removeItem(at: url) }
            return (urls, file, trashed.count)
        }

        /// A new connection to a copy of the catalog as `folder` made it: a
        /// first heal stamps the gone Trash rows missing, and the first heal
        /// of a later connection to the same file would skip them.
        func freshCopy(of file: URL) throws -> Catalog {
            let copy = file.deletingLastPathComponent().appendingPathComponent("run-\(UUID().uuidString).sqlite")
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
                try FileManager.default.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
            }
            return try Catalog(url: copy)
        }

        @Test(.enabled(if: Bench.enabled)) func marksAndHeal() throws {
            let scratch = try TemporaryFolder()
            for count in [Bench.size(5_000, quick: 500), Bench.size(20_000, quick: 1_000)] {
                let (urls, file, trashRows) = try folder(count, in: scratch)
                let catalog = try freshCopy(of: file)
                let folder = urls[0].deletingLastPathComponent()
                try Bench.measure("catalog", "marks\(count)", extra: "files=\(count) rows=\((count + 3) / 4)") {
                    _ = catalog.marks(for: urls)
                }
                // The first heal of a launch also lstats the Trash's rows: a
                // new connection to a fresh copy of the catalog each run.
                var fresh: Catalog?
                Perf.startRecording()
                try Bench.measure("catalog", "healFirst\(count)", warmups: 0, extra: {
                    let recording = Perf.stopRecording()
                    return "files=\(count) trash_rows=\(trashRows) heals=\(recording.durations["catalog.heal"]?.count ?? 0)"
                }(), setup: { fresh = try freshCopy(of: file) }) {
                    fresh?.heal(folder: folder)
                }
                try Bench.measure("catalog", "heal\(count)", extra: "files=\(count)") {
                    catalog.heal(folder: folder)
                }
            }
        }

        /// The two catalog reads the main thread makes when the library
        /// changes: the sidebar's smart folders and collections
        /// (`SidebarViewController.reloadLibrary`, which also runs at
        /// launch), and the collections as Add to Collection's menu opens
        /// (`BrowserOrganise`). 20 collections of 500 members (each count
        /// is of members still where the catalog last saw them) and 10
        /// smart folders, catalog on disk.
        @Test(.enabled(if: Bench.enabled)) func libraryReadsOnTheMainThread() throws {
            let scratch = try TemporaryFolder()
            let (urls, file, _) = try folder(Bench.size(10_000, quick: 500), in: scratch)
            let catalog = try freshCopy(of: file)
            let collections = Bench.size(20, quick: 4), members = Bench.size(500, quick: 50)
            for c in 0..<collections {
                let id = try #require(catalog.createCollection(named: "Collection \(c)"))
                catalog.addToCollection(id, urls: Array(urls.dropFirst(c * 37).prefix(members)))
            }
            for f in 0..<10 {
                _ = catalog.saveSmartFolder(named: "Smart \(f)", query: SearchQuery(scope: scratch.url, minimumRating: f % 5))
            }
            try Bench.measure("catalog", "sidebarLibrary", runs: Bench.runs(10),
                              extra: "collections=\(collections) members=\(members) smart_folders=10") {
                _ = catalog.smartFolders()
                _ = catalog.collections()
            }
            try Bench.measure("catalog", "collectionsMenu", runs: Bench.runs(10)) { _ = catalog.collections() }
        }

        /// The first heal does lstat each Trash row and stamps the gone ones
        /// missing, so `healFirst` times what it says.
        @Test(.enabled(if: Bench.enabled)) func theFirstHealStampsGoneTrashRows() throws {
            let scratch = try TemporaryFolder()
            let (urls, file, trashRows) = try folder(200, in: scratch)
            let catalog = try freshCopy(of: file)
            let gone = { (try? catalog.db.query(
                "SELECT COUNT(*) AS n FROM files WHERE instr(path, '/.Trash') > 0 AND missing_since IS NOT NULL").first?
                .int("n")) ?? -1 }
            #expect(gone() == 0)
            catalog.heal(folder: urls[0].deletingLastPathComponent())
            #expect(gone() == Int64(trashRows / 2))
        }
    }

    /// The parts of a launch in MinivuCore, each on its own: the catalog
    /// opened (its schema made or checked), the thumbnail store opened (the
    /// first run makes it with a VACUUM), and the store's prune, whose total
    /// is a scan of every row at every launch.
    @Suite(.serialized) struct StoreLaunchBenchmark {
        @Test(.enabled(if: Bench.enabled)) func catalogAndThumbnailStore() throws {
            let scratch = try TemporaryFolder()
            var round = 0
            try Bench.measure("launch", "catalogOpenNew", runs: Bench.runs(7)) {
                round += 1
                _ = try Catalog(url: scratch.url.appendingPathComponent("new-\(round).sqlite"))
            }
            // A catalog of 20,000 rated files, opened again.
            let rows = Bench.size(20_000, quick: 500)
            let existing = scratch.url.appendingPathComponent("existing.sqlite")
            do {
                let catalog = try Catalog(url: existing)
                catalog.setRating(3, for: (0..<rows).map { URL(fileURLWithPath: String(format: "/bench/IMG_%05d.jpg", $0)) })
            }
            try Bench.measure("launch", "catalogOpenExisting", runs: Bench.runs(7), extra: "rows=\(rows)") {
                _ = try Catalog(url: existing)
            }

            try Bench.measure("launch", "thumbnailStoreOpenNew", runs: Bench.runs(7)) {
                round += 1
                _ = try ThumbnailStore(url: scratch.url.appendingPathComponent("thumbs-new-\(round).sqlite"))
            }

            // A store of real-sized thumbnails (a photo's when there is one).
            let picture = Bench.jpeg.flatMap { ImageDecoder.thumbnail(for: $0, maxPixelSize: 512) }
                ?? TestImages.gradient(width: 512, height: 341)
            let data = try #require(ThumbnailStore.encode(picture))
            let thumbnails = Bench.size(5_000, quick: 200)
            let storeFile = scratch.url.appendingPathComponent("thumbs.sqlite")
            do {
                let store = try ThumbnailStore(url: storeFile)
                for i in 0..<thumbnails {
                    store.store(encoded: data, for: URL(fileURLWithPath: "/bench/IMG_\(i).jpg"), modified: Date(),
                                fileSize: 1000, tier: 512)
                }
            }
            let mb = Double(data.count * thumbnails) / 1_048_576
            try Bench.measure("launch", "thumbnailStoreOpenExisting", runs: Bench.runs(7), extra: "rows=\(thumbnails)") {
                _ = try ThumbnailStore(url: storeFile)
            }
            let store = try ThumbnailStore(url: storeFile)
            // Under the limit, as nearly every launch: the total alone.
            try Bench.measure("launch", "thumbnailPruneScan", runs: Bench.runs(7),
                              extra: String(format: "rows=%d mb=%.0f", thumbnails, mb)) {
                // The app's limit (AppServices.thumbnailCacheLimit).
                store.prune(maxBytes: 1_000_000_000)
            }
            // Over it: a tenth of the rows deleted, from a fresh copy each run.
            var copy: ThumbnailStore?
            try Bench.measure("launch", "thumbnailPruneTenth", warmups: 0, runs: Bench.runs(5),
                              extra: String(format: "rows=%d mb=%.0f", thumbnails, mb), setup: {
                copy = nil
                round += 1
                let target = scratch.url.appendingPathComponent("prune-\(round).sqlite")
                try FileManager.default.copyItem(at: storeFile, to: target)
                copy = try ThumbnailStore(url: target)
            }) {
                copy?.prune(maxBytes: data.count * thumbnails * 9 / 10)
            }
        }
    }

    /// A screenful of thumbnails through the real `ThumbnailService`, with its
    /// worker count, from files (cold: an empty store) and from the store
    /// (warm: an empty memory cache), per format.
    @Suite(.serialized) struct ThumbnailBenchmark {
        static let cells = Bench.size(60, quick: 8)

        func screenful(_ entries: [FolderEntry], store: ThumbnailStore) async -> (ms: Double, delivered: Int) {
            let service = ThumbnailService(store: store)
            let start = ContinuousClock.now
            let delivered = await withTaskGroup(of: Bool.self) { group in
                for entry in entries {
                    group.addTask {
                        await withCheckedContinuation { done in
                            service.request(entry, pixelSize: 256) { done.resume(returning: $0 != nil) }
                        }
                    }
                }
                return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            return (Bench.milliseconds(ContinuousClock.now - start), delivered)
        }

        /// One format: a fresh store every cold run, the filled one for warm runs.
        func run(_ format: String, _ source: URL, scratch: TemporaryFolder) async throws {
            let folder = scratch.url.appendingPathComponent(format, isDirectory: true)
            let entries = try Bench.clones(of: source, count: Self.cells, in: folder).compactMap(FolderEntry.init(url:))
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
            var cold: [Double] = [], delivered = 0
            var store: ThumbnailStore?
            for run in 0...Bench.runs(5) {
                let url = scratch.url.appendingPathComponent("thumbs-\(format)-\(run).sqlite")
                store = try ThumbnailStore(url: url)
                Perf.startRecording()
                let result = await screenful(entries, store: store!)
                let recording = Perf.stopRecording()
                delivered = result.delivered
                if run > 0 { cold.append(result.ms) }   // the first is the warm-up
                if run == Bench.runs(5) {
                    let decode = recording.durations["thumb.decode"] ?? []
                    Bench.report("thumbs", "\(format)ColdDecodeEach", decode,
                                 String(format: "write_ms_each=%.2f lock_wait_ms_each=%.2f encode_ms_each=%.2f",
                                        recording.total("thumb.storeWrite") / Double(max(decode.count, 1)),
                                        recording.total("thumb.diskLockWait") / Double(max(decode.count, 1)),
                                        Bench.median(recording.durations["thumb.encode"] ?? [])))
                }
            }
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Bench.report("thumbs", "\(format)Cold", cold,
                         "cells=\(Self.cells) delivered=\(delivered) workers=\(workers) file_mb=\(String(format: "%.1f", Double(size) / 1e6))")
            guard let store else { return }
            var warm: [Double] = []
            for run in 0...Bench.runs(7) {
                let result = await screenful(entries, store: store)
                if run > 0 { warm.append(result.ms) }
            }
            Bench.report("thumbs", "\(format)Warm", warm, "cells=\(Self.cells) workers=\(workers)")
        }

        @Test(.enabled(if: Bench.folder != nil)) func screenfulPerFormat() async throws {
            let scratch = try TemporaryFolder()
            if let jpeg = Bench.jpeg {
                try await run("jpeg", jpeg, scratch: scratch)
                // A PNG of the same 24 MP photo, written once into the scratch folder.
                if let decoded = try? ImageDecoder.decode(jpeg) {
                    let png = TestImages.write(decoded.image, to: scratch.url.appendingPathComponent("source.png"), type: .png)
                    try await run("png", png, scratch: scratch)
                }
            }
            if let heic = Bench.heic { try await run("heic", heic, scratch: scratch) }
            if let nef = Bench.nef { try await run("nef", nef, scratch: scratch) }
            let movie = try await TestVideos.make(at: scratch.url.appendingPathComponent("source.mov"),
                                                  width: 1920, height: 1080, seconds: 3)
            try await run("video", movie, scratch: scratch)
        }

        /// One thumbnail's row written to the store on disk, an autocommit
        /// INSERT, as each worker writes it.
        @Test(.enabled(if: Bench.enabled)) func storeWriteEach() throws {
            let scratch = try TemporaryFolder()
            let store = try ThumbnailStore(url: scratch.url.appendingPathComponent("thumbs.sqlite"))
            // A real photo's thumbnail when there is one: its JPEG is several
            // times the size of a gradient's.
            let picture = Bench.jpeg.flatMap { ImageDecoder.thumbnail(for: $0, maxPixelSize: 256) }
                ?? TestImages.gradient(width: 256, height: 171)
            let data = try #require(ThumbnailStore.encode(picture))
            let count = Bench.size(500, quick: 20)
            let modified = Date()
            var samples: [Double] = []
            for i in 0..<count {
                let file = URL(fileURLWithPath: "/bench/IMG_\(i).jpg")
                let start = ContinuousClock.now
                store.store(encoded: data, for: file, modified: modified, fileSize: 1000, tier: 256)
                samples.append(Bench.milliseconds(ContinuousClock.now - start))
            }
            Bench.report("thumbs", "storeWriteEach", Array(samples.dropFirst(5)), "kb=\(data.count / 1024)")
            var reads: [Double] = []
            for i in 0..<count {
                let file = URL(fileURLWithPath: "/bench/IMG_\(i).jpg")
                let start = ContinuousClock.now
                _ = store.image(for: file, modified: modified, fileSize: 1000, tier: 256)
                reads.append(Bench.milliseconds(ContinuousClock.now - start))
            }
            Bench.report("thumbs", "storeReadEach", Array(reads.dropFirst(5)), "kb=\(data.count / 1024)")
        }
    }

    /// The info panel's read and Count Colors, on the 24 MP photo.
    @Suite(.serialized) struct PhotoInfoBenchmark {
        @Test(.enabled(if: Bench.jpeg != nil)) func infoPanelAndCountColors() throws {
            let photo = try #require(Bench.jpeg)
            try Bench.measure("info", "sectionsAndFields", runs: Bench.runs(10)) {
                _ = MetadataReader.sectionsAndFields(for: photo)
            }
            try Bench.measure("info", "summary", runs: Bench.runs(10)) { _ = MetadataReader.summary(for: photo) }
            // The header read every decode, Save and batch file starts with,
            // the HDR check (gain map look-ups and a lazy image) included.
            try Bench.measure("info", "imageInfo", runs: Bench.runs(10)) { _ = ImageDecoder.info(for: photo) }
            if let heic = Bench.heic {
                try Bench.measure("info", "imageInfoHEIC", runs: Bench.runs(10)) { _ = ImageDecoder.info(for: heic) }
            }

            // Count Colors as the histogram panel runs it: the header, a full
            // SDR decode, then the count.
            var decoded: DecodedImage?
            try Bench.measure("colors", "decode", runs: Bench.runs(5)) {
                _ = ImageDecoder.info(for: photo)
                decoded = try ImageDecoder.decode(photo, allowHDR: false)
            }
            let image = try #require(decoded?.image)
            var count = 0
            let peak = Bench.FootprintPeak()
            try Bench.measure("colors", "count", runs: Bench.runs(5), extra: {
                let memory = peak.stop()
                return String(format: "colors=%d pixels=%d peak_mb=%.0f start_mb=%.0f", count, image.width * image.height,
                              memory.peak, memory.start)
            }()) {
                count = try ColorCounter.countUniqueColors(in: image, isCancelled: { false })
            }
        }
    }
}
