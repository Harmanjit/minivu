import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Collects completion calls on the main actor, in order.
@MainActor final class Recorder {
    var names: [String] = []
}

@MainActor @Suite struct ThumbnailServiceTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    func imageEntry(_ name: String, width: Int = 640, height: Int = 480, type: UTType = .jpeg) -> FolderEntry {
        let url = TestImages.write(TestImages.gradient(width: width, height: height),
                                   to: folder.url.appendingPathComponent(name), type: type)
        return FolderEntry(url: url)!
    }

    func thumbnail(_ service: ThumbnailService, _ entry: FolderEntry, pixelSize: Int = 256) async -> CGImage? {
        await withCheckedContinuation { continuation in
            service.request(entry, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    @Test func tierSelection() {
        #expect(ThumbnailService.tier(forPixelSize: 1) == 256)
        #expect(ThumbnailService.tier(forPixelSize: 256) == 256)
        #expect(ThumbnailService.tier(forPixelSize: 257) == 512)
        #expect(ThumbnailService.tier(forPixelSize: 4000) == 512)
    }

    @Test func producesThumbnailAndCachesItInMemoryAndOnDisk() async throws {
        let store = try ThumbnailStore.inMemory()
        let service = ThumbnailService(store: store)
        let entry = imageEntry("photo.jpg", width: 1024, height: 768)

        #expect(service.cachedImage(for: entry, pixelSize: 200) == nil)
        let image = try #require(await thumbnail(service, entry, pixelSize: 200))
        #expect(image.width == 256 && image.height == 192)
        #expect(service.cachedImage(for: entry, pixelSize: 200) === image)
        #expect(service.cachedImage(for: entry, pixelSize: 300) == nil)   // tier 512 not made yet
        #expect(store.image(for: entry.url, modified: entry.modified, fileSize: entry.fileSize, tier: 256) != nil)

        // A fresh service with an empty memory cache is served from disk.
        let second = ThumbnailService(store: store)
        #expect(await thumbnail(second, entry) != nil)
    }

    @Test func largerTierSatisfiesSmallerRequest() async throws {
        let service = ThumbnailService(store: nil)
        let entry = imageEntry("big.jpg", width: 1024, height: 768)
        let large = try #require(await thumbnail(service, entry, pixelSize: 500))
        #expect(large.width == 512)
        #expect(service.cachedImage(for: entry, pixelSize: 100) === large)
    }

    /// Thumbnails reach the memory cache as Core Animation wants them (8-bit
    /// BGRA, premultiplied, in the service's colour space), whether decoded
    /// or read from disk, while the disk keeps the compact JPEG.
    @Test func thumbnailsAreDisplayReady() async throws {
        let store = try ThumbnailStore.inMemory()
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = TestImages.write(try #require(context.makeImage()), to: folder.url.appendingPathComponent("red.jpg"))
        let entry = try #require(FolderEntry(url: url))

        let service = ThumbnailService(store: store)
        #expect(service.displayColorSpace == CGColorSpace(name: CGColorSpace.sRGB))
        service.displayColorSpace = p3
        let decoded = try #require(await thumbnail(service, entry))
        let fromDisk = ThumbnailService(store: store)
        fromDisk.displayColorSpace = p3
        let stored = try #require(await thumbnail(fromDisk, entry))
        #expect(stored !== decoded)

        for image in [decoded, stored] {
            #expect(image.colorSpace == p3)
            #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
            #expect(image.alphaInfo == .premultipliedFirst && image.byteOrderInfo == .order32Little)
            // sRGB red as Display P3 is about (234, 51, 35); the bytes are B, G, R, A.
            let data = try #require(image.dataProvider?.data) as Data
            let i = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
            let bgra = [Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3])]
            #expect(zip(bgra, [35, 51, 234, 255]).allSatisfy { abs($0 - $1) <= 4 }, "\(bgra)")
        }
        let onDisk = try #require(store.image(for: url, modified: entry.modified, fileSize: entry.fileSize, tier: 256))
        #expect(onDisk.utType as String? == UTType.jpeg.identifier)
    }

    /// Another colour space empties the memory cache, and thumbnails are
    /// drawn again for it; setting the same one again changes nothing.
    @Test func changingTheColourSpaceRedrawsThumbnails() async throws {
        let service = ThumbnailService(store: nil)
        let entry = imageEntry("colour.jpg")
        let first = try #require(await thumbnail(service, entry))
        service.displayColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        #expect(service.cachedImage(for: entry, pixelSize: 256) === first)

        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        service.displayColorSpace = p3
        #expect(service.cachedImage(for: entry, pixelSize: 256) == nil)
        let redrawn = try #require(await thumbnail(service, entry))
        #expect(redrawn !== first && redrawn.colorSpace == p3)
        #expect(service.cachedImage(for: entry, pixelSize: 256) === redrawn)
    }

    @Test func directoriesAndUnreadableFilesGiveNil() async throws {
        let service = ThumbnailService(store: nil)
        let directory = try #require(FolderEntry(url: try folder.folder("sub")))
        #expect(await thumbnail(service, directory) == nil)
        let broken = try #require(FolderEntry(url: try folder.file("broken.jpg", bytes: 100)))
        #expect(await thumbnail(service, broken) == nil)
    }

    @Test func identicalRequestsShareOneResult() async throws {
        let service = ThumbnailService(store: nil)
        let entry = imageEntry("shared.jpg")
        async let a = thumbnail(service, entry)
        async let b = thumbnail(service, entry)
        let (first, second) = await (a, b)
        #expect(first != nil && first === second)
    }

    /// Queued requests run newest first, and asking again for a queued
    /// thumbnail moves it to the front.
    @Test func runsNewestRequestFirst() async throws {
        let service = ThumbnailService(store: nil, memoryCacheBytes: 100_000_000, workerLimit: 1)
        let entries = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { imageEntry($0) }
        let recorder = Recorder()
        service.setSuspended(true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var remaining = 5
            for entry in entries + [entries[1]] {   // b is asked for twice: first and last
                service.request(entry, pixelSize: 256) { _ in
                    recorder.names.append(entry.name)
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
            service.setSuspended(false)
        }
        // Both requests for b share one decode, delivered together.
        #expect(recorder.names == ["b.jpg", "b.jpg", "d.jpg", "c.jpg", "a.jpg"])
    }

    @Test func cancelledRequestsNeverCompleteAndAreNotDecoded() async throws {
        let service = ThumbnailService(store: nil, memoryCacheBytes: 100_000_000, workerLimit: 1)
        let skipped = imageEntry("skipped.jpg")
        let other = imageEntry("other.jpg")
        let recorder = Recorder()

        service.setSuspended(true)
        let request = service.request(skipped, pixelSize: 256) { _ in recorder.names.append("skipped") }
        request.cancel()
        #expect(request.isCancelled)
        async let otherDone = thumbnail(service, other)
        await Task.yield()
        service.setSuspended(false)
        #expect(await otherDone != nil)

        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.names.isEmpty)
        #expect(service.cachedImage(for: skipped, pixelSize: 256) == nil)   // never decoded
    }

    /// A request right after `invalidate` must decode the file again, not
    /// pick up the old disk copy while the asynchronous delete is pending.
    @Test func invalidateThenRequestNeverServesOldDiskCopy() async throws {
        let store = try ThumbnailStore.inMemory()
        let entry = imageEntry("edited.jpg")
        // A stand-in "old" thumbnail on disk, recognisable by its size.
        store.store(TestImages.gradient(width: 10, height: 10), for: entry.url, modified: entry.modified,
                    fileSize: entry.fileSize, tier: 256)
        let service = ThumbnailService(store: store)
        #expect(await thumbnail(service, entry)?.width == 10)      // served from disk

        service.invalidate(entry.url)
        #expect(service.cachedImage(for: entry, pixelSize: 256) == nil)
        #expect(await thumbnail(service, entry)?.width == 256)     // decoded again, immediately
        #expect(service.cachedImage(for: entry, pixelSize: 256)?.width == 256)
    }

    /// A file that can't be decoded fails once; asking again answers nil
    /// without another decode, until the file is invalidated.
    @Test func failedDecodesAreRememberedUntilInvalidated() async throws {
        let service = ThumbnailService(store: nil)
        let url = try folder.file("later.jpg", bytes: 100)
        let broken = try #require(FolderEntry(url: url))
        #expect(await thumbnail(service, broken) == nil)

        // Make the file decodable without changing the entry's date and size,
        // so only a fresh decode attempt could now succeed.
        TestImages.write(TestImages.gradient(width: 640, height: 480), to: url)
        #expect(await thumbnail(service, broken) == nil)            // remembered, not retried
        service.invalidate(url)
        #expect(await thumbnail(service, broken)?.width == 256)     // retried after invalidate
    }

    // MARK: - HEIF route

    /// Draws `image` into a tiny sRGB bitmap, for comparing two thumbnails.
    nonisolated static func samples(_ image: CGImage, width: Int = 8, height: Int = 8) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.map(Int.init)
    }

    nonisolated static func directThumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ] as CFDictionary)
    }

    /// The quarter-size HEIC path must give the same picture as ImageIO's
    /// direct thumbnail: same size, orientation applied, same colours.
    @Test func heicThumbnailMatchesDirectDecode() throws {
        let url = folder.url.appendingPathComponent("rotated.heic")
        TestImages.write(TestImages.gradient(width: 2048, height: 1024), to: url, type: .heic,
                         properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(ImageDecoder.embeddedThumbnailLongEdge(source: source, index: 0) == 0)   // so the quarter route runs
        #expect(ImageDecoder.heifThumbnail(source: source, maxPixelSize: 256) != nil)   // the route applies

        let fast = try #require(ImageDecoder.thumbnail(for: url, maxPixelSize: 256))
        let direct = try #require(Self.directThumbnail(url, maxPixelSize: 256))
        #expect(fast.width == direct.width && fast.height == direct.height)
        #expect(fast.width == 128 && fast.height == 256)
        #expect(fast.alphaInfo == .noneSkipFirst)   // opaque, so the store keeps it as JPEG
        let difference = zip(Self.samples(fast), Self.samples(direct)).map { abs($0 - $1) }.max() ?? 0
        #expect(difference <= 12)
    }

    /// A HEIC carrying its own thumbnail uses it when it's big enough, with
    /// orientation applied, and falls back to decoding when it's too small.
    @Test func heicEmbeddedThumbnailRoute() throws {
        let url = folder.url.appendingPathComponent("embedded.heic")
        TestImages.write(TestImages.gradient(width: 2048, height: 1024), to: url, type: .heic,
                         properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
                                      kCGImageDestinationEmbedThumbnail: true])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let embedded = ImageDecoder.embeddedThumbnailLongEdge(source: source, index: 0)
        try #require(embedded >= 256, "ImageIO wrote no usable embedded thumbnail (\(embedded) px)")

        let fast = try #require(ImageDecoder.thumbnail(for: url, maxPixelSize: 256))
        let direct = try #require(Self.directThumbnail(url, maxPixelSize: 256))
        #expect(fast.width == direct.width && fast.height == direct.height)
        #expect(fast.width == 128 && fast.height == 256)
        let difference = zip(Self.samples(fast), Self.samples(direct)).map { abs($0 - $1) }.max() ?? 0
        #expect(difference <= 12)

        // Bigger than the embedded thumbnail: a real decode at full size.
        let large = try #require(ImageDecoder.thumbnail(for: url, maxPixelSize: embedded + 100))
        #expect(max(large.width, large.height) == embedded + 100)
    }

    @Test func smallHeicUsesDirectPath() throws {
        let url = folder.url.appendingPathComponent("small.heic")
        TestImages.write(TestImages.gradient(width: 400, height: 300), to: url, type: .heic)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(ImageDecoder.heifThumbnail(source: source, maxPixelSize: 256) == nil)   // 100 px quarter is too small
        #expect(ImageDecoder.thumbnail(for: url, maxPixelSize: 256)?.width == 256)
    }

    nonisolated static let sampleHEIC = URL(fileURLWithPath: "/Users/harman/latent/TestAssets/HSB_6548.heic")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sampleHEIC.path)))
    func realHeicThumbnail() throws {
        let clock = ContinuousClock()
        var fast: CGImage?, direct: CGImage?
        let fastTime = clock.measure { fast = ImageDecoder.thumbnail(for: Self.sampleHEIC, maxPixelSize: 256) }
        let directTime = clock.measure { direct = Self.directThumbnail(Self.sampleHEIC, maxPixelSize: 256) }
        let a = try #require(fast), b = try #require(direct)
        // ImageIO rounds the short edge up for HEIC (171.1 -> 172); CG rounds.
        #expect(a.width == b.width && abs(a.height - b.height) <= 1)
        let difference = zip(Self.samples(a), Self.samples(b)).map { abs($0 - $1) }.max() ?? 0
        #expect(difference <= 12)
        print("HEIC 256 px thumbnail: quarter route \(fastTime), direct \(directTime)")
    }
}
