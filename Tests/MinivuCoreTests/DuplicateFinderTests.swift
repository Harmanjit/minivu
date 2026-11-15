import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Vision
@testable import MinivuCore

/// Synthetic photographs for the similarity tests: a sky gradient, ground and
/// a few shapes placed by a seed, so each seed is a different picture and
/// the same seed at another size or quality is a near-duplicate.
enum SyntheticScenes {
    static func scene(seed: UInt64, width: Int = 800, height: Int = 600) -> CGImage {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.scaleBy(x: CGFloat(width) / 800, y: CGFloat(height) / 600)
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 1),
                                      CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 150 + 200 * random()))
        for _ in 0..<8 {
            ctx.setFillColor(CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 1))
            let rect = CGRect(x: 700 * random(), y: 500 * random(), width: 40 + 260 * random(), height: 40 + 260 * random())
            if random() > 0.5 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.9) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }
}

/// `image` scaled to `width`, as an export or a "resize for email" makes.
func resized(_ image: CGImage, width: Int) -> CGImage {
    let height = image.height * width / image.width
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite struct DuplicateFinderTests {
    func entry(_ url: URL) throws -> FolderEntry { try #require(FolderEntry(url: url)) }

    func write(_ bytes: [UInt8], to url: URL) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Hashing

    /// A file several chunks long hashes to the digest of its whole bytes,
    /// read a chunk at a time and never more.
    @Test func hashStreamsAFileLargerThanTheChunk() throws {
        let t = try TemporaryFolder()
        var bytes = [UInt8](repeating: 0, count: 2_500_123)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 7) }
        let url = try write(bytes, to: t.url.appendingPathComponent("big.tif"))
        var reads: [Int] = []
        let digest = try ContentHash.sha256(of: url, chunkSize: 65_536, didRead: { reads.append($0) })
        #expect(digest == Data(SHA256.hash(data: Data(bytes))))
        #expect(reads.count == 39)
        #expect(reads.allSatisfy { $0 <= 65_536 })
        #expect(reads.reduce(0, +) == bytes.count)
        // The default chunk gives the same answer.
        #expect(try ContentHash.sha256(of: url) == digest)
    }

    @Test func hashStopsWhenCancelled() throws {
        let t = try TemporaryFolder()
        let url = try t.file("a.jpg", bytes: 10_000)
        var chunks = 0
        #expect(throws: CancellationError.self) {
            try ContentHash.sha256(of: url, chunkSize: 1000, isCancelled: { chunks >= 3 }, didRead: { _ in chunks += 1 })
        }
        #expect(chunks == 3)
    }

    // MARK: - Exact duplicates

    /// Same size and bytes group; same size with other bytes, a size of its
    /// own and empty files don't. Only files sharing a size are read.
    @Test func exactGroupsBySizeThenContent() throws {
        let t = try TemporaryFolder()
        let sub = try t.folder("Sub")
        let a = try write([1, 2, 3, 4], to: t.url.appendingPathComponent("a.jpg"))
        let b = try write([1, 2, 3, 4], to: sub.appendingPathComponent("b.jpg"))
        let c = try write([1, 2, 3, 5], to: t.url.appendingPathComponent("c.jpg"))
        let d = try write([1, 2, 3, 4, 5], to: t.url.appendingPathComponent("d.jpg"))
        let big1 = try write([UInt8](repeating: 7, count: 9000), to: t.url.appendingPathComponent("e.png"))
        let big2 = try write([UInt8](repeating: 7, count: 9000), to: t.url.appendingPathComponent("f.png"))
        let big3 = try write([UInt8](repeating: 7, count: 9000), to: sub.appendingPathComponent("g.png"))
        let empty1 = try t.file("empty1.jpg"), empty2 = try t.file("empty2.jpg")
        var totals: Set<Int> = []
        let groups = DuplicateFinder.exactGroups(in: try [a, b, c, d, big1, big2, big3, empty1, empty2].map(entry),
                                                 cache: nil, chunkSize: 1000,
                                                 progress: { totals.insert($0.total) })
        // The group with most to win back first: two spare 9000-byte copies.
        #expect(groups.map { $0.map(\.name) } == [["e.png", "f.png", "g.png"], ["a.jpg", "b.jpg"]])
        // a, b, c (size 4) and the three big ones: never d or the empty files.
        #expect(totals == [6])
    }

    /// The same file reached twice (a symbolic link) is not its own duplicate.
    @Test func exactIgnoresTheSameFileTwice() throws {
        let t = try TemporaryFolder()
        let a = try write([9, 9, 9], to: t.url.appendingPathComponent("a.jpg"))
        let link = t.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.url)
        let again = FolderEntry(url: link.appendingPathComponent("a.jpg"), name: "a.jpg", isDirectory: false,
                                kind: .raster, fileSize: 3, modified: .now, created: .now)
        #expect(DuplicateFinder.exactGroups(in: [try entry(a), again], cache: nil).isEmpty)
    }

    /// A second run takes hashes from the cache while the file keeps its
    /// size and date (proved by changing the bytes behind its back), and
    /// reads it again once the date moves.
    @Test func exactReusesCachedHashes() throws {
        let t = try TemporaryFolder()
        let store = try ThumbnailStore.inMemory()
        let a = try write([1, 1, 1, 1], to: t.url.appendingPathComponent("a.jpg"))
        let b = try write([1, 1, 1, 1], to: t.url.appendingPathComponent("b.jpg"))
        #expect(DuplicateFinder.exactGroups(in: try [a, b].map(entry), cache: store).count == 1)

        let date = try #require(try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        _ = try write([2, 2, 2, 2], to: a)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        #expect(DuplicateFinder.exactGroups(in: try [a, b].map(entry), cache: store).count == 1)

        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(10)], ofItemAtPath: a.path)
        #expect(DuplicateFinder.exactGroups(in: try [a, b].map(entry), cache: store).isEmpty)
    }

    @Test func exactStopsWhenCancelled() throws {
        let t = try TemporaryFolder()
        let files = try (0..<6).map { try write([5, 5], to: t.url.appendingPathComponent("\($0).jpg")) }
        var seen = 0
        let groups = DuplicateFinder.exactGroups(in: try files.map(entry), cache: nil, isCancelled: { seen >= 2 },
                                                 progress: { seen = $0.done })
        // Two files read before the stop: still a group of what was read.
        #expect(groups.map(\.count) == [2])
    }

    // MARK: - Similar images

    /// The scenes of `SyntheticScenes` with copies: three of seed 0 (the
    /// original, a half-size JPEG at low quality, a PNG), two of seed 1, and
    /// seed 2 alone.
    func nearDuplicates(in t: TemporaryFolder) throws -> [FolderEntry] {
        func scene(_ seed: UInt64) -> CGImage { SyntheticScenes.scene(seed: seed) }
        let urls = [
            SyntheticScenes.write(scene(0), to: t.url.appendingPathComponent("beach.jpg")),
            SyntheticScenes.write(resized(scene(0), width: 400), to: t.url.appendingPathComponent("beach small.jpg"),
                                  quality: 0.4),
            SyntheticScenes.write(scene(0), to: t.url.appendingPathComponent("beach.png"), type: .png),
            SyntheticScenes.write(scene(1), to: t.url.appendingPathComponent("hill.jpg")),
            SyntheticScenes.write(resized(scene(1), width: 300), to: t.url.appendingPathComponent("hill email.jpg"),
                                  quality: 0.8),
            SyntheticScenes.write(scene(2), to: t.url.appendingPathComponent("town.jpg")),
        ]
        return try urls.map(entry)
    }

    func similarGroups(_ entries: [FolderEntry], threshold: Float, store: ThumbnailStore? = nil) -> [[String]] {
        let prints = DuplicateFinder.featurePrints(for: entries, store: store)
        let indexed = entries.filter { prints[$0.url] != nil }
        let index = SimilarityIndex(prints: indexed.map { prints[$0.url]! },
                                    maximumDistance: SimilarityIndex.thresholdRange.upperBound)
        return index.groups(threshold: threshold).map { $0.map { indexed[$0].name } }
    }

    /// At the default threshold the resized and re-encoded copies group with
    /// their originals, and different pictures stay apart.
    @Test func similarGroupsCopiesAndNotOtherPictures() throws {
        let t = try TemporaryFolder()
        let groups = similarGroups(try nearDuplicates(in: t), threshold: SimilarityIndex.defaultThreshold)
        #expect(groups == [["beach.jpg", "beach small.jpg", "beach.png"], ["hill.jpg", "hill email.jpg"]])
    }

    /// Stricter finds only the near-identical PNG copy; the loosest joins
    /// everything; every group at one threshold lies inside a group at any
    /// looser one.
    @Test func thresholdTightensAndLoosensGroups() throws {
        let t = try TemporaryFolder()
        let entries = try nearDuplicates(in: t)
        let prints = DuplicateFinder.featurePrints(for: entries, store: nil)
        let index = SimilarityIndex(prints: entries.map { prints[$0.url]! },
                                    maximumDistance: SimilarityIndex.thresholdRange.upperBound)
        let strict = index.groups(threshold: 0.15)
        #expect(strict == [[0, 2]])
        #expect(index.groups(threshold: SimilarityIndex.thresholdRange.upperBound) == [[0, 1, 2, 3, 4, 5]])
        var previous: [[Int]] = []
        for threshold in stride(from: Float(0.05), through: 0.8, by: 0.05) {
            let groups = index.groups(threshold: threshold)
            for group in previous {
                #expect(groups.contains { Set(group).isSubset(of: $0) })
            }
            previous = groups
        }
        // Nothing past the index's own ceiling is kept.
        #expect(index.pairs.allSatisfy { $0.distance <= SimilarityIndex.thresholdRange.upperBound })
    }

    /// Our distance is Vision's.
    @Test func distanceMatchesVision() throws {
        func observation(_ image: CGImage) throws -> VNFeaturePrintObservation {
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return try #require(request.results?.first)
        }
        let a = try observation(resized(SyntheticScenes.scene(seed: 4), width: 256))
        let b = try observation(resized(SyntheticScenes.scene(seed: 5), width: 256))
        var expected: Float = 0
        try a.computeDistance(&expected, to: b)
        let printA = try #require(FeaturePrint(observation: a, revision: FeaturePrint.currentRevision))
        let printB = try #require(FeaturePrint(observation: b, revision: FeaturePrint.currentRevision))
        let mine = try #require(printA.distance(to: printB))
        #expect(abs(mine - expected) < 0.0005)
    }

    /// A second run makes no prints; a file changed since makes one.
    @Test func featurePrintsAreCached() throws {
        let t = try TemporaryFolder()
        let store = try ThumbnailStore.inMemory()
        let entries = try nearDuplicates(in: t)
        let made = Tally()
        let make: @Sendable (FolderEntry, ThumbnailStore?) -> FeaturePrint? = { entry, thumbnails in
            made.add()
            return FeaturePrint.make(for: entry, thumbnails: thumbnails)
        }
        let first = DuplicateFinder.featurePrints(for: entries, store: store, workers: 2, make: make)
        #expect(made.count == 6)
        let second = DuplicateFinder.featurePrints(for: entries, store: store, make: make)
        #expect(made.count == 6)
        #expect(second == first)

        let changed = entries[5].url
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: changed.path)
        _ = DuplicateFinder.featurePrints(for: try entries.map { try entry($0.url) }, store: store, make: make)
        #expect(made.count == 7)
    }

    /// Prints come from the thumbnail cache's small tier when it has one,
    /// so a browsed folder costs no decode.
    @Test func featurePrintUsesTheCachedThumbnail() throws {
        let t = try TemporaryFolder()
        let store = try ThumbnailStore.inMemory()
        // Not an image file at all: only the cache can give it a picture.
        let url = try t.file("fake.jpg", bytes: 20)
        let fake = try entry(url)
        #expect(FeaturePrint.make(for: fake, thumbnails: store) == nil)
        store.store(resized(SyntheticScenes.scene(seed: 0), width: 256), for: url, modified: fake.modified,
                    fileSize: fake.fileSize, tier: 256)
        #expect(FeaturePrint.make(for: fake, thumbnails: store) != nil)
    }

    @Test func featurePrintsStopWhenCancelled() throws {
        let t = try TemporaryFolder()
        let entries = try nearDuplicates(in: t)
        let made = Tally()
        let prints = DuplicateFinder.featurePrints(for: entries, store: nil, workers: 1, isCancelled: { made.count >= 2 },
                                                   make: { _, _ in
                                                       made.add()
                                                       return FeaturePrint(revision: FeaturePrint.currentRevision, vector: [1, 2])
                                                   })
        #expect(prints.count == 2)
    }

    // MARK: - The index on its own

    /// Chains join (single linkage); each image keeps only its nearest pairs.
    @Test func indexJoinsChainsAndCapsNeighbours() {
        func print(_ x: Float) -> FeaturePrint { FeaturePrint(revision: 2, vector: [x, 0, 0]) }
        let index = SimilarityIndex(prints: [print(0), print(0.3), print(0.6), print(5)], maximumDistance: 1)
        #expect(index.groups(threshold: 0.35) == [[0, 1, 2]])
        #expect(index.groups(threshold: 0.2).isEmpty)
        #expect(index.pairs.map(\.distance).allSatisfy { $0 <= 1 })

        let crowd = SimilarityIndex(prints: (0..<10).map { print(Float($0) * 0.01) }, maximumDistance: 1, neighbours: 2)
        #expect(crowd.pairs.count <= 18)
        #expect(crowd.groups(threshold: 0.05) == [Array(0..<10)])
    }

    /// Prints that can't be compared with the first (another revision) are
    /// left out rather than compared wrongly; so are blocks past the first
    /// when the matrix is larger than a block.
    @Test func indexSkipsOtherRevisionsAndSpansBlocks() {
        let n = SimilarityIndex.blockRows + 40
        var prints = (0..<n).map { FeaturePrint(revision: 2, vector: [Float($0) * 10, 1]) }
        prints[n - 1] = FeaturePrint(revision: 2, vector: [0, 1.1])
        prints[1] = FeaturePrint(revision: 1, vector: [0, 1])
        let index = SimilarityIndex(prints: prints, maximumDistance: 0.5)
        #expect(index.groups(threshold: 0.5) == [[0, n - 1]])
    }

    // MARK: - Keep rule

    @Test func keepRulesPickTheirFile() {
        func file(_ name: String, size: Int64, age: TimeInterval) -> FolderEntry {
            FolderEntry(url: URL(fileURLWithPath: "/p/\(name)"), name: name, isDirectory: false, kind: .raster,
                        fileSize: size, modified: Date(timeIntervalSince1970: age),
                        created: Date(timeIntervalSince1970: age + 5))
        }
        let big = file("big.jpg", size: 900, age: 300)
        let sharp = file("sharp.jpg", size: 500, age: 200)
        let old = file("old.jpg", size: 100, age: 100)
        let sizes: [URL: CGSize] = [big.url: CGSize(width: 100, height: 100), sharp.url: CGSize(width: 400, height: 300),
                                    old.url: CGSize(width: 100, height: 100)]
        let files = [old, sharp, big]
        #expect(KeepRule.largestFile.keeper(of: files, pixelSizes: sizes) == big)
        #expect(KeepRule.highestResolution.keeper(of: files, pixelSizes: sizes) == sharp)
        #expect(KeepRule.oldest.keeper(of: files, pixelSizes: sizes) == old)
        // Exact copies tie on size and pixels: the oldest, then path order.
        let copyA = file("a.jpg", size: 10, age: 50), copyB = file("b.jpg", size: 10, age: 50)
        let copyC = file("c.jpg", size: 10, age: 40)
        #expect(KeepRule.largestFile.keeper(of: [copyB, copyA], pixelSizes: [:]) == copyA)
        #expect(KeepRule.highestResolution.keeper(of: [copyA, copyB, copyC], pixelSizes: [:]) == copyC)
    }

    // MARK: - Memory

    @Test func memoryPolicyIsLeanOnSmallMacs() {
        #expect(DuplicateFinder.analysisWorkers(physicalMemory: 8 << 30) == 1)
        #expect(DuplicateFinder.analysisWorkers(physicalMemory: 16 << 30) == 2)
        #expect(DuplicateFinder.analysisWorkers(physicalMemory: 64 << 30) == 3)
        #expect(DuplicateFinder.maximumSimilarImages(physicalMemory: 8 << 30) == 10_000)
        #expect(DuplicateFinder.maximumSimilarImages(physicalMemory: 16 << 30) == 20_000)
    }
}

