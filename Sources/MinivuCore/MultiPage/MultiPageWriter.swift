import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The kinds of file Create Multi-Page File writes. Each is written page by
/// page by `MultiPageWriter`.
///
/// Animated AVIF isn't here: ImageIO on macOS 27 has no AVIF sequence
/// encoder (`public.avis` isn't a destination type, and a `public.avif`
/// destination asked for more than one image can't be created; measured).
/// Animated HEIC is offered where ImageIO lists `public.heics`, with what
/// its encoder keeps (measured on macOS 27): every frame's delay but the
/// last, which reads back as the one before it, and no loop count (files
/// read back as playing once), so no loop choice is offered for it.
public enum MultiPageFormat: String, Codable, CaseIterable, Sendable {
    case tiff, pdf, gif, heics

    public var title: String {
        switch self {
        case .tiff: localized(.init("Multi-Page TIFF", comment: "File format: a TIFF file with several pages"))
        case .pdf: "PDF"
        case .gif: localized(.init("Animated GIF", comment: "File format"))
        case .heics: localized(.init("Animated HEIC", comment: "File format"))
        }
    }

    /// "heic" rather than "heics" for an animated HEIC: it is what the
    /// browser lists and what other apps open, and readers tell the two
    /// apart by their contents.
    public var fileExtension: String {
        switch self {
        case .tiff: "tif"
        case .pdf: "pdf"
        case .gif: "gif"
        case .heics: "heic"
        }
    }

    public var utType: UTType {
        switch self {
        case .tiff: .tiff
        case .pdf: .pdf
        case .gif: .gif
        case .heics: .heic
        }
    }

    /// Frames with a delay, all of one size.
    public var isAnimation: Bool { self == .gif || self == .heics }

    /// Whether the file keeps a loop count: GIF does; ImageIO's HEIC
    /// sequence encoder records none.
    public var keepsLoopCount: Bool { self == .gif }

    /// ImageIO's GIF and HEIC sequence encoders keep every frame they are
    /// given until the file is finished (measured on macOS 27: 16 frames of
    /// 1000 x 750 px peak at 133 MB as a GIF, and a 12 MP HEIC frame adds
    /// about 48 MB as it is added), so these are checked against the export
    /// budget as a whole before anything is decoded. TIFF and PDF are
    /// written a page at a time.
    public var holdsEveryFrame: Bool { isAnimation }

    /// Whether this Mac can write the format: animated HEIC needs ImageIO's
    /// sequence encoder, asked for at run time.
    public var isWritable: Bool {
        self != .heics || ExportFormat.writableTypeIdentifiers.contains("public.heics")
    }

    public static var writableCases: [MultiPageFormat] { allCases.filter(\.isWritable) }
}

/// The page size of a PDF made from pictures.
public enum PDFPageSize: String, Codable, CaseIterable, Sendable {
    /// Each page the size of its picture, at the resolution the file
    /// records (72 dpi when it records none, as Preview has it).
    case image
    case a4
    case letter

    public var title: String {
        switch self {
        case .image: localized(.init("Same as Each Image", comment: "PDF page size: each page the size of its image"))
        case .a4: "A4"
        case .letter: localized(.init("US Letter", comment: "Paper size"))
        }
    }

