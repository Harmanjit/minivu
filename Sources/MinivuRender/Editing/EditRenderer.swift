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
    /// Keeps the pixels alive; `image` reads them. Nil only for an export's
    /// source that is larger than a texture may be, which Core Image reads
    /// from the CGImage in tiles instead.
    let texture: MTLTexture?
    /// Extent at the origin, Core Image's y-up orientation, upright, with
    /// `EditGraph.workingLength` of `size` at `scale` for its dimensions.
    let image: CIImage
    /// The original's full oriented pixel size, which every operation's
    /// lengths refer to.
    let size: CGSize
    /// `image`'s size over `size`: 1, or less for an original larger than
    /// Metal's 16384 px texture limit, which is edited on screen at that
    /// limit but still saved at its own size (see `renderForExport`).
    let scale: Double
    let isHDR: Bool
    let contentHeadroom: Float

    init(texture: MTLTexture?, image: CIImage, size: CGSize, scale: Double = 1, isHDR: Bool, contentHeadroom: Float) {
        self.texture = texture
        self.image = image
        self.size = size
        self.scale = scale
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

/// The committed operations up to and including a downsizing resize,
/// rendered once into a texture of the resized size, that later renders
/// start from instead of the original.
///
/// The graph has one scale, and after a resize to fewer pixels than the
/// screen shows, that scale is 1: every slider frame would otherwise read
/// the whole 24 MP original and resample it again (18-20 ms a frame on M4,
/// four times a normal 3024 px preview) only to work on 1600 px. Starting
/// from the stage costs the operations after the resize and nothing else,
/// and gives the same pixels (the resample kernel's output is a half-float
/// intermediate either way). Saving never uses it.
final class EditStage: @unchecked Sendable {
    let source: EditSource
    /// The operations it holds, and the scale it was rendered at.
    let operations: [EditOperation]
    let scale: Double
    /// Full-resolution size after `operations`.
    let size: CGSize
    let texture: MTLTexture
    let image: CIImage

    init(source: EditSource, operations: [EditOperation], scale: Double, size: CGSize, texture: MTLTexture,
         image: CIImage) {
        self.source = source
        self.operations = operations
        self.scale = scale
        self.size = size
        self.texture = texture
        self.image = image
    }

    func matches(source: EditSource, operations prefix: ArraySlice<EditOperation>, scale: Double) -> Bool {
        self.source === source && abs(self.scale - scale) < 1e-9 && self.operations[...] == prefix
    }
}

/// Renders edit documents: screen previews while editing, full resolution
/// for zooming in, and final pixels for saving (DESIGN.md 4.7).
///
/// **The original** is decoded once per document at full resolution into a
/// GPU texture and wrapped as a `CIImage`: 8-bit in the file's own colour
/// space for opaque sRGB and Display P3 photos (half the memory of a
/// half-float copy, and no conversion, so an edit that changes no colour
/// saves the same values back), half float for everything else (see
/// `upload`).
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
/// full-resolution render of the same state. Nor is one delivered that the
/// document has moved away from, rather than along (a preview cancelled or
/// applied, an undo), while a render of the newer state is on its way: it
/// would show the dropped state for a frame (see `isOvertaken`).
///
/// **Measured** on M4, release build, 6032 x 4032 JPEG (`EditBenchmark`):
///
///     prepare (decode, upload, 3024 px proxy)      119 ms, 104 ms again
///     preview at 3024 px, request to delivery      lighting 4.1 ms, colors 4.3-4.5,
///       (warm medians, mip chain included)         curves 3.8-6.1, levels 3.9-4.5
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
        let expected = document.sourceSignature
        let preparation = Task { [weak document] in
            // A full-resolution decode and a GPU wait block their thread for
            // 100 ms or more: on GCD, not the cooperative pool (BlockingWork).
            let (source, proxy, signature) = try await BlockingWork.run {
                () throws -> (EditSource, EditProxy?, FileSignature?) in
                // Read before decoding, so a change racing the decode is caught.
                let signature = FileSignature.read(url)
                if let expected, signature != expected { throw EditRenderError.sourceChanged(url) }
                let source = try Self.loadSource(url: url, page: page, kind: kind, settings: settings, gpu: gpu)
                let scale = Self.proxyScale(sourceSize: source.size, sourceScale: source.scale, longEdge: edge)
                let proxy = try scale.map { try Self.makeProxy(source, scale: $0, context: context, gpu: gpu) }
                return (source, proxy, signature)
            }
            guard let document, document.preparationToken == token else { return }
            document.source = source
            document.proxy = proxy
            document.sourceSize = source.size
            if document.sourceSignature == nil { document.sourceSignature = signature }
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
        document.previewLane.stage = nil
        document.fullLane.stage = nil
        document.lastDelivered = nil
        document.deliveredOperations = nil
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
    ///
    /// An HDR original saved into an SDR colour space (anything but the
    /// PQ and HLG transfers) is tone mapped to SDR first with Core Image's
    /// `CIToneMapHeadroom`, the same mapping ImageIO uses for a gain-map
    /// photo's SDR rendition: clipping instead would flatten every highlight
    /// above paper white, which is most of an iPhone photo's sky.
    ///
    /// An original larger than Metal's texture limit is decoded again here
    /// at its own size, so saving never shrinks it.
    nonisolated public func renderForExport(_ snapshot: EditDocument.Snapshot, colorSpace: CGColorSpace,
                                            bitsPerComponent: Int) async throws -> CGImage {
        guard bitsPerComponent == 8 || bitsPerComponent == 16 else {
            throw EditRenderError.unsupportedBitDepth(bitsPerComponent)
        }
        let gpu = self.gpu, context = self.context
        // Decoding and Core Image's CPU readback block for tens of ms to
        // seconds (a RAW, a batch of them): on GCD, not the cooperative pool.
        return try await BlockingWork.run(qos: Task.currentPriority >= .userInitiated ? .userInitiated : .utility) {
            try Self.exportImage(snapshot, colorSpace: colorSpace, bitsPerComponent: bitsPerComponent,
                                 context: context, gpu: gpu)
        }
    }

    nonisolated private static func exportImage(_ snapshot: EditDocument.Snapshot, colorSpace: CGColorSpace,
                                                bitsPerComponent: Int, context: CIContext, gpu: GPU) throws -> CGImage {
        let source: EditSource
        if let prepared = snapshot.source, prepared.scale >= 1 {
            source = prepared
        } else {
            // Re-reading the file is only safe if it is still the file the
            // operations were made on. After a Save over the original it
            // isn't: the edits are already in it, and applying them again
            // would write them twice.
            if let expected = snapshot.sourceSignature, FileSignature.read(snapshot.url) != expected {
                throw EditRenderError.sourceChanged(snapshot.url)
            }
            source = try loadSource(url: snapshot.url, page: snapshot.page, kind: snapshot.kind,
                                    settings: snapshot.settings, gpu: gpu, forExport: true)
        }
        var image = EditGraph.image(source: workingImage(source: source, proxy: nil, scale: 1),
                                    sourceSize: source.size, operations: snapshot.operations, scale: 1)
        if source.isHDR && !CGColorSpaceUsesITUR_2100TF(colorSpace) {
            image = image.applyingFilter("CIToneMapHeadroom", parameters: [
                "inputSourceHeadroom": max(source.contentHeadroom, 1),
                "inputTargetHeadroom": 1,
            ])
        }
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
        let committed = document.operations, preview = document.preview
        let lane = full ? document.fullLane : document.previewLane
        lane.runningRevision = revision
        defer { lane.runningRevision = nil }
        let outputSize = EditGraph.outputSize(source: source.size, operations: operations)
        let proxy = document.proxy
        let plan = full
            ? Self.fullResolutionPlan(outputSize: outputSize, sourceScale: source.scale)
            : Self.previewPlan(outputSize: outputSize, pixelSize: request.pixelSize ?? 1, proxyScale: proxy?.scale,
                               sourceScale: source.scale)
        let gpu = self.gpu, context = self.context
        let stageLength = Self.stageLength(operations: operations, committed: committed.count, sourceSize: source.size)
        let stage = stageLength.flatMap { length in
            lane.stage.flatMap { $0.matches(source: source, operations: operations.prefix(length), scale: plan.scale) ? $0 : nil }
        }

        // `renderTexture` waits for the GPU: on GCD, not the cooperative pool.
        let result = await BlockingWork.run(qos: full ? .utility : .userInitiated) {
            () -> (ImageTexture, EditProxy?, EditStage?)? in
            do {
                var workingProxy = proxy
                var newStage: EditStage?
                let image: CIImage
                if let stage {
                    image = EditGraph.image(source: stage.image, sourceSize: stage.size,
                                            operations: Array(operations[stage.operations.count...]), scale: plan.scale)
                } else {
                    if plan.rebuildProxy {
                        workingProxy = try Self.makeProxy(source, scale: plan.scale, context: context, gpu: gpu)
                    }
                    let working = Self.workingImage(source: source, proxy: plan.useProxy ? workingProxy : nil,
                                                    scale: plan.scale)
                    if let stageLength {
                        let prefix = Array(operations.prefix(stageLength))
                        let size = EditGraph.outputSize(source: source.size, operations: prefix)
                        let staged = EditGraph.image(source: working, sourceSize: source.size, operations: prefix,
                                                     scale: plan.scale)
                        let (texture, stagedImage) = try Self.renderIntermediate(staged, context: context, gpu: gpu,
                                                                                 label: "an edit stage")
                        newStage = EditStage(source: source, operations: prefix, scale: plan.scale, size: size,
                                             texture: texture, image: stagedImage)
                        image = EditGraph.image(source: stagedImage, sourceSize: size,
                                                operations: Array(operations[stageLength...]), scale: plan.scale)
                    } else {
                        image = EditGraph.image(source: working, sourceSize: source.size, operations: operations,
                                                scale: plan.scale)
                    }
                }
                let texture = try Self.renderTexture(image, context: context, gpu: gpu)
                let output = ImageTexture(texture: texture, imageSize: outputSize,
                                          isFullResolution: plan.scale >= plan.maximumScale,
                                          isHDR: source.isHDR, contentHeadroom: source.contentHeadroom)
                return (output, plan.rebuildProxy && stage == nil ? workingProxy : nil, newStage)
            } catch {
                return nil
            }
        }

        // Released, or prepared again from scratch, while rendering.
        guard let (texture, newProxy, newStage) = result, document.source === source else { return }
        if let newProxy, newProxy.scale > (document.proxy?.scale ?? 0) {
            document.proxy = newProxy
        }
        // A render without a stage to use (none fits its operations, or it
        // made one) drops the lane's old one, whose memory nothing needs.
        if stage == nil { lane.stage = newStage }
        guard Self.shouldDeliver(revision: revision, full: full, after: document.lastDelivered) else { return }
        if revision != document.revision,
           Self.isOvertaken(committed: committed, preview: preview,
                            by: document.operations, preview: document.preview) {
            // A render of the current state is waiting or running: show that.
            let other = full ? document.previewLane : document.fullLane
            // (The other lane's render takes the document's state when it
            // starts, which is at least the current one.)
            let newerComing = lane.pending != nil || other.pending != nil
                || (other.isRunning && (other.runningRevision ?? .max) > revision)
            if newerComing { return }
        }
        document.lastDelivered = (revision, full)
        document.deliveredOperations = operations
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

    /// Whether a render of one state, finished after the document changed,
    /// shows something the user has left behind rather than a step on the
    /// way: true unless the committed operations are the same and a preview
    /// of the same kind is still live (a slider still moving, whose
    /// in-between frames are what keeps a drag responsive). A preview
    /// cancelled or applied, a section switched, an undo: all overtaken.
    nonisolated static func isOvertaken(committed: [EditOperation], preview: EditOperation?,
                                        by currentCommitted: [EditOperation], preview currentPreview: EditOperation?) -> Bool {
        guard let preview, let currentPreview else { return true }
        return committed != currentCommitted || preview.title != currentPreview.title
    }

    // MARK: - Plans

    /// How many of `operations` a render can take from an `EditStage`: those
    /// up to the last committed resize to fewer pixels than it was given,
    /// when at least one operation follows it (with none, the stage would
    /// be the output, rendered twice). Nil when there is no such resize.
    nonisolated static func stageLength(operations: [EditOperation], committed: Int, sourceSize: CGSize) -> Int? {
        var size = EditGraph.Size(width: Int(sourceSize.width.rounded()), height: Int(sourceSize.height.rounded()))
        var length: Int?
        for (index, op) in operations.prefix(committed).enumerated() where !op.isIdentity {
            let next = EditGraph.fullSize(after: op, from: size)
            if case .resize = op, next.width * next.height < size.width * size.height { length = index + 1 }
            size = next
        }
        guard let length, length < operations.count else { return nil }
        return length
    }

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

    /// The largest scale at which an output of `outputSize` fits a texture
    /// and the original has the pixels for (`EditSource.scale`).
    nonisolated static func maximumScale(outputSize: CGSize, sourceScale: Double = 1) -> Double {
        let long = max(outputSize.width, outputSize.height)
        let fits = long > 0 ? min(1, Double(maximumDimension) / Double(long)) : 1
        return min(fits, sourceScale)
    }

    nonisolated static func fullResolutionPlan(outputSize: CGSize, sourceScale: Double = 1) -> Plan {
        let maximum = maximumScale(outputSize: outputSize, sourceScale: sourceScale)
        return Plan(scale: maximum, maximumScale: maximum, useProxy: false, rebuildProxy: false)
    }

    /// The scale for an output whose long edge is about `pixelSize`, and
    /// where to start:
    /// - within 3/4 of full size, the original: a proxy that large saves too
    ///   little to be worth its memory;
    /// - otherwise the proxy, when it has enough pixels (3% slack), resampled
    ///   down first when it has more than one and a half times too many;
    /// - otherwise a new, larger proxy, a quarter larger than needed. Proxies
    ///   only grow, so going back and forth between a crop and the whole
    ///   image doesn't rebuild one each time, and the extra quarter means a
    ///   crop being dragged smaller rebuilds one every 25% of growth rather
    ///   than on nearly every frame (each rebuild is a full-resolution
    ///   Lanczos pass, 50 to 100 ms for 24 MP).
    nonisolated static func previewPlan(outputSize: CGSize, pixelSize: Int, proxyScale: Double?,
                                        sourceScale: Double = 1) -> Plan {
        let maximum = maximumScale(outputSize: outputSize, sourceScale: sourceScale)
        let long = Double(max(outputSize.width, outputSize.height))
        let wanted = long > 0 ? min(maximum, Double(pixelSize) / long) : maximum
        if wanted >= 0.75 * maximum {
            return Plan(scale: maximum, maximumScale: maximum, useProxy: false, rebuildProxy: false)
        }
        if let proxyScale, proxyScale >= wanted * 0.97 {
            let scale = proxyScale <= wanted * 1.5 ? proxyScale : wanted
            return Plan(scale: scale, maximumScale: maximum, useProxy: true, rebuildProxy: false)
        }
        let grown = wanted * 1.25 < 0.75 * maximum ? wanted * 1.25 : wanted
        return Plan(scale: grown, maximumScale: maximum, useProxy: true, rebuildProxy: true)
    }

    /// The scale of the proxy `prepare` makes, or nil when the original is
    /// small enough to serve itself (see `previewPlan`).
    nonisolated static func proxyScale(sourceSize: CGSize, sourceScale: Double = 1, longEdge: Int) -> Double? {
        let long = Double(max(sourceSize.width, sourceSize.height))
        guard long > 0 else { return nil }
        let scale = Double(max(longEdge, 1)) / long
        return scale < 0.75 * sourceScale ? scale : nil
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
    /// `scale`, the original at its own scale, otherwise whichever is the
    /// smallest that is still large enough, resampled with Lanczos.
    nonisolated static func workingImage(source: EditSource, proxy: EditProxy?, scale: Double) -> CIImage {
        if let proxy, abs(proxy.scale - scale) < 1e-9 { return proxy.image }
        if abs(source.scale - scale) < 1e-9 { return source.image }
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
        let (texture, proxyImage) = try renderIntermediate(image, context: context, gpu: gpu, label: "an edit proxy")
        return EditProxy(texture: texture, image: proxyImage, scale: scale)
    }

    /// Renders `image` (extent at the origin, whole pixels) into a half-float
    /// texture of its size and wraps that as a `CIImage` with the same
    /// extent, for later renders to start from.
    nonisolated static func renderIntermediate(_ image: CIImage, context: CIContext, gpu: GPU,
                                               label: String) throws -> (MTLTexture, CIImage) {
        let width = max(1, Int(image.extent.width.rounded())), height = max(1, Int(image.extent.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw GPUError.allocationFailed(label)
        }
        // No command buffer of ours: Core Image submits its own, which a
        // stage's resample kernel needs when the render is split into tiles
        // (see `renderTexture`).
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = workingSpace
        // Not flipped: `CIImage(mtlTexture:)` reads row 0 as the bottom, so
        // writing it that way keeps the image upright in Core Image.
        destination.isFlipped = false
        _ = try context.startTask(toRender: image, to: destination).waitUntilCompleted()
        guard let wrapped = CIImage(mtlTexture: texture, options: [.colorSpace: workingSpace]) else {
            throw GPUError.allocationFailed(label)
        }
        return (texture, wrapped)
    }

    /// Renders `image` (extent at the origin) into a new mipmapped half-float
    /// texture, top row first, as the canvas expects.
    ///
    /// Core Image submits its own command buffers and the mip chain follows
    /// in a second one. Handing Core Image a command buffer of ours instead
    /// (one submission for both) breaks renders it splits into tiles around
    /// a `CIImageProcessorKernel`: tile intermediates are reused before our
    /// buffer runs, so tiles come out swapped or black. Measured with oil
    /// paint on a 6032 x 4032 image (four tiles): the top-left tile showed
    /// the top-right one and the bottom-left stayed black.
    nonisolated static func renderTexture(_ image: CIImage, context: CIContext, gpu: GPU) throws -> MTLTexture {
        let width = max(1, Int(image.extent.width.rounded()))
        let height = max(1, Int(image.extent.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw GPUError.allocationFailed("an edit texture")
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = workingSpace
        destination.isFlipped = true
        _ = try context.startTask(toRender: image, to: destination).waitUntilCompleted()
        guard let commands = gpu.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw GPUError.allocationFailed("a mipmap encoder")
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return texture
    }

    // MARK: - Decoding

    /// The original, decoded at full resolution and uploaded. Synchronous
    /// and slow (a quarter of a second for 24 MP): background only.
    ///
    /// An original larger than a texture may be is uploaded at the texture
    /// limit (`EditSource.scale` below 1) for editing on screen. `forExport`
    /// decodes it at its own size instead and leaves it to Core Image to
    /// read in tiles, so a saved file keeps every pixel.
    nonisolated static func loadSource(url: URL, page: Int, kind: ImageKind?, settings: DisplaySettings,
                                       gpu: GPU, forExport: Bool = false) throws -> EditSource {
        if kind == .raw, let raw = try loadRaw(url: url, settings: settings, gpu: gpu) {
            return raw
        }
        let decoded = try ImageDecoder.decode(url, maxPixelSize: forExport ? nil : maximumDimension, page: page,
                                              allowHDR: settings.showHDR)
        let drawn = orientedSize(decoded)
        if forExport && max(drawn.width, drawn.height) > CGFloat(maximumDimension) {
            return try tiledSource(decoded)
        }
        // The size edited is what was decoded, except for a raster larger than
        // a texture, which the decoder may have shrunk towards the limit: its
        // own size then, so saving it doesn't shrink it. (Not a vector, whose
        // "full resolution" is the render; nor a raster whose metadata merely
        // claims a few more pixels than decode, as some RAW files do.)
        let isVector = kind == .pdf || kind == .svg
        let claimed = max(decoded.imageSize.width, decoded.imageSize.height)
        let full = !isVector && claimed > CGFloat(maximumDimension) && claimed > max(drawn.width, drawn.height)
            ? decoded.imageSize : drawn
        return try upload(decoded, fullSize: full, gpu: gpu)
    }

    nonisolated static func orientedSize(_ decoded: DecodedImage) -> CGSize {
        decoded.orientation.swapsAxes
            ? CGSize(width: decoded.image.height, height: decoded.image.width)
            : CGSize(width: decoded.image.width, height: decoded.image.height)
    }

    /// An export's source too large for a texture: the CGImage itself, which
    /// Core Image converts to the working space and reads in tiles.
    nonisolated static func tiledSource(_ decoded: DecodedImage) throws -> EditSource {
        var image = CIImage(cgImage: decoded.image)
        let size = orientedSize(decoded)
        if decoded.orientation != .up {
            image = image.oriented(decoded.orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        return EditSource(texture: nil, image: image, size: size, isHDR: decoded.isHDR,
                          contentHeadroom: decoded.contentHeadroom)
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

    /// How an original's pixels are stored on the GPU.
    enum Storage: Equatable {
        /// 8 bits per channel in the image's own colour space (sRGB or
        /// Display P3, which share the sRGB transfer curve), in an `_srgb`
        /// texture. Drawing into the same space is a copy, not a conversion,
        /// and Core Image converts to the working space in floating point on
        /// the GPU, so an 8-bit photo saved back to its own space comes out
        /// with the values it went in with. (Converting sRGB to 8-bit
        /// Display P3 on the way in, as the viewer does, measured up to 9
        /// levels off on the way back out.)
        case eightBit(CGColorSpace)
        /// Half float in the working space, extended linear Display P3: HDR,
        /// 16-bit, wide-gamut and other colour spaces, and anything with
        /// transparency.
        case halfFloat
    }

    /// The storage for `decoded`, before looking at its alpha values.
    ///
    /// Transparency needs half float because Core Graphics premultiplies an
    /// 8-bit bitmap in encoded values, while an `_srgb` texture decodes each
    /// channel on its own: a half-transparent white (0.5 encoded, 0.5 alpha)
    /// would read as linear 0.21 with alpha 0.5, a 43% grey. In a linear
    /// float bitmap premultiplying is exact.
    nonisolated static func storage(for decoded: DecodedImage) -> Storage {
        let image = decoded.image
        guard !decoded.isHDR, !decoded.needsDeepStorage, image.bitsPerComponent == 8,
              let space = image.colorSpace, space.model == .rgb, let name = space.name as String? else {
            return .halfFloat
        }
        for candidate in [CGColorSpace.sRGB, CGColorSpace.displayP3] where name == candidate as String {
            return CGColorSpace(name: candidate).map(Storage.eightBit) ?? .halfFloat
        }
        return .halfFloat
    }

    /// Draws a decoded image into GPU-shared memory, as `TextureUploader`
    /// does (no copy to the GPU), but without the private mipmapped copy the
    /// canvas needs: the original is only ever read by Core Image at full
    /// size, so the mip chain would be a third more memory for nothing. Rows
    /// are stored bottom first, Core Image's orientation.
    ///
    /// - Parameter fullSize: the original's oriented size, when the decoded
    ///   image is smaller than it. Above Metal's texture limit the pixels
    ///   are drawn at the limit and the source's `scale` says so.
    nonisolated static func upload(_ decoded: DecodedImage, fullSize: CGSize? = nil, gpu: GPU) throws -> EditSource {
        let full = fullSize ?? orientedSize(decoded)
        let fullWidth = max(1, Int(full.width.rounded())), fullHeight = max(1, Int(full.height.rounded()))
        let longest = max(fullWidth, fullHeight)
        let scale = longest > maximumDimension ? Double(maximumDimension) / Double(longest) : 1
        let width = min(EditGraph.workingLength(fullWidth, scale: scale), maximumDimension)
        let height = min(EditGraph.workingLength(fullHeight, scale: scale), maximumDimension)

        var storage = storage(for: decoded)
        var pixels = try draw(decoded, width: width, height: height, storage: storage, gpu: gpu)
        if case .eightBit = storage, decoded.image.hasAlphaChannel, pixels.hasTransparency() {
            storage = .halfFloat
            pixels = try draw(decoded, width: width, height: height, storage: storage, gpu: gpu)
        }

        let format: MTLPixelFormat
        let space: CGColorSpace
        switch storage {
        case .eightBit(let encoded):
            // An sRGB texture decodes to linear values when sampled, so Core
            // Image is told the pixels are the linear form of their space.
            format = .bgra8Unorm_srgb
            space = CGColorSpace(name: (encoded.name as String?) == (CGColorSpace.displayP3 as String) ? CGColorSpace.linearDisplayP3
                                                                              : CGColorSpace.linearSRGB)!
        case .halfFloat:
            format = .rgba16Float
            space = workingSpace
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = pixels.buffer.makeTexture(descriptor: descriptor, offset: 0,
                                                      bytesPerRow: pixels.bytesPerRow) else {
            throw GPUError.allocationFailed("an edit source texture")
        }
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: space]) else {
            throw GPUError.allocationFailed("an edit source image")
        }
        return EditSource(texture: texture, image: image, size: CGSize(width: fullWidth, height: fullHeight),
                          scale: scale, isHDR: decoded.isHDR, contentHeadroom: decoded.contentHeadroom)
    }

    /// Page-aligned GPU-shared memory with a decoded image drawn into it.
    struct DrawnPixels {
        let buffer: MTLBuffer
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let isEightBit: Bool

        /// True if any 8-bit pixel isn't fully opaque. Many opaque files
        /// (HEIC photos among them) still decode with an alpha channel, so
        /// the channel alone doesn't decide; one pass over the alpha bytes
        /// (a few milliseconds for 24 MP) does.
        func hasTransparency() -> Bool {
            guard isEightBit else { return false }
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                var x = 3   // BGRA: alpha is the fourth byte
                let end = width * 4
                while x < end {
                    if row[x] != 255 { return true }
                    x += 4
                }
            }
            return false
        }
    }

    nonisolated static func draw(_ decoded: DecodedImage, width: Int, height: Int, storage: Storage,
                                 gpu: GPU) throws -> DrawnPixels {
        let deep = storage == .halfFloat
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
        switch storage {
        case .halfFloat:
            drawSpace = workingSpace
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        case .eightBit(let space):
            drawSpace = space
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        }
        guard let bitmap = CGContext(data: memory, width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                                     bytesPerRow: bytesPerRow, space: drawSpace, bitmapInfo: bitmapInfo) else {
            throw GPUError.allocationFailed("an edit source bitmap")
        }
        if decoded.isHDR { bitmap.setEDRTargetHeadroom(max(decoded.contentHeadroom, 1)) }
        bitmap.interpolationQuality = .high
        // Replace, don't composite: the memory is freshly allocated, not
        // cleared, and drawing a transparent pixel over it with the usual
        // source-over would mix in whatever bytes were there before.
        bitmap.setBlendMode(.copy)
        // A bitmap context's first row of memory is its top (highest y), so
        // its user space is the image's top-left coordinates with y down, the
        // space the orientation transform works in. Drawing the image upside
        // down in it stores the bottom row first, as Core Image reads it.
        bitmap.concatenate(decoded.orientation.transform(width: CGFloat(width), height: CGFloat(height)))
        let drawSize = decoded.orientation.swapsAxes
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        bitmap.translateBy(x: 0, y: drawSize.height)
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.draw(decoded.image, in: CGRect(origin: .zero, size: drawSize))
        return DrawnPixels(buffer: buffer, bytesPerRow: bytesPerRow, width: width, height: height, isEightBit: !deep)
    }
}

private extension CGImage {
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

public enum EditRenderError: Error, CustomStringConvertible {
    case unsupportedBitDepth(Int)
    case renderFailed
    /// The file changed on disk after editing began (often: it was saved
    /// over), so its edits can't be applied to it again.
    case sourceChanged(URL)

    public var description: String {
        switch self {
        case .unsupportedBitDepth(let bits): "\(bits) bits per component can't be exported (8 or 16 can)."
        case .renderFailed: "The edited image could not be rendered."
        case .sourceChanged(let url):
            "\u{201C}\(url.lastPathComponent)\u{201D} changed on disk after editing began, so the edits can\u{2019}t be applied to it again. Reopen the image to keep editing."
        }
    }
}

/// What a file looked like when it was decoded for editing: enough to tell
/// that it has been rewritten since (a save changes both on APFS, whose
/// timestamps have nanosecond resolution).
struct FileSignature: Sendable, Equatable {
    let modified: Date?
    let size: Int64?

    static func read(_ url: URL) -> FileSignature? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return FileSignature(modified: values.contentModificationDate, size: values.fileSize.map(Int64.init))
    }
}
