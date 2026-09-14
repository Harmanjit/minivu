import Foundation
import Metal
import QuartzCore
import simd

/// Everything the slideshow needs to draw one frame.
///
/// A slide at rest is a finished transition: `to` the slide, progress 1.
public struct SlideshowFrame {
    /// The slide going away; nil for black (the first slide fades in from it).
    public var from: ImageTexture?
    /// The slide arriving; nil for black.
    public var to: ImageTexture?
    public var transition: SlideshowTransition
    /// Time through the transition, 0...1. The renderer eases it.
    public var progress: Float
    public var direction: SlideshowDirection
    /// What the screen can show above SDR white right now (1 on SDR screens,
    /// or whenever the layer's EDR is off).
    public var displayHeadroom: Float
    /// Scale images smaller than the screen up to fill it, as the viewer's
    /// setting of that name does.
    public var enlargeSmallImages: Bool

    public init(from: ImageTexture?, to: ImageTexture?, transition: SlideshowTransition, progress: Float,
                direction: SlideshowDirection = .forward, displayHeadroom: Float = 1,
                enlargeSmallImages: Bool = false) {
        self.from = from
        self.to = to
        self.transition = transition
        self.progress = progress
        self.direction = direction
        self.displayHeadroom = displayHeadroom
        self.enlargeSmallImages = enlargeSmallImages
    }

    /// `texture` alone, as it rests between transitions.
    public static func still(_ texture: ImageTexture?, displayHeadroom: Float = 1,
                             enlargeSmallImages: Bool = false) -> SlideshowFrame {
        SlideshowFrame(from: nil, to: texture, transition: .crossFade, progress: 1,
                       displayHeadroom: displayHeadroom, enlargeSmallImages: enlargeSmallImages)
    }
}

/// Where each slide sits on screen during a transition. Plain arithmetic on
/// the CPU, so it is unit tested and the shader only mixes.
public enum SlideshowGeometry {
    /// How far the old slide has grown by the end of a zoom.
    public static let zoomOutgoingScale: CGFloat = 1.3
    /// How small the new slide starts in a zoom.
    public static let zoomIncomingScale: CGFloat = 0.9

    /// The image aspect-fit and centred in the view, in whole pixels (top-left
    /// origin). Images smaller than the view stay at one image pixel per
    /// screen pixel unless `enlargeSmall`, as the viewer's best fit does.
    public static func fitRect(imageSize: CGSize, viewSize: CGSize, enlargeSmall: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        var zoom = ViewportTransform.fitZoom(imageSize: imageSize, viewSize: viewSize)
        if !enlargeSmall { zoom = min(zoom, 1) }
        let width = max(1, (imageSize.width * zoom).rounded())
        let height = max(1, (imageSize.height * zoom).rounded())
        return CGRect(x: ((viewSize.width - width) / 2).rounded(), y: ((viewSize.height - height) / 2).rounded(),
                      width: width, height: height)
    }

