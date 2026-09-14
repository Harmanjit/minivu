import Testing
import Foundation
import CoreGraphics
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// The GPU histogram against textures whose exact bin counts are known.
@Suite(.serialized) struct HistogramTests {
    /// An 8-bit Display P3 image from a per-pixel colour function, uploaded
    /// the way the viewer uploads a photo (mipmapped bgra8Unorm_srgb). The
    /// image is already in the working space, so the upload keeps every byte.
    func texture(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> ImageTexture {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let decoded = DecodedImage(image: image, orientation: .up, imageSize: CGSize(width: width, height: height),
                                   isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        let uploaded = try TextureUploader.upload(decoded)
        #expect(uploaded.texture.pixelFormat == .bgra8Unorm_srgb)
        return uploaded
    }

    /// A half-float texture of extended linear values, as HDR photos and
    /// edit renders are stored.
    func floatTexture(width: Int, height: Int, alpha: (Int, Int) -> Float = { _, _ in 1 },
                      _ value: (Int, Int) -> SIMD3<Float>) throws -> ImageTexture {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let i = (y * width + x) * 4
                pixels[i] = Float16(v.x); pixels[i + 1] = Float16(v.y); pixels[i + 2] = Float16(v.z)
                pixels[i + 3] = Float16(alpha(x, y))
            }
        }
        let gpu = GPU.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                         mipmapped: true)
        d.storageMode = .private
        let shared = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                              mipmapped: false)
        shared.storageMode = .shared
        let source = try #require(gpu.device.makeTexture(descriptor: shared))
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                       bytesPerRow: width * 8)
        let texture = try #require(gpu.device.makeTexture(descriptor: d))
        let commands = try #require(gpu.queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return ImageTexture(texture: texture, imageSize: CGSize(width: width, height: height), isFullResolution: true,
                            isHDR: true, contentHeadroom: 4)
    }

    /// The bin the kernel puts a linear value in, computed the same way.
    func bin(linear: Double) -> Int {
        let c = min(max(linear, 0), 1)
        let encoded = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return Int(encoded * 255 + 0.5)
    }

    func only(_ bins: [UInt32], _ expected: [Int: UInt32]) -> Bool {
        bins.indices.allSatisfy { bins[$0] == (expected[$0] ?? 0) }
    }

    @Test func midGreyFillsOneBinOfEveryChannel() throws {
        let data = try Histogram.compute(texture: texture(width: 100, height: 60) { _, _ in (128, 128, 128) })
        #expect(data.level == 0)
        #expect(data.pixelCount == 6000)
        for channel in HistogramData.Channel.allCases {
            #expect(only(data.bins(channel), [128: 6000]), "\(channel)")
            #expect(data.shadowClipping(channel) == 0 && data.highlightClipping(channel) == 0)
        }
        #expect(data.aboveSDRWhite == 0)
        #expect(data.peak() == 6000)
    }

    @Test func twoColourSplitCountsEachHalf() throws {
        // Pure P3 red on the left, pure P3 blue on the right; 63 px wide so
        // threadgroups straddle the edge.
        let data = try Histogram.compute(texture: texture(width: 63, height: 41) { x, _ in x < 30 ? (255, 0, 0) : (0, 0, 255) })
        let left: UInt32 = 30 * 41, right: UInt32 = 33 * 41
        #expect(only(data.red, [255: left, 0: right]))
        #expect(only(data.green, [0: left + right]))
        #expect(only(data.blue, [0: left, 255: right]))
        #expect(only(data.luminance, [bin(linear: 0.2289746): left, bin(linear: 0.0792869): right]))
        #expect(abs(data.highlightClipping(.red) - Double(left) / Double(left + right)) < 1e-9)
        #expect(abs(data.shadowClipping(.green) - 1) < 1e-9)
        #expect(data.aboveSDRWhite == 0)
    }

    @Test func rampPutsFourPixelsInEveryBin() throws {
        let data = try Histogram.compute(texture: texture(width: 256, height: 4) { x, _ in
            (UInt8(x), UInt8(x), UInt8(x))
        })
        #expect(data.pixelCount == 1024)
        for channel in HistogramData.Channel.allCases {
            #expect(data.bins(channel) == [UInt32](repeating: 4, count: 256), "\(channel)")
        }
    }

    @Test func extendedRangeValuesClipToTheTopBinAndCountAsAboveWhite() throws {
        // Left half linear 0.5 grey, right half 2x white (an HDR highlight),
        // plus one column at exactly 1.0, which is white, not above it.
        let data = try Histogram.compute(texture: floatTexture(width: 40, height: 10) { x, _ in
            x == 39 ? SIMD3(repeating: 1) : x < 20 ? SIMD3(repeating: 0.5) : SIMD3(2, 1.5, 3)
        })
        let grey = bin(linear: 0.5)
        #expect(grey == 188)
        for channel in HistogramData.Channel.allCases {
            #expect(only(data.bins(channel), [grey: 200, 255: 200]), "\(channel)")
        }
        #expect(data.aboveSDRWhite == 190)
        #expect(abs(data.aboveSDRWhiteFraction - 0.475) < 1e-9)
    }

    /// An 8-bit premultiplied texture with alpha, as a PNG with transparency
    /// is stored (mipmapped bgra8Unorm_srgb). Written straight into the
    /// texture: the uploader draws over memory it doesn't clear, so a small
    /// transparent image can pick up stale bytes there.
    func translucentTexture(width: Int, height: Int,
                            _ color: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> ImageTexture {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = a
            }
        }
        let gpu = GPU.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                         mipmapped: true)
        d.storageMode = .shared
        let texture = try #require(gpu.device.makeTexture(descriptor: d))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
                        bytesPerRow: width * 4)
        return ImageTexture(texture: texture, imageSize: CGSize(width: width, height: height), isFullResolution: true,
                            isHDR: false, contentHeadroom: 1)
    }

    /// A logo on a clear background: the clear pixels are not black, and a
    /// translucent pixel counts as its own colour, for both texture kinds.
    @Test func transparentPixelsAreLeftOutAndTranslucentOnesUnpremultiplied() throws {
        // 40 x 10: columns 0-19 fully transparent, 20-29 white at half
        // alpha (premultiplied 128), 30-39 opaque grey 128.
        let eight = try Histogram.compute(texture: translucentTexture(width: 40, height: 10) { x, _ in
            x < 20 ? (0, 0, 0, 0) : x < 30 ? (128, 128, 128, 128) : (128, 128, 128, 255)
        })
        #expect(eight.pixelCount == 200)
        #expect(eight.sampledWidth * eight.sampledHeight == 400)
        for channel in HistogramData.Channel.allCases {
            #expect(only(eight.bins(channel), [255: 100, 128: 100]), "\(channel)")
            #expect(eight.shadowClipping(channel) == 0)
        }

        // Half-float, premultiplied in linear light: 0.25 at alpha 0.5 is
        // linear 0.5.
        let float = try Histogram.compute(texture: floatTexture(width: 40, height: 10, alpha: { x, _ in
            x < 20 ? 0 : x < 30 ? 0.5 : 1
        }) { x, _ in x < 20 ? SIMD3(repeating: 0) : x < 30 ? SIMD3(repeating: 0.25) : SIMD3(repeating: 1) })
        #expect(float.pixelCount == 200)
        for channel in HistogramData.Channel.allCases {
            #expect(only(float.bins(channel), [bin(linear: 0.5): 100, 255: 100]), "\(channel)")
        }
        #expect(float.aboveSDRWhite == 0)

        // Nothing but transparency: no pixels, no clipping, no division by zero.
        let clear = try Histogram.compute(texture: translucentTexture(width: 8, height: 8) { _, _ in (0, 0, 0, 0) })
        #expect(clear.pixelCount == 0)
        #expect(clear.shadowClipping(.red) == 0)
    }

    @Test func measuresTheMipLevelClosestTo1024() throws {
        #expect(Histogram.level(width: 800, height: 600, levelCount: 10) == 0)
        #expect(Histogram.level(width: 2048, height: 1024, levelCount: 12) == 1)
        #expect(Histogram.level(width: 4096, height: 3000, levelCount: 13) == 2)
        // 6032 px: 1508 is 1.47x too big, 754 only 1.36x too small.
        #expect(Histogram.level(width: 6032, height: 4032, levelCount: 13) == 3)
        // Portrait: the long edge decides.
        #expect(Histogram.level(width: 1000, height: 3000, levelCount: 12) == 2)
        #expect(Histogram.level(width: 16384, height: 100, levelCount: 15) == 4)
        // No mips, or too few to reach the target: the closest there is.
        #expect(Histogram.level(width: 8000, height: 8000, levelCount: 1) == 0)
        #expect(Histogram.level(width: 8000, height: 8000, levelCount: 2) == 1)

        // A real 4096 x 2048 upload is measured at 1024 x 512.
        let data = try Histogram.compute(texture: texture(width: 4096, height: 2048) { _, _ in (128, 128, 128) })
        #expect(data.level == 2)
        #expect(data.sampledWidth == 1024 && data.sampledHeight == 512)
        #expect(data.pixelCount == 1024 * 512)
        #expect(data.luminance.reduce(0, +) == 1024 * 512)
        #expect(data.green[128] == 1024 * 512)
    }
}
