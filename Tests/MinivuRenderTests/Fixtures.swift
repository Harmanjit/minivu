import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
@testable import MinivuRender

/// Builds small test images on disk so tests need no checked-in assets.
enum Fixtures {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// An image split into four solid quadrants: red top-left, green
    /// top-right, blue bottom-left, white bottom-right (as stored).
    static func quadrants(width: Int = 64, height: Int = 32) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG origin is bottom-left, so "top" is the high y half.
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h, width: w, height: h))
        fill(0, 1, 0, CGRect(x: w, y: h, width: w, height: h))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w, height: h))
        fill(1, 1, 1, CGRect(x: w, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, name: String, type: UTType = .tiff,
                      orientation: CGImagePropertyOrientation = .up) -> URL {
        let url = directory.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    /// Renders `frame` into a readable half-float texture and returns it.
    static func render(_ frame: CanvasFrame, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CanvasRenderer.pixelFormat,
                                                         width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = GPU.shared.device.makeTexture(descriptor: d)!
        try CanvasRenderer().draw(frame, into: target)
        return target
    }

    static func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> SIMD4<Float> {
        var p = [Float16](repeating: 0, count: 4)
        texture.getBytes(&p, bytesPerRow: 8 * texture.width,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3]))
    }
}

func near(_ a: SIMD4<Float>, _ b: SIMD3<Float>, tolerance: Float = 0.02) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance
}
