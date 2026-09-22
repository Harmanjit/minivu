import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

extension TestImages {
    /// A PNG whose header claims `width` x `height` while the file holds
    /// only `rows` scanlines of black, stored uncompressed: what a file that
    /// costs kilobytes to keep and gigabytes to decode looks like, whether
    /// it was built to be one or is simply a very large flat image.
    ///
    /// ImageIO won't describe a file whose pixel data is missing altogether,
    /// so the fixture has to carry some: three rows of a 40000 px image
    /// (360 KB) is about the least it will still read the header of.
    @discardableResult
    static func forgedPNG(width: Int, height: Int, rows: Int, to url: URL) throws -> URL {
        let rowBytes = 1 + width * 3                            // a filter byte, then 8-bit RGB
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", be(UInt32(width)) + be(UInt32(height)) + [8, 2, 0, 0, 0])
        file += chunk("IDAT", zlibZeros(count: rowBytes * rows))
        file += chunk("IEND", [])
        try Data(file).write(to: url)
        return url
    }

    /// A PNG chunk: its payload's length, its type, the payload, and the
    /// CRC-32 over type and payload that the format asks for.
    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        return be(UInt32(payload.count)) + body + be(crc32(body))
    }

    private static func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// `count` zero bytes as a zlib stream of stored (uncompressed) deflate
    /// blocks, each with its length and that length's complement, so the
    /// fixture needs no compressor.
    private static func zlibZeros(count: Int) -> [UInt8] {
        var stream: [UInt8] = [0x78, 0x01]
        var written = 0
        while written < count {
            let n = min(65535, count - written)
            stream += [written + n == count ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8),
                       UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            stream += [UInt8](repeating: 0, count: n)
            written += n
        }
        // Adler-32 of a run of zeros: the running sum stays 1, and the sum
        // of those sums simply counts the bytes.
        return stream + be(UInt32(count % 65521) << 16 | 1)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

@Suite struct DecodeSizeTests {
    @Test func snapsToCodecFractions() {
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3000) == 3016)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3024) == 3016)   // within 3%
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 1400) == 1508)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 500) == 754)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3200) == 6032)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 101, needed: 20) == 26)        // rounds up
    }

    @Test func fitsTheImageIntoTheView() {
        func fit(_ iw: CGFloat, _ ih: CGFloat, _ vw: CGFloat, _ vh: CGFloat) -> Int {
            ImageDecoder.fittedLongEdge(imageSize: CGSize(width: iw, height: ih), in: CGSize(width: vw, height: vh))
        }
        // A 24 MP 3:2 photo on a 3420 px wide canvas: the height limits it.
        #expect(fit(6000, 4000, 3420, 2214) == 3321)
        #expect(fit(6000, 4000, 3420, 2000) == 3000)
        #expect(fit(6000, 4000, 3000, 3000) == 3000)   // a square view gives its side
        #expect(fit(4000, 6000, 3000, 3000) == 3000)
        // Portrait in a landscape view, and the same view turned.
        #expect(fit(4000, 6000, 3420, 2214) == 2214)
        #expect(fit(4000, 6000, 2214, 3420) == 3321)
        // Width-limited, exactly on a pixel despite a scale like 3420/6032.
        #expect(fit(6032, 4032, 3420, 3000) == 3420)
        #expect(fit(6032, 4032, 3420, 2048) == 3064)
        // Small images are enlarged to fit; callers cap at the image.
        #expect(fit(400, 200, 3000, 3000) == 3000)
        // Unknown image size: the view's long edge.
        #expect(fit(0, 0, 3420, 2214) == 3420)
    }

    @Test func wantedLongEdgeTakesTheSmallerLimit() {
        let image = CGSize(width: 6000, height: 4000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: nil, fitting: nil) == nil)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: 2000, fitting: nil) == 2000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: nil, fitting: CGSize(width: 3420, height: 2000)) == 3000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: 2000, fitting: CGSize(width: 3420, height: 2000)) == 2000)
    }

    /// The thumbnail budget is the app's own export cap, the same on every
    /// Mac, so what minivu will thumbnail does not depend on the machine.
    /// Every photograph and scan there is passes: a 151 MP frame, a 205 MP
    /// drum scan, an A0 page at 300 dpi.
    @Test func theThumbnailBudgetIsTheExportCap() {
        #expect(ImageDecoder.thumbnailPixelBudget == 32768 * 32768)
        // A billion pixels: five times the largest drum scan there is.
        let megapixel = 1 << 20
        #expect(ImageDecoder.thumbnailPixelBudget > 512 * megapixel)
    }

    /// A header claiming more pixels than the budget allows gets no
    /// thumbnail, and an ordinary photograph is untouched by the check.
    @Test func headersOverTheBudgetGetNoThumbnail() throws {
        let folder = try TemporaryFolder()
        let bomb = try TestImages.forgedPNG(width: 40000, height: 30000, rows: 3,
                                            to: folder.url.appendingPathComponent("bomb.png"))
        let source = try #require(CGImageSourceCreateWithURL(bomb as CFURL, nil))
        let pixels = ImageDecoder.headerPixelCount(source: source, index: 0)
        try #require(pixels == 40000 * 30000, "ImageIO no longer reads this fixture's header (\(pixels) px)")
        #expect(pixels > Double(ImageDecoder.thumbnailPixelBudget))
        #expect(ImageDecoder.thumbnail(for: bomb, maxPixelSize: 256) == nil)

        let photo = TestImages.write(TestImages.gradient(width: 640, height: 480),
                                     to: folder.url.appendingPathComponent("photo.jpg"))
        let photoSource = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil))
        #expect(ImageDecoder.headerPixelCount(source: photoSource, index: 0) == 640 * 480)
        #expect(ImageDecoder.thumbnail(for: photo, maxPixelSize: 256)?.width == 256)
    }
}
