import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import AppKit
import UniformTypeIdentifiers

public enum DecodeError: Error, CustomStringConvertible {
    case unreadable(URL)
    case noImage(URL)
    case tooLarge(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): localized("\(url.lastPathComponent) could not be opened.")
        case .noImage(let url): localized("\(url.lastPathComponent) contains no image minivu can decode.")
        case .tooLarge(let url): localized("\(url.lastPathComponent) is too large to decode.")
        }
    }
}

/// What a file is, read from its header without decoding pixels.
public struct ImageInfo: Sendable, Equatable {
    public var kind: ImageKind
    /// Oriented pixel size (width and height as displayed).
    public var pixelSize: CGSize
    public var orientation: CGImagePropertyOrientation
    /// Pages in a PDF or multi-page TIFF, frames in a GIF/APNG/WebP.
    public var pageCount: Int
    public var isAnimated: Bool
    public var hasAlpha: Bool
    public var bitDepth: Int
    public var colorModel: String?
    public var profileName: String?
    /// The file carries HDR content: a gain map, or a PQ/HLG transfer.
    public var isHDR: Bool
    public var uti: String?

    /// Pages the viewer steps through: a PDF's pages and a TIFF's. The
    /// frames of an animation, the sizes in an icon file and the pictures
    /// of a HEIC collection are all "images" to ImageIO, but none of them
    /// reads as a page.
    public var documentPageCount: Int {
        switch kind {
        case .pdf: max(pageCount, 1)
        case .raster where !isAnimated && uti == "public.tiff": max(pageCount, 1)
        default: 1
        }
    }
}

/// A decoded image, still on the CPU side, plus what the uploader needs.
public struct DecodedImage: @unchecked Sendable {
    public var image: CGImage
    /// How `image` must be rotated/flipped for display. `.up` when the
    /// decoder already applied it.
    public var orientation: CGImagePropertyOrientation
    /// Full oriented pixel size of the source, even if `image` is smaller.
    public var imageSize: CGSize
    public var isFullResolution: Bool
    public var isHDR: Bool
    public var contentHeadroom: Float
    /// 16-bit or wider-than-P3 sources keep float storage to avoid banding
    /// and gamut clipping.
    public var needsDeepStorage: Bool

    public init(image: CGImage, orientation: CGImagePropertyOrientation, imageSize: CGSize,
                isFullResolution: Bool, isHDR: Bool, contentHeadroom: Float, needsDeepStorage: Bool) {
        self.image = image
        self.orientation = orientation
        self.imageSize = imageSize
        self.isFullResolution = isFullResolution
        self.isHDR = isHDR
        self.contentHeadroom = contentHeadroom
        self.needsDeepStorage = needsDeepStorage
    }
}

/// Decodes files with Apple's frameworks (DESIGN.md 3 and 4.2).
///
/// All functions are thread-safe and synchronous; callers run them on
/// background tasks.
public enum ImageDecoder {
    // MARK: - Info

