import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import MinivuCore

/// A document's decoded original, on the GPU.
///
/// Immutable, so it can be shared with background renders and exports.
/// `@unchecked Sendable` because Metal textures and `CIImage` are safe to
/// use from any thread and nothing here changes after init.
final class EditSource: @unchecked Sendable {
    /// Keeps the pixels alive; `image` reads them.
    let texture: MTLTexture
    /// Extent at the origin, Core Image's y-up orientation, upright.
    let image: CIImage
    /// Pixel size (oriented, at most 16384 on the long edge).
    let size: CGSize
    let isHDR: Bool
    let contentHeadroom: Float

    init(texture: MTLTexture, image: CIImage, size: CGSize, isHDR: Bool, contentHeadroom: Float) {
        self.texture = texture
        self.image = image
        self.size = size
        self.isHDR = isHDR
        self.contentHeadroom = contentHeadroom
    }
}

/// A smaller copy of the original that slider renders run on.
final class EditProxy: @unchecked Sendable {
    let texture: MTLTexture
    let image: CIImage
    /// Its size over the original's (`EditGraph.workingLength` per axis).
    let scale: Double

    init(texture: MTLTexture, image: CIImage, scale: Double) {
        self.texture = texture
        self.image = image
        self.scale = scale
    }
}

/// Renders edit documents: screen previews while editing, full resolution
/// for zooming in, and final pixels for saving (DESIGN.md 4.7).
///
/// **The original** is decoded once per document at full resolution into a
/// GPU texture (8-bit sRGB-encoded for ordinary photos, which halves the
/// memory of a half-float copy, and half float for 16-bit, wide-gamut and
/// HDR sources) and wrapped as a `CIImage`.
///
/// **The proxy** is made from it once with Lanczos, at about the screen's
/// long edge, and rendered into a texture of its own, so a slider render
/// reads 6 MP instead of 24 MP and never touches the original. A preview
/// that needs more pixels than the proxy has (a crop, a larger window)
/// gets a larger proxy or, when it would be nearly full size anyway, the
/// original itself.
///
/// **Coalescing.** Each document has a lane for previews and one for full
/// resolution. A lane runs one render at a time; requests that arrive
/// meanwhile replace each other, so only the newest runs next and a slider
/// dragged faster than the GPU renders skips states instead of queueing
/// them. A finished render is delivered only if nothing newer is already on
/// screen: a full-resolution render of an older state never replaces a
/// preview of the current one, and a preview never replaces a
/// full-resolution render of the same state.
///
/// **Measured** on M4, release build, 6032 x 4032 JPEG (`EditBenchmark`):
///
///     prepare (decode, upload, 3024 px proxy)      146 ms, 137 ms again
///     preview at 3024 px, request to delivery      lighting 4.7 ms, colors 4.1,
///       (warm medians, mip chain included)         curves 4.1, levels 4.0
///     full resolution, Lanczos 3 to 75%            30 ms (to 150%: 94 ms)
///     full resolution, Lanczos 8 to 50%            42 ms
///     export of 5 operations, 8-bit sRGB CGImage   54 ms first, 38 ms again
@MainActor public final class EditRenderer {
    public static let shared = EditRenderer()

    nonisolated let gpu: GPU
    /// One context for every edit render: it keeps compiled kernels between
    /// renders, which is most of what makes a repeat render fast. Working
    /// space is extended linear Display P3 in half floats, the canvas's own,
    /// so HDR values and wide-gamut colours survive every operation.
    /// Intermediates aren't cached: a slider render changes the input to
    /// most of the graph each time, so a cache would mostly hold memory.
    nonisolated let context: CIContext

    /// Textures stay within Metal's limit on every Apple Silicon GPU.
    nonisolated static let maximumDimension = TextureUploader.maximumDimension

    nonisolated static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    public init(gpu: GPU = .shared) {
        self.gpu = gpu
        context = CIContext(mtlCommandQueue: gpu.queue, options: [
            .workingColorSpace: Self.workingSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "minivu edit",
        ])
    }

