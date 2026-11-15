import Testing
import Foundation
@testable import MinivuCore

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
}
