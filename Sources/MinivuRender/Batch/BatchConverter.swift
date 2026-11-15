import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import MinivuCore

/// Turns one source file into the encoded bytes of its converted file for
/// Batch Convert, through the same paths Save As uses (DESIGN.md 4.7):
///
/// - **Format change only** (no edits, resize, turn or flip) of an ordinary
///   image: ImageIO decodes it at full resolution with its EXIF
///   orientation baked in, and the encoder converts colour and depth. No
///   Core Image round trip, so a JPEG written as PNG keeps exactly its
///   pixels.
/// - **With operations, or a camera RAW:** the operations (a preset's edits,
///   the turn, flip and resize, a watermark) run through `EditGraph` (the
///   eleven resampling filters included) and `EditRenderer.renderForExport`
///   renders them on Metal, decoding the original the way an edit does (RAW
///   files through the RAW engine). There is no second renderer to keep in
///   step.
/// - **HDR originals** (gain-map, PQ or HLG), when the settings keep HDR and
///   the format holds a gain map (JPEG, HEIC, AVIF): rendered as Save renders
///   a gain-map photo (`renderHDRForExport`, half floats with the original's
///   headroom) and written with an ISO gain map, so the highlights survive.
///
/// **Memory.** Before anything is decoded, the header's size and the size
/// the operations will make are checked against the renderer's export limit
/// (`exportDecodeLimit`, a quarter of RAM): a file or an output the Mac
/// can't hold is refused as `DecodeError.tooLarge`, which the batch reports
/// for that file and goes on. RAW files render through the editor's RAW
/// slots, and the job runs one at a time.
///
/// **Pages** (`BatchOutput.pages`): an output that is one page of a
/// multi-page original decodes that page; one that holds every page is
/// written page by page into a temporary file beside its destination by
/// `MultiPageWriter` (a multi-page TIFF, an animated GIF keeping the
/// original's frame delays and loops), one decoded page at a time, and
/// handed back as that file (`Encoded.file`).
///
/// Stateless and `Sendable`: two files convert side by side. Every step
/// blocks for a long time (a 24 MP render, a HEIC encode), so run them on a
/// thread that may block, as `BatchWorkExecutor` provides.
public struct BatchConverter: Sendable {
    /// The colour space a render with operations is made in, for a source
    /// and the chosen profile; the app answers with its Save policy.
    public typealias ColorSpaceResolver = @Sendable (_ source: URL, _ kind: ImageKind?, _ options: ExportOptions) -> CGColorSpace

    let renderer: EditRenderer
    let displaySettings: DisplaySettings
    let resolveColorSpace: ColorSpaceResolver
    let loadInfo: @Sendable (URL) -> ImageInfo?

    /// - Parameters:
    ///   - displaySettings: how RAW files decode (embedded preview or the RAW
    ///     engine). HDR is off for the SDR path; HDR originals written with a
    ///     gain map are decoded for HDR by the renderer whatever this says.
    public init(renderer: EditRenderer, displaySettings: DisplaySettings, resolveColorSpace: @escaping ColorSpaceResolver,
                loadInfo: @escaping @Sendable (URL) -> ImageInfo? = ImageDecoder.info(for:)) {
        self.renderer = renderer
        var settings = displaySettings
        settings.showHDR = false
        settings.hdrRaw = false
        self.displaySettings = settings
        self.resolveColorSpace = resolveColorSpace
        self.loadInfo = loadInfo
    }

    /// The upright, operated-on picture, ready to encode (SDR).
    public func image(for url: URL, settings: BatchConvertSettings) async throws -> CGImage {
        let job = try prepare(url, settings: settings, keepingHDR: false)
        return try await sdrImage(job, settings: settings)
    }

    /// The converted file's bytes. Metadata comes from the source when
    /// kept (with the orientation reset, the pixels being upright now).
    public func encodedData(for url: URL, settings: BatchConvertSettings) async throws -> Data {
        try await encodedData(for: url, page: 0, settings: settings)
    }

    /// A converted file: its bytes, or a file already written in full at a
    /// hidden temporary name beside the destination (every page of a
    /// multi-page original), which the caller renames into place or deletes.
    public enum Encoded: Sendable {
        case data(Data)
        case file(URL)
    }

