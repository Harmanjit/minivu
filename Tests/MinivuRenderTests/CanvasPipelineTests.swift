import Testing
import CoreGraphics
import ImageIO
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// End to end: file -> decode -> upload -> canvas -> pixels.
@Suite(.serialized) struct CanvasPipelineTests {
    // sRGB primaries expressed in linear Display P3 (what the canvas outputs).
    static let red = SIMD3<Float>(0.8225, 0.0332, 0.0171)
    static let green = SIMD3<Float>(0.1774, 0.9669, 0.0724)
    static let blue = SIMD3<Float>(0, 0, 0.9108)
    static let white = SIMD3<Float>(1, 1, 1)

    func renderActualSize(_ decoded: DecodedImage) throws -> MTLTexture {
        let texture = try TextureUploader.upload(decoded)
        let size = decoded.imageSize
        let frame = CanvasFrame(image: texture,
                                transform: ViewportTransform(zoom: 1, center: CGPoint(x: size.width / 2, y: size.height / 2)),
                                background: SIMD3(0, 0, 0))
        return try Fixtures.render(frame, width: Int(size.width), height: Int(size.height))
    }

    @Test func shadersCompileAndSRGBBecomesLinearP3() throws {
        let url = Fixtures.write(Fixtures.quadrants(), name: "quad.tiff")
        let out = try renderActualSize(ImageDecoder.decode(url))
        #expect(near(Fixtures.pixel(out, 8, 8), Self.red))
        #expect(near(Fixtures.pixel(out, 56, 8), Self.green))
        #expect(near(Fixtures.pixel(out, 8, 24), Self.blue))
        #expect(near(Fixtures.pixel(out, 56, 24), Self.white))
    }

    /// Orientation 6 (.right): displayed top-left is the stored bottom-left.
    @Test(arguments: [false, true])
    func orientationRightAtFullAndScaledSize(scaled: Bool) throws {
        let url = Fixtures.write(Fixtures.quadrants(), name: "quad-right-\(scaled).tiff", orientation: .right)
        let decoded = try ImageDecoder.decode(url, maxPixelSize: scaled ? 63 : nil)
        #expect(decoded.imageSize == CGSize(width: 32, height: 64))
        #expect(decoded.orientation == .up)
        let texture = try TextureUploader.upload(decoded)
        let frame = CanvasFrame(image: texture, transform: ViewportTransform(zoom: 1, center: CGPoint(x: 16, y: 32)),
                                background: SIMD3(0, 0, 0))
        let out = try Fixtures.render(frame, width: 32, height: 64)
        #expect(near(Fixtures.pixel(out, 6, 10), Self.blue, tolerance: 0.05))
        #expect(near(Fixtures.pixel(out, 26, 10), Self.red, tolerance: 0.05))
        #expect(near(Fixtures.pixel(out, 6, 54), Self.white, tolerance: 0.05))
        #expect(near(Fixtures.pixel(out, 26, 54), Self.green, tolerance: 0.05))
    }

    /// The uploader can also orient an unrotated image itself; it must agree
    /// with ImageIO for all eight orientations.
    @Test(arguments: [CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left])
    func uploaderOrientationMatchesImageIO(orientation: CGImagePropertyOrientation) throws {
        let url = Fixtures.write(Fixtures.quadrants(), name: "quad-\(orientation.rawValue).tiff", orientation: orientation)
        let reference = try ImageDecoder.decode(url)   // ImageIO applies the transform
        let stored = Fixtures.quadrants()
        let manual = DecodedImage(image: stored, orientation: orientation, imageSize: reference.imageSize,
                                  isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        let a = try renderActualSize(manual)
        let b = try renderActualSize(reference)
        let w = a.width, h = a.height
        for (x, y) in [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)] {
            let pa = Fixtures.pixel(a, x, y), pb = Fixtures.pixel(b, x, y)
            #expect(near(pa, SIMD3(pb.x, pb.y, pb.z), tolerance: 0.05), "orientation \(orientation.rawValue) at \(x),\(y)")
        }
    }

    @Test func magnifierShowsZoomedPixels() throws {
        let url = Fixtures.write(Fixtures.quadrants(width: 400, height: 200), name: "quad-big.tiff")
        let texture = try TextureUploader.upload(ImageDecoder.decode(url))
        // Fit 400x200 into 100x50, loupe at the centre with 4x zoom and a
        // 20 px radius: the loupe spans image pixels 195...205 horizontally,
        // so its left half is red/blue and right half green/white.
        var frame = CanvasFrame(image: texture, transform: .bestFit(imageSize: texture.imageSize,
                                                                    viewSize: CGSize(width: 100, height: 50)),
                                background: SIMD3(0, 0, 0))
        frame.magnifier = Magnifier(center: CGPoint(x: 50, y: 25), radius: 20, zoom: 4)
        let out = try Fixtures.render(frame, width: 100, height: 50)
        #expect(near(Fixtures.pixel(out, 45, 20), Self.red, tolerance: 0.05))
        #expect(near(Fixtures.pixel(out, 55, 30), Self.white, tolerance: 0.05))
    }
}

/// Transparent pixels must upload as transparent, whatever the freshly
/// allocated memory held before (the uploader doesn't zero it).
@Suite(.serialized) struct TransparentUploadTests {
    @Test func transparentPixelsAreClearEvenOnDirtyMemory() throws {
        // Dirty the allocator: fill and free a few page-sized blocks of the
        // size the upload will ask for.
        let byteCount = 64 * 64 * 4 + 16384
        for _ in 0..<8 {
            let p = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: Int(getpagesize()))
            p.initializeMemory(as: UInt8.self, repeating: 0xC8, count: byteCount)
            p.deallocate()
        }
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))   // left half red, right half clear
        let decoded = DecodedImage(image: ctx.makeImage()!, orientation: .up, imageSize: CGSize(width: 64, height: 64),
                                   isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        let texture = try TextureUploader.upload(decoded)
        let frame = CanvasFrame(image: texture, transform: ViewportTransform(zoom: 1, center: CGPoint(x: 32, y: 32)),
                                background: SIMD3(0, 0, 1), checkerboard: false)
        let out = try Fixtures.render(frame, width: 64, height: 64)
        // The clear half shows the blue background exactly.
        #expect(near(Fixtures.pixel(out, 48, 32), SIMD3(0, 0, 1), tolerance: 0.002))
        #expect(near(Fixtures.pixel(out, 16, 32), CanvasPipelineTests.red, tolerance: 0.02))
    }
}
