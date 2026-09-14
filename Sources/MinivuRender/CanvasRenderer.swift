import Foundation
import Metal
import QuartzCore
import simd

/// Everything the canvas needs to draw one frame.
public struct CanvasFrame {
    public var image: ImageTexture?
    public var transform: ViewportTransform
    /// Surround colour, linear Display P3.
    public var background: SIMD3<Float>
    /// What the screen can show above SDR white right now (1 on SDR screens).
    public var displayHeadroom: Float
    public var magnifier: Magnifier?
    /// Show pixels as crisp squares when magnified past 200%.
    public var pixelatedZoom: Bool
    public var checkerboard: Bool

    public init(image: ImageTexture?, transform: ViewportTransform, background: SIMD3<Float>,
                displayHeadroom: Float = 1, magnifier: Magnifier? = nil,
                pixelatedZoom: Bool = false, checkerboard: Bool = true) {
        self.image = image
        self.transform = transform
        self.background = background
        self.displayHeadroom = displayHeadroom
        self.magnifier = magnifier
        self.pixelatedZoom = pixelatedZoom
        self.checkerboard = checkerboard
    }
}

/// The one-click magnifier: a circle around the pointer showing the image at
/// `zoom` screen pixels per image pixel.
public struct Magnifier: Equatable, Sendable {
    /// Centre in drawable pixels, top-left origin.
    public var center: CGPoint
    /// Radius in drawable pixels.
    public var radius: CGFloat
    /// Absolute zoom inside the loupe (e.g. 2 = 200%).
    public var zoom: CGFloat

    public init(center: CGPoint, radius: CGFloat, zoom: CGFloat) {
        self.center = center
        self.radius = radius
        self.zoom = zoom
    }
}

/// The canvas shader's HDR roll-off (`toneMapToHeadroom` in Common.h),
/// copied line for line so its properties can be tested without a GPU.
/// Change both together.
enum HeadroomToneMap {
    /// The value a pixel whose largest channel is `peak` is scaled to.
    static func map(peak: Float, displayHeadroom: Float, contentHeadroom: Float) -> Float {
        if contentHeadroom <= displayHeadroom || peak <= 0 { return peak }
        let knee = displayHeadroom * 0.75
        if peak <= knee { return peak }
        let range = displayHeadroom - knee
        let x = (peak - knee) / range
        let xMax = (contentHeadroom - knee) / range
        let y = x * (1 + x / (xMax * xMax)) / (1 + x)
        return knee + range * min(y, 1)
    }
}

/// Mirror of `CanvasUniforms` in Canvas.metal. All float4, so the Swift and
/// Metal layouts cannot drift apart through padding.
struct CanvasUniforms {
    var imageU = SIMD4<Float>()
    var imageV = SIMD4<Float>()
    var loupeU = SIMD4<Float>()
    var loupeV = SIMD4<Float>()
    var background = SIMD4<Float>()
    var loupe = SIMD4<Float>()
    var params = SIMD4<Float>()
    var flags = SIMD4<Float>()
}

/// Draws a `CanvasFrame` into a CAMetalLayer drawable.
public final class CanvasRenderer {
    /// The pixel format canvas layers must use: half-float, so extended
    /// range (HDR) values survive to the compositor.
    public static let pixelFormat: MTLPixelFormat = .rgba16Float

    private let gpu: GPU
    private let pipeline: MTLRenderPipelineState

    public init(gpu: GPU = .shared) throws {
        self.gpu = gpu
        self.pipeline = try gpu.renderPipeline("canvas") { device, library in
            let d = MTLRenderPipelineDescriptor()
            d.label = "Canvas"
            d.vertexFunction = library.makeFunction(name: "canvasVertex")
            d.fragmentFunction = library.makeFunction(name: "canvasFragment")
            d.colorAttachments[0].pixelFormat = CanvasRenderer.pixelFormat
            return try device.makeRenderPipelineState(descriptor: d)
        }
    }

    /// Configures a layer for the canvas: extended linear Display P3, EDR off.
    ///
    /// EDR makes the display raise its backlight and dim everything else to
    /// match, which costs power, so the owner turns it on with
    /// `setExtendedDynamicRange` only while an HDR image is shown.
    public static func configure(_ layer: CAMetalLayer, gpu: GPU = .shared) {
        layer.device = gpu.device
        layer.pixelFormat = pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = false
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
    }

    /// Whether a canvas showing `image` on a screen that can reach
    /// `potentialHeadroom` should ask for EDR: only for HDR content, and only
    /// where the screen can show some of it.
    public static func wantsExtendedDynamicRange(for image: ImageTexture?, potentialHeadroom: CGFloat) -> Bool {
        guard let image, image.isHDR, image.contentHeadroom > 1 else { return false }
        return potentialHeadroom > 1
    }

