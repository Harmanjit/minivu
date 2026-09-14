import Foundation
import CoreGraphics
import Observation
import MinivuCore
import MinivuRender

/// What the "Estimated size" line shows.
nonisolated enum SizeEstimate: Equatable, Sendable {
    /// Nothing measured yet (the debounce hasn't elapsed).
    case none
    /// The exact encode is slow and no approximation is in yet.
    case estimating
    /// Extrapolated from a centre crop while the exact encode runs.
    case approximate(Int64)
    /// The size of the file the current options would write, metadata included.
    case exact(Int64)
    case failed
}

/// Crops and extrapolation for the size estimate and the quality comparison.
nonisolated enum SizeEstimator {
    /// Side of the region encoded for an approximation or a comparison: big
    /// enough to hold typical detail and noise, small enough (4 MB of 8-bit
    /// pixels) to encode in a few milliseconds.
    static let cropSide = 1024

    /// JPEG and HEIC code the picture in 16 × 16 blocks (8 × 8 luma blocks
    /// under 2 × 2 chroma subsampling). A crop that starts on that grid
    /// shows the same blocks, and so the same artefacts, as the whole file.
    static let blockAlignment = 16

    /// A `side` × `side` region (or the whole image when it is smaller)
    /// centred as near `centre` as the image allows, its origin on the block
    /// grid. Coordinates in pixels, origin at the top left.
    static func crop(imageWidth: Int, imageHeight: Int, centre: CGPoint, side: Int = cropSide,
                     alignment: Int = blockAlignment) -> CGRect {
        func axis(_ length: Int, _ middle: CGFloat) -> (origin: Int, size: Int) {
            let size = min(side, length)
            let wanted = Int((middle - CGFloat(size) / 2).rounded())
            let aligned = Int((Double(wanted) / Double(alignment)).rounded()) * alignment
            // The last aligned origin that still fits; if even 0 is the only
            // one (the image is smaller than a block past the crop), 0.
            let limit = (length - size) / alignment * alignment
            return (min(max(aligned, 0), limit), size)
        }
        let x = axis(imageWidth, centre.x), y = axis(imageHeight, centre.y)
        return CGRect(x: x.origin, y: y.origin, width: x.size, height: y.size)
    }

    static func centreCrop(imageWidth: Int, imageHeight: Int, side: Int = cropSide) -> CGRect {
        crop(imageWidth: imageWidth, imageHeight: imageHeight,
             centre: CGPoint(x: CGFloat(imageWidth) / 2, y: CGFloat(imageHeight) / 2), side: side)
    }

    /// The whole file's size from a crop's, in proportion to pixel count.
    static func extrapolate(cropBytes: Int, cropPixels: Int, totalPixels: Int) -> Int64 {
        guard cropPixels > 0 else { return 0 }
        return Int64((Double(cropBytes) * Double(totalPixels) / Double(cropPixels)).rounded())
    }

    /// Encodes the whole image exactly as saving would, metadata included.
    static func exactBytes(_ image: CGImage, options: ExportOptions, metadataSource: URL?) throws -> Int64 {
        Int64(try ImageEncoder.encode(image, options: options, metadataSource: metadataSource).count)
    }

    /// Encodes the centre crop without metadata and scales up. Detail is
    /// rarely uniform, so this is a first impression while the exact encode
    /// of a very large image is still running.
    static func approximateBytes(_ image: CGImage, options: ExportOptions) throws -> Int64 {
        let rect = centreCrop(imageWidth: image.width, imageHeight: image.height)
        guard let cropped = image.cropping(to: rect) else { throw ExportError.cannotConvertPixels }
        var cropOptions = options
        cropOptions.keepMetadata = false
        let bytes = try ImageEncoder.encode(cropped, options: cropOptions, metadataSource: nil).count
        return extrapolate(cropBytes: bytes, cropPixels: cropped.width * cropped.height,
                           totalPixels: image.width * image.height)
    }
}

/// The state of one Save As: the options being chosen and what they cost.
/// Shared by the panel's accessory view and the quality comparison, so a
/// change in either shows in both.
///
/// The estimate follows the options: 150 ms after the last change the image
/// is rendered (once per colour space and depth; see `SaveImageSource`) and
/// encoded in full in the background, which is the only way to give the
/// real size of a file with metadata and a colour profile. Only one full
/// encode runs at a time: one superseded by newer options finishes, and is
/// ignored. If an encode takes longer than 400 ms (a 50 MP TIFF, say), the
/// line says "Estimating…" and then shows a figure extrapolated from a
/// centre crop until the exact one arrives.
@MainActor @Observable final class SaveAsModel {
    let entry: FolderEntry
    let source: SaveImageSource
    @ObservationIgnored let store: SaveOptionsStore

    var options: ExportOptions {
        didSet {
            guard options != oldValue else { return }
            refreshEstimate()
        }
    }

    private(set) var estimate: SizeEstimate = .none
    /// Whether `estimate` was measured for the current options. After a
    /// change the old figure stays on screen, with a spinner, until the new
    /// one is in, rather than passing for the size of the new options.
    private(set) var isEstimateCurrent = false
    /// The pixels for the current options are being rendered or decoded.
    private(set) var isRendering = false
    /// Why the image couldn't be rendered, when it couldn't.
    private(set) var renderError: String?
    /// The source has an alpha channel, so formats without one need a background.
    private(set) var sourceHasAlpha = false

    /// Called after the format changes, for the panel to change the extension.
    @ObservationIgnored var onFormatChange: ((ExportFormat) -> Void)?