    /// Converts `output`'s pages of its source. A multi-page output is
    /// written beside `output.destination` and checks `cancel` before every
    /// page, throwing `CancellationError` (and deleting what it wrote) once
    /// it is set.
    ///
    /// `sequences` keeps the source's pages open from one page output to the
    /// next, so extracting every frame of an animation composites each frame
    /// from the one before rather than from the first again.
    public func encoded(_ output: BatchOutput, settings: BatchConvertSettings,
                        cancel: CancellationFlag = CancellationFlag(),
                        sequences: PageSequences = PageSequences()) async throws -> Encoded {
        switch output.pages {
        case .primary:
            return .data(try await encodedData(for: output.source, page: 0, settings: settings))
        case .page(let index, _):
            return .data(try await encodedData(for: output.source, page: index, settings: settings,
                                               sequence: index == 0 ? nil : sequences.sequence(for: output.source)))
        case .all(let count):
            return .file(try await writeEveryPage(of: output.source, count: count, beside: output.destination,
                                                  settings: settings, cancel: cancel))
        }
    }

    func encodedData(for url: URL, page: Int, settings: BatchConvertSettings,
                     sequence: PageSequence? = nil) async throws -> Data {
        let job = try prepare(url, page: page, settings: settings, keepingHDR: settings.keepsHDR, sequence: sequence)
        if job.keepsHDR, let hdr = try await renderer.renderHDRForExport(job.snapshot(settings: displaySettings)) {
            return try ImageEncoder.encode(hdr, options: settings.options, metadataSource: url, gainMap: true)
        }
        let image = try await sdrImage(job, settings: settings)
        return try ImageEncoder.encode(image, options: settings.options, metadataSource: url)
    }