/// A count that worker threads can add to.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// The fingerprint cache in the thumbnail database.
@Suite struct FingerprintCacheTests {
    let identity = FileIdentity(volume: "VOL", fileID: 42, size: 1000, modified: 750_000_000.25)

    @Test func hashAndPrintShareARowWhileTheFileIsUnchanged() throws {
        let store = try ThumbnailStore.inMemory()
        let print = FeaturePrint(revision: 2, vector: [0.5, -1, 3])
        store.storeHashes([(identity, Data([1, 2, 3]))])
        store.storePrints([(identity, print)])
        #expect(store.fingerprints(for: [identity])[identity] == Fingerprint(sha256: Data([1, 2, 3]), print: print))

        // Rewritten (another date): the old values are not handed out, and
        // a new hash doesn't bring the old print back.
        var changed = identity
        changed.modified += 1
        #expect(store.fingerprints(for: [changed]).isEmpty)
        store.storeHashes([(changed, Data([9]))])
        #expect(store.fingerprints(for: [changed])[changed] == Fingerprint(sha256: Data([9]), print: nil))
        #expect(store.fingerprints(for: [identity]).isEmpty)
    }

    /// Bounded: the least recently used rows go first.
    @Test func pruneKeepsTheMostRecentlyUsed() throws {
        let store = try ThumbnailStore.inMemory()
        for id in 0..<10 as Range<Int64> {
            var item = identity
            item.fileID = id
            store.storePrints([(item, FeaturePrint(revision: 2, vector: [Float](repeating: 1, count: 256)))])
            try store.db.execute("UPDATE fingerprints SET accessed = ?1 WHERE file_id = ?2", [.real(Double(id)), .integer(id)])
        }
        #expect(store.fingerprintBytes == 10 * 1024)
        store.pruneFingerprints(maxBytes: 3 * 1024)
        #expect(store.fingerprintBytes == 3 * 1024)
        let kept = (0..<10 as Range<Int64>).filter { id in
            var item = identity
            item.fileID = id
            return !store.fingerprints(for: [item]).isEmpty
        }
        #expect(kept == [7, 8, 9])
    }

