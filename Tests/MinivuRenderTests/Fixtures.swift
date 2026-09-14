import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import CoreImage
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

    // MARK: - HDR

    static let hdrWidth = 256, hdrHeight = 64

    /// A grey ramp from 0 at the left to 4x SDR white at the right, in
    /// extended linear sRGB: the HDR rendition both HDR fixtures carry.
    static func hdrRamp() -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: CGFloat(hdrWidth), y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, colorSpace: space)!,
            "inputColor1": CIColor(red: 4, green: 4, blue: 4, colorSpace: space)!,
        ])!
        return gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: hdrWidth, height: hdrHeight))
    }

    /// An HEIC with an SDR base image and a gain map that lifts it back to
    /// the ramp, as an iPhone photo stores HDR. Decoded for HDR its content
    /// headroom is about 3.94.
    static func gainMapHEIC(name: String = "hdr-gainmap-\(UUID()).heic") throws -> URL {
        let ramp = hdrRamp()
        let sdr = ramp.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4, "inputTargetHeadroom": 1])
        guard let data = CIContext().heifRepresentation(of: sdr, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                        options: [.hdrImage: ramp])
        else { throw CocoaError(.fileWriteUnknown) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A 10-bit HEIC in the PQ transfer (BT.2100), as HDR video frames and
    /// some cameras store HDR. Content headroom about 4.93.
    static func pqHEIC(name: String = "hdr-pq-\(UUID()).heic") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try CIContext().writeHEIF10Representation(of: hdrRamp(), to: url,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!,
                                                  options: [:])
        return url
    }

    /// A CPU-readable copy of a (usually private) texture's top mip level.
    static func readable(_ texture: MTLTexture) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                         height: texture.height, mipmapped: false)
        d.storageMode = .shared
        let copy = GPU.shared.device.makeTexture(descriptor: d)!
        let commands = GPU.shared.queue.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, to: copy, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return copy
    }

    /// Draws `texture` at 100% into a half-float target the size of the image.
    static func renderActualSize(_ texture: ImageTexture, displayHeadroom: Float) throws -> MTLTexture {
        let size = texture.imageSize
        let frame = CanvasFrame(image: texture,
                                transform: ViewportTransform(zoom: 1, center: CGPoint(x: size.width / 2, y: size.height / 2)),
                                background: SIMD3(0, 0, 0), displayHeadroom: displayHeadroom)
        return try render(frame, width: Int(size.width), height: Int(size.height))
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