    /// Every page of `url`, converted, into one multi-page file at a hidden
    /// name beside `destination`: TIFF pages with the chosen compression and
    /// colour profile, or GIF frames with the original's delays and loops.
    /// No metadata (TIFF pages each keep their colour profile). An animated
    /// GIF's frames must fit the export budget together, since ImageIO holds
    /// them until the file is finished.
    func writeEveryPage(of url: URL, count: Int, beside destination: URL, settings: BatchConvertSettings,
                        cancel: CancellationFlag) async throws -> URL {
        guard let sequence = PageSequence(url: url) else { throw DecodeError.unreadable(url) }
        let format = settings.options.format
        let pageSettings = MultiPageSettings(format: format == .gif ? .gif : .tiff,
                                             tiffCompression: settings.options.tiffCompression,
                                             loopCount: sequence.kind == .animation ? sequence.loopCount : 0,
                                             frameSize: nil, colorProfile: settings.options.colorProfile)
        if format == .gif {
            let first = EditGraph.outputSize(source: sequence.pixelSize(ofPage: 0),
                                             operations: settings.operations(sourceSize: sequence.pixelSize(ofPage: 0)))
            try MultiPageBuilder.checkBudget(pageCount: count, first: first, settings: pageSettings,
                                             byteLimit: renderer.exportDecodeLimit)
        }
        let temporary = BatchFileWriter.temporaryURL(beside: destination)
        do {
            let writer = try MultiPageWriter(url: temporary, settings: pageSettings, expectedPages: count)
            for index in 0..<count {
                if cancel.isCancelled { throw CancellationError() }
                let job = try prepare(url, page: index, settings: settings, keepingHDR: false, sequence: sequence)
                let image = try await sdrImage(job, settings: settings)
                try writer.add(image, delay: sequence.delay(ofPage: index))
            }
            if cancel.isCancelled { throw CancellationError() }
            try writer.finish()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// One file's work, worked out before any pixel is decoded.
    struct Job {
        var url: URL
        var page: Int = 0
        var kind: ImageKind?
        var info: ImageInfo
        var operations: [EditOperation]
        /// Written with a gain map: an HDR original, a format that holds one,
        /// and the settings asking for it.
        var keepsHDR: Bool
        /// The original's pages, when a page other than the first is wanted.
        var sequence: PageSequence?

        func snapshot(settings: DisplaySettings) -> EditDocument.Snapshot {
            EditDocument.Snapshot(url: url, page: page, kind: kind, operations: operations, sourceSize: info.pixelSize,
                                  source: nil, settings: settings, sourceSignature: nil)
        }
    }

    /// Reads the header, checks the memory budget and measures Auto Enhance
    /// for this image (page `page` of it). Blocking (a small decode for the
    /// measurement).
    func prepare(_ url: URL, page: Int = 0, settings: BatchConvertSettings, keepingHDR: Bool,
                 sequence: PageSequence? = nil) throws -> Job {
        let kind = ImageFormats.kind(of: url)
        // A movie is never turned into a picture (G18): Batch Convert leaves
        // videos out, and a shortcut handed one gets this file's failure.
        guard kind != .video else { throw DecodeError.noImage(url) }
        var sequence = sequence
        let info: ImageInfo
        if page == 0 {
            guard let read = loadInfo(url) else { throw DecodeError.unreadable(url) }
            info = read
        } else {
            if sequence == nil { sequence = PageSequence(url: url) }
            guard let sequence, page < sequence.count else { throw DecodeError.noImage(url) }
            info = sequence.info(ofPage: page)
        }
        let operations = settings.operations(sourceSize: info.pixelSize)
        let hdr = keepingHDR && info.isHDR && kind == .raster && ImageEncoder.canWriteGainMap(settings.options)
        let bits = settings.options.format.supports16Bit && settings.options.sixteenBit ? 16 : 8
        try Self.checkBudget(url, info: info, operations: operations, bytesPerPixel: hdr || bits == 16 ? 8 : 4,
                             limit: renderer.exportDecodeLimit)
        return Job(url: url, page: page, kind: kind, info: info,
                   operations: try measuringAutoEnhance(operations, url: url, page: page, kind: kind, info: info),
                   keepsHDR: hdr, sequence: sequence)
    }

    func sdrImage(_ job: Job, settings: BatchConvertSettings) async throws -> CGImage {
        if job.operations.isEmpty && job.kind != .raw {
            // Every pixel, as an export keeps; a header claiming more than
            // the renderer's export limit is refused unread (`tooLarge`),
            // which the batch reports for this file and goes on. An HDR
            // original comes out as ImageIO's SDR rendition. An animation's
            // later frames come composited, as the viewer plays them.
            if let sequence = job.sequence, sequence.kind == .animation {
                return try sequence.page(job.page, byteLimit: renderer.exportDecodeLimit)
            }
            return try ImageDecoder.decode(job.url, maxPixelSize: nil, page: job.page, allowHDR: false,
                                           byteLimit: renderer.exportDecodeLimit).image
        }
        let options = settings.options
        let bits = options.format.supports16Bit && options.sixteenBit ? 16 : 8
        return try await renderer.renderForExport(job.snapshot(settings: displaySettings),
                                                  colorSpace: resolveColorSpace(job.url, job.kind, options),
                                                  bitsPerComponent: bits)
    }

    /// Refuses, before anything is decoded, a file whose header claims more
    /// than an export may hold (as the decode itself would), and one whose
    /// operations would make an output that large: a resize up to 32768 px,
    /// a frame or a shadow grows the picture past its original, and the
    /// render holds the whole output at `bytesPerPixel` (8 for 16 bits and
    /// for HDR half floats) before Core Image's tiles and the encoder take
    /// their share.
    static func checkBudget(_ url: URL, info: ImageInfo, operations: [EditOperation], bytesPerPixel: Int,
                            limit: Int) throws {
        if ImageDecoder.exceedsExportBudget(info, byteLimit: limit) { throw DecodeError.tooLarge(url) }
        guard !operations.isEmpty else { return }
        let output = EditGraph.outputSize(source: info.pixelSize, operations: operations)
        let pixels = Double(output.width) * Double(output.height)
        if pixels > Double(ImageDecoder.thumbnailPixelBudget) || pixels * Double(bytesPerPixel) > Double(limit) {
            throw DecodeError.tooLarge(url)
        }
    }

    // MARK: - Auto Enhance

    /// `operations` with every Auto Enhance step measured on this image: a
    /// preset carries the step, not the values measured on the photo it was
    /// made on (`BatchEdits.portable`), since a curve and a colour balance
    /// suggested for one photo suit no other. Each step is measured as the
    /// viewer measures it, on a rendering of the steps before it at
    /// `EditRenderer.analysisPixelSize`, from a small decode: the codec's
    /// own downscale for ordinary files, the camera's embedded preview for
    /// RAW files (never a render of the sensor data, which would need a RAW
    /// slot of its own). A RAW file with no embedded preview leaves the step
    /// out, as does one whose analysis can't be rendered.
    func measuringAutoEnhance(_ operations: [EditOperation], url: URL, page: Int = 0, kind: ImageKind?,
                              info: ImageInfo) throws -> [EditOperation] {
        guard operations.contains(where: BatchEdits.isAutoEnhance) else { return operations }
        let edge = EditRenderer.analysisPixelSize
        let small: CGImage? = if kind == .raw {
            try ImageDecoder.decodeRawPreview(url, maxPixelSize: edge)?.image
        } else {
            try ImageDecoder.decode(url, maxPixelSize: edge, page: page, allowHDR: false).image
        }
        var result = operations
        for index in result.indices where BatchEdits.isAutoEnhance(result[index]) {
            let measured = small.flatMap { Self.autoEnhancement(of: $0, sourceSize: info.pixelSize,
                                                                before: Array(result[..<index]),
                                                                context: renderer.context) }
            result[index] = .autoEnhance(measured ?? AutoEnhance())
        }
        return result
    }

    /// What Auto Enhance suggests for `small` (the original, decoded small)
    /// with `before` applied, lengths in full-resolution pixels; nil when
    /// the rendering fails.
    static func autoEnhancement(of small: CGImage, sourceSize: CGSize, before: [EditOperation],
                                context: CIContext) -> AutoEnhance? {
        let fullWidth = Int(sourceSize.width.rounded()), fullHeight = Int(sourceSize.height.rounded())
        guard fullWidth > 0, fullHeight > 0 else { return nil }
        let scale = Double(max(small.width, small.height)) / Double(max(fullWidth, fullHeight))
        // The graph wants its source exactly at the working size; the codec's
        // downscale may be a pixel off, which a measurement doesn't mind.
        let width = EditGraph.workingLength(fullWidth, scale: scale)
        let height = EditGraph.workingLength(fullHeight, scale: scale)
        let source = CIImage(cgImage: small).transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(small.width), y: CGFloat(height) / CGFloat(small.height)))
        let image = EditGraph.image(source: source, sourceSize: sourceSize, operations: before, scale: scale)
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let output = EditGraph.outputSize(source: sourceSize, operations: before)
        let analysedScale = output.width > 0 ? Double(rendered.width) / Double(output.width) : scale
        return AutoEnhance.analyse(CIImage(cgImage: rendered), analysedScale: analysedScale)
    }
}

