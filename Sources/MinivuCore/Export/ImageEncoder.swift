import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, Equatable, LocalizedError {
    /// ImageIO has no encoder for the type on this Mac.
    case cannotCreateDestination(ExportFormat)
    /// The encoder refused the image (ImageIO gives no reason).
    case encodingFailed(ExportFormat)
    /// Converting the pixels for the format failed, e.g. out of memory.
    case cannotConvertPixels

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let format): "This Mac can't write \(format.title) files."
        case .encodingFailed(let format): "The image couldn't be encoded as \(format.title)."
        case .cannotConvertPixels: "The image's pixels couldn't be converted for saving."
        }
    }
}

/// Encodes a finished image into any `ExportFormat` with ImageIO.
///
/// Three steps: make the pixels fit the format (colour space, bit depth,
/// alpha, icon size), gather the metadata to carry over, and hand both to a
/// `CGImageDestination`. Nothing here holds state, so all of it is safe to
/// call from any thread; a 24 MP image takes tens to hundreds of
/// milliseconds, so never call it on the main thread.
public enum ImageEncoder {
    /// Formats ImageIO (macOS 15) writes an ISO 21496-1 gain map into: an
    /// SDR base image any reader shows, and a gain map that lifts it back to
    /// HDR where the display can. Measured: JPEG and HEIC write one and
    /// decode back to HDR; PNG refuses, and the "ISO HDR" request for PNG
    /// and HEIC tone maps an extended-range image to SDR instead.
    public static func canWriteGainMap(_ format: ExportFormat) -> Bool {
        format == .jpeg || format == .heic
    }

    /// Encodes to memory (also used for size estimation and the quality preview).
    public static func encode(_ image: CGImage, options: ExportOptions, metadataSource: URL?) throws -> Data {
        try encode(image, options: options, metadataSource: metadataSource,
                   comments: carriedComments(options: options, metadataSource: metadataSource))
    }