    /// The rectangles of the old and new slide at eased progress `t`: slide
    /// and push move them a screen's width along the direction of travel,
    /// zoom scales them about their centres.
    public static func rects(transition: SlideshowTransition, progress t: CGFloat, direction: SlideshowDirection,
                             fromImage: CGSize?, toImage: CGSize?, viewSize: CGSize,
                             enlargeSmall: Bool) -> (from: CGRect?, to: CGRect?) {
        var from = fromImage.map { fitRect(imageSize: $0, viewSize: viewSize, enlargeSmall: enlargeSmall) }
        var to = toImage.map { fitRect(imageSize: $0, viewSize: viewSize, enlargeSmall: enlargeSmall) }
        let sign: CGFloat = direction == .forward ? 1 : -1
        switch transition {
        case .slide:
            to = to?.offsetBy(dx: sign * (1 - t) * viewSize.width, dy: 0)
        case .push:
            from = from?.offsetBy(dx: -sign * t * viewSize.width, dy: 0)
            to = to?.offsetBy(dx: sign * (1 - t) * viewSize.width, dy: 0)
        case .zoom:
            from = from.map { scaled($0, by: 1 + (zoomOutgoingScale - 1) * t) }
            to = to.map { scaled($0, by: zoomIncomingScale + (1 - zoomIncomingScale) * t) }
        case .crossFade, .fadeThroughBlack, .wipe, .iris, .dissolve:
            break
        }
        return (from, to)
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let width = rect.width * factor, height = rect.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Mirror of `SlideshowUniforms` in Slideshow.metal. All float4, so the
/// Swift and Metal layouts cannot drift apart through padding.
struct SlideshowUniforms {
    var fromRect = SIMD4<Float>()
    var toRect = SIMD4<Float>()
    var fromInfo = SIMD4<Float>()
    var toInfo = SIMD4<Float>()
    var params = SIMD4<Float>()
    var view = SIMD4<Float>()
}

/// Draws slideshow transitions into a CAMetalLayer configured like the
/// canvas (`CanvasRenderer.configure`: half-float, extended linear Display
/// P3), with the canvas's tone map to the display's headroom.
public final class SlideshowRenderer {
    /// The same format as the canvas, so a layer set up for one suits both.
    public static let pixelFormat = CanvasRenderer.pixelFormat
    /// Soft edges of wipe and iris, as a fraction of the screen's short side.
    static let softEdgeFraction: Float = 0.03
    /// Dissolve blotches across the screen's short side.
    static let noiseCells: Float = 9

    private let gpu: GPU
    private let pipeline: MTLRenderPipelineState
    /// Bound in place of a missing slide: Metal wants every texture the
    /// shader names bound, even one a branch never samples.
    private let black: MTLTexture

    public init(gpu: GPU = .shared) throws {
        self.gpu = gpu
        pipeline = try gpu.renderPipeline("slideshow") { device, library in
            let d = MTLRenderPipelineDescriptor()
            d.label = "Slideshow"
            d.vertexFunction = library.makeFunction(name: "slideshowVertex")
            d.fragmentFunction = library.makeFunction(name: "slideshowFragment")
            d.colorAttachments[0].pixelFormat = SlideshowRenderer.pixelFormat
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let black = gpu.device.makeTexture(descriptor: d) else { throw GPUError.allocationFailed("a black texture") }
        var pixel: [UInt8] = [0, 0, 0, 255]
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        self.black = black
    }

    /// Whether a slideshow layer should ask for EDR while these slides show:
    /// only for HDR content on a screen that can show some of it (see
    /// `CanvasRenderer.wantsExtendedDynamicRange`).
    public static func wantsExtendedDynamicRange(for frame: SlideshowFrame, potentialHeadroom: CGFloat) -> Bool {
        CanvasRenderer.wantsExtendedDynamicRange(for: frame.from, potentialHeadroom: potentialHeadroom)
            || CanvasRenderer.wantsExtendedDynamicRange(for: frame.to, potentialHeadroom: potentialHeadroom)
    }

    static func uniforms(for frame: SlideshowFrame, viewSize: CGSize) -> SlideshowUniforms {
        let t = SlideshowEasing.easeInOut(frame.progress)
        let rects = SlideshowGeometry.rects(transition: frame.transition, progress: CGFloat(t),
                                           direction: frame.direction, fromImage: frame.from?.imageSize,
                                           toImage: frame.to?.imageSize, viewSize: viewSize,
                                           enlargeSmall: frame.enlargeSmallImages)
        var u = SlideshowUniforms()
        u.fromRect = vector(rects.from)
        u.toRect = vector(rects.to)
        u.fromInfo = info(frame.from, rect: rects.from)
        u.toInfo = info(frame.to, rect: rects.to)
        u.params = SIMD4(t, Float(frame.transition.shaderIndex), max(frame.displayHeadroom, 1),
                         frame.direction == .backward ? 1 : 0)
        let shortSide = Float(min(viewSize.width, viewSize.height))
        u.view = SIMD4(Float(viewSize.width), Float(viewSize.height), max(1, shortSide * softEdgeFraction), noiseCells)
        return u
    }

    private static func vector(_ rect: CGRect?) -> SIMD4<Float> {
        guard let rect, rect.width > 0, rect.height > 0 else { return SIMD4(0, 0, 1, 1) }
        return SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
    }

    /// Has-image flag, content headroom and mip level (from how many texels
    /// land on a screen pixel, which changes as a zoom scales the slide).
    private static func info(_ image: ImageTexture?, rect: CGRect?) -> SIMD4<Float> {
        guard let image, let rect, rect.width > 0 else { return SIMD4<Float>() }
        let texelsPerPixel = Float(image.textureSize.width / rect.width)
        let lod = max(0, log2(max(texelsPerPixel, 1e-6)))
        return SIMD4(1, image.isHDR ? image.contentHeadroom : 1, lod, 0)
    }

    /// Draws `frame` and presents it. Returns at once; the GPU finishes
    /// asynchronously.
    public func draw(_ frame: SlideshowFrame, to drawable: CAMetalDrawable) {
        guard let commands = encode(frame, into: drawable.texture) else { return }
        commands.present(drawable)
        commands.commit()
    }

    /// Draws into an offscreen texture and waits, for tests and snapshots.
    public func draw(_ frame: SlideshowFrame, into target: MTLTexture) {
        guard let commands = encode(frame, into: target) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// Renders `frame` offscreen and returns it as an 8-bit sRGB image, for
    /// snapshots (see `CanvasRenderer.snapshot`, which this matches). Reads
    /// pixels back from the GPU, which live frames never do.
    public func snapshot(_ frame: SlideshowFrame, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: d) else { return nil }
        draw(frame, into: target)

        let bytesPerRow = width * 8
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let floatImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                       bytesPerRow: bytesPerRow, space: linear,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                           | CGBitmapInfo.floatComponents.rawValue
                                           | CGBitmapInfo.byteOrder16Little.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false,
                                       intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(floatImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Encodes one pass into `target`; the caller commits.
    private func encode(_ frame: SlideshowFrame, into target: MTLTexture) -> MTLCommandBuffer? {
        var u = Self.uniforms(for: frame, viewSize: CGSize(width: target.width, height: target.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commands = gpu.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        commands.label = "Slideshow"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<SlideshowUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.from?.texture ?? black, index: 0)
        encoder.setFragmentTexture(frame.to?.texture ?? black, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commands
    }
}
