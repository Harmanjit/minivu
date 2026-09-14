import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Small generated images, so tests need no checked-in assets. Also used by
/// the thumbnail service and metadata suites.
enum TestImages {
    /// A horizontal gradient from red to blue, opaque or with an alpha ramp.
    static func gradient(width: Int = 64, height: Int = 48, alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(max(width - 1, 1))
            ctx.setFillColor(CGColor(srgbRed: 1 - t, green: 0.2, blue: t, alpha: alpha ? 0.25 + 0.75 * t : 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, properties: [CFString: Any] = [:]) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }
}

@Suite struct ThumbnailStoreTests {
    let file = URL(fileURLWithPath: "/Users/someone/Pictures/photo.jpg")
    let modified = Date(timeIntervalSinceReferenceDate: 750_000_000.123456)

    @Test func storesAndReadsBack() throws {
        let store = try ThumbnailStore.inMemory()
        store.store(TestImages.gradient(width: 256, height: 192), for: file, modified: modified, fileSize: 1234, tier: 256)
        let image = try #require(store.image(for: file, modified: modified, fileSize: 1234, tier: 256))
        #expect(image.width == 256 && image.height == 192)
        #expect(store.totalBytes > 0)
    }

    @Test func missesWhenFileChangedOrOtherTier() throws {
        let store = try ThumbnailStore.inMemory()
        store.store(TestImages.gradient(), for: file, modified: modified, fileSize: 1234, tier: 256)
        #expect(store.image(for: file, modified: modified.addingTimeInterval(1), fileSize: 1234, tier: 256) == nil)
        #expect(store.image(for: file, modified: modified, fileSize: 1235, tier: 256) == nil)
        #expect(store.image(for: file, modified: modified, fileSize: 1234, tier: 512) == nil)
        #expect(store.image(for: URL(fileURLWithPath: "/other.jpg"), modified: modified, fileSize: 1234, tier: 256) == nil)
        // Replacing the row makes the new version hit.
        store.store(TestImages.gradient(), for: file, modified: modified.addingTimeInterval(1), fileSize: 1234, tier: 256)
        #expect(store.image(for: file, modified: modified.addingTimeInterval(1), fileSize: 1234, tier: 256) != nil)
    }

    @Test func opaqueImagesAreJPEGAndAlphaImagesPNG() throws {
        let jpeg = try #require(ThumbnailStore.encode(TestImages.gradient(width: 256, height: 256)))
        let png = try #require(ThumbnailStore.encode(TestImages.gradient(width: 256, height: 256, alpha: true)))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        let store = try ThumbnailStore.inMemory()
        store.store(TestImages.gradient(alpha: true), for: file, modified: modified, fileSize: 1, tier: 256)
        let image = try #require(store.image(for: file, modified: modified, fileSize: 1, tier: 256))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
    }

    @Test func invalidateRemovesEveryTier() throws {
        let store = try ThumbnailStore.inMemory()
        for tier in [256, 512] { store.store(TestImages.gradient(), for: file, modified: modified, fileSize: 1, tier: tier) }
        store.invalidate(file)
        #expect(store.image(for: file, modified: modified, fileSize: 1, tier: 256) == nil)
        #expect(store.image(for: file, modified: modified, fileSize: 1, tier: 512) == nil)
        #expect(store.totalBytes == 0)
    }

    @Test func removeAllEmptiesTheCache() throws {
        let store = try ThumbnailStore.inMemory()
        for i in 0..<5 {
            store.store(TestImages.gradient(), for: URL(fileURLWithPath: "/p\(i).jpg"), modified: modified, fileSize: 1, tier: 256)
        }
        store.removeAll()
        #expect(store.totalBytes == 0)
    }

    @Test func pruneKeepsMostRecentlyUsed() throws {
        let store = try ThumbnailStore.inMemory()
        let urls = (0..<6).map { URL(fileURLWithPath: "/p\($0).jpg") }
        for url in urls {
            store.store(TestImages.gradient(width: 128, height: 128), for: url, modified: modified, fileSize: 1, tier: 256)
        }
        let each = store.totalBytes / urls.count
        store.prune(maxBytes: each * 2 + each / 2)
        #expect(store.totalBytes <= each * 2 + each / 2)
        #expect(store.image(for: urls[5], modified: modified, fileSize: 1, tier: 256) != nil)
        #expect(store.image(for: urls[4], modified: modified, fileSize: 1, tier: 256) != nil)
        #expect(store.image(for: urls[0], modified: modified, fileSize: 1, tier: 256) == nil)

        let before = store.totalBytes
        store.prune(maxBytes: before * 10)   // under budget: nothing to do
        #expect(store.totalBytes == before)
    }

    @Test func persistsOnDiskWithIncrementalVacuum() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("minivu/thumbnails.sqlite")
        do {
            let store = try ThumbnailStore(url: url)
            store.store(TestImages.gradient(), for: file, modified: modified, fileSize: 9, tier: 512)
        }
        let reopened = try ThumbnailStore(url: url)
        #expect(reopened.image(for: file, modified: modified, fileSize: 9, tier: 512) != nil)

        let db = try SQLiteDatabase(url: url)
        #expect(try db.userVersion() == ThumbnailStore.schemaVersion)
        #expect(try db.query("PRAGMA auto_vacuum").first?.int("auto_vacuum") == 2)   // INCREMENTAL
    }

    /// A damaged cache file is replaced, not a permanent failure.
    @Test func recreatesCacheFileThatIsNotADatabase() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("thumbnails.sqlite")
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        let store = try ThumbnailStore(url: url)
        store.store(TestImages.gradient(), for: file, modified: modified, fileSize: 9, tier: 256)
        #expect(store.image(for: file, modified: modified, fileSize: 9, tier: 256) != nil)
    }

    @Test func defaultURLIsInCaches() {
        #expect(ThumbnailStore.defaultURL.path.contains("/Caches/minivu/thumbnails.sqlite"))
    }
}
