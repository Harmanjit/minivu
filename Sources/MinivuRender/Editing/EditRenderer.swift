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
    /// The RAW tool's settings this original was developed with; nil for
    /// one decoded by the viewer's rules (any file that isn't RAW, and a RAW
    /// file before any RAW step).
    let develop: RawDevelop?

    init(texture: MTLTexture?, image: CIImage, size: CGSize, scale: Double = 1, isHDR: Bool, contentHeadroom: Float,
         develop: RawDevelop? = nil) {
        self.texture = texture
        self.image = image
        self.size = size
        self.scale = scale
        self.isHDR = isHDR
        self.contentHeadroom = contentHeadroom
        self.develop = develop
    }
}

/// A smaller copy of the original that slider renders run on.
final class EditProxy: @unchecked Sendable {
    let texture: MTLTexture
    let image: CIImage
    /// Its size over the original's (`EditGraph.workingLength` per axis).
    let scale: Double
    /// The RAW settings it shows (see `EditSource.develop`): the original's
    /// for a proxy made from it, the RAW tool's live ones for a proxy the
    /// engine developed at this size while the tool's sliders move.
    let develop: RawDevelop?
    let isHDR: Bool
    let contentHeadroom: Float

    init(texture: MTLTexture, image: CIImage, scale: Double, develop: RawDevelop? = nil, isHDR: Bool = false,
         contentHeadroom: Float = 1) {
        self.texture = texture
        self.image = image
        self.scale = scale
        self.develop = develop
        self.isHDR = isHDR
        self.contentHeadroom = contentHeadroom
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
    /// The RAW settings of the image it was rendered from (see `EditProxy`).
    let develop: RawDevelop?
    /// The operations it holds, and the scale it was rendered at.
    let operations: [EditOperation]
    let scale: Double
    /// Full-resolution size after `operations`.
    let size: CGSize
    let texture: MTLTexture
    let image: CIImage

    init(source: EditSource, develop: RawDevelop?, operations: [EditOperation], scale: Double, size: CGSize,
         texture: MTLTexture, image: CIImage) {
        self.source = source
        self.develop = develop
        self.operations = operations
        self.scale = scale
        self.size = size
        self.texture = texture
        self.image = image
    }

    func matches(source: EditSource, develop: RawDevelop?, operations prefix: ArraySlice<EditOperation>,
                 scale: Double) -> Bool {
        self.source === source && self.develop == develop && abs(self.scale - scale) < 1e-9
            && self.operations[...] == prefix
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
/// **RAW settings.** The RAW tool's step (`EditOperation.rawDevelop`) is
/// not a graph operation: it changes how the sensor data is developed, so
/// it changes the original itself, and `EditGraph` passes the image through
/// it untouched. Every original and proxy records the settings it shows
/// (`EditSource.develop`, `EditProxy.develop`), and each render compares
/// them with the settings its operations ask for (the last RAW step's;
/// `RawDevelop.inEffect`):
///
/// - a full-resolution render, or any render once no RAW step is left (all
///   undone), first makes the original again with those settings and puts
///   it on the document in place of the old one, which frees it. Both lanes
///   share that decode (`remadeSource`): after an undo past the last RAW
///   step the preview waits for the full lane's decode rather than run a
///   second one, and a render that finishes after the original changed
///   keeps neither the stage nor the proxy it built from the old one;
/// - a preview while the tool's sliders move doesn't wait for that: the
///   engine develops the file again at the preview's own size (its scale
///   factor skips the work a smaller picture doesn't need; 65-78 ms at half
///   size for 24 MP on M4, with the file kept open on the document as
///   `RawDevelopFilter`), and that image is the proxy the preview and the
///   next ones with the same settings start from.
///
/// So undo and redo are a change of operations like any other, and the
/// renders that follow make the original agree again; a save renders from
/// an original with the committed settings, decoding one if the document's
/// doesn't have them. HDR follows the viewer's RAW settings, as the first
/// decode does: with extended dynamic range on, every developed image keeps
/// highlights above white and measures its own headroom. Engine renders take
/// one of the editor's RAW slots (`RawRenderer.withEditRenderSlot`: one at a
/// time on 8 GB Macs, shared there with the viewer's RAW renders) and run on
/// the RAW context, with its memory limit.
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

    /// The most bytes an export may decode an original into
    /// (`ImageDecoder.exportDecodeLimit`): Save of an unedited original and
    /// Batch Convert's format-only path, which decode without this renderer,
    /// read it from here too, so every export refuses the same files.
    /// Tests pin it.
    nonisolated public let exportDecodeLimit: Int

    public init(gpu: GPU = .shared, exportDecodeLimit: Int = ImageDecoder.exportDecodeLimit()) {
        self.gpu = gpu
        self.exportDecodeLimit = exportDecodeLimit
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
        // A document prepared again (after a release) with RAW steps decodes
        // its original with their settings straight away.
        let develop = Self.rawDevelop(kind: kind, operations: document.operations)
        let rawFilter = document.rawFilter
        let preparation = Task { [weak document] in
            // A full-resolution decode and a GPU wait block their thread for
            // 100 ms or more: on GCD, not the cooperative pool (BlockingWork).
            let (source, proxy, signature, filter) = try await BlockingWork.run {
                () throws -> (EditSource, EditProxy?, FileSignature?, RawDevelopFilter?) in
                let preparing = Perf.begin("edit.prepare")
                defer { preparing.end() }
                // Read before decoding, so a change racing the decode is caught.
                let signature = FileSignature.read(url)
                if let expected, signature != expected { throw EditRenderError.sourceChanged(url) }
                let filter = develop == nil ? rawFilter : rawFilter ?? RawDevelopFilter(url: url)
                let source = try Perf.measure("edit.prepare.load") {
                    try Self.loadSource(url: url, page: page, kind: kind, settings: settings, gpu: gpu,
                                        develop: develop, rawFilter: filter)
                }
                let scale = Self.proxyScale(sourceSize: source.size, sourceScale: source.scale, longEdge: edge)
                let proxy = try Perf.measure("edit.prepare.proxy") {
                    try scale.map { try Self.makeProxy(source, scale: $0, context: context, gpu: gpu) }
                }
                return (source, proxy, signature, filter)
            }
            guard let document, document.preparationToken == token else { return }
            document.source = source
            document.proxy = proxy
            document.sourceSize = source.size
            if document.rawFilter == nil { document.rawFilter = filter }
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
        document.rawFilter = nil
        document.sourceRemake = nil
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
        let gpu = self.gpu, context = self.context, limit = exportDecodeLimit
        // Decoding and Core Image's CPU readback block for tens of ms to
        // seconds (a RAW, a batch of them): on GCD, not the cooperative pool.
        return try await BlockingWork.run(qos: Task.currentPriority >= .userInitiated ? .userInitiated : .utility) {
            try Self.exportImage(snapshot, colorSpace: colorSpace, bitsPerComponent: bitsPerComponent,
                                 context: context, gpu: gpu, decodeLimit: limit)
        }
    }

    /// Final pixels for saving an HDR photo with its highlights: the
    /// committed operations at full resolution, as half floats in extended
    /// linear Display P3 with the original's content headroom set, which is
    /// what ImageIO needs to write a gain map (`ImageEncoder.write(gainMap:)`).
    /// Values above the headroom are clipped by the gain map, as the canvas
    /// showed them. The original is decoded for HDR whatever the viewer's HDR
    /// setting (a setting for the screen, not for the file); nil when it has
    /// no HDR form to decode.
    nonisolated public func renderHDRForExport(_ snapshot: EditDocument.Snapshot) async throws -> CGImage? {
        let gpu = self.gpu, context = self.context, limit = exportDecodeLimit
        return try await BlockingWork.run(qos: Task.currentPriority >= .userInitiated ? .userInitiated : .utility) {
            let exporting = Perf.begin("edit.exportHDR")
            defer { exporting.end() }
            var settings = snapshot.settings
            settings.showHDR = true
            let source = try Self.exportSource(snapshot, settings: settings, requireHDR: true, gpu: gpu,
                                               decodeLimit: limit)
            guard source.isHDR, source.contentHeadroom > 1 else { return nil }
            let image = EditGraph.image(source: Self.workingImage(source: source, proxy: nil, scale: 1),
                                        sourceSize: source.size, operations: snapshot.operations, scale: 1)
            guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBAh,
                                                       colorSpace: Self.workingSpace, deferred: false),
                  let withHeadroom = CGImageCreateCopyWithContentHeadroom(source.contentHeadroom, rendered) else {
                throw EditRenderError.renderFailed
            }
            return withHeadroom
        }
    }

    /// The original an export renders from: the document's own when it has
    /// every pixel (and, with `requireHDR`, is HDR), otherwise decoded again
    /// with `settings`.
    nonisolated private static func exportSource(_ snapshot: EditDocument.Snapshot, settings: DisplaySettings,
                                                 requireHDR: Bool = false, gpu: GPU,
                                                 decodeLimit: Int) throws -> EditSource {
        let develop = rawDevelop(kind: snapshot.kind, operations: snapshot.operations)
        if let prepared = snapshot.source, prepared.scale >= 1, prepared.isHDR || !requireHDR,
           snapshot.kind != .raw || prepared.develop == develop {
            return prepared
        }
        // Re-reading the file is only safe if it is still the file the
        // operations were made on. After a Save over the original it
        // isn't: the edits are already in it, and applying them again
        // would write them twice.
        if let expected = snapshot.sourceSignature, FileSignature.read(snapshot.url) != expected {
            throw EditRenderError.sourceChanged(snapshot.url)
        }
        return try loadSource(url: snapshot.url, page: snapshot.page, kind: snapshot.kind,
                              settings: settings, gpu: gpu, forExport: true, decodeLimit: decodeLimit,
                              develop: develop)
    }

    nonisolated private static func exportImage(_ snapshot: EditDocument.Snapshot, colorSpace: CGColorSpace,
                                                bitsPerComponent: Int, context: CIContext, gpu: GPU,
                                                decodeLimit: Int) throws -> CGImage {
        let exporting = Perf.begin("edit.export")
        defer { exporting.end() }
        let source = try Perf.measure("edit.export.source") {
            try exportSource(snapshot, settings: snapshot.settings, gpu: gpu, decodeLimit: decodeLimit)
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
        guard let cgImage = Perf.measure("edit.export.render", {
            context.createCGImage(image, from: image.extent, format: format, colorSpace: colorSpace, deferred: false)
        }) else {
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

    /// What a render made besides its texture, for the document to keep.
    private struct RunResult: Sendable {
        let texture: ImageTexture
        /// A proxy it built (larger, or developed with new RAW settings).
        let proxy: EditProxy?
        let stage: EditStage?
        /// The RAW file opened in the engine, if this render opened it.
        let rawFilter: RawDevelopFilter?
    }

    private func run(_ request: RenderLane.Request, for document: EditDocument, full: Bool) async {
        do {
            try await prepare(document)
        } catch {
            return   // an unreadable file: nothing to show, and the viewer reports decode errors
        }
        guard var source = document.source else { return }
        let token = document.preparationToken
        let operations = document.renderedOperations
        let revision = document.revision
        let committed = document.operations, preview = document.preview
        let lane = full ? document.fullLane : document.previewLane
        lane.runningRevision = revision
        defer { lane.runningRevision = nil }
        let pixelSize = request.pixelSize ?? 1

        // RAW settings (see the type's documentation). For any other file
        // `develop` is nil, as is every source's and proxy's, so nothing
        // below changes for it.
        let kind = document.entry.kind, url = document.entry.url
        let develop = Self.rawDevelop(kind: kind, operations: operations)
        if source.develop != develop, full || develop == nil {
            // The original made again first, by one decode both lanes share.
            guard let remade = await remadeSource(document, develop: develop, qos: full ? .utility : .userInitiated),
                  document.preparationToken == token else { return }
            source = remade
        }
        let sourceShowsDevelop = source.develop == develop
        let developPreview = !sourceShowsDevelop
        let rawFilter = document.rawFilter
        let settings = ImageLoader.shared.settings
        let expected = document.sourceSignature
        // Only a proxy showing the same settings can serve.
        let proxy = document.proxy.flatMap { $0.develop == develop ? $0 : nil }

        let outputSize = EditGraph.outputSize(source: source.size, operations: operations)
        let plan = full
            ? Self.fullResolutionPlan(outputSize: outputSize, sourceScale: source.scale)
            : Self.previewPlan(outputSize: outputSize, pixelSize: pixelSize, proxyScale: proxy?.scale,
                               sourceScale: source.scale)
        let gpu = self.gpu, context = self.context
        // A render that makes its own original or proxy from the RAW engine
        // starts without a stage: the stage's image may show other settings.
        let stageLength = sourceShowsDevelop
            ? Self.stageLength(operations: operations, committed: committed.count, sourceSize: source.size) : nil
        let stage = stageLength.flatMap { length in
            lane.stage.flatMap {
                $0.matches(source: source, develop: develop, operations: operations.prefix(length), scale: plan.scale)
                    ? $0 : nil
            }
        }

        let renderSource = source
        // `renderTexture` waits for the GPU: on GCD, not the cooperative pool.
        let result = await BlockingWork.run(qos: full ? .utility : .userInitiated) { () -> RunResult? in
            let rendering = Perf.begin(full ? "edit.render.full" : "edit.render.preview")
            defer { rendering.end() }
            do {
                var filter = rawFilter
                var plan = plan
                var workingProxy = proxy
                var newProxy: EditProxy?
                var newStage: EditStage?
                var isHDR = renderSource.isHDR, headroom = renderSource.contentHeadroom
                let image: CIImage
                if let stage {
                    image = EditGraph.image(source: stage.image, sourceSize: stage.size,
                                            operations: Array(operations[stage.operations.count...]), scale: plan.scale)
                } else {
                    if developPreview, plan.rebuildProxy || !plan.useProxy {
                        // The RAW tool's sliders: the engine develops the file
                        // at exactly the size this preview asks for. (Not the
                        // quarter more a growing proxy gets: every slider
                        // frame develops again anyway, so the extra pixels
                        // would only cost time.)
                        let long = Double(max(outputSize.width, outputSize.height))
                        let scale = long > 0 ? min(plan.maximumScale, Double(pixelSize) / long) : plan.maximumScale
                        if filter == nil {
                            if let expected, FileSignature.read(url) != expected {
                                throw EditRenderError.sourceChanged(url)
                            }
                            filter = RawDevelopFilter(url: url)
                        }
                        guard let filter else { throw DecodeError.noImage(url) }
                        let developed = try Perf.measure("edit.render.rawDevelop") {
                            try Self.renderDeveloped(filter, develop: develop, fullSize: renderSource.size,
                                                     scale: scale, settings: settings, gpu: gpu)
                        }
                        workingProxy = EditProxy(texture: developed.texture, image: developed.image, scale: scale,
                                                 develop: develop, isHDR: settings.rendersHDRRaw,
                                                 contentHeadroom: developed.headroom)
                        newProxy = workingProxy
                        plan = Plan(scale: scale, maximumScale: plan.maximumScale, useProxy: true, rebuildProxy: false)
                    } else if plan.rebuildProxy {
                        workingProxy = try Perf.measure("edit.render.proxyRebuild") {
                            try Self.makeProxy(renderSource, scale: plan.scale, context: context, gpu: gpu)
                        }
                        newProxy = workingProxy
                    }
                    if developPreview, let workingProxy {
                        isHDR = workingProxy.isHDR
                        headroom = workingProxy.contentHeadroom
                    }
                    let working = Self.workingImage(source: renderSource, proxy: plan.useProxy ? workingProxy : nil,
                                                    scale: plan.scale)
                    if let stageLength {
                        let prefix = Array(operations.prefix(stageLength))
                        let size = EditGraph.outputSize(source: renderSource.size, operations: prefix)
                        let staged = EditGraph.image(source: working, sourceSize: renderSource.size, operations: prefix,
                                                     scale: plan.scale)
                        let (texture, stagedImage) = try Self.renderIntermediate(staged, context: context, gpu: gpu,
                                                                                 label: "an edit stage")
                        newStage = EditStage(source: renderSource, develop: develop, operations: prefix,
                                             scale: plan.scale, size: size, texture: texture, image: stagedImage)
                        image = EditGraph.image(source: stagedImage, sourceSize: size,
                                                operations: Array(operations[stageLength...]), scale: plan.scale)
                    } else {
                        image = EditGraph.image(source: working, sourceSize: renderSource.size, operations: operations,
                                                scale: plan.scale)
                    }
                }
                let texture = try Perf.measure("edit.render.texture") {
                    try Self.renderTexture(image, context: context, gpu: gpu)
                }
                let output = ImageTexture(texture: texture, imageSize: outputSize,
                                          isFullResolution: plan.scale >= plan.maximumScale,
                                          isHDR: isHDR, contentHeadroom: headroom)
                return RunResult(texture: output, proxy: newProxy, stage: newStage,
                                 rawFilter: filter !== rawFilter ? filter : nil)
            } catch {
                return nil
            }
        }

        // Released, or prepared again from scratch, while rendering.
        guard let result, document.preparationToken == token else { return }
        let texture = result.texture
        if let filter = result.rawFilter, document.rawFilter == nil { document.rawFilter = filter }
        // The original made again while this rendered (by the other lane):
        // a stage or proxy built from the old one would keep its pixels
        // alive, and may be the wrong size, so neither is kept.
        let sourceIsCurrent = document.source === source
        if let newProxy = result.proxy, sourceIsCurrent {
            // Keep the proxy that shows the document's settings now: a larger
            // one, or one developed with settings the old one doesn't show.
            let wanted = Self.rawDevelop(kind: kind, operations: document.renderedOperations)
            if let current = document.proxy {
                if newProxy.develop == wanted, current.develop != wanted || newProxy.scale > current.scale {
                    document.proxy = newProxy
                }
            } else {
                document.proxy = newProxy
            }
        }
        // A render without a stage to use (none fits its operations, or it
        // made one) drops the lane's old one, whose memory nothing needs.
        if stage == nil { lane.stage = sourceIsCurrent ? result.stage : nil }
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

    /// The document's original made again with `develop` (see the type's
    /// documentation), put on the document in place of the one it had, which
    /// frees that one, if the document still wants those settings when it is
    /// done. The lanes share one decode: a lane asking for the same
    /// settings while a remake is under way waits for it rather than decode
    /// the file a second time (after the last RAW step is undone both lanes
    /// need the plain original at once). Nil when the file can't be decoded
    /// or has changed, or the document was released meanwhile.
    func remadeSource(_ document: EditDocument, develop: RawDevelop?,
                      qos: DispatchQoS.QoSClass) async -> EditSource? {
        if let remake = document.sourceRemake, remake.develop == develop { return await remake.task.value }
        guard document.source != nil else { return nil }
        let token = document.preparationToken
        let url = document.entry.url, page = document.page, kind = document.entry.kind
        let settings = ImageLoader.shared.settings, gpu = self.gpu
        let expected = document.sourceSignature, rawFilter = document.rawFilter
        let id = UUID()
        let task = Task { [weak document] () -> EditSource? in
            let made = await BlockingWork.run(qos: qos) { () -> (EditSource, RawDevelopFilter?)? in
                do {
                    // The same check as `prepare`: the operations were made
                    // on the file as it was first decoded.
                    if let expected, FileSignature.read(url) != expected { throw EditRenderError.sourceChanged(url) }
                    let filter = develop == nil ? rawFilter : rawFilter ?? RawDevelopFilter(url: url)
                    let source = try Self.loadSource(url: url, page: page, kind: kind, settings: settings, gpu: gpu,
                                                     develop: develop, rawFilter: filter)
                    return (source, filter)
                } catch {
                    return nil
                }
            }
            guard let document else { return nil }
            if document.sourceRemake?.id == id { document.sourceRemake = nil }
            guard let (source, filter) = made, document.preparationToken == token else { return nil }
            if let filter, document.rawFilter == nil { document.rawFilter = filter }
            // Put on the document only while its operations still ask for
            // these settings (committed, or a live preview's) and its
            // original doesn't already show them: a remake for settings
            // undone meanwhile serves the render that asked for it and no
            // more, rather than leave an original no render wants.
            let wanted = [document.operations, document.renderedOperations].map {
                Self.rawDevelop(kind: kind, operations: $0)
            }
            if wanted.contains(develop), document.source?.develop != develop {
                // Stages made from the old original go with it.
                document.source = source
                document.sourceSize = source.size
                for lane in [document.previewLane, document.fullLane] where lane.stage?.source !== source {
                    lane.stage = nil
                }
            }
            return source
        }
        document.sourceRemake = EditDocument.SourceRemake(id: id, develop: develop, task: task)
        document.sourceRemakes += 1
        return await task.value
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
    ///
    /// The edges are repeated underneath rather than in the kernel's input.
    /// Fused into one graph with a scale filter, the node `clampedToExtent`
    /// makes is materialised by macOS 27 in an 8-bit buffer whenever the
    /// context works in half float, so every value is clipped to 1 before
    /// the resample and an HDR photo loses its highlights (see "Core Image
    /// on macOS 27" in DESIGN.md). So Lanczos resamples the image as it
    /// stands, keeping them, over an affine copy of the clamped one, which
    /// is opaque everywhere the kernel would otherwise have sampled
    /// transparent black. Alpha is 1 across the picture, so only the border
    /// blends. Rendering the clamped image to a texture first would also
    /// work, at the cost of a full-size buffer for every proxy.
    nonisolated static func lanczos(_ image: CIImage, to fullSize: CGSize, scale: Double) -> CIImage {
        let width = EditGraph.workingLength(Int(fullSize.width.rounded()), scale: scale)
        let height = EditGraph.workingLength(Int(fullSize.height.rounded()), scale: scale)
        let sx = Double(width) / Double(image.extent.width)
        let sy = Double(height) / Double(image.extent.height)
        let border = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return image
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            .composited(over: border)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    nonisolated static func makeProxy(_ source: EditSource, scale: Double, context: CIContext, gpu: GPU) throws -> EditProxy {
        let image = lanczos(source.image, to: source.size, scale: scale)
        let (texture, proxyImage) = try renderIntermediate(image, context: context, gpu: gpu, label: "an edit proxy")
        return EditProxy(texture: texture, image: proxyImage, scale: scale, develop: source.develop,
                         isHDR: source.isHDR, contentHeadroom: source.contentHeadroom)
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
    /// read in tiles, so a saved file keeps every pixel; a file whose header
    /// claims more than `decodeLimit` bytes of that is refused with
    /// `DecodeError.tooLarge` before it is decoded.
    ///
    /// A RAW file with RAW tool settings (`develop`) is developed with them
    /// by Apple's RAW engine, through `rawFilter` when the document has the
    /// file open already; a camera the engine doesn't know falls back to the
    /// viewer's rules, as without settings.
    nonisolated static func loadSource(url: URL, page: Int, kind: ImageKind?, settings: DisplaySettings,
                                       gpu: GPU, forExport: Bool = false,
                                       decodeLimit: Int = ImageDecoder.exportDecodeLimit(),
                                       develop: RawDevelop? = nil,
                                       rawFilter: RawDevelopFilter? = nil) throws -> EditSource {
        if kind == .raw {
            // The RAW path decodes the embedded preview at the size the header
            // claims, so an export reads the header first, as `decode` does for
            // every other file. A header with no size at all is a camera the
            // RAW engine doesn't know, whose preview is the image: let through.
            if forExport, let info = ImageDecoder.info(for: url), info.pixelSize != .zero,
               ImageDecoder.exceedsExportBudget(info, byteLimit: decodeLimit) {
                throw DecodeError.tooLarge(url)
            }
            if let develop, let filter = rawFilter ?? RawDevelopFilter(url: url) {
                return try developedSource(filter, develop: develop, settings: settings, gpu: gpu)
            }
            if let raw = try loadRaw(url: url, settings: settings, gpu: gpu) {
                return raw
            }
        }
        let decoded = try ImageDecoder.decode(url, maxPixelSize: forExport ? nil : maximumDimension, page: page,
                                              allowHDR: settings.showHDR, byteLimit: forExport ? decodeLimit : nil)
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
            let rendered = try RawRenderer.withEditRenderSlot {
                try RawRenderer.render(url: url, maxPixelSize: nil, hdr: plan == .render(hdr: true),
                                       headroom: settings.rawHeadroom, gpu: gpu)
            }
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
        case .unsupportedBitDepth(let bits): localized("\(bits) bits per component can't be exported (8 or 16 can).")
        case .renderFailed: localized("The edited image could not be rendered.")
        case .sourceChanged(let url):
            localized("“\(url.lastPathComponent)” changed on disk after editing began, so the edits can’t be applied to it again. Reopen the image to keep editing.")
        }
    }
}

/// What a file looked like when it was decoded for editing: enough to tell
/// that it has been rewritten since (see `FileStamp`).
typealias FileSignature = FileStamp