    /// Encodes and writes atomically (temp file in the same folder, then
    /// replace), preserving the destination's creation date when overwriting.
    ///
    /// With `gainMap`, `image` is an HDR image (extended range, with its
    /// content headroom set) written as an SDR base and a gain map, for a
    /// format where `canWriteGainMap`; its pixels go to ImageIO as they are.
    public static func write(_ image: CGImage, to url: URL, options: ExportOptions, metadataSource: URL?,
                             gainMap: Bool = false) throws {
        if gainMap, !canWriteGainMap(options.format) { throw ExportError.cannotCreateDestination(options.format) }
        if let comments = carriedComments(options: options, metadataSource: metadataSource) {
            // The comment is spliced in after encoding, which is simplest in memory.
            let data = try encode(image, options: options, metadataSource: metadataSource, comments: comments,
                                  gainMap: gainMap)
            try SafeFileWriter.write(data, to: url)
            OwnWrites.record(url)
            return
        }
        // Otherwise ImageIO streams straight into the file: a 16-bit TIFF of
        // a 24 MP photo is 145 MB we'd rather not also hold as `Data`.
        try SafeFileWriter.replace(url) { temp in
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
                throw ExportError.cannotCreateDestination(options.format)
            }
            try encode(image, into: destination, options: options, metadataSource: metadataSource, gainMap: gainMap)
        }
        OwnWrites.record(url)
    }

    /// Decodes encoded data back to a CGImage (what the compare view shows
    /// for lossy formats). Decoded right here rather than lazily at first
    /// draw, so the cost lands on the caller's background thread, not on
    /// whichever thread draws it.
    public static func decodePreview(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Encoding

    static func encode(_ image: CGImage, options: ExportOptions, metadataSource: URL?, comments: [Data]?,
                       gainMap: Bool = false) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, options.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreateDestination(options.format)
        }
        try encode(image, into: destination, options: options, metadataSource: metadataSource, gainMap: gainMap)
        guard let comments else { return data as Data }
        return try JPEGComment.replacingComments(in: data as Data, withPayloads: comments)
    }

    static func encode(_ image: CGImage, into destination: CGImageDestination, options: ExportOptions, metadataSource: URL?,
                       gainMap: Bool = false) throws {
        let format = options.format
        // A gain map's base is ImageIO's own SDR rendition in Display P3;
        // converting the HDR pixels first would clip what the map keeps.
        let pixels = gainMap ? image : try prepare(image, options: options)
        let space = gainMap ? CGColorSpace(name: CGColorSpace.displayP3)!
                            : pixels.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        var properties: [CFString: Any] = [
            // An embedded thumbnail is a stale second copy of the picture
            // (and ImageIO would make one from the new pixels anyway).
            kCGImageDestinationEmbedThumbnail: false,
        ]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality, 0), 1)
        }
        if gainMap {
            properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        }

        var metadata: CGImageMetadata?
        if options.keepMetadata, format.supportsMetadata, let metadataSource,
           let carried = CarriedMetadata(source: metadataSource, width: pixels.width, height: pixels.height, colorSpace: space) {
            properties.merge(carried.properties) { _, new in new }
            metadata = carried.metadata
        }

        switch format {
        case .jpeg where options.progressive:
            properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        case .tiff:
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = options.tiffCompression.tagValue
            properties[kCGImagePropertyTIFFDictionary] = tiff
        default:
            break
        }

        if let metadata {
            CGImageDestinationAddImageAndMetadata(destination, pixels, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed(format) }
    }

    /// The source's JPEG comment segments, when both ends are JPEG and
    /// metadata is kept. Raw payloads, not text, so a comment in an old
    /// encoding and several separate comments are carried exactly.
    static func carriedComments(options: ExportOptions, metadataSource: URL?) -> [Data]? {
        guard options.format == .jpeg, options.keepMetadata, let metadataSource,
              ExportFormat.format(for: metadataSource) == .jpeg,
              let header = JPEGComment.headerData(at: metadataSource) else { return nil }
        let payloads = JPEGComment.commentPayloads(in: header)
        return payloads.isEmpty ? nil : payloads
    }

    // MARK: - Pixels

    /// Redraws the image into the colour space, bit depth and alpha the
    /// options ask for, or returns it untouched when it already fits:
    /// redrawing 24 MP costs a noticeable fraction of a second and would
    /// change nothing.
    static func prepare(_ image: CGImage, options: ExportOptions) throws -> CGImage {
        let format = options.format
        let space = targetColorSpace(for: image, options: options)
        let bits = options.sixteenBit && format.supports16Bit ? 16 : 8
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let flatten = hasAlpha && !format.supportsAlpha

        var width = image.width, height = image.height
        var canvas = (width: width, height: height)
        if format == .ico {
            // Windows icons are square and at most 256 px; ImageIO refuses
            // anything else. Fit inside the square and centre on transparency.
            let scale = min(1, 256 / Double(max(width, height)))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
            let side = max(width, height)
            canvas = (side, side)
        }

        let sameSpace = image.colorSpace.map { same($0, space) } ?? false
        if !flatten, sameSpace, canvas.width == image.width, canvas.height == image.height, image.bitsPerComponent == bits,
           !image.bitmapInfo.contains(.floatComponents) {
            return image
        }

        // Gray contexts can't have alpha; an RGB context in the gray
        // image's own profile isn't possible either, so gray with alpha
        // goes to sRGB.
        let gray = space.model == .monochrome
        // Transparent padding around a non-square icon needs alpha too.
        let keepAlpha = (hasAlpha && !flatten) || canvas.width != width || canvas.height != height
        let drawSpace = gray && keepAlpha ? CGColorSpace(name: CGColorSpace.sRGB)! : space
        let alphaInfo: CGImageAlphaInfo = keepAlpha ? .premultipliedLast : (drawSpace.model == .monochrome ? .none : .noneSkipLast)
        var info = alphaInfo.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: bits,
                                      bytesPerRow: 0, space: drawSpace, bitmapInfo: info) else {
            throw ExportError.cannotConvertPixels
        }
        let rect = CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
        if flatten {
            // Opaque whatever alpha the colour has: the file has no alpha
            // channel, and a see-through background would fade to black.
            context.setFillColor(options.backgroundForOpaqueFormats.cgColor.copy(alpha: 1) ?? options.backgroundForOpaqueFormats.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ExportError.cannotConvertPixels }
        return result
    }

    static func same(_ a: CGColorSpace, _ b: CGColorSpace) -> Bool {
        if a == b { return true }
        // Decoded files often carry a profile-built space equal to a named one.
        guard let x = a.copyICCData(), let y = b.copyICCData() else { return false }
        return CFEqual(x, y)
    }

    /// The colour space the file is written in.
    static func targetColorSpace(for image: CGImage, options: ExportOptions) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = options.format
        guard format.supportsColorProfile else { return srgb }
        let space: CGColorSpace
        switch options.colorProfile {
        case .original: space = standardColorSpace(for: image.colorSpace)
        case .sRGB: space = srgb
        case .displayP3: space = CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
        // ImageIO's JPEG 2000 writer can't embed version 4 ICC profiles such
        // as Display P3: it tags the file sRGB without converting, which
        // shifts every colour (measured). sRGB and Adobe RGB, both version 2,
        // work; everything else is converted to sRGB.
        if format == .jpeg2000, space.model != .monochrome,
           !same(space, srgb), !same(space, CGColorSpace(name: CGColorSpace.adobeRGB1998)!) {
            return srgb
        }
        return space
    }

    /// An SDR, gamma-encoded, standard-range space for "Keep original".
    /// Edits render in extended linear Display P3; a file in that space
    /// would clip highlights anyway and confuse most readers, so it is
    /// written as plain Display P3. The same goes for the other linear,
    /// extended and HDR spaces, mapped by family.
    static func standardColorSpace(for space: CGColorSpace?) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let space else { return srgb }
        switch space.model {
        case .rgb, .monochrome: break
        default: return srgb   // CMYK, Lab, indexed: convert to something every format takes
        }
        let name = (space.name as String?) ?? ""
        let special = CGColorSpaceUsesExtendedRange(space) || space.isHDR() || name.localizedCaseInsensitiveContains("linear")
        guard special else { return space }
        if space.model == .monochrome { return CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! }
        let wide = ["P3", "2020", "2100", "ACES", "ROMM"].contains { name.localizedCaseInsensitiveContains($0) }
        if wide { return CGColorSpace(name: CGColorSpace.displayP3)! }
        if name.isEmpty, CGColorSpaceUsesExtendedRange(space) {
            // An unnamed ICC space marked extended: keep its gamut.
            return CGColorSpaceCreateCopyWithStandardRange(space)
        }
        return srgb
    }
}

