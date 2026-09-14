import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AgateCore

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

    @Test func invalidateDropsMemoryAndDiskCopies() async throws {
        let store = try ThumbnailStore.inMemory()
        let service = ThumbnailService(store: store)
        let entry = imageEntry("edited.jpg")
        #expect(await thumbnail(service, entry) != nil)
        service.invalidate(entry.url)
        #expect(service.cachedImage(for: entry, pixelSize: 256) == nil)
        // The disk delete is asynchronous; a new request after it re-decodes.
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.image(for: entry.url, modified: entry.modified, fileSize: entry.fileSize, tier: 256) == nil)
        #expect(await thumbnail(service, entry) != nil)
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
        #expect(ImageDecoder.heifThumbnail(source: source, maxPixelSize: 256) != nil)   // the route applies

        let fast = try #require(ImageDecoder.thumbnail(for: url, maxPixelSize: 256))
        let direct = try #require(Self.directThumbnail(url, maxPixelSize: 256))
        #expect(fast.width == direct.width && fast.height == direct.height)
        #expect(fast.width == 128 && fast.height == 256)
        #expect(fast.alphaInfo == .noneSkipFirst)   // opaque, so the store keeps it as JPEG
        let difference = zip(Self.samples(fast), Self.samples(direct)).map { abs($0 - $1) }.max() ?? 0
        #expect(difference <= 12)
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