    // MARK: - Preparing

    /// Decodes the full-resolution original once (ImageIO, oriented; RAW files
    /// by the viewer's rules: the embedded preview when it is full size, else
    /// Apple's RAW engine) and builds the screen proxy. Idempotent, and
    /// concurrent calls share one decode.
    ///
    /// - Parameter proxyPixelSize: the proxy's long edge; nil for the largest
    ///   connected display's long edge in pixels.
    public func prepare(_ document: EditDocument, proxyPixelSize: Int? = nil) async throws {
        if document.source != nil { return }
        if let preparation = document.preparation {
            try await preparation.value
            return
        }
        let url = document.entry.url, page = document.page, kind = document.entry.kind
        let settings = ImageLoader.shared.settings
        let edge = proxyPixelSize ?? Self.screenLongEdge()
        let token = document.preparationToken
        let gpu = self.gpu, context = self.context
        let work = Task.detached(priority: .userInitiated) { () throws -> (EditSource, EditProxy?) in
            let source = try Self.loadSource(url: url, page: page, kind: kind, settings: settings, gpu: gpu)
            let scale = Self.proxyScale(sourceSize: source.size, longEdge: edge)
            let proxy = try scale.map { try Self.makeProxy(source, scale: $0, context: context, gpu: gpu) }
            return (source, proxy)
        }
        let preparation = Task { [weak document] in
            let (source, proxy) = try await work.value
            guard let document, document.preparationToken == token else { return }
            document.source = source
            document.proxy = proxy
            document.sourceSize = source.size
        }
        document.preparation = preparation
        defer { if document.preparationToken == token { document.preparation = nil } }
        try await preparation.value
    }

    /// Drops the document's original and proxy (and Core Image's caches of
    /// them). Renders under way finish but aren't delivered; a later render
    /// request prepares the document again.
    public func release(_ document: EditDocument) {
        document.preparationToken += 1
        document.preparation = nil
        document.source = nil
        document.proxy = nil
        document.previewLane.pending = nil
        document.fullLane.pending = nil
        document.lastDelivered = nil
        context.clearCaches()
    }

    // MARK: - Rendering

    /// Renders the committed and preview operations so the output's long edge
    /// is about `pixelSize` (never above the output size) into a mipmapped
    /// texture whose `imageSize` is `document.outputSize`. Coalesced (see
    /// the type's documentation); `completion` runs on the main actor, and
    /// not at all for a request that was superseded or became stale.
    public func renderPreview(_ document: EditDocument, pixelSize: Int, completion: @escaping (ImageTexture) -> Void) {
        document.previewLane.pending = RenderLane.Request(pixelSize: max(pixelSize, 1), completion: completion)
        pump(document, full: false)
    }

    /// The same at full output resolution (capped at 16384 px), for zooming
    /// past the proxy. Runs in the background beside previews.
    public func renderFullResolution(_ document: EditDocument, completion: @escaping (ImageTexture) -> Void) {
        document.fullLane.pending = RenderLane.Request(pixelSize: nil, completion: completion)
        pump(document, full: true)
    }

    /// Final pixels for saving: the committed operations only, at full
    /// resolution, converted to `colorSpace` with 8 or 16 bits per
    /// component, top row first. Values outside the colour space's range
    /// are clipped here, and only here.
    nonisolated public func renderForExport(_ snapshot: EditDocument.Snapshot, colorSpace: CGColorSpace,
                                            bitsPerComponent: Int) async throws -> CGImage {
        guard bitsPerComponent == 8 || bitsPerComponent == 16 else {
            throw EditRenderError.unsupportedBitDepth(bitsPerComponent)
        }
        let source = try snapshot.source
            ?? Self.loadSource(url: snapshot.url, page: snapshot.page, kind: snapshot.kind,
                               settings: snapshot.settings, gpu: gpu)
        let image = EditGraph.image(source: source.image, sourceSize: source.size,
                                    operations: snapshot.operations, scale: 1)
        let format: CIFormat = bitsPerComponent == 16 ? .RGBA16 : .RGBA8
        // Core Image renders in tiles as needed, so an upscaled result larger
        // than a texture still exports.
        guard let cgImage = context.createCGImage(image, from: image.extent, format: format, colorSpace: colorSpace,
                                                  deferred: false) else {
            throw EditRenderError.renderFailed
        }
        return cgImage
    }

