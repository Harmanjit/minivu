import Foundation
import CoreGraphics
import ImageIO
import MinivuCore

/// Turns one source file into the encoded bytes of its converted file for
/// Batch Convert, through the same paths Save As uses (DESIGN.md 4.7):
///
/// - **Format change only** (no resize, turn or flip) of an ordinary image:
///   ImageIO decodes it at full resolution with its EXIF orientation baked
///   in, and the encoder converts colour and depth. No Core Image round
///   trip, so a JPEG written as PNG keeps exactly its pixels.
/// - **With operations, or a camera RAW:** the operations run through
///   `EditGraph` (the eleven resampling filters included) and
///   `EditRenderer.renderForExport` renders them on Metal, decoding the
///   original the way an edit does (RAW files through the RAW engine).
///   There is no second renderer to keep in step.
///
/// Stateless and `Sendable`: two files convert side by side. Both steps
/// block for a long time (a 24 MP render, a HEIC encode), so run them on a
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
    ///     engine). HDR is always off: every format written is SDR.
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

    /// The upright, operated-on picture, ready to encode.
    public func image(for url: URL, settings: BatchConvertSettings) async throws -> CGImage {
        let kind = ImageFormats.kind(of: url)
        guard let info = loadInfo(url) else { throw DecodeError.unreadable(url) }
        let operations = settings.operations(sourceSize: info.pixelSize)
        if operations.isEmpty && kind != .raw {
            return try ImageDecoder.decode(url, maxPixelSize: nil, page: 0, allowHDR: false).image
        }
        let options = settings.options
        let bits = options.format.supports16Bit && options.sixteenBit ? 16 : 8
        let snapshot = EditDocument.Snapshot(url: url, page: 0, kind: kind, operations: operations,
                                             sourceSize: info.pixelSize, source: nil, settings: displaySettings,
                                             sourceSignature: nil)
        return try await renderer.renderForExport(snapshot, colorSpace: resolveColorSpace(url, kind, options),
                                                  bitsPerComponent: bits)
    }

    /// The converted file's bytes. Metadata comes from the source when
    /// kept (with the orientation reset, the pixels being upright now).
    public func encodedData(for url: URL, settings: BatchConvertSettings) async throws -> Data {
        let image = try await image(for: url, settings: settings)
        return try ImageEncoder.encode(image, options: settings.options, metadataSource: url)
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