/// Metadata from the source file, cleaned up for a new image.
///
/// ImageIO offers metadata two ways: property dictionaries (EXIF, TIFF, GPS,
/// IPTC, the values cameras write) and `CGImageMetadata` (the XMP view,
/// which also holds XMP-only things such as ratings, keywords and
/// Lightroom's fields). Both are passed to the destination: the metadata
/// object is written as XMP and mirrored into EXIF/IPTC where tags have an
/// equivalent, and the dictionaries fill in what has no XMP form. Where
/// both have a tag the metadata object wins, so the few values that must
/// change are changed in both.
struct CarriedMetadata {
    var properties: [CFString: Any]
    var metadata: CGImageMetadata?

    /// TIFF tags that describe how the source's pixels were stored, not the
    /// photo. Copied into a new file they would lie about it; a camera
    /// raw's "PhotometricInterpretation: CFA" in a JPEG, say. Colour
    /// description tags go too: the embedded profile says what the colours are.
    /// (Computed, because CF strings aren't `Sendable` and can't sit in a static let.)
    static var structuralTIFF: [CFString] {
        [kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
         kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
         kCGImagePropertyTIFFTransferFunction, kCGImagePropertyTIFFWhitePoint,
         kCGImagePropertyTIFFPrimaryChromaticities, kCGImagePropertyTIFFOrientation]
    }
    static var structuralExif: [CFString] {
        [kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifCompressedBitsPerPixel,
         kCGImagePropertyExifCFAPattern, kCGImagePropertyExifSubjectArea]
    }
    /// The same, as XMP paths, plus things that go stale: Adobe's digests of
    /// the EXIF block, old XMP thumbnails, and ImageIO's own bookkeeping.
    static let structuralXMPPaths = [
        "tiff:Compression", "tiff:PhotometricInterpretation", "tiff:ImageWidth", "tiff:ImageLength",
        "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration", "tiff:YCbCrSubSampling",
        "tiff:YCbCrPositioning", "tiff:YCbCrCoefficients", "tiff:ReferenceBlackWhite", "tiff:TileWidth",
        "tiff:TileLength", "tiff:TransferFunction", "tiff:WhitePoint", "tiff:PrimaryChromaticities",
        "tiff:NativeDigest", "exif:NativeDigest", "exif:ComponentsConfiguration", "exif:CompressedBitsPerPixel",
        "exif:CFAPattern", "exif:SubjectArea", "xmp:Thumbnails", "photoshop:ICCProfile", "iio:hasXMP", "iio:hasIIM",
    ]
    /// Whole namespaces dropped by prefix. Camera Raw's develop settings
    /// ("crs") describe edits already baked into these pixels; left in, Adobe
    /// software would apply them a second time.
    /// Gain map descriptions ("hdrgm", Adobe's and ISO's; "HDRGainMap",
    /// Apple's) go too: they describe the source's map, which a new file
    /// either doesn't have or gets afresh from ImageIO.
    static let droppedPrefixes: Set<String> = ["crs", "hdrgm", "HDRGainMap"]