    /// Portrait paper in points.
    public var paper: CGSize? {
        switch self {
        case .image: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

/// Everything Create Multi-Page File asks about. Remembered between
/// launches; decoding fills anything missing from the defaults.
public struct MultiPageSettings: Codable, Hashable, Sendable {
    public var format: MultiPageFormat
    public var tiffCompression: TIFFCompression
    public var pdfPageSize: PDFPageSize
    /// Space around the picture on a paper page, in points.
    public var pdfMargin: Double
    /// PDF pages are JPEG compressed at this quality (0...1) unless
    /// `pdfLossless`, which keeps every pixel (Flate, several times larger).
    public var pdfQuality: Double
    public var pdfLossless: Bool
    /// Seconds each frame shows, for pictures that aren't animation frames
    /// themselves (an animation's frames keep their own delays).
    public var frameDelay: Double
    /// Times the animation plays; 0 is forever.
    public var loopCount: Int
    /// The long side of an animation's frames in pixels, or nil for the
    /// first picture's own size (never enlarged). Every frame is fitted
    /// into that size, centred.
    public var frameSize: Int?
    /// Animated HEIC's quality, 0...1.
    public var quality: Double
    /// What shows around a frame or page picture of another shape; nil is
    /// transparent (GIF and HEIC frames; a PDF page is paper, always white
    /// unless a colour is chosen).
    public var background: ExportColor?
    /// Every page of a multi-page file goes in, not only its first.
    public var includesEveryPage: Bool
    /// TIFF pages: the colour profile each page is converted to and tagged
    /// with (Batch Convert's choice); Keep original leaves each page's own.
    public var colorProfile: ExportColorProfile

    public init(format: MultiPageFormat = .tiff, tiffCompression: TIFFCompression = .lzw,
                pdfPageSize: PDFPageSize = .image, pdfMargin: Double = 36, pdfQuality: Double = 0.85,
                pdfLossless: Bool = false, frameDelay: Double = 0.5, loopCount: Int = 0, frameSize: Int? = 800,
                quality: Double = 0.8, background: ExportColor? = nil, includesEveryPage: Bool = true,
                colorProfile: ExportColorProfile = .original) {
        self.format = format
        self.tiffCompression = tiffCompression
        self.pdfPageSize = pdfPageSize
        self.pdfMargin = pdfMargin
        self.pdfQuality = pdfQuality
        self.pdfLossless = pdfLossless
        self.frameDelay = frameDelay
        self.loopCount = loopCount
        self.frameSize = frameSize
        self.quality = quality
        self.background = background
        self.includesEveryPage = includesEveryPage
        self.colorProfile = colorProfile
    }

    private enum CodingKeys: String, CodingKey {
        case format, tiffCompression, pdfPageSize, pdfMargin, pdfQuality, pdfLossless, frameDelay, loopCount
        case frameSize, quality, background, includesEveryPage, colorProfile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MultiPageSettings()
        format = (try? c.decodeIfPresent(MultiPageFormat.self, forKey: .format)) ?? d.format
        tiffCompression = (try? c.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression)) ?? d.tiffCompression
        pdfPageSize = (try? c.decodeIfPresent(PDFPageSize.self, forKey: .pdfPageSize)) ?? d.pdfPageSize
        pdfMargin = (try? c.decodeIfPresent(Double.self, forKey: .pdfMargin)) ?? d.pdfMargin
        pdfQuality = (try? c.decodeIfPresent(Double.self, forKey: .pdfQuality)) ?? d.pdfQuality
        pdfLossless = (try? c.decodeIfPresent(Bool.self, forKey: .pdfLossless)) ?? d.pdfLossless
        frameDelay = (try? c.decodeIfPresent(Double.self, forKey: .frameDelay)) ?? d.frameDelay
        loopCount = (try? c.decodeIfPresent(Int.self, forKey: .loopCount)) ?? d.loopCount
        // A stored nil (the first picture's size) is a choice, not a gap.
        frameSize = c.contains(.frameSize) ? (try? c.decodeIfPresent(Int.self, forKey: .frameSize)) ?? nil : d.frameSize
        quality = (try? c.decodeIfPresent(Double.self, forKey: .quality)) ?? d.quality
        background = c.contains(.background) ? (try? c.decodeIfPresent(ExportColor.self, forKey: .background)) ?? nil
                                             : d.background
        includesEveryPage = (try? c.decodeIfPresent(Bool.self, forKey: .includesEveryPage)) ?? d.includesEveryPage
        colorProfile = (try? c.decodeIfPresent(ExportColorProfile.self, forKey: .colorProfile)) ?? d.colorProfile
    }

    /// The shortest frame delay written, in seconds. Browsers show anything
    /// at or under 10 ms at 100 ms (`AnimationFrames.effectiveDelay`), so
    /// 20 ms is the fastest a GIF really plays.
    public static let shortestFrameDelay = 0.02
    /// The largest animation frame side offered.
    public static let largestFrameSize = 4096

    /// Why the settings can't be used, or nil.
    public var problem: String? {
        if format.isAnimation {
            if !(frameDelay.isFinite && frameDelay >= Self.shortestFrameDelay && frameDelay <= 60) {
                return localized(.init("The frame delay must be between \(Self.shortestFrameDelay.formatted()) and \(60.formatted()) seconds.",
                                       comment: "The shortest delay (0.02) and the longest (60), as numbers"))
            }
            if format.keepsLoopCount, loopCount < 0 || loopCount > 65535 {
                return localized(.init("The number of loops must be between \(0.formatted()) and \(65535.formatted()).",
                                       comment: "The fewest loops (0) and the most (65,535), as numbers"))
            }
            if let frameSize, !(16...Self.largestFrameSize).contains(frameSize) {
                return localized("The frame size must be between 16 and \(Self.largestFrameSize) px.")
            }
        }
        if format == .pdf, pdfPageSize != .image, !(pdfMargin.isFinite && pdfMargin >= 0 && pdfMargin <= 144) {
            return localized("The margin must be between 0 and 144 points.")
        }
        return nil
    }

    /// The size every animation frame is made at, for a first picture of
    /// `first` pixels: fitted into `frameSize` on its long side, never
    /// larger than the picture itself.
    public func frameCanvas(first: CGSize) -> (width: Int, height: Int) {
        let w = max(Double(first.width), 1), h = max(Double(first.height), 1)
        let long = max(w, h)
        let target = Double(frameSize.map { min($0, Self.largestFrameSize) } ?? Int(saturating: long.rounded()))
        let scale = min(target / long, 1)
        return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
    }
}

/// Writes a multi-page file a page at a time, into a file that doesn't
/// exist yet (the caller writes to a temporary file and puts it in place
/// when it is whole, through the app's write queue).
///
/// - **TIFF:** each page is encoded by ImageIO as its own TIFF and joined by
///   `TIFFPageWriter`; one page in memory at a time. Pages keep their own
///   size and colour profile.
/// - **PDF:** a Core Graphics PDF context writes each page to the file as it
///   ends. A JPEG-compressed page is encoded first and handed over as JPEG
///   data, which the PDF context embeds as it is (measured: eight 12 MP
///   pages written with a flat footprint, the file the size of the JPEGs).
/// - **GIF and animated HEIC:** every frame is drawn into a canvas of one
///   size (`MultiPageSettings.frameCanvas`), fitted and centred over the
///   background, and given to ImageIO, which keeps the frames until
///   `finish` (see `MultiPageFormat.holdsEveryFrame`).
///
/// Not thread-safe: one writer is used by one job, on one thread at a time.
public final class MultiPageWriter {
    public let url: URL
    public let settings: MultiPageSettings
    private var tiff: TIFFPageWriter?
    private var pdf: CGContext?
    private var destination: CGImageDestination?
    private var canvas: (width: Int, height: Int)?
    public private(set) var pageCount = 0
    private let expectedPages: Int

    /// - Parameter expectedPages: frames an animation will have (ImageIO
    ///   wants the count up front); ignored for TIFF and PDF.
    public init(url: URL, settings: MultiPageSettings, expectedPages: Int) throws {
        self.url = url
        self.settings = settings
        self.expectedPages = max(expectedPages, 1)
        switch settings.format {
        case .tiff:
            tiff = try TIFFPageWriter(url: url)
        case .pdf:
            // Created with the first page, whose size is the media box.
            break
        case .gif, .heics:
            let type = settings.format == .gif ? UTType.gif.identifier : "public.heics"
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, self.expectedPages,
                                                                    nil) else {
                throw ExportError.cannotCreateDestination(settings.format == .gif ? .gif : .heic)
            }
            CGImageDestinationSetProperties(destination, Self.animationProperties(settings) as CFDictionary)
            self.destination = destination
        }
    }

    /// Adds a page. `delay` is an animation frame's own delay (nil: the
    /// settings' frame delay); `dpi` the resolution the picture's file
    /// records, for a PDF page the size of its picture.
    public func add(_ image: CGImage, delay: TimeInterval? = nil, dpi: Double? = nil) throws {
        switch settings.format {
        case .tiff:
            var options = ExportOptions(format: .tiff, colorProfile: settings.colorProfile, keepMetadata: false)
            options.tiffCompression = settings.tiffCompression
            options.sixteenBit = image.bitsPerComponent > 8
            let page = try ImageEncoder.encode(image, options: options, metadataSource: nil)
            try tiff?.append(page)
        case .pdf:
            try addPDFPage(image, dpi: dpi)
        case .gif, .heics:
            try addFrame(image, delay: delay)
        }
        pageCount += 1
    }

    /// Finishes the file. Throws when nothing was added or the encoder
    /// refuses; the caller then deletes the file.
    public func finish() throws {
        guard pageCount > 0 else { throw ExportError.encodingFailed(.tiff) }
        switch settings.format {
        case .tiff:
            try tiff?.finish()
        case .pdf:
            pdf?.closePDF()
            pdf = nil
        case .gif, .heics:
            if settings.format == .heics { BlockingWork.expectOffCooperativePool("MultiPageWriter animated HEIC") }
            guard let destination, CGImageDestinationFinalize(destination) else {
                throw ExportError.encodingFailed(settings.format == .gif ? .gif : .heic)
            }
            self.destination = nil
        }
    }

    // MARK: - PDF

    private func addPDFPage(_ image: CGImage, dpi: Double?) throws {
        let pixels = CGSize(width: image.width, height: image.height)
        let page: CGSize
        if let paper = settings.pdfPageSize.paper {
            // The paper turned to the picture's shape.
            page = pixels.width > pixels.height ? CGSize(width: paper.height, height: paper.width) : paper
        } else {
            page = Self.pageSize(pixels: pixels, dpi: dpi)
        }
        var box = CGRect(origin: .zero, size: page)
        if pdf == nil {
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            pdf = context
        }
        guard let pdf else { return }
        let picture: CGImage
        if settings.pdfLossless {
            picture = image
        } else {
            var options = ExportOptions(format: .jpeg, quality: settings.pdfQuality, colorProfile: .original,
                                        keepMetadata: false)
            options.backgroundForOpaqueFormats = settings.background ?? .white
            let jpeg = try ImageEncoder.encode(image, options: options, metadataSource: nil)
            // Handed over as JPEG data, which the PDF embeds unchanged.
            guard let provider = CGDataProvider(data: jpeg as CFData),
                  let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                        intent: .defaultIntent) else { throw ExportError.encodingFailed(.jpeg) }
            picture = decoded
        }
        let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        pdf.beginPDFPage(pageInfo)
        if settings.pdfPageSize != .image || settings.background != nil {
            pdf.setFillColor((settings.background ?? .white).cgColor)
            pdf.fill(box)
        }
        let margin = settings.pdfPageSize == .image ? 0 : CGFloat(settings.pdfMargin)
        pdf.interpolationQuality = .high
        pdf.draw(picture, in: Self.fit(pixels, into: box.insetBy(dx: margin, dy: margin)))
        pdf.endPDFPage()
    }

