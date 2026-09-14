import Testing
import Foundation
import Metal
@testable import MinivuRender

@Suite struct TextureCacheTests {
    static let url = URL(fileURLWithPath: "/photos/a.jpg")
    static let date = Date(timeIntervalSince1970: 1_000_000)
    /// byteCost of a 64 px square 8-bit texture: 64 * 64 * 4 bytes, plus a
    /// third for mipmaps.
    static let smallCost = 21_845

    /// A texture of `width` x `height` standing for an image of `imageSize`.
    func texture(_ width: Int, _ height: Int, imageSize: CGSize? = nil, full: Bool = false) -> ImageTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                         mipmapped: false)
        d.storageMode = .shared
        let t = GPU.shared.device.makeTexture(descriptor: d)!
        return ImageTexture(texture: t, imageSize: imageSize ?? CGSize(width: width, height: height),
                            isFullResolution: full, isHDR: false, contentHeadroom: 1)
    }

    func key(_ url: URL = url, longEdge: Int, full: Bool = false, page: Int = 0) -> TextureKey {
        TextureKey(url: url, modified: Self.date, page: page, longEdge: longEdge, fullResolution: full)
    }

    func other(_ n: Int) -> URL { URL(fileURLWithPath: "/photos/\(n).jpg") }

    @Test func defaultBudgetIsAnEighthOfRAMWithinLimits() {
        let gib: UInt64 = 1 << 30
        #expect(TextureCache.defaultBudget(physicalMemory: 8 * gib) == 1 << 30)
        #expect(TextureCache.defaultBudget(physicalMemory: 16 * gib) == 1536 << 20)   // capped at 1.5 GB
        #expect(TextureCache.defaultBudget(physicalMemory: 64 * gib) == 1536 << 20)
        #expect(TextureCache.defaultBudget(physicalMemory: 1 * gib) == 256 << 20)     // floor
    }

    @Test func insertAndLookUp() {
        let cache = TextureCache(budgetBytes: 1 << 30)
        let t = texture(64, 64)
        cache.insert(t, for: key(longEdge: 64))
        #expect(cache.texture(for: key(longEdge: 64)) === t)
        #expect(cache.texture(for: key(longEdge: 65)) == nil)
        #expect(cache.usedBytes == Self.smallCost)
        // Replacing a key doesn't count its bytes twice.
        cache.insert(texture(64, 64), for: key(longEdge: 64))
        #expect(cache.usedBytes == Self.smallCost)
    }

    @Test func evictsLeastRecentlyUsed() {
        let cache = TextureCache(budgetBytes: Self.smallCost * 2)
        cache.insert(texture(64, 64), for: key(other(1), longEdge: 64))
        cache.insert(texture(64, 64), for: key(other(2), longEdge: 64))
        // Touch 1, so 2 is now the oldest.
        _ = cache.texture(for: key(other(1), longEdge: 64))
        cache.insert(texture(64, 64), for: key(other(3), longEdge: 64))
        #expect(cache.texture(for: key(other(1), longEdge: 64)) != nil)
        #expect(cache.texture(for: key(other(2), longEdge: 64)) == nil)
        #expect(cache.texture(for: key(other(3), longEdge: 64)) != nil)
        #expect(cache.usedBytes == Self.smallCost * 2)
    }

    @Test func oversizedTextureIsKeptAlone() {
        let cache = TextureCache(budgetBytes: Self.smallCost / 2)
        cache.insert(texture(64, 64), for: key(other(1), longEdge: 64))
        cache.insert(texture(64, 64), for: key(other(2), longEdge: 64))
        #expect(cache.count == 1)
        #expect(cache.texture(for: key(other(2), longEdge: 64)) != nil)
    }

    @Test func bestTexturePrefersFullResolution() {
        let cache = TextureCache(budgetBytes: 1 << 30)
        let image = CGSize(width: 600, height: 400)
        let screen = texture(300, 200, imageSize: image)
        let full = texture(600, 400, imageSize: image, full: true)
        cache.insert(screen, for: key(longEdge: 300))
        cache.insert(full, for: key(longEdge: 600, full: true))
        #expect(cache.bestTexture(url: Self.url, modified: Self.date, page: 0, minimumLongEdge: 100) === full)
    }

    @Test func bestTextureIsTheSmallestThatCovers() {
        let cache = TextureCache(budgetBytes: 1 << 30)
        let image = CGSize(width: 6000, height: 4000)
        let small = texture(150, 100, imageSize: image)
        let medium = texture(300, 200, imageSize: image)
        let large = texture(600, 400, imageSize: image)
        cache.insert(small, for: key(longEdge: 150))
        cache.insert(medium, for: key(longEdge: 300))
        cache.insert(large, for: key(longEdge: 600))
        func best(_ edge: Int) -> ImageTexture? {
            cache.bestTexture(url: Self.url, modified: Self.date, page: 0, minimumLongEdge: edge)
        }
        #expect(best(200) === medium)
        #expect(best(300) === medium)
        #expect(best(309) === medium)   // 300 >= 0.97 * 309: the decoder's own tolerance
        #expect(best(310) === large)
        #expect(best(700) == nil)
        // Another modification date or page is another image.
        #expect(cache.bestTexture(url: Self.url, modified: .now, page: 0, minimumLongEdge: 100) == nil)
        #expect(cache.bestTexture(url: Self.url, modified: Self.date, page: 1, minimumLongEdge: 100) == nil)
    }

    @Test func bestTextureFitsEachImageIntoTheView() {
        // A 3:2 photo in a 3420 x 2048 view is 3072 px wide at fit, not
        // 3420: the 3016 px half-size decode covers it (3% slack), and a
        // larger texture decoded for the long edge still serves.
        let cache = TextureCache(budgetBytes: 1 << 30)
        let image = CGSize(width: 6000, height: 4000)
        let half = texture(3000, 2000, imageSize: image)
        func best(_ width: CGFloat, _ height: CGFloat) -> ImageTexture? {
            cache.bestTexture(url: Self.url, modified: Self.date, page: 0, fitting: CGSize(width: width, height: height))
        }
        cache.insert(half, for: key(longEdge: 3000))
        #expect(best(3420, 2048) === half)
        #expect(best(3420, 2214) == nil)   // 3321 px at fit
        #expect(best(2048, 3420) === half)   // a tall view: 2048 px
        let full = texture(6000, 4000, imageSize: image)
        cache.insert(full, for: key(longEdge: 6000))
        #expect(best(3420, 2214) === full)
        #expect(best(1000, 1000) === half)   // the smallest that covers
    }

    @Test func bestTextureCapsTheNeedAtTheImageSize() {
        // A 500 px image can't have a texture larger than 500 px, so its
        // (not full-resolution, say an embedded preview) texture covers a
        // 3000 px window as well as anything can.
        let cache = TextureCache(budgetBytes: 1 << 30)
        let t = texture(490, 300, imageSize: CGSize(width: 500, height: 306))
        cache.insert(t, for: key(longEdge: 490))
        #expect(cache.bestTexture(url: Self.url, modified: Self.date, page: 0, minimumLongEdge: 3000) === t)
    }

    @Test func anyTextureIsTheLargest() {
        let cache = TextureCache(budgetBytes: 1 << 30)
        let image = CGSize(width: 6000, height: 4000)
        cache.insert(texture(150, 100, imageSize: image), for: key(longEdge: 150))
        let large = texture(300, 200, imageSize: image)
        cache.insert(large, for: key(longEdge: 300))
        #expect(cache.anyTexture(url: Self.url, modified: Self.date, page: 0) === large)
        #expect(cache.anyTexture(url: other(9), modified: Self.date, page: 0) == nil)
    }

    @Test func removeAllForURL() {
        let cache = TextureCache(budgetBytes: 1 << 30)
        cache.insert(texture(64, 64), for: key(longEdge: 64))
        cache.insert(texture(32, 32), for: key(longEdge: 32))
        cache.insert(texture(64, 64), for: key(other(1), longEdge: 64))
        cache.removeAll(for: Self.url)
        #expect(cache.count == 1)
        #expect(cache.usedBytes == Self.smallCost)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.usedBytes == 0)
    }

    @Test func memoryPressureTrims() {
        let cache = TextureCache(budgetBytes: Self.smallCost * 4)
        for i in 1...4 { cache.insert(texture(64, 64), for: key(other(i), longEdge: 64)) }
        cache.handleMemoryPressure(.warning)
        #expect(cache.count == 2)
        #expect(cache.texture(for: key(other(3), longEdge: 64)) != nil)
        #expect(cache.texture(for: key(other(4), longEdge: 64)) != nil)

        // Critical keeps only the most recently used, here 3 (just looked up).
        _ = cache.texture(for: key(other(3), longEdge: 64))
        cache.handleMemoryPressure(.critical)
        #expect(cache.count == 1)
        #expect(cache.texture(for: key(other(3), longEdge: 64)) != nil)
    }
}