    /// A version 1 thumbnail cache gains the table and keeps its thumbnails.
    @Test func versionOneCacheKeepsItsThumbnails() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("thumbnails.sqlite")
        let file = URL(fileURLWithPath: "/p/photo.jpg"), date = Date(timeIntervalSinceReferenceDate: 1000)
        do {
            let store = try ThumbnailStore(url: url)
            store.store(TestImages.gradient(), for: file, modified: date, fileSize: 9, tier: 256)
            try store.db.executeScript("DROP TABLE fingerprints")
            try store.db.setUserVersion(1)
        }
        let store = try ThumbnailStore(url: url)
        #expect(store.image(for: file, modified: date, fileSize: 9, tier: 256) != nil)
        store.storeHashes([(identity, Data([7]))])
        #expect(store.fingerprints(for: [identity])[identity]?.sha256 == Data([7]))
        #expect(try store.db.userVersion() == ThumbnailStore.schemaVersion)
    }

    @Test func clearingTheThumbnailCacheClearsFingerprints() throws {
        let store = try ThumbnailStore.inMemory()
        store.storeHashes([(identity, Data([7]))])
        store.removeAll()
        #expect(store.fingerprints(for: [identity]).isEmpty)
    }

    /// Identities come from the file system: a rename keeps one.
    @Test func identityFollowsARename() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg", bytes: 10)
        let before = try #require(FileIdentity.read([a])[a])
        let b = t.url.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: a, to: b)
        #expect(FileIdentity.read([b])[b] == before)
        #expect(FileIdentity.read([a]).isEmpty)
    }
}