    // MARK: - Lanes

    private func pump(_ document: EditDocument, full: Bool) {
        let lane = full ? document.fullLane : document.previewLane
        guard !lane.isRunning, let request = lane.pending else { return }
        lane.pending = nil
        lane.isRunning = true
        Task { [weak self, weak document] in
            if let self, let document {
                await self.run(request, for: document, full: full)
            }
            lane.isRunning = false
            if let self, let document { self.pump(document, full: full) }
        }
    }

    private func run(_ request: RenderLane.Request, for document: EditDocument, full: Bool) async {
        do {
            try await prepare(document)
        } catch {
            return   // an unreadable file: nothing to show, and the viewer reports decode errors
        }
        guard let source = document.source else { return }
        let operations = document.renderedOperations
        let revision = document.revision
        let outputSize = EditGraph.outputSize(source: source.size, operations: operations)
        let proxy = document.proxy
        let plan = full
            ? Self.fullResolutionPlan(outputSize: outputSize)
            : Self.previewPlan(outputSize: outputSize, pixelSize: request.pixelSize ?? 1, proxyScale: proxy?.scale)
        let gpu = self.gpu, context = self.context

        let result = await Task.detached(priority: full ? .utility : .userInitiated) { () -> (ImageTexture, EditProxy?)? in
            do {
                var workingProxy = proxy
                if plan.rebuildProxy {
                    workingProxy = try Self.makeProxy(source, scale: plan.scale, context: context, gpu: gpu)
                }
                let working = Self.workingImage(source: source, proxy: plan.useProxy ? workingProxy : nil,
                                                scale: plan.scale)
                let image = EditGraph.image(source: working, sourceSize: source.size, operations: operations,
                                            scale: plan.scale)
                let texture = try Self.renderTexture(image, context: context, gpu: gpu)
                let output = ImageTexture(texture: texture, imageSize: outputSize,
                                          isFullResolution: plan.scale >= plan.maximumScale,
                                          isHDR: source.isHDR, contentHeadroom: source.contentHeadroom)
                return (output, plan.rebuildProxy ? workingProxy : nil)
            } catch {
                return nil
            }
        }.value

        // Released, or prepared again from scratch, while rendering.
        guard let (texture, newProxy) = result, document.source === source else { return }
        if let newProxy, newProxy.scale > (document.proxy?.scale ?? 0) {
            document.proxy = newProxy
        }
        guard Self.shouldDeliver(revision: revision, full: full, after: document.lastDelivered) else { return }
        document.lastDelivered = (revision, full)
        request.completion(texture)
    }

    /// Whether a finished render may replace what was delivered last: only
    /// if it shows a newer state, or the same state at least as sharply
    /// (full resolution over a preview; a preview over a preview, since a
    /// larger window asks again for the same state).
    nonisolated static func shouldDeliver(revision: Int, full: Bool, after last: (revision: Int, full: Bool)?) -> Bool {
        guard let last else { return true }
        return revision > last.revision || (revision == last.revision && (full || !last.full))
    }

    // MARK: - Plans

    /// Which image a render starts from and at what scale.
    struct Plan: Equatable {
        /// Working size over full-resolution size.
        var scale: Double
        /// The largest scale the output may have: 1, or less where the output
        /// would exceed Metal's texture limit.
        var maximumScale: Double
        /// Start from the proxy (at `scale`, resampled if it is larger);
        /// otherwise from the original.
        var useProxy: Bool
        /// Make a new proxy at `scale` first.
        var rebuildProxy: Bool
    }