    static let debounce: Duration = .milliseconds(150)
    static let slowEncode: Duration = .milliseconds(400)

    @ObservationIgnored private var optionsByFormat: [ExportFormat: ExportOptions] = [:]
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var runningEncode: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(entry: FolderEntry, document: EditDocument?, store: SaveOptionsStore = SaveOptionsStore()) {
        self.entry = entry
        self.store = store
        source = SaveImageSource(entry: entry, document: document)
        options = store.options(for: store.initialFormat(for: entry.url))
        let url = entry.url
        Task { [weak self] in
            let info = await Task.detached(priority: .utility) { ImageDecoder.info(for: url) }.value
            self?.sourceInfoArrived(hasAlpha: info?.hasAlpha ?? false, bitDepth: info?.bitDepth ?? 8)
        }
    }

    /// Bits per channel of the source, once its header has been read.
    @ObservationIgnored private(set) var sourceBitDepth = 8

    /// The header is read in the background after the panel opens. A deep
    /// source (a 16-bit TIFF, a RAW) starts PNG and TIFF at 16 bits unless
    /// the user has saved in that format before, so converting it doesn't
    /// throw away precision by default; options already touched are left alone.
    func sourceInfoArrived(hasAlpha: Bool, bitDepth: Int) {
        sourceHasAlpha = hasAlpha
        sourceBitDepth = bitDepth
        if options == store.options(for: options.format) {
            options = startingOptions(for: options.format)
        }
    }

    /// What a format starts with in this dialog: the remembered options, or
    /// the defaults adjusted to the source's depth.
    private func startingOptions(for format: ExportFormat) -> ExportOptions {
        var options = store.options(for: format)
        if !store.hasRemembered(format), sourceBitDepth > 8, format.supports16Bit {
            options.sixteenBit = true
        }
        return options
    }

    /// Stops estimating; the panel has closed.
    func cancel() {
        generation += 1
        estimateTask?.cancel()
        estimateTask = nil
    }

    // MARK: - Options

    var format: ExportFormat {
        get { options.format }
        set { select(newValue) }
    }

    /// Switches format, restoring what was chosen for that format earlier in
    /// this dialog, or else what was remembered from the last save in it.
    func select(_ format: ExportFormat) {
        guard format != options.format else { return }
        optionsByFormat[options.format] = options
        options = optionsByFormat[format] ?? startingOptions(for: format)
        onFormatChange?(format)
    }

    /// Quality as the slider shows it, 1...100.
    var qualityPercent: Double {
        get { (options.quality * 100).rounded() }
        set { options.quality = min(max(newValue.rounded(), 1), 100) / 100 }
    }

    /// "JPEG quality 72", or just "PNG" for lossless formats.
    var formatDescription: String {
        let format = options.format
        return format.supportsQuality ? "\(format.title) quality \(Int(qualityPercent))" : format.title
    }

    /// The value of the "Estimated size" line.
    var sizeText: String {
        if renderError != nil { return "Unavailable" }
        if isRendering { return "Preparing image…" }
        return switch estimate {
        case .none, .estimating: "Estimating…"
        case .approximate(let bytes): "About \(SaveSizeText.file(bytes))"
        case .exact(let bytes): SaveSizeText.file(bytes)
        case .failed: "Unavailable"
        }
    }

    /// Whether the size shown is still being worked out.
    var isEstimating: Bool {
        guard renderError == nil else { return false }
        if isRendering || !isEstimateCurrent { return true }
        switch estimate {
        case .exact, .failed: return false
        default: return true
        }
    }

    // MARK: - Estimating

    func refreshEstimate() {
        isEstimateCurrent = false
        generation += 1
        let generation = self.generation
        estimateTask?.cancel()
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            await self.estimate(generation: generation)
        }
    }

    private func estimate(generation: Int) async {
        let options = self.options
        let image: CGImage
        do {
            if source.cachedImage(for: options) == nil { isRendering = true }
            image = try await source.image(for: options)
        } catch {
            guard generation == self.generation else { return }
            isRendering = false
            renderError = SaveAlert.message(for: error)
            estimate = .failed
            isEstimateCurrent = true
            return
        }
        guard generation == self.generation else { return }
        isRendering = false
        renderError = nil

        // The approximation's clock starts now, so it also covers the wait
        // for a superseded encode below: dragging the quality slider over a
        // 100 MP TIFF shows a rough figure within 400 ms, not after the
        // previous full encode.
        let slow = Task { [weak self] in
            try? await Task.sleep(for: Self.slowEncode)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.estimate = .estimating
            let approximate = await Task.detached(priority: .userInitiated) {
                try? SizeEstimator.approximateBytes(image, options: options)
            }.value
            guard !Task.isCancelled, generation == self.generation, let approximate else { return }
            self.estimate = .approximate(approximate)
        }
        defer { slow.cancel() }

        // Wait for an encode that is still running for older options rather
        // than stack a second 100 MB encode on top of it. ImageIO can't stop
        // one part way, so a superseded encode finishes and is ignored.
        if let running = runningEncode { await running.value }
        guard generation == self.generation, !Task.isCancelled else { return }

        let url = entry.url
        let exact = Task.detached(priority: .userInitiated) {
            try? SizeEstimator.exactBytes(image, options: options, metadataSource: url)
        }
        runningEncode = Task { _ = await exact.value }
        let bytes = await exact.value
        guard generation == self.generation else { return }
        estimate = bytes.map(SizeEstimate.exact) ?? .failed
        isEstimateCurrent = true
    }
}