    public static func info(for url: URL) -> ImageInfo? {
        guard let kind = ImageFormats.kind(of: url) else { return nil }
        switch kind {
        case .pdf:
            // A page past the size limit is described as nothing, as an
            // unreadable file is: there is no size to show that is true.
            guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1),
                  let size = pdfPixelSize(page) else { return nil }
            return ImageInfo(kind: .pdf, pixelSize: size, orientation: .up,
                             pageCount: doc.numberOfPages, isAnimated: false, hasAlpha: false,
                             bitDepth: 8, colorModel: "RGB", profileName: nil, isHDR: false, uti: "com.adobe.pdf")
        case .svg:
            guard let image = NSImage(contentsOf: url), let size = svgPixelSize(image) else { return nil }
            return ImageInfo(kind: .svg, pixelSize: size, orientation: .up, pageCount: 1, isAnimated: false,
                             hasAlpha: true, bitDepth: 8, colorModel: "RGB", profileName: nil, isHDR: false,
                             uti: "public.svg-image")
        case .raster, .raw:
            guard let source = makeSource(url) else { return nil }
            return info(source: source, kind: kind)
        case .video:
            return VideoFrames.info(for: url).map { info(video: $0, url: url) }
        }
    }

    /// A video described as an image: its displayed size, one page, no
    /// alpha. Ten bits for HDR, which is what every HDR codec stores.
    static func info(video: VideoInfo, url: URL) -> ImageInfo {
        ImageInfo(kind: .video, pixelSize: video.pixelSize, orientation: .up, pageCount: 1, isAnimated: false,
                  hasAlpha: false, bitDepth: video.isHDR ? 10 : 8, colorModel: "RGB", profileName: nil,
                  isHDR: video.isHDR, uti: UTType(filenameExtension: url.pathExtension)?.identifier)
    }

    /// - Parameter index: the image to describe; nil for the primary one.
    ///   Pages of a multi-page TIFF can differ in size and orientation.
    static func info(source: CGImageSource, kind: ImageKind, index: Int? = nil) -> ImageInfo? {
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, index ?? primaryIndex(source), nil)
                as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let rawOrientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let size = orientation.swapsAxes ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let type = CGImageSourceGetType(source) as String?
        let animated = count > 1 && (fileProps?[kCGImagePropertyGIFDictionary] != nil
            || fileProps?[kCGImagePropertyPNGDictionary] != nil
            || fileProps?[kCGImagePropertyWebPDictionary] != nil
            || fileProps?[kCGImagePropertyHEICSDictionary] != nil
            || type == "com.compuserve.gif")
        return ImageInfo(kind: kind, pixelSize: size, orientation: orientation,
                         pageCount: kind == .raw ? 1 : count, isAnimated: animated,
                         hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false,
                         bitDepth: (props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8,
                         colorModel: props[kCGImagePropertyColorModel] as? String,
                         profileName: props[kCGImagePropertyProfileName] as? String,
                         isHDR: hasHDRContent(source: source, props: props), uti: type)
    }

    // MARK: - Thumbnails

    /// The most pixels a file's header may claim before the browser gives
    /// up on thumbnailing it: the 32768 px square that Resize and Batch
    /// Convert already cap their output at, so nothing above it is anything
    /// minivu could have written itself.
    ///
    /// The header, not the size on disk, says what a decode could cost. An
    /// image that is flat or gently graded compresses to a few hundred
    /// kilobytes however large it is, and a damaged or forged header claims
    /// pixels the file does not hold, so a file of no size at all can ask
    /// for gigabytes.
    ///
    /// Measured on macOS 15.7, ImageIO's thumbnail request streams the rows
    /// rather than holding the whole image: a 144 megapixel PNG costs 11 MB
    /// and half a second. So this is a backstop against a format or an
    /// ImageIO version that does hold it, not a limit real work should meet,
    /// and it is deliberately a fixed line rather than a share of memory: a
    /// share would refuse a scan on a small Mac to guard against a cost that
    ///, as measured, is not there. A file over it costs one property read
    /// and no decode, and the thumbnail service remembers the nil, so
    /// scrolling past it again is free. It still opens in the viewer, which
    /// decodes it once, at screen size, because the user asked for it.
    public static let thumbnailPixelBudget = 32768 * 32768

    /// A small oriented image for the browser grid, decoded at `maxPixelSize`
    /// on the long edge. Uses embedded previews when they are big enough, so
    /// RAW files cost milliseconds. Nil for a file over
    /// `thumbnailPixelBudget`, which is never decoded at all.
    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let kind = ImageFormats.kind(of: url) else { return nil }
        switch kind {
        case .pdf:
            // Refused past the size limit, as a raster over
            // `thumbnailPixelBudget` is: a size that large is no drawing.
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1), pdfPixelSize(page) != nil else { return nil }
            return renderPDF(page, maxPixelSize: maxPixelSize)
        case .svg:
            guard let image = NSImage(contentsOf: url), svgPixelSize(image) != nil else { return nil }
            return renderSVG(image, maxPixelSize: maxPixelSize)
        case .raster, .raw:
            guard let source = makeSource(url) else { return nil }
            let index = primaryIndex(source)
            // The header bounds what the decode could cost, so it is read
            // first and the outsized file refused unstarted. Nil, not
            // an error: the thumbnail service records a nil as a failure and
            // stops asking for the file.
            guard headerPixelCount(source: source, index: index) <= Double(thumbnailPixelBudget) else { return nil }
            if let image = heifThumbnail(source: source, maxPixelSize: maxPixelSize) { return image }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Embedded previews are used only if they are large enough;
                // "IfAbsent" would happily return a 160 px EXIF thumbnail.
                kCGImageSourceCreateThumbnailFromImageAlways: kind != .raw,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        case .video:
            return VideoFrames.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }

    /// The pixels image `index` claims in its header: what decoding it whole
    /// would have to hold, read without touching a pixel. A count rather
    /// than a size because that is what the memory costs, and a Double
    /// because a damaged or hostile header can claim more than an Int holds.
    /// Zero when the file names no size.
    static func headerPixelCount(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return 0 }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return w * h
    }

    /// HEIC and HEIF thumbnails, which ImageIO's direct route makes slow.
    ///
    /// 1. **Embedded thumbnail**, when the file carries one at least as big
    ///    as asked (iPhones store one of about 320 px). Decoding that is a
    ///    tiny HEVC frame. A plain "if absent" request can't be used blindly:
    ///    it returns the embedded image even when it is smaller than asked.
    /// 2. **Quarter-size decode, then shrink on the CPU.** The HEVC decoder
    ///    has a cheap reduced-resolution path, but asking ImageIO for a small
    ///    thumbnail directly decodes at full size and resamples 24 MP down.
    ///
    /// Measured on HSB_6548.heic (6032x4032, M4, median of 10), 256 px:
    ///
    ///     direct                        92 ms  (512 px: 75 ms)
    ///     1508 px (1/4), then CG        61 ms  (754 px (1/8), then CG: 77 ms)
    ///     embedded 368 px thumbnail      2.5 ms (a re-encode with one)
    ///     40 on 10 threads: direct 1490 ms, 1/4 route 714 ms, embedded 25 ms
    ///
    /// The concurrent numbers matter most: the browser decodes many at once.
    /// AVIF (an SVT-AV1 encode of the same photo) gains nothing from the
    /// quarter route, 37 ms either way, so it keeps the direct path. Returns
    /// nil for other formats, or when neither route can make the size asked.
    static func heifThumbnail(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard let type = CGImageSourceGetType(source) as String?, type == "public.heic" || type == "public.heif"
        else { return nil }
        let index = primaryIndex(source)
        if embeddedThumbnailLongEdge(source: source, index: index) >= maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                return image
            }
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let quarter = (max(w, h) + 3) / 4
        guard quarter >= maxPixelSize else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: quarter,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        guard let large = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        else { return nil }
        return downscale(large, maxPixelSize: maxPixelSize, hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
    }

    /// The long edge of the largest thumbnail stored in the file for image
    /// `index`, or 0. Read from the container's table of contents, which
    /// ImageIO has already parsed; no pixels are touched.
    static func embeddedThumbnailLongEdge(source: CGImageSource, index: Int) -> Int {
        guard let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let contents = props[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
              let images = contents[kCGImagePropertyImages] as? [[CFString: Any]],
              let image = images.first(where: { ($0[kCGImagePropertyImageIndex] as? Int) == index }),
              let thumbnails = image[kCGImagePropertyThumbnailImages] as? [[CFString: Any]]
        else { return 0 }
        return thumbnails.map {
            max(($0[kCGImagePropertyWidth] as? Int) ?? 0, ($0[kCGImagePropertyHeight] as? Int) ?? 0)
        }.max() ?? 0
    }

    /// Draws `image` no larger than `maxPixelSize` on its long edge with Core
    /// Graphics' high-quality filter (`image` itself when it already fits),
    /// keeping its colour space when an 8-bit context can use it (sRGB,
    /// Display P3) and falling back to Display P3 otherwise (HDR PQ/HLG and
    /// extended-range sources, which thumbnails and paper show as SDR).
    public static func downscale(_ image: CGImage, maxPixelSize: Int, hasAlpha: Bool = true) -> CGImage? {
        let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        // Opaque images get no alpha channel, so the thumbnail cache can
        // store them as JPEG rather than PNG.
        let alpha = hasAlpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst
        let bitmapInfo = alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        var space = image.colorSpace ?? p3
        if space.model != .rgb || CGColorSpaceUsesITUR_2100TF(space) || CGColorSpaceUsesExtendedRange(space) {
            space = p3
        }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: p3, bitmapInfo: bitmapInfo)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: - Export budget

    /// The most bytes a full-resolution decode for Save, Save As, Batch
    /// Convert or export may hold, on a Mac with `physicalMemory` bytes of
    /// RAM: a quarter of it.
    ///
    /// Those decodes keep every pixel on purpose (a saved file must not
    /// lose resolution, which is why the export path tiles), so unlike the
    /// viewer's they can't be made smaller to fit. ImageIO allocates the
    /// whole image the header declares before it reads a row, so a file of
    /// a few kilobytes claiming 60000 x 60000 would ask for 14 GB. Instead a
    /// header claiming more than this is refused before anything is
    /// decoded. A quarter, as Count Colors allows itself. The limit counts
    /// the decode alone: the export then renders a second image the size of
    /// the output, about as large again when the depth is kept and twice as
    /// large when an 8-bit original is saved at 16 bits, before Core Image's
    /// tiles and the encoder take their share. So an enormous real photo
    /// near the limit can still make a save swap; what the limit stops is a
    /// header asking for more than the Mac has. That is 2 GB on an 8 GB
    /// Mac: a 100 megapixel photo at 16 bits a channel (800 MB) saves with
    /// room to spare, and 8-bit images up to 536 megapixels do.
    public static func exportDecodeLimit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int(physicalMemory / 4)
    }

    /// The bytes a pixel of image `info` takes once ImageIO has decoded it:
    /// four channels at the file's own depth, which ImageIO keeps (8 bits,
    /// 16 bits, or 32-bit float), and at least 16 bits for an HDR image,
    /// which decodes to half floats or, tone mapped, to 16 bits. A grey
    /// image may decode smaller; counting it as colour errs on the side of
    /// refusing.
    static func decodedBytesPerPixel(_ info: ImageInfo) -> Int {
        let bytesPerChannel = info.bitDepth > 16 ? 4 : info.bitDepth > 8 || info.isHDR ? 2 : 1
        return 4 * bytesPerChannel
    }

    /// True when decoding image `info` whole would hold more than `byteLimit`
    /// bytes, or more pixels than `thumbnailPixelBudget`: the 32768 px square
    /// minivu caps its own output at, so nothing over it is anything the app
    /// could have written, and the browser won't thumbnail it either. In
    /// Doubles, because a forged header can claim more than an Int holds.
    ///
    /// Also true when a side is missing, zero, negative or not a number. A
    /// header that gives no size makes no promise about the decode: asked
    /// for a longest side of zero, ImageIO picks the size itself.
    public static func exceedsExportBudget(_ info: ImageInfo, byteLimit: Int) -> Bool {
        guard info.pixelSize.width > 0, info.pixelSize.height > 0 else { return true }
        let pixels = info.pixelSize.width * info.pixelSize.height
        return pixels > Double(thumbnailPixelBudget)
            || pixels * Double(decodedBytesPerPixel(info)) > Double(byteLimit)
    }

    // MARK: - Display decode

    /// Decodes for display, oriented. `maxPixelSize` and `fitting` both nil
    /// means full resolution; otherwise see `wantedLongEdge`.
    ///
    /// Screen-sized requests are snapped to a size the codec can produce
    /// without resampling (see `scaledDecodeSize`). RAW files use the
    /// camera's embedded preview when it is large enough.
    ///
    /// - Parameter byteLimit: for the decodes behind Save, Save As, Batch
    ///   Convert and export, `exportDecodeLimit()`. A full-resolution decode
    ///   whose header claims more than that, or no size at all (see
    ///   `exceedsExportBudget`), throws `DecodeError.tooLarge` without
    ///   decoding anything. A RAW file reaches this only when the RAW path
    ///   gave up, so `EditRenderer.loadSource` checks RAW headers itself. Nil checks nothing, as the viewer needs: it never
    ///   asks for more than a texture holds.
    public static func decode(_ url: URL, maxPixelSize: Int? = nil, fitting: CGSize? = nil, page: Int = 0,
                              allowHDR: Bool = true, byteLimit: Int? = nil) throws -> DecodedImage {
        let decoding = Perf.begin("decode")
        defer { decoding.end() }
        guard let kind = ImageFormats.kind(of: url) else { throw DecodeError.noImage(url) }
        switch kind {
        case .pdf:
            guard let doc = CGPDFDocument(url as CFURL) else { throw DecodeError.unreadable(url) }
            guard doc.numberOfPages > 0, let pdfPage = doc.page(at: min(max(page, 0), doc.numberOfPages - 1) + 1)
            else { throw DecodeError.noImage(url) }
            guard let size = pdfPixelSize(pdfPage) else { throw DecodeError.tooLarge(url) }
            let wanted = wantedLongEdge(imageSize: size, maxPixelSize: maxPixelSize, fitting: fitting)
            let render = vectorRenderEdge(for: size, maxPixelSize: wanted)
            guard let image = renderPDF(pdfPage, maxPixelSize: render.edge) else { throw DecodeError.noImage(url) }
            return DecodedImage(image: image, orientation: .up, imageSize: size,
                                isFullResolution: render.isFullResolution, isHDR: false, contentHeadroom: 1,
                                needsDeepStorage: false)
        case .svg:
            guard let svg = NSImage(contentsOf: url) else { throw DecodeError.unreadable(url) }
            guard let size = svgPixelSize(svg) else {
                // No size at all is no image; a size past the limit is a
                // file too large, as for a raster whose header claims more
                // than a decode could hold.
                throw svg.size.width > 0 && svg.size.height > 0 ? DecodeError.tooLarge(url) : DecodeError.noImage(url)
            }
            let wanted = wantedLongEdge(imageSize: size, maxPixelSize: maxPixelSize, fitting: fitting)
            let render = vectorRenderEdge(for: size, maxPixelSize: wanted)
            guard let image = renderSVG(svg, maxPixelSize: render.edge) else { throw DecodeError.noImage(url) }
            return DecodedImage(image: image, orientation: .up, imageSize: size,
                                isFullResolution: render.isFullResolution, isHDR: false, contentHeadroom: 1,
                                needsDeepStorage: false)
        case .raster, .raw:
            guard let source = makeSource(url) else { throw DecodeError.unreadable(url) }
            let count = CGImageSourceGetCount(source)
            // Page 0 is the file's primary image (the largest size in an
            // icon, a HEIC collection's chosen picture); later pages of a
            // multi-page TIFF by index, each with its own size.
            let index = kind == .raw || page <= 0 || count <= 1 ? primaryIndex(source) : min(page, count - 1)
            guard let info = Perf.measure("decode.info", { info(source: source, kind: kind, index: index) })
            else { throw DecodeError.noImage(url) }
            let longest = Int(saturating: max(info.pixelSize.width, info.pixelSize.height))
            let wanted = wantedLongEdge(imageSize: info.pixelSize, maxPixelSize: maxPixelSize, fitting: fitting)
            let wantsFull = wanted == nil || wanted! >= longest
            let hdr = allowHDR && info.isHDR
            // The header is all there is to go on before ImageIO allocates
            // the whole image, so an export that could not hold it is
            // refused here rather than discovered by running out of memory.
            if wantsFull, let byteLimit, exceedsExportBudget(info, byteLimit: byteLimit) {
                throw DecodeError.tooLarge(url)
            }

            var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if info.isHDR {
                // Without a request ImageIO returns what the file stores: the
                // SDR base of a gain-map photo, but a PQ or HLG file stays
                // 10-bit HDR. Asking for SDR makes it tone map those too.
                options[kCGImageSourceDecodeRequest] = hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR
            }

            options[kCGImageSourceCreateThumbnailWithTransform] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = wantsFull
                ? longest : scaledDecodeSize(longestEdge: longest, needed: wanted!)
            if kind == .raw && !wantsFull {
                // The camera's embedded preview if it's at least the
                // requested size, otherwise a real (slow) raw render.
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            } else {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
            guard let image = Perf.measure("decode.pixels", {
                CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            }) else {
                // ImageIO never says why it gave up. One failure can be
                // named: a file whose header claims more pixels than the
                // browser will even thumbnail, asked for whole, is too large
                // rather than unreadable. A file ImageIO can decode never
                // reaches this line, so nothing is refused by saying so.
                let pixels = info.pixelSize.width * info.pixelSize.height
                throw wantsFull && pixels > Double(thumbnailPixelBudget)
                    ? DecodeError.tooLarge(url) : DecodeError.noImage(url)
            }
            let full = max(image.width, image.height) >= longest
            return makeDecoded(image: image, orientation: .up, info: info, full: full, hdr: hdr)
        case .video:
            // The viewer's still: the very first frame, as the player will
            // start from it. A video is never exported, so `byteLimit` has
            // nothing to guard.
            guard let video = VideoFrames.info(for: url) else { throw DecodeError.unreadable(url) }
            let info = info(video: video, url: url)
            let longest = Int(saturating: max(info.pixelSize.width, info.pixelSize.height))
            let wanted = wantedLongEdge(imageSize: info.pixelSize, maxPixelSize: maxPixelSize, fitting: fitting)
            let hdr = allowHDR && info.isHDR
            guard let image = VideoFrames.frame(of: url, at: 0, maxPixelSize: wanted.map { min($0, longest) },
                                                allowHDR: hdr) else { throw DecodeError.noImage(url) }
            let full = max(image.width, image.height) >= longest
            return makeDecoded(image: image, orientation: .up, info: info, full: full, hdr: hdr)
        }
    }

    /// The largest preview the camera embedded in a RAW file, oriented and
    /// no larger than `wantedLongEdge` (nil: as large as it is), or nil when
    /// the file has none.
    ///
    /// Unlike `decode`, this never falls back to rendering the sensor data,
    /// which ImageIO does on the CPU when the preview is smaller than asked.
    /// Callers compare the result's size with the image's to decide whether
    /// a real RAW render is needed.
    public static func decodeRawPreview(_ url: URL, maxPixelSize: Int? = nil,
                                        fitting: CGSize? = nil) throws -> DecodedImage? {
        let decoding = Perf.begin("decode.rawPreview")
        defer { decoding.end() }
        guard let source = makeSource(url) else { throw DecodeError.unreadable(url) }
        guard var info = info(source: source, kind: .raw) else { throw DecodeError.noImage(url) }
        let longest = Int(saturating: max(info.pixelSize.width, info.pixelSize.height))
        let wanted = longest > 0
            ? wantedLongEdge(imageSize: info.pixelSize, maxPixelSize: maxPixelSize, fitting: fitting) : nil
        let options = rawPreviewOptions(imageLongEdge: longest, wantedLongEdge: wanted)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, primaryIndex(source), options as CFDictionary)
        else { return nil }
        if longest == 0 { info.pixelSize = CGSize(width: image.width, height: image.height) }
        let full = longest == 0 || isFullSizePreview(longEdge: max(image.width, image.height), imageLongEdge: longest)
        return makeDecoded(image: image, orientation: .up, info: info, full: full, hdr: false)
    }

    /// The long edge a RAW preview is held to when the header gives no size:
    /// the largest texture minivu can show (`TextureUploader.maximumDimension`).
    static let rawPreviewMaximumEdge = 16384

    /// `decodeRawPreview`'s options for an image whose header gives
    /// `imageLongEdge` (0 when it gives none). Neither "from image" option:
    /// only an image already in the file may be returned, scaled down if it
    /// is larger than asked.
    ///
    /// A camera newer than the RAW engine has no size ImageIO can read, only
    /// its preview. Then the preview is the image, decoded whole so every
    /// texture of the file agrees on its size, but held to
    /// `rawPreviewMaximumEdge`: with nothing else to go by, the preview's own
    /// header would set the size, and a forged one could ask for gigabytes.
    /// A real camera's preview is far smaller, so this changes nothing for it.
    static func rawPreviewOptions(imageLongEdge: Int, wantedLongEdge: Int?) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        options[kCGImageSourceThumbnailMaxPixelSize] = imageLongEdge > 0
            ? min(wantedLongEdge ?? imageLongEdge, imageLongEdge)
            : rawPreviewMaximumEdge
        return options
    }

    /// True when an embedded RAW preview is as good as the sensor image: at
    /// least 97% of its long edge. Cameras often leave out a few edge pixels
    /// the demosaic can't use, and a difference that small is invisible at
    /// any zoom, so rendering the RAW for it would be wasted time.
    public static func isFullSizePreview(longEdge: Int, imageLongEdge: Int) -> Bool {
        Double(longEdge) >= Double(imageLongEdge) * 0.97
    }

    /// The long edge `imageSize` has when fitted whole into `viewSize`,
    /// enlarged or shrunk with its aspect kept, rounded up: what the canvas
    /// shows at fit zoom. A square view gives its side whatever the aspect,
    /// so a plain long-edge request is the square of that edge. An unknown
    /// (empty) image size gives the view's long edge, the most any image
    /// fitted into it can need.
    ///
    /// Computed along the limiting axis, so a fit that lands on a whole
    /// pixel isn't pushed one past it by floating-point error.
    public static func fittedLongEdge(imageSize: CGSize, in viewSize: CGSize) -> Int {
        let viewLongest = max(viewSize.width, viewSize.height, 0)
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return Int(viewLongest.rounded(.up))
        }
        let fitted = viewSize.width * imageSize.height <= viewSize.height * imageSize.width
            ? CGSize(width: viewSize.width, height: imageSize.height * viewSize.width / imageSize.width)
            : CGSize(width: imageSize.width * viewSize.height / imageSize.height, height: viewSize.height)
        return Int(max(fitted.width, fitted.height).rounded(.up))
    }

    /// The long edge a display decode wants from an image of `imageSize`:
    /// at most `maxPixelSize`, and with `fitting` no more than the image
    /// fitted into that view size. nil when neither is given: full resolution.
    public static func wantedLongEdge(imageSize: CGSize, maxPixelSize: Int?, fitting: CGSize?) -> Int? {
        guard let fitting else { return maxPixelSize }
        let fitted = fittedLongEdge(imageSize: imageSize, in: fitting)
        return min(maxPixelSize ?? fitted, fitted)
    }

    /// The oriented pixel size from the file's header alone, no pixels
    /// decoded; nil for PDF, SVG and files without one.
    public static func headerPixelSize(of url: URL) -> CGSize? {
        guard let kind = ImageFormats.kind(of: url), kind == .raster || kind == .raw,
              let source = makeSource(url), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex(source), nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return nil }
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let swapsAxes = CGImagePropertyOrientation(rawValue: raw)?.swapsAxes ?? false
        return swapsAxes ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The decode size to ask ImageIO for, given what the screen needs.
    ///
    /// JPEG decoders scale by 1/2, 1/4 and 1/8 almost for free (they skip
    /// the fine DCT coefficients), but any other size means a full decode
    /// plus a resample. Measured on a 6032 px JPEG (M4): 3016 px in 33 ms,
    /// 3024 px in 103 ms, full size in 60 ms. So pick the smallest exact
    /// fraction that covers the need, tolerating a few percent undersize,
    /// which the GPU's mipmapped sampling hides.
    public static func scaledDecodeSize(longestEdge: Int, needed: Int) -> Int {
        guard longestEdge > 0 else { return needed }
        for shift in stride(from: 3, through: 1, by: -1) {
            let size = (longestEdge + (1 << shift) - 1) >> shift
            if Double(size) >= Double(needed) * 0.97 { return size }
        }
        return longestEdge
    }

    static func makeDecoded(image: CGImage, orientation: CGImagePropertyOrientation, info: ImageInfo,
                            full: Bool, hdr: Bool) -> DecodedImage {
        let headroom: Float = hdr ? max(image.contentHeadroom, 1) : 1
        let isHDR = hdr && headroom > 1
        let deep = image.bitsPerComponent > 8 || isWiderThanP3(image.colorSpace)
        return DecodedImage(image: image, orientation: orientation, imageSize: info.pixelSize,
                            isFullResolution: full, isHDR: isHDR, contentHeadroom: headroom,
                            needsDeepStorage: deep)
    }

    // MARK: - Helpers

    static func makeSource(_ url: URL) -> CGImageSource? {
        Perf.count("file.open")
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// The index to show for multi-image containers (HEIC collections, ICO
    /// files with several sizes): the primary image if the file names one,
    /// else for icons the largest, else the first.
    static func primaryIndex(_ source: CGImageSource) -> Int {
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let type = CGImageSourceGetType(source) as String?
        guard type == "com.microsoft.ico" || type == "com.microsoft.cur" || type == "com.apple.icns" else {
            return primary
        }
        var best = 0, bestArea = 0.0
        for i in 0..<CGImageSourceGetCount(source) {
            guard let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else { continue }
            let area = ((p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
                * ((p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
            if area > bestArea { bestArea = area; best = i }
        }
        return best
    }

    static func hasHDRContent(source: CGImageSource, props: [CFString: Any]) -> Bool {
        let checking = Perf.begin("decode.hdrCheck")
        defer { checking.end() }
        // Gain map (Apple, ISO 21496-1 or Ultra HDR) present?
        let index = primaryIndex(source)
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil { return true }
        }
        // PQ or HLG encoded (HDR HEIC/AVIF from phones and cameras)?
        if let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary),
           let space = image.colorSpace, CGColorSpaceUsesITUR_2100TF(space) {
            return true
        }
        return false
    }

    static func isWiderThanP3(_ space: CGColorSpace?) -> Bool {
        guard let space, space.model == .rgb, space.isWideGamutRGB else { return false }
        let p3Names: Set<CFString> = [CGColorSpace.displayP3, CGColorSpace.dcip3, CGColorSpace.linearDisplayP3,
                                      CGColorSpace.extendedDisplayP3, CGColorSpace.extendedLinearDisplayP3]
        if let name = space.name, p3Names.contains(name) { return false }
        return true
    }

    // MARK: - Vectors (PDF and SVG)

    /// A vector's "actual size" is the size it would have on a Retina
    /// screen: two pixels per point. That is the image's coordinate space
    /// on the canvas, however large or small the texture drawn from it.
    static let vectorPixelsPerPoint: CGFloat = 2
    /// Full resolution renders small vectors at least this large, so
    /// zooming in stays crisp...
    static let vectorMinimumFullEdge = 4096
    /// ...but no larger than the canvas's deepest zoom (32x) could use...
    static let vectorMaximumMagnification = 32
    /// ...and never past Metal's texture limit.
    static let vectorMaximumEdge = 16384
    /// The largest actual-size edge a vector may declare, in pixels (half
    /// that in points, about 176 metres at 72 points to the inch). A file
    /// that claims more is refused as too large rather than sized from it.
    ///
    /// An SVG's width and a PDF's crop box are whatever the file says, and
    /// AppKit and Core Graphics pass absurd values straight through: an SVG
    /// with width="1e18" reports 1e18 points. Nothing past this line is a
    /// real drawing: the largest page the PDF format allows without
    /// UserUnit is 200 inches (28,800 px here), and the app never renders a
    /// vector above `vectorMaximumEdge` anyway. Yet it is small enough that
    /// every sum the app does with a size (32 times it, its area) stays far
    /// inside an Int.
    static let vectorMaximumDeclaredEdge: CGFloat = 1_000_000

    /// The long edge to render a vector at, and whether that render counts as
    /// full resolution.
    ///
    /// A vector has no pixels of its own, so "full resolution" means the
    /// render the canvas treats as final: the actual size, raised to 4096 px
    /// so that zooming a small drawing stays sharp (but at most 32 times the
    /// actual size, the canvas's zoom limit) and capped at 16384 px. A
    /// screen-sized render smaller than that is not full resolution, so the
    /// canvas asks for the sharper one when the user zooms in. (Counting any
    /// render at least the actual size as full would stop that: a window
    /// larger than a small SVG would never get past its first texture.)
    ///
    /// - Parameters:
    ///   - longEdge: the vector's actual-size long edge in pixels.
    ///   - maxPixelSize: the long edge wanted, nil for full resolution.
    static func vectorRenderEdge(longEdge: Int, maxPixelSize: Int?) -> (edge: Int, isFullResolution: Bool) {
        // Capped before it is multiplied, so a size no caller should pass
        // still can't overflow: past the cap the answer is the cap anyway.
        let actual = min(max(longEdge, 1), vectorMaximumEdge)
        let full = min(max(actual, vectorMinimumFullEdge), actual * vectorMaximumMagnification, vectorMaximumEdge)
        guard let wanted = maxPixelSize else { return (full, true) }
        let edge = min(max(wanted, 1), full)
        return (edge, edge >= full)
    }

    static func vectorRenderEdge(for size: CGSize, maxPixelSize: Int?) -> (edge: Int, isFullResolution: Bool) {
        vectorRenderEdge(longEdge: Int(saturating: max(size.width, size.height).rounded()), maxPixelSize: maxPixelSize)
    }

    /// A page's /Rotate as 0, 90, 180 or 270. The PDF specification allows
    /// any multiple of 90, negative ones included.
    static func pdfRotation(_ page: CGPDFPage) -> Int {
        let degrees = ((Int(page.rotationAngle) % 360) + 360) % 360
        return (degrees + 45) / 90 % 4 * 90
    }

    /// The crop box's size as displayed (width and height swap on a page
    /// turned by 90 or 270 degrees), in points.
    static func pdfDisplaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox).standardized
        return pdfRotation(page) % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// The page's actual size in pixels (144 dpi), or nil when the crop box
    /// is past `vectorMaximumDeclaredEdge`.
    static func pdfPixelSize(_ page: CGPDFPage) -> CGSize? {
        vectorPixelSize(points: pdfDisplaySize(page))
    }

    /// An SVG's actual size in pixels: its intrinsic size in points, twice.
    /// Nil when the SVG has no size, or claims one past
    /// `vectorMaximumDeclaredEdge`.
    static func svgPixelSize(_ image: NSImage) -> CGSize? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return vectorPixelSize(points: image.size)
    }

    /// A vector's declared size in points as pixels, or nil when it is not
    /// a finite size within `vectorMaximumDeclaredEdge`. This is where a
    /// file's word on its own size enters the app, so it is checked here
    /// once rather than wherever the size is used.
    static func vectorPixelSize(points: CGSize) -> CGSize? {
        let pixels = CGSize(width: (points.width * vectorPixelsPerPoint).rounded(),
                            height: (points.height * vectorPixelsPerPoint).rounded())
        guard pixels.width.isFinite, pixels.height.isFinite,
              max(pixels.width, pixels.height) <= vectorMaximumDeclaredEdge else { return nil }
        return pixels
    }

    /// Pixel dimensions with `maxPixelSize` on the long edge, at least 1x1.
    static func scaledPixelSize(_ size: CGSize, longEdge maxPixelSize: Int) -> (width: Int, height: Int) {
        let scale = CGFloat(maxPixelSize) / max(size.width, size.height)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// Maps the page's crop box, as the page is displayed (turned by its
    /// /Rotate), onto a `width` x `height` pixel rectangle. Built by hand
    /// rather than with `getDrawingTransform`, which never scales up and so
    /// can't render a page larger than 72 dpi.
    ///
    /// Core Graphics' y axis points up, so a clockwise turn on screen is a
    /// negative rotation here; each case also moves the turned page back to
    /// the origin.
    static func pdfTransform(cropBox: CGRect, rotation: Int, width: Int, height: Int) -> CGAffineTransform {
        let box = cropBox.standardized
        let (w, h) = (box.width, box.height)
        let turn = switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: CGAffineTransform.identity
        }
        let turned = rotation % 180 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        return CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(turn)
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / turned.width,
                                             y: CGFloat(height) / turned.height))
    }

    /// Renders a page with its long edge at `maxPixelSize`, on white (a PDF
    /// page is paper). Opaque, so the thumbnail cache stores it as JPEG.
    static func renderPDF(_ page: CGPDFPage, maxPixelSize: Int) -> CGImage? {
        let displayed = pdfDisplaySize(page)
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let (w, h) = scaledPixelSize(displayed, longEdge: maxPixelSize)
        // Display P3, so wide-gamut colours in the document aren't clipped
        // on the way to the P3 texture.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let box = page.getBoxRect(.cropBox)
        ctx.concatenate(pdfTransform(cropBox: box, rotation: pdfRotation(page), width: w, height: h))
        // Anything drawn outside the crop box isn't part of the page.
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Renders an SVG with its long edge at `maxPixelSize`. The background
    /// stays transparent, so the canvas's checkerboard shows through.
    ///
    /// Drawn through AppKit into a bitmap of exactly the size asked for:
    /// `NSImage.cgImage(forProposedRect:)` may hand back a cached bitmap
    /// of another size. AppKit drawing is safe off the main thread when the
    /// image and the context belong to this call alone.
    static func renderSVG(_ image: NSImage, maxPixelSize: Int) -> CGImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let (w, h) = scaledPixelSize(image.size, longEdge: maxPixelSize)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clear(rect)
        ctx.interpolationQuality = .high
        // Rasterise the vector afresh at this size rather than scale a cached bitmap.
        image.cacheMode = .never
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