    /// A page the size of a picture of `pixels` at `dpi` (72 when the file
    /// records none or less), in points, no larger than the 14,400 points a
    /// side a PDF page may have.
    static func pageSize(pixels: CGSize, dpi: Double?) -> CGSize {
        let resolution = max(dpi ?? 72, 72)
        var size = CGSize(width: pixels.width * 72 / resolution, height: pixels.height * 72 / resolution)
        let long = max(size.width, size.height)
        if long > 14_400 {
            size = CGSize(width: size.width * 14_400 / long, height: size.height * 14_400 / long)
        }
        return size
    }

    /// A picture of `size` scaled to fit `box`, centred (enlarged too, as a
    /// printed page fills its paper).
    static func fit(_ size: CGSize, into box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    // MARK: - Animation

    private func addFrame(_ image: CGImage, delay: TimeInterval?) throws {
        guard let destination else { return }
        let canvas = self.canvas ?? settings.frameCanvas(first: CGSize(width: image.width, height: image.height))
        self.canvas = canvas
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.cannotConvertPixels
        }
        let box = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        if let background = settings.background {
            context.setFillColor(background.cgColor)
            context.fill(box)
        }
        context.interpolationQuality = .high
        let picture = CGSize(width: image.width, height: image.height)
        context.draw(image, in: Self.fit(picture, into: box).integral)
        guard let frame = context.makeImage() else { throw ExportError.cannotConvertPixels }
        let seconds = max(delay ?? settings.frameDelay, MultiPageSettings.shortestFrameDelay)
        var properties: [CFString: Any] = [:]
        if settings.format == .gif {
            properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: seconds,
                                                         kCGImagePropertyGIFUnclampedDelayTime: seconds]
        } else {
            properties[kCGImagePropertyHEICSDictionary] = [kCGImagePropertyHEICSDelayTime: seconds,
                                                           kCGImagePropertyHEICSUnclampedDelayTime: seconds]
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(settings.quality, 0), 1)
        }
        CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
    }

    static func animationProperties(_ settings: MultiPageSettings) -> [CFString: Any] {
        let loops = min(max(settings.loopCount, 0), 65535)
        return settings.format == .gif
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]]
            : [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: loops]]
    }
}