    /// Turns EDR on or off for a canvas layer (see `configure`). While it's
    /// off, frames must be drawn for a headroom of 1: the compositor clips
    /// anything brighter.
    public static func setExtendedDynamicRange(_ enabled: Bool, on layer: CAMetalLayer) {
        if layer.wantsExtendedDynamicRangeContent != enabled { layer.wantsExtendedDynamicRangeContent = enabled }
    }

    static func uniforms(for frame: CanvasFrame, viewSize: CGSize) -> CanvasUniforms {
        var u = CanvasUniforms()
        u.background = SIMD4(frame.background, 1)
        guard let image = frame.image else { return u }

        let map = frame.transform.screenToUV(imageSize: image.imageSize, viewSize: viewSize)
        u.imageU = SIMD4(map.columns.0.x, map.columns.1.x, map.columns.2.x, 0)
        u.imageV = SIMD4(map.columns.0.y, map.columns.1.y, map.columns.2.y, 0)

        // Texels of the actual texture per screen pixel, for mip selection.
        let texelsPerImagePixel = image.textureSize.width / max(image.imageSize.width, 1)
        let imageTexels = texelsPerImagePixel / max(frame.transform.zoom, 1e-6)
        u.params = SIMD4(max(frame.displayHeadroom, 1), image.isHDR ? image.contentHeadroom : 1,
                         Float(imageTexels), Float(imageTexels))
        u.flags = SIMD4(1, 0, frame.pixelatedZoom ? 1 : 0, frame.checkerboard ? 1 : 0)

        if let m = frame.magnifier {
            // The loupe shows the image point under its centre, at m.zoom.
            let anchor = frame.transform.imagePoint(forScreenPoint: m.center, viewSize: viewSize)
            let zoomed = ViewportTransform(zoom: m.zoom, center: anchor)
            // screenToUV centres the transform on viewSize/2; a view twice the
            // loupe's centre coordinates puts that centre on the loupe.
            let shifted = CGSize(width: 2 * m.center.x, height: 2 * m.center.y)
            let lmap = zoomed.screenToUV(imageSize: image.imageSize, viewSize: shifted)
            u.loupeU = SIMD4(lmap.columns.0.x, lmap.columns.1.x, lmap.columns.2.x, 0)
            u.loupeV = SIMD4(lmap.columns.0.y, lmap.columns.1.y, lmap.columns.2.y, 0)
            u.loupe = SIMD4(Float(m.center.x), Float(m.center.y), Float(m.radius), 3)
            u.params.w = Float(texelsPerImagePixel / max(m.zoom, 1e-6))
            u.flags.y = 1
        }
        return u
    }

    /// Draws `frame` and presents it. Returns immediately; the GPU finishes
    /// asynchronously.
    public func draw(_ frame: CanvasFrame, to drawable: CAMetalDrawable) {
        draw(frame, to: drawable, presentsWithTransaction: false)
    }

    /// Draws `frame` and presents it.
    ///
    /// With `presentsWithTransaction` (for a layer whose property of that
    /// name is set, during live window resize) this waits until the GPU has
    /// scheduled the frame and then presents inside the current Core
    /// Animation transaction, so the new pixels appear together with the new
    /// window size instead of a stretched old frame.
    public func draw(_ frame: CanvasFrame, to drawable: CAMetalDrawable, presentsWithTransaction: Bool) {
        guard let commands = encode(frame, into: drawable.texture) else { return }
        if presentsWithTransaction {
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
    }

    /// Draws into an offscreen texture, for tests and snapshots.
    public func draw(_ frame: CanvasFrame, into target: MTLTexture) {
        guard let commands = encode(frame, into: target) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// Renders `frame` offscreen at `width` x `height` pixels and returns it
    /// as an 8-bit sRGB image (for tests, thumbnails of the view, sharing).
    ///
    /// This reads pixels back from the GPU, a copy the live canvas never
    /// makes; it is for occasional snapshots only. Values beyond sRGB (HDR
    /// highlights, P3 colours) are clipped by the conversion.
    public func snapshot(_ frame: CanvasFrame, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: d) else { return nil }
        draw(frame, into: target)

        // Half floats in extended linear Display P3, rows top first, the same
        // layout CGImage uses; ColorSync converts to sRGB when drawn below.
        let bytesPerRow = width * 8
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
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

    /// Encodes one canvas pass into `target`; the caller commits.
    private func encode(_ frame: CanvasFrame, into target: MTLTexture) -> MTLCommandBuffer? {
        let viewSize = CGSize(width: target.width, height: target.height)
        var u = Self.uniforms(for: frame, viewSize: viewSize)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let commands = gpu.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        if let image = frame.image { encoder.setFragmentTexture(image.texture, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commands
    }
}
