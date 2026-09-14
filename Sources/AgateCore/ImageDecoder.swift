import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import AppKit

public enum DecodeError: Error, CustomStringConvertible {
    case unreadable(URL)
    case noImage(URL)
    case tooLarge(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): "\(url.lastPathComponent) could not be opened."
        case .noImage(let url): "\(url.lastPathComponent) contains no image Agate can decode."
        case .tooLarge(let url): "\(url.lastPathComponent) is too large to decode."
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
            guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let points = rotated ? CGSize(width: box.height, height: box.width) : box.size
            // Report pixels at 144 dpi (2x of 72 pt): a sensible "actual size".
            return ImageInfo(kind: .pdf, pixelSize: CGSize(width: points.width * 2, height: points.height * 2),
                             orientation: .up, pageCount: doc.numberOfPages, isAnimated: false, hasAlpha: false,
                             bitDepth: 8, colorModel: "RGB", profileName: nil, isHDR: false, uti: "com.adobe.pdf")
        case .svg:
            guard let image = NSImage(contentsOf: url) else { return nil }
            return ImageInfo(kind: .svg, pixelSize: image.size, orientation: .up, pageCount: 1, isAnimated: false,
                             hasAlpha: true, bitDepth: 8, colorModel: "RGB", profileName: nil, isHDR: false,
                             uti: "public.svg-image")
        case .raster, .raw:
            guard let source = makeSource(url) else { return nil }
            return info(source: source, kind: kind)
        }
    }

    static func info(source: CGImageSource, kind: ImageKind) -> ImageInfo? {
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex(source), nil) as? [CFString: Any]
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

    /// A small oriented image for the browser grid, decoded at `maxPixelSize`
    /// on the long edge. Uses embedded previews when they are big enough, so
    /// RAW files cost milliseconds.
    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let kind = ImageFormats.kind(of: url) else { return nil }
        switch kind {
        case .pdf: return renderPDF(url: url, page: 1, maxPixelSize: maxPixelSize)
        case .svg: return renderSVG(url: url, maxPixelSize: maxPixelSize)
        case .raster, .raw:
            guard let source = makeSource(url) else { return nil }
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
            return CGImageSourceCreateThumbnailAtIndex(source, primaryIndex(source), options as CFDictionary)
        }
    }

    /// HEIC and HEIF thumbnails: decode at a quarter of full size, then
    /// shrink on the CPU.
    ///
    /// The HEVC decoder has a cheap reduced-resolution path at 1/2 and 1/4
    /// scale, but asking ImageIO for a small thumbnail directly decodes at
    /// full size and resamples 24 MP down. Measured on HSB_6548.heic
    /// (6032x4032, M4, median of 10):
    ///
    ///     direct 256 px                 92 ms
    ///     direct 512 px                 75 ms
    ///     1508 px (1/4), then CG 256    68 ms  (min 45)
    ///     754 px (1/8), then CG 256     77 ms
    ///     40 thumbnails on 10 threads:  1490 ms direct, 714 ms via 1/4
    ///
    /// The concurrent number matters most: the browser decodes many at
    /// once. AVIF (an SVT-AV1 encode of the same photo) gains nothing, 37 ms
    /// either way, so it keeps the direct path. Returns nil for other
    /// formats, or when a quarter-size decode would be smaller than asked.
    static func heifThumbnail(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard let type = CGImageSourceGetType(source) as String?, type == "public.heic" || type == "public.heif",
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex(source), nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let quarter = (max(w, h) + 3) / 4
        guard quarter >= maxPixelSize else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: quarter,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        guard let large = CGImageSourceCreateThumbnailAtIndex(source, primaryIndex(source), options as CFDictionary)
        else { return nil }
        return downscale(large, maxPixelSize: maxPixelSize, hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
    }

    /// Draws `image` smaller with Core Graphics' high-quality filter, keeping
    /// its colour space when an 8-bit context can use it (sRGB, Display P3)
    /// and falling back to Display P3 otherwise (HDR PQ/HLG sources, which
    /// a thumbnail shows as SDR anyway).
    static func downscale(_ image: CGImage, maxPixelSize: Int, hasAlpha: Bool) -> CGImage? {
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
        if space.model != .rgb || CGColorSpaceUsesITUR_2100TF(space) { space = p3 }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: p3, bitmapInfo: bitmapInfo)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: - Display decode

    /// Decodes for display, oriented. `maxPixelSize` nil means full resolution.
    ///
    /// Screen-sized requests are snapped to a size the codec can produce
    /// without resampling (see `scaledDecodeSize`). RAW files use the
    /// camera's embedded preview when it is large enough.
    public static func decode(_ url: URL, maxPixelSize: Int? = nil, page: Int = 0,
                              allowHDR: Bool = true) throws -> DecodedImage {
        guard let kind = ImageFormats.kind(of: url) else { throw DecodeError.noImage(url) }
        switch kind {
        case .pdf:
            guard let info = info(for: url) else { throw DecodeError.unreadable(url) }
            let target = maxPixelSize ?? Int(max(info.pixelSize.width, info.pixelSize.height))
            guard let image = renderPDF(url: url, page: page + 1, maxPixelSize: target) else {
                throw DecodeError.noImage(url)
            }
            return DecodedImage(image: image, orientation: .up,
                                imageSize: CGSize(width: image.width, height: image.height),
                                isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        case .svg:
            let target = maxPixelSize ?? 4096
            guard let image = renderSVG(url: url, maxPixelSize: target) else { throw DecodeError.noImage(url) }
            return DecodedImage(image: image, orientation: .up,
                                imageSize: CGSize(width: image.width, height: image.height),
                                isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        case .raster, .raw:
            guard let source = makeSource(url) else { throw DecodeError.unreadable(url) }
            guard let info = info(source: source, kind: kind) else { throw DecodeError.noImage(url) }
            let index = kind == .raw ? primaryIndex(source) : min(max(page, 0), CGImageSourceGetCount(source) - 1)
            let longest = Int(max(info.pixelSize.width, info.pixelSize.height))
            let wantsFull = maxPixelSize == nil || maxPixelSize! >= longest
            let hdr = allowHDR && info.isHDR

            var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }

            options[kCGImageSourceCreateThumbnailWithTransform] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = wantsFull
                ? longest : scaledDecodeSize(longestEdge: longest, needed: maxPixelSize!)
            if kind == .raw && !wantsFull {
                // The camera's embedded preview if it's at least the
                // requested size, otherwise a real (slow) raw render.
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            } else {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw DecodeError.noImage(url)
            }
            let full = max(image.width, image.height) >= longest
            return makeDecoded(image: image, orientation: .up, info: info, full: full, hdr: hdr)
        }
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
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
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

    static func renderPDF(url: URL, page number: Int, maxPixelSize: Int) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: number) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(size.width, size.height)
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h),
                                                 rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        // getDrawingTransform never scales up; do it ourselves when needed.
        if scale > 1 {
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.midX, y: -box.midY)
        }
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func renderSVG(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(image.size.width, image.size.height)
        var rect = CGRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high])
    }
}