    /// The largest scale at which an output of `outputSize` fits a texture.
    nonisolated static func maximumScale(outputSize: CGSize) -> Double {
        let long = max(outputSize.width, outputSize.height)
        return long > 0 ? min(1, Double(maximumDimension) / Double(long)) : 1
    }

    nonisolated static func fullResolutionPlan(outputSize: CGSize) -> Plan {
        let maximum = maximumScale(outputSize: outputSize)
        return Plan(scale: maximum, maximumScale: maximum, useProxy: false, rebuildProxy: false)
    }

    /// The scale for an output whose long edge is about `pixelSize`, and
    /// where to start:
    /// - within 3/4 of full size, the original: a proxy that large saves too
    ///   little to be worth its memory;
    /// - otherwise the proxy, when it has enough pixels (3% slack), resampled
    ///   down first when it has more than one and a half times too many;
    /// - otherwise a new, larger proxy at the scale needed. Proxies only
    ///   grow, so going back and forth between a crop and the whole image
    ///   doesn't rebuild one each time.
    nonisolated static func previewPlan(outputSize: CGSize, pixelSize: Int, proxyScale: Double?) -> Plan {
        let maximum = maximumScale(outputSize: outputSize)
        let long = Double(max(outputSize.width, outputSize.height))
        let wanted = long > 0 ? min(maximum, Double(pixelSize) / long) : maximum
        if wanted >= 0.75 * maximum {
            return Plan(scale: maximum, maximumScale: maximum, useProxy: false, rebuildProxy: false)
        }
        if let proxyScale, proxyScale >= wanted * 0.97 {
            let scale = proxyScale <= wanted * 1.5 ? proxyScale : wanted
            return Plan(scale: scale, maximumScale: maximum, useProxy: true, rebuildProxy: false)
        }
        return Plan(scale: wanted, maximumScale: maximum, useProxy: true, rebuildProxy: true)
    }

    /// The scale of the proxy `prepare` makes, or nil when the original is
    /// small enough to serve itself (see `previewPlan`).
    nonisolated static func proxyScale(sourceSize: CGSize, longEdge: Int) -> Double? {
        let long = Double(max(sourceSize.width, sourceSize.height))
        guard long > 0 else { return nil }
        let scale = Double(max(longEdge, 1)) / long
        return scale < 0.75 ? scale : nil
    }

