import Testing
import Foundation
import CoreGraphics
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

    // MARK: - For the performance study (docs/feature-notes/perf.md)

    /// Find Duplicates on 200 photos: exact (hashing every file of a size
    /// shared with another) and similar (feature prints, then the index).
    /// The photos are 3000 x 2000 JPEGs made for the run, one in four an
    /// exact copy of another, one in four a lightly changed one. Cold runs
    /// start from an empty store; cached runs reuse its hashes and prints.
    @Test(.enabled(if: Bench.enabled)) func exactAndSimilarOnTwoHundred() throws {
        let t = try TemporaryFolder()
        let count = Bench.size(200, quick: 12)
        var urls: [URL] = []
        for i in 0..<count {
            let url = t.url.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            if i % 4 == 1 {
                try FileManager.default.copyItem(at: urls[i - 1], to: url)
            } else {
                let base = i % 4 == 2 ? i - 2 : i
                TestImages.write(Self.photo(seed: base, tint: i % 4 == 2 ? 0.03 : 0), to: url)
            }
            urls.append(url)
        }
        let entries = urls.compactMap(FolderEntry.init(url:))
        let bytes = entries.reduce(0) { $0 + $1.fileSize }
        var store = try ThumbnailStore.inMemory()
        var groups = 0
        try Bench.measure("duplicates", "exactCold", setup: { store = try ThumbnailStore.inMemory() }) {
            groups = DuplicateFinder.exactGroups(in: entries, cache: store).count
        }
        try Bench.measure("duplicates", "exactCached",
                      extra: "files=\(count) groups=\(groups) mb=\(String(format: "%.0f", Double(bytes) / 1e6))") {
            groups = DuplicateFinder.exactGroups(in: entries, cache: store).count
        }
        var prints: [URL: FeaturePrint] = [:]
        try Bench.measure("duplicates", "similarCold", runs: Bench.runs(5), setup: { store = try ThumbnailStore.inMemory() }) {
            prints = DuplicateFinder.featurePrints(for: entries, store: store)
            _ = SimilarityIndex(prints: Array(prints.values), maximumDistance: SimilarityIndex.thresholdRange.upperBound)
                .groups(threshold: SimilarityIndex.defaultThreshold)
        }
        try Bench.measure("duplicates", "similarCached",
                      extra: "files=\(count) prints=\(prints.count) workers=\(DuplicateFinder.analysisWorkers())") {
            prints = DuplicateFinder.featurePrints(for: entries, store: store)
            _ = SimilarityIndex(prints: Array(prints.values), maximumDistance: SimilarityIndex.thresholdRange.upperBound)
                .groups(threshold: SimilarityIndex.defaultThreshold)
        }
        try Bench.measure("duplicates", "pixelSizes", extra: "files=\(count)") {
            _ = DuplicateFinder.pixelSizes(of: entries)
        }
    }

    /// A 3000 x 2000 picture of a few coloured bands that `seed` arranges,
    /// `tint` lifting its red a little.
    static func photo(seed: Int, tint: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var state = UInt64(seed + 1) &* 2862933555777941757
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 1000) / 1000
        }
        for _ in 0..<12 {
            ctx.setFillColor(CGColor(srgbRed: min(1, next() + tint), green: next(), blue: next(), alpha: 1))
            let x = next() * 2400, y = next() * 1600
            ctx.fill(CGRect(x: x, y: y, width: 200 + next() * 1200, height: 150 + next() * 800))
        }
        return ctx.makeImage()!
    }
}