/// Runs batch work on Grand Central Dispatch threads, including the async
/// renderer calls inside it.
///
/// A conversion blocks its thread for hundreds of milliseconds (decoding,
/// Core Image rendering, encoding). On Swift's cooperative pool, which has
/// one thread per core, a batch could starve every other task in the app
/// (see `BlockingWork`). Work run with this executor as its task executor
/// preference (`withTaskExecutorPreference`) runs on GCD's global
/// user-initiated threads instead, which grow for blocking work, and that
/// includes nonisolated async functions it calls, such as
/// `EditRenderer.renderForExport`.
public final class BatchWorkExecutor: TaskExecutor {
    public static let shared = BatchWorkExecutor()

    private let queue = DispatchQueue.global(qos: .userInitiated)

    public init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// The pages of the source a batch is working through, kept from one page
/// output to the next (`BatchConverter.encoded`). Only the latest source is
/// held: a batch takes one file's pages in order before the next file's.
public final class PageSequences: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PageSequence?
    /// For tests: the number of times a file's pages were opened.
    public private(set) var opened = 0

    public init() {}

    /// The pages of `url`, opened again only when the file changes; nil when
    /// it can't be read.
    func sequence(for url: URL) -> PageSequence? {
        lock.lock(); defer { lock.unlock() }
        if let current, current.url == url { return current }
        current = PageSequence(url: url)
        opened += 1
        return current
    }
}