    /// The largest connected display's long edge in pixels, which is the
    /// most a preview can show at once.
    static func screenLongEdge() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 3024 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return 3024 }
        let edges = displays.compactMap { id -> Int? in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return max(mode.pixelWidth, mode.pixelHeight)
        }
        return edges.max() ?? 3024
    }

    // MARK: - Pixels

    /// The image a render's graph starts from: the proxy if it is exactly at
    /// `scale`, the original at scale 1, otherwise whichever is the smallest
    /// that is still large enough, resampled with Lanczos.
    nonisolated static func workingImage(source: EditSource, proxy: EditProxy?, scale: Double) -> CIImage {
        if let proxy, abs(proxy.scale - scale) < 1e-9 { return proxy.image }
        if scale >= 1 { return source.image }
        if let proxy, proxy.scale > scale {
            return lanczos(proxy.image, to: source.size, scale: scale)
        }
        return lanczos(source.image, to: source.size, scale: scale)
    }

    /// `image` resampled to `EditGraph.workingLength` of `fullSize` at
    /// `scale`, exactly, with the edges repeated so the border stays opaque.
    nonisolated static func lanczos(_ image: CIImage, to fullSize: CGSize, scale: Double) -> CIImage {
        let width = EditGraph.workingLength(Int(fullSize.width.rounded()), scale: scale)
        let height = EditGraph.workingLength(Int(fullSize.height.rounded()), scale: scale)
        let sx = Double(width) / Double(image.extent.width)
        let sy = Double(height) / Double(image.extent.height)
        return image.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    nonisolated static func makeProxy(_ source: EditSource, scale: Double, context: CIContext, gpu: GPU) throws -> EditProxy {
        let image = lanczos(source.image, to: source.size, scale: scale)
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else {
            throw GPUError.allocationFailed("an edit proxy")
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
        destination.colorSpace = workingSpace
        // Not flipped: `CIImage(mtlTexture:)` reads row 0 as the bottom, so
        // writing it that way keeps the proxy upright in Core Image.
        destination.isFlipped = false
        let task = try context.startTask(toRender: image, to: destination)
        commands.commit()
        commands.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        if let error = commands.error { throw error }
        guard let proxyImage = CIImage(mtlTexture: texture, options: [.colorSpace: workingSpace]) else {
            throw GPUError.allocationFailed("an edit proxy image")
        }
        return EditProxy(texture: texture, image: proxyImage, scale: scale)
    }

    /// Renders `image` (extent at the origin) into a new mipmapped half-float
    /// texture, top row first, as the canvas expects, in one GPU submission.
    nonisolated static func renderTexture(_ image: CIImage, context: CIContext, gpu: GPU) throws -> MTLTexture {
        let width = max(1, Int(image.extent.width.rounded()))
        let height = max(1, Int(image.extent.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else {
            throw GPUError.allocationFailed("an edit texture")
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
        destination.colorSpace = workingSpace
        destination.isFlipped = true
        let task = try context.startTask(toRender: image, to: destination)
        guard let blit = commands.makeBlitCommandEncoder() else {
            throw GPUError.allocationFailed("a mipmap encoder")
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        if let error = commands.error { throw error }
        return texture
    }

    // MARK: - Decoding

    /// The original, decoded at full resolution and uploaded. Synchronous
    /// and slow (a quarter of a second for 24 MP): background only.
    nonisolated static func loadSource(url: URL, page: Int, kind: ImageKind?, settings: DisplaySettings,
                                       gpu: GPU) throws -> EditSource {
        if kind == .raw, let raw = try loadRaw(url: url, settings: settings, gpu: gpu) {
            return raw
        }
        let decoded = try ImageDecoder.decode(url, maxPixelSize: maximumDimension, page: page,
                                              allowHDR: settings.showHDR)
        return try upload(decoded, gpu: gpu)
    }

    /// A RAW file by `ImageLoader`'s rules, at full size: the embedded
    /// preview when the camera stored one at sensor size (and the settings
    /// allow it), otherwise a render with Apple's RAW engine. For a camera
    /// the engine doesn't know, the embedded preview at whatever size it
    /// is. Nil leaves the file to ImageIO, as `ImageLoader` does when the
    /// GPU render fails for any other reason.
    nonisolated static func loadRaw(url: URL, settings: DisplaySettings, gpu: GPU) throws -> EditSource? {
        let plan = ImageLoader.rawPlan(settings: settings)
        if plan == .previewOrRender, let preview = try? ImageDecoder.decodeRawPreview(url),
           preview.isFullResolution {
            return try upload(preview, gpu: gpu)
        }
        do {
            let rendered = try RawRenderer.render(url: url, maxPixelSize: nil, hdr: plan == .render(hdr: true),
                                                  headroom: settings.rawHeadroom, gpu: gpu)
            return try wrap(rendered)
        } catch DecodeError.noImage {
            guard let preview = try? ImageDecoder.decodeRawPreview(url) else { return nil }
            return try upload(preview, gpu: gpu)
        } catch {
            return nil
        }
    }

    /// A top-left texture from `RawRenderer`, turned into Core Image's y-up
    /// orientation with an exact flip.
    nonisolated static func wrap(_ texture: ImageTexture) throws -> EditSource {
        let space = texture.texture.pixelFormat == .rgba16Float
            ? workingSpace : CGColorSpace(name: CGColorSpace.linearDisplayP3)!
        guard let image = CIImage(mtlTexture: texture.texture, options: [.colorSpace: space]) else {
            throw GPUError.allocationFailed("a RAW source image")
        }
        let h = CGFloat(texture.texture.height)
        let upright = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
        return EditSource(texture: texture.texture, image: upright, size: texture.textureSize,
                          isHDR: texture.isHDR, contentHeadroom: texture.contentHeadroom)
    }

    /// Draws a decoded image into GPU-shared memory, as `TextureUploader`
    /// does (one colour conversion by ColorSync, no copy to the GPU), but
    /// without the private mipmapped copy the canvas needs: the original is
    /// only ever read by Core Image at full size, so the mip chain would be a
    /// third more memory for nothing. Rows are stored bottom first, Core
    /// Image's orientation.
    nonisolated static func upload(_ decoded: DecodedImage, gpu: GPU) throws -> EditSource {
        let cgImage = decoded.image
        let oriented = decoded.orientation.swapsAxes
            ? CGSize(width: cgImage.height, height: cgImage.width)
            : CGSize(width: cgImage.width, height: cgImage.height)
        let longest = max(oriented.width, oriented.height)
        let fit = longest > CGFloat(maximumDimension) ? CGFloat(maximumDimension) / longest : 1
        let width = max(1, Int((oriented.width * fit).rounded()))
        let height = max(1, Int((oriented.height * fit).rounded()))

        let deep = decoded.isHDR || decoded.needsDeepStorage
        let format: MTLPixelFormat = deep ? .rgba16Float : .bgra8Unorm_srgb
        let bytesPerPixel = deep ? 8 : 4
        let alignment = gpu.device.minimumLinearTextureAlignment(for: format)
        let bytesPerRow = TextureUploader.roundUp(width * bytesPerPixel, to: alignment)
        let pageSize = Int(getpagesize())
        let length = TextureUploader.roundUp(bytesPerRow * height, to: pageSize)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: pageSize)
        guard let buffer = gpu.device.makeBuffer(bytesNoCopy: memory, length: length, options: .storageModeShared,
                                                 deallocator: { pointer, _ in pointer.deallocate() }) else {
            memory.deallocate()
            throw GPUError.allocationFailed("an edit source buffer")
        }

        let drawSpace: CGColorSpace
        let bitmapInfo: UInt32
        if deep {
            drawSpace = workingSpace
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        } else {
            drawSpace = CGColorSpace(name: CGColorSpace.displayP3)!
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        }
        guard let bitmap = CGContext(data: memory, width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                                     bytesPerRow: bytesPerRow, space: drawSpace, bitmapInfo: bitmapInfo) else {
            throw GPUError.allocationFailed("an edit source bitmap")
        }
        if decoded.isHDR { bitmap.setEDRTargetHeadroom(max(decoded.contentHeadroom, 1)) }
        bitmap.interpolationQuality = .high
        // A bitmap context's first row of memory is its top (highest y). An
        // upright drawing would therefore store the image top row first;
        // drawing it upside down stores the bottom row first instead.
        bitmap.concatenate(decoded.orientation.transform(width: CGFloat(width), height: CGFloat(height)))
        let drawSize = decoded.orientation.swapsAxes
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        bitmap.translateBy(x: 0, y: drawSize.height)
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.draw(cgImage, in: CGRect(origin: .zero, size: drawSize))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow) else {
            throw GPUError.allocationFailed("an edit source texture")
        }
        // An sRGB texture decodes to linear values when sampled, so Core
        // Image is told the pixels are linear; half floats are already in
        // the working space.
        let space = deep ? workingSpace : CGColorSpace(name: CGColorSpace.linearDisplayP3)!
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: space]) else {
            throw GPUError.allocationFailed("an edit source image")
        }
        return EditSource(texture: texture, image: image, size: CGSize(width: width, height: height),
                          isHDR: decoded.isHDR, contentHeadroom: decoded.contentHeadroom)
    }
}

public enum EditRenderError: Error, CustomStringConvertible {
    case unsupportedBitDepth(Int)
    case renderFailed

    public var description: String {
        switch self {
        case .unsupportedBitDepth(let bits): "\(bits) bits per component can't be exported (8 or 16 can)."
        case .renderFailed: "The edited image could not be rendered."
        }
    }
}
