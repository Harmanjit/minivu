import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

/// The catalog's folder reads: a folder's marks in one query, and healing.
@Suite(.serialized) struct CatalogBenchmark {
    /// `count` empty photos in a folder of their own, a quarter of them rated
    /// in a catalog on disk (the app's is never in memory).
    func folder(_ count: Int, in scratch: TemporaryFolder) throws -> (urls: [URL], catalog: Catalog, file: URL) {
        let folder = try scratch.folder("Photos \(count)")
        let urls = (0..<count).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = scratch.url.appendingPathComponent("catalog-\(count).sqlite")
        let catalog = try Catalog(url: file)
        catalog.setRating(3, for: urls.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
        return (urls, catalog, file)
    }

    @Test(.enabled(if: Bench.enabled)) func marksAndHeal() throws {
        let scratch = try TemporaryFolder()
        for count in [Bench.size(5_000, quick: 500), Bench.size(20_000, quick: 1_000)] {
            let (urls, catalog, file) = try folder(count, in: scratch)
            let folder = urls[0].deletingLastPathComponent()
            try Bench.measure("catalog", "marks\(count)", extra: "files=\(count) rows=\((count + 3) / 4)") {
                _ = catalog.marks(for: urls)
            }
            // The first heal of a launch also scans the Trash's rows: a new
            // catalog on the same file, each run.
            var fresh: Catalog?
            try Bench.measure("catalog", "healFirst\(count)", warmups: 0, extra: "files=\(count)",
                          setup: { fresh = try Catalog(url: file) }) {
                fresh?.heal(folder: folder)
            }
            try Bench.measure("catalog", "heal\(count)", extra: "files=\(count)") {
                catalog.heal(folder: folder)
            }
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
                             "write_ms_each=\(String(format: "%.2f", recording.total("thumb.storeWrite") / Double(max(decode.count, 1))))")
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
