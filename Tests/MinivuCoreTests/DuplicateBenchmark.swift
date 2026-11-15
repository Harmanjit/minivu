import Testing
import Foundation
@testable import MinivuCore

/// Timings behind the duplicate finder's limits (G5; docs/feature-notes/org.md).
/// Runs only when MINIVU_BENCH_DIR is set (any folder of photos), e.g.
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter DuplicateBenchmark
@Suite(.serialized) struct DuplicateBenchmark {
    static let folder = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// Comparing every print with every other, at the 8 GB Mac's limit and
    /// at the walk's: random unit vectors the length of a revision 2 print.
    @Test(.enabled(if: folder != nil)) func indexTenAndTwentyThousandPrints() {
        var state: UInt64 = 1
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) % 2000) / 1000 - 1
        }
        for n in [10_000, 20_000] {
            let prints = (0..<n).map { _ -> FeaturePrint in
                let v = (0..<768).map { _ in random() }
                let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
                return FeaturePrint(revision: 2, vector: v.map { $0 / norm })
            }
            let clock = ContinuousClock()
            var index: SimilarityIndex?
            let build = clock.measure { index = SimilarityIndex(prints: prints, maximumDistance: SimilarityIndex.thresholdRange.upperBound) }
            let regroup = clock.measure { _ = index?.groups(threshold: SimilarityIndex.defaultThreshold) }
            print(String(format: "index of %d prints: %.0f ms, regroup %.1f ms, %d pairs", n, Self.ms(build),
                         Self.ms(regroup), index?.pairs.count ?? 0))
        }
    }

    /// Prints of real photos: cold (thumbnail-sized decodes and Vision),
    /// then from the cache; and hashing them all.
    @Test(.enabled(if: folder != nil)) func printsAndHashesColdThenCached() throws {
        let images = try TreeEnumerator.images(under: Self.folder!).images
        let store = try ThumbnailStore.inMemory()
        let clock = ContinuousClock()
        let cold = clock.measure { _ = DuplicateFinder.featurePrints(for: images, store: store) }
        let warm = clock.measure { _ = DuplicateFinder.featurePrints(for: images, store: store) }
        let bytes = images.reduce(0) { $0 + $1.fileSize }
        let hash = clock.measure { for image in images { _ = try? ContentHash.sha256(of: image.url) } }
        print(String(format: "prints of %d photos: cold %.0f ms (%.1f ms each), cached %.1f ms; hashing %.0f MB: %.0f ms",
                     images.count, Self.ms(cold), Self.ms(cold) / Double(max(images.count, 1)), Self.ms(warm),
                     Double(bytes) / 1e6, Self.ms(hash)))
    }
}
