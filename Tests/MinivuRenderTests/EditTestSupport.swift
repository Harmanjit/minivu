import Foundation
import CoreGraphics
import CoreImage
import Metal
import simd
@testable import MinivuRender
@testable import MinivuCore

/// Images and pixel readers for the editing tests, all in the edit graph's
/// working space (extended linear Display P3), so expected values are the
/// numbers written, with no colour conversion in between.
enum EditFixtures {
    static let space = EditRenderer.workingSpace

    /// Same options as `EditRenderer`'s context.
    static let context = CIContext(mtlCommandQueue: GPU.shared.queue, options: [
        .workingColorSpace: space,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    static let red = SIMD4<Float>(1, 0, 0, 1)
    static let green = SIMD4<Float>(0, 1, 0, 1)
    static let blue = SIMD4<Float>(0, 0, 1, 1)
    static let white = SIMD4<Float>(1, 1, 1, 1)

    /// An image from premultiplied RGBA values, rows top first.
    static func image(width: Int, height: Int, pixel: (_ x: Int, _ yTop: Int) -> SIMD4<Float>) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y)
                let i = (y * width + x) * 4
                data[i] = p.x; data[i + 1] = p.y; data[i + 2] = p.z; data[i + 3] = p.w
            }
        }
        return CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }

    /// Red top-left, green top-right, blue bottom-left, white bottom-right.
    static func quadrants(width: Int = 64, height: Int = 32) -> CIImage {
        image(width: width, height: height) { x, y in
            switch (x < width / 2, y < height / 2) {
            case (true, true): red
            case (false, true): green
            case (true, false): blue
            case (false, false): white
            }
        }
    }

    static func flat(_ value: Float, width: Int, height: Int, alpha: Float = 1) -> CIImage {
        image(width: width, height: height) { _, _ in SIMD4(value * alpha, value * alpha, value * alpha, alpha) }
    }

    /// Every pixel of `image` (extent at the origin), top row first.
    struct Pixels {
        let width: Int
        let height: Int
        let data: [Float]

        subscript(x: Int, yTop: Int) -> SIMD4<Float> {
            let i = (yTop * width + x) * 4
            return SIMD4(data[i], data[i + 1], data[i + 2], data[i + 3])
        }

        /// The pixel at a fraction of the width and height, for "the middle
        /// of the top-left quadrant" without caring about the exact size.
        func at(_ fx: Double, _ fy: Double) -> SIMD4<Float> {
            self[min(Int(fx * Double(width)), width - 1), min(Int(fy * Double(height)), height - 1)]
        }

        var all: [SIMD4<Float>] { (0..<(width * height)).map { self[$0 % width, $0 / width] } }
    }

    static func pixels(_ image: CIImage, bounds: CGRect? = nil) -> Pixels {
        let rect = bounds ?? image.extent
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        var data = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 16, bounds: rect, format: .RGBAf, colorSpace: space)
        return Pixels(width: width, height: height, data: data)
    }

    /// A readable copy of a texture's top level (rgba16Float), top row first.
    static func pixels(_ texture: MTLTexture) -> Pixels {
        let readable = Fixtures.readable(texture)
        var half = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        readable.getBytes(&half, bytesPerRow: texture.width * 8,
                          from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return Pixels(width: texture.width, height: texture.height, data: half.map { Float($0) })
    }

    /// sRGB transfer, mirrored for negatives: what the tone kernels call
    /// encoded values.
    static func encode(_ c: Float) -> Float {
        let a = abs(c)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return c < 0 ? -e : e
    }

    static func decode(_ e: Float) -> Float {
        let a = abs(e)
        let c = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return e < 0 ? -c : c
    }
}

func nearly(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tolerance: Float = 2e-3) -> Bool {
    let d = abs(a - b)
    return d.x <= tolerance && d.y <= tolerance && d.z <= tolerance && d.w <= tolerance
}

func nearly(_ a: Float, _ b: Float, _ tolerance: Float = 2e-3) -> Bool {
    abs(a - b) <= tolerance
}
