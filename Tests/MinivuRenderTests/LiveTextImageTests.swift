import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// The canvas's texture read back as the picture Live Text recognises:
/// upright, no larger than it needs to be, and with HDR highlights tone
/// mapped rather than clipped.
@Suite struct LiveTextImageTests {
    /// The pixel at `x`, `y` (top-left origin) as 8-bit red, green, blue.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func texture(width: Int, height: Int) throws -> ImageTexture {
        let url = Fixtures.write(Fixtures.quadrants(width: width, height: height), name: "livetext-\(UUID()).png",
                                 type: .png)
        return try TextureUploader.upload(ImageDecoder.decode(url))
    }

    /// Red stays at the top left and blue at the bottom left: Core Image
    /// reads a texture's first row as the bottom, and a picture handed to
    /// text recognition upside down would read as nothing at all.
    @Test func thePictureComesOutUprightAtTheTexturesSize() throws {
        let image = try #require(LiveTextImage.render(try texture(width: 64, height: 32)))
        #expect(image.width == 64 && image.height == 32)
        let topLeft = pixel(image, 8, 8), bottomLeft = pixel(image, 8, 24)
        #expect(topLeft.0 > 200 && topLeft.2 < 50, "red at the top left: \(topLeft)")
        #expect(bottomLeft.2 > 200 && bottomLeft.0 < 50, "blue at the bottom left: \(bottomLeft)")
    }

    /// A full-resolution texture (the user zoomed in) is scaled down to the
    /// limit, keeping its shape and its orientation.
    @Test func aLargeTextureIsScaledDownToTheLimit() throws {
        let image = try #require(LiveTextImage.render(try texture(width: 400, height: 200), maximumLongEdge: 100))
        #expect(image.width == 100 && image.height == 50)
        let topLeft = pixel(image, 10, 10)
        #expect(topLeft.0 > 200 && topLeft.2 < 50, "\(topLeft)")
    }

    /// The gain-map ramp climbs to four times SDR white. Clipped, its whole
    /// bright half would be one flat white and any text there would vanish;
    /// tone mapped, twice and four times white are still told apart.
    @Test func hdrHighlightsAreToneMappedNotClipped() throws {
        let hdr = try TextureUploader.upload(ImageDecoder.decode(Fixtures.gainMapHEIC()))
        #expect(hdr.isHDR && hdr.contentHeadroom > 3)
        let image = try #require(LiveTextImage.render(hdr))
        let y = image.height / 2
        let half = pixel(image, image.width / 2, y).1, end = pixel(image, image.width - 2, y).1
        #expect(end - half > 8, "2x white \(half), 4x white \(end)")
        #expect(half < 250, "2x white is not clipped to white: \(half)")
    }
}
