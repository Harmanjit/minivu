import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// G14: AVIF as a Save As, Batch Convert and Shortcuts format, where ImageIO
/// can write it. Quality, metadata and Remove location as for HEIC; 10 bits a
/// channel from a 16-bit image; HDR kept as an ISO gain map.
@Suite(.enabled(if: ExportFormat.avif.isWritable, "ImageIO on this Mac has no AVIF encoder"), .offCooperativePool)
struct ExportAVIFTests {
    typealias F = ExportFixtures

    func source(_ data: Data) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func depth(_ data: Data) throws -> Int? {
        let properties = CGImageSourceCopyPropertiesAtIndex(try source(data), 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue
    }

    /// The image decoded as ImageIO hands HDR over, drawn into extended
    /// linear Display P3 floats, and its brightest red.
    func brightestRed(_ image: CGImage) throws -> Float {
        let w = image.width, h = image.height
        var values = [Float](repeating: 0, count: w * h * 4)
        try values.withUnsafeMutableBytes { buffer in
            let ctx = try #require(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 32,
                                             bytesPerRow: w * 16,
                                             space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                 | CGBitmapInfo.floatComponents.rawValue
                                                 | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 0, to: values.count, by: 4).map { values[$0] }.max() ?? 0
    }

    /// A flat colour at `value` (above 1 is brighter than paper white) in
    /// half floats, extended linear Display P3, with its content headroom.
    func hdrImage(value: CGFloat, headroom: Float) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                             | CGBitmapInfo.floatComponents.rawValue
                                             | CGBitmapInfo.byteOrder16Little.rawValue))
        let color = try #require(CGColor(colorSpace: space, components: [value, value * 0.5, 0.2, 1]))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        return try #require(CGImageCreateCopyWithContentHeadroom(headroom, image))
    }

    @Test func roundTripsAndQualityTradesSize() throws {
        let image = TestImages.gradient(width: 256, height: 192)
        var options = ExportOptions.defaults(for: .avif)
        options.quality = 0.2
        let small = try ImageEncoder.encode(image, options: options, metadataSource: nil)
        options.quality = 1
        let large = try ImageEncoder.encode(image, options: options, metadataSource: nil)
        #expect(CGImageSourceGetType(try source(small)) as String? == "public.avif")
        #expect(small.count < large.count, "quality \(small.count) vs \(large.count) bytes")
        // Quality 1 asks ImageIO for a lossless AVIF, which it refuses;
        // minivu writes its best lossy file instead.
        #expect(ImageEncoder.maximumQuality(.avif) < 1 && ImageEncoder.maximumQuality(.heic) == 1)
        let decoded = try #require(ImageEncoder.decodePreview(large))
        #expect(decoded.width == 256 && decoded.height == 192)
        // Quality 1 keeps the gradient's ends: red on the left, blue on the right.
        let pixels = F.pixels(of: decoded)
        let left = F.pixel(pixels, width: 256, x: 2, y: 96), right = F.pixel(pixels, width: 256, x: 253, y: 96)
        #expect(left[0] > 200 && left[2] < 60 && right[2] > 200 && right[0] < 60, "\(left) \(right)")
    }

    /// The "16 bits" option writes 10 bits, all AVIF holds; off, 8.
    @Test func tenBitsFromASixteenBitImage() throws {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                             | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        var options = ExportOptions.defaults(for: .avif)
        options.sixteenBit = true
        #expect(try depth(ImageEncoder.encode(image, options: options, metadataSource: nil)) == 10)
        options.sixteenBit = false
        #expect(try depth(ImageEncoder.encode(image, options: options, metadataSource: nil)) == 8)
    }

    /// Keep metadata and Remove location as for HEIC: EXIF, XMP and the
    /// camera stay, the GPS position goes unless asked to stay.
    @Test func metadataAndRemoveLocation() throws {
        let t = try TemporaryFolder()
        let tagged = MetadataWriterTests.tagged(.jpeg, ext: "jpg", in: t.url, name: "source")
        let image = try #require(F.decode(tagged))
        var options = ExportOptions.defaults(for: .avif)
        #expect(options.keepMetadata && options.removeLocation)

        let removed = t.url.appendingPathComponent("removed.avif")
        try ImageEncoder.write(image, to: removed, options: options, metadataSource: tagged)
        MetadataWriterTests.expectNoLocation(removed, "AVIF removed")
        #expect(MetadataWriterTests.dictionary(removed, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String == "NIKON")
        #expect(MetadataFields.read(from: removed).title == MetadataWriterTests.oldTitle)

        options.removeLocation = false
        let kept = t.url.appendingPathComponent("kept.avif")
        try ImageEncoder.write(image, to: kept, options: options, metadataSource: tagged)
        let gps = MetadataWriterTests.dictionary(kept, kCGImagePropertyGPSDictionary)
        #expect((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? 0 > 48)

        options.keepMetadata = false
        let bare = t.url.appendingPathComponent("bare.avif")
        try ImageEncoder.write(image, to: bare, options: options, metadataSource: tagged)
        #expect(MetadataWriterTests.dictionary(bare, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] == nil)
    }

    /// The chosen profile is embedded and the colours converted into it.
    @Test func colorProfileIsEmbedded() throws {
        var options = ExportOptions.defaults(for: .avif)
        options.colorProfile = .adobeRGB
        options.quality = 1
        let data = try ImageEncoder.encode(F.solid(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)), options: options,
                                           metadataSource: nil)
        let decoded = try #require(ImageEncoder.decodePreview(data))
        #expect(decoded.colorSpace?.name == CGColorSpace.adobeRGB1998)
        let back = F.pixel(F.pixels(of: decoded), width: 32, x: 16, y: 12)
        #expect(abs(back[0] - 51) <= 6 && abs(back[1] - 179) <= 6 && abs(back[2] - 77) <= 6, "\(back)")
    }

    /// HDR is kept the way Save keeps a HEIC's: an SDR base any reader shows
    /// and an ISO gain map that brings the highlights back. Measured on
    /// macOS 27: the decode asked for HDR has the content headroom written
    /// and values well above paper white; the plain decode stays SDR.
    @Test func hdrIsKeptAsAGainMap() throws {
        let image = try hdrImage(value: 3, headroom: 4)
        let data = try ImageEncoder.encode(image, options: .defaults(for: .avif), metadataSource: nil, gainMap: true)
        let source = try source(data)
        #expect(CGImageSourceGetType(source) as String? == "public.avif")
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)
        let hdr = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
        #expect(hdr.contentHeadroom > 2, "headroom \(hdr.contentHeadroom)")
        #expect(try brightestRed(hdr) > 1.8, "HDR highlight")
        let sdr = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(try brightestRed(sdr) <= 1.01, "the base is SDR")
        // Without the gain map request an extended image is clipped to SDR.
        let plain = try ImageEncoder.encode(image, options: .defaults(for: .avif), metadataSource: nil)
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(try self.source(plain), 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil)
        #expect(ImageEncoder.canWriteGainMap(.avif))
    }

    /// A gain map asked of a format that can't hold one is refused, not
    /// written as something else.
    @Test func aGainMapIsRefusedWhereItCantGo() throws {
        let image = try hdrImage(value: 2, headroom: 2)
        #expect(throws: ExportError.cannotCreateDestination(.png)) {
            try ImageEncoder.encode(image, options: .defaults(for: .png), metadataSource: nil, gainMap: true)
        }
    }
}
