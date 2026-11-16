import Testing
import Foundation
@testable import MinivuCore

extension Benchmarks {
    /// Timings behind Find's choice of walking the tree over Spotlight (G3;
    /// docs/feature-notes/org.md). Runs only when MINIVU_BENCH_DIR points at
    /// the test assets, e.g.
    ///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter SearchBenchmark
    @Suite(.serialized) struct SearchBenchmark {
        static let folder = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

        /// 200 folders of 100 empty photos: the walk alone, at the image limit.
        @Test(.enabled(if: folder != nil)) func walkTwentyThousandFiles() throws {
            let t = try TemporaryFolder()
            for f in 0..<200 {
                let folder = t.url.appendingPathComponent("Day \(f)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for i in 0..<100 { FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG_\(i).jpg").path, contents: nil) }
            }
            let clock = ContinuousClock()
            var result: TreeEnumerator.Result?
            let elapsed = try clock.measure { result = try TreeEnumerator.images(under: t.url) }
            print(String(format: "walk: %d images in %d folders, %.0f ms", result?.images.count ?? 0,
                         result?.foldersListed ?? 0, Double(elapsed.components.attoseconds) / 1e15
                            + Double(elapsed.components.seconds) * 1000))
            var query = SearchQuery(scope: t.url, name: "img_99")
            query.minimumRating = 0
            let find = try clock.measure { _ = try ImageSearch.run(query, catalog: .inMemory()) }
            print(String(format: "find by name over the same tree: %.0f ms",
                         Double(find.components.attoseconds) / 1e15 + Double(find.components.seconds) * 1000))
        }

        /// Header reads for a metadata condition: cold, then from the catalog.
        @Test(.enabled(if: folder != nil)) func metadataColdThenCached() throws {
            let images = try TreeEnumerator.images(under: Self.folder!).images
            let catalog = Catalog.inMemory()
            let clock = ContinuousClock()
            let cold = clock.measure { _ = catalog.loadFilterMetadata(for: images) }
            let warm = clock.measure { _ = catalog.loadFilterMetadata(for: images) }
            func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            print(String(format: "metadata: %d files, cold %.0f ms (%.1f ms a file), cached %.1f ms", images.count,
                         ms(cold), ms(cold) / Double(max(images.count, 1)), ms(warm)))
        }

        // MARK: - For the performance study (docs/feature-notes/perf.md)

        /// The walk of 200 folders of 100 empty photos and Find by name over it,
        /// repeated, as BENCH lines.
        @Test(.enabled(if: Bench.enabled)) func walkAndFindByName() throws {
            let t = try TemporaryFolder()
            let folders = Bench.size(200, quick: 10)
            for f in 0..<folders {
                let folder = t.url.appendingPathComponent("Day \(f)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for i in 0..<100 { FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG_\(i).jpg").path, contents: nil) }
            }
            try Bench.measure("find", "walk\(folders * 100)", extra: "folders=\(folders)") {
                _ = try TreeEnumerator.images(under: t.url)
            }
            try Bench.measure("find", "byName\(folders * 100)", extra: "folders=\(folders)") {
                _ = try ImageSearch.run(SearchQuery(scope: t.url, name: "img_99"), catalog: .inMemory())
            }
        }

        /// Find across folders with a metadata condition (at least 4000 px
        /// wide), which reads every header: cold with a new catalog each run,
        /// then again with the catalog that cached them. The photos are clones
        /// of the test assets in ten folders, so after the first run the file
        /// system cache is warm either way: "cold" is the catalog's cache.
        @Test(.enabled(if: Self.folder != nil)) func findWithMetadataColdAndCached() throws {
            let sources = try FileManager.default.contentsOfDirectory(at: Bench.folder!, includingPropertiesForKeys: nil)
                .filter { ImageFormats.kind(of: $0) == .raster || ImageFormats.kind(of: $0) == .raw }
            let t = try TemporaryFolder()
            for f in 0..<Bench.size(10, quick: 2) {
                let folder = try t.folder("Folder \(f)")
                for source in sources {
                    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
                }
            }
            var criteria = MetadataCriteria()
            criteria.minimumWidth = 4000
            let query = SearchQuery(scope: t.url, criteria: criteria)
            var outcome: ImageSearch.Outcome?
            var catalog = Catalog.inMemory()
            // Where the time goes: each folder's filter, the header reads in
            // it, the catalog's cache looked up and written.
            func text(_ phases: Bench.Phases) -> String {
                let runs = Bench.runs()
                return String(format: "filter_ms=%.1f header_read_ms=%.2f header_reads=%.0f cache_lookup_ms=%.1f cache_store_ms=%.1f",
                              phases.perRun("search.filter", runs), phases.median("filter.metadataRead"),
                              phases.countPerRun("filter.metadataRead", runs), phases.perRun("filter.metadataCached", runs),
                              phases.perRun("filter.metadataStore", runs))
            }
            let cold = Bench.Phases()
            try Bench.measure("find", "metadataCold", extra: text(cold), setup: { catalog = Catalog.inMemory() },
                              timing: cold.timing) {
                outcome = try ImageSearch.run(query, catalog: catalog)
            }
            let cached = Bench.Phases()
            try Bench.measure("find", "metadataCached",
                              extra: "files=\(outcome?.scanned ?? 0) matches=\(outcome?.matches.count ?? 0) " + text(cached),
                              timing: cached.timing) {
                outcome = try ImageSearch.run(query, catalog: catalog)
            }
        }
    }
}