    init?(source: URL, width: Int, height: Int, colorSpace: CGColorSpace) {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(imageSource)
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] ?? [:]

        // Exif ColorSpace is 1 for sRGB and 0xFFFF ("uncalibrated") for
        // anything else, which tells readers to use the embedded profile.
        // A stale 1 on an Adobe RGB file would make them show it as sRGB.
        let exifColorSpace = ImageEncoder.same(colorSpace, CGColorSpace(name: CGColorSpace.sRGB)!) ? 1 : 0xFFFF

        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = sourceProperties[key] { properties[key] = value }
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = sourceProperties[key] as? [CFString: Any] { properties[key] = value }
        }
        var exif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in Self.structuralExif { exif[key] = nil }
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        exif[kCGImagePropertyExifColorSpace] = exifColorSpace
        properties[kCGImagePropertyExifDictionary] = exif
        var tiff = sourceProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in Self.structuralTIFF { tiff[key] = nil }
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
        self.properties = properties

        if let original = CGImageSourceCopyMetadataAtIndex(imageSource, index, nil),
           let mutable = CGImageMetadataCreateMutableCopy(original) {
            for path in Self.structuralXMPPaths {
                CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString)
            }
            let tags = CGImageMetadataCopyTags(mutable) as? [CGImageMetadataTag] ?? []
            for tag in tags {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, Self.droppedPrefixes.contains(prefix),
                      let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
                CGImageMetadataRemoveTagWithPath(mutable, nil, "\(prefix):\(name)" as CFString)
            }
            let updates: [(CFString, CFString, Int)] = [
                (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifColorSpace, exifColorSpace),
            ]
            for (dictionary, key, value) in updates {
                CGImageMetadataSetValueMatchingImageProperty(mutable, dictionary, key, value as CFNumber)
            }
            metadata = mutable
        }
    }
}
