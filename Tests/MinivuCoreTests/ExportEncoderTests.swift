import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

@Suite struct ExportEncoderTests {
    typealias F = ExportFixtures

    func options(_ format: ExportFormat, _ change: (inout ExportOptions) -> Void = { _ in }) -> ExportOptions {
        var options = ExportOptions.defaults(for: format)
        change(&options)
        return options
    }

    func within(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // MARK: - Colour

    @Test func sRGBRedExportedAsDisplayP3KeepsItsColour() throws {
        let red = F.solid(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        for format in [ExportFormat.png, .tiff, .jpeg] {
            let data = try ImageEncoder.encode(red, options: options(format) { $0.colorProfile = .displayP3; $0.quality = 1 }, metadataSource: nil)
            #expect(F.properties(data)[kCGImagePropertyProfileName as String] as? String == "Display P3", "\(format)")
            let decoded = try #require(ImageEncoder.decodePreview(data))
            let tolerance = format == .jpeg ? 3 : 1
            // Seen through sRGB it is still pure red...
            #expect(within(F.pixel(F.pixels(of: decoded), width: decoded.width, x: 5, y: 5), [255, 0, 0, 255], tolerance), "\(format)")
            // ...because the stored numbers really were converted (P3 red is 234, 51, 35).
            #expect(within(F.pixel(F.pixels(of: decoded, in: F.displayP3), width: decoded.width, x: 5, y: 5), [234, 51, 35, 255], tolerance + 1), "\(format)")
        }
    }

    @Test func adobeRGBFilesCarryTheAdobeProfile() throws {
        let image = TestImages.gradient()
        for format in [ExportFormat.jpeg, .tiff, .png, .heic, .jpeg2000] {
            let data = try ImageEncoder.encode(image, options: options(format) { $0.colorProfile = .adobeRGB }, metadataSource: nil)
            #expect(F.properties(data)[kCGImagePropertyProfileName as String] as? String == "Adobe RGB (1998)", "\(format)")
        }
    }

    @Test func originalKeepsTheImageProfileButNotALinearWorkingSpace() throws {
        let p3Green = F.solid(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), space: F.displayP3)
        let kept = try ImageEncoder.encode(p3Green, options: options(.png), metadataSource: nil)
        #expect(F.properties(kept)[kCGImagePropertyProfileName as String] as? String == "Display P3")
        // Nothing to convert: the image goes to the encoder as it is.
        #expect(try ImageEncoder.prepare(p3Green, options: options(.png)) === p3Green)

        // An edit rendered in extended linear P3, half float, with a highlight above 1.0.
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let ctx = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 16, bytesPerRow: 0, space: linear,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.setFillColor(CGColor(colorSpace: linear, components: [0.2140, 0.2140, 0.2140, 1])!)   // linear 0.214 = sRGB 128
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
        ctx.setFillColor(CGColor(colorSpace: linear, components: [4, 4, 4, 1])!)
        ctx.fill(CGRect(x: 8, y: 0, width: 8, height: 16))
        let hdr = try #require(ctx.makeImage())
        let data = try ImageEncoder.encode(hdr, options: options(.jpeg) { $0.quality = 1 }, metadataSource: nil)
        let props = F.properties(data)
        #expect(props[kCGImagePropertyProfileName as String] as? String == "Display P3")
        #expect(props[kCGImagePropertyDepth as String] as? Int == 8)
        let decoded = try #require(ImageEncoder.decodePreview(data))
        let bytes = F.pixels(of: decoded)
        #expect(within(F.pixel(bytes, width: 16, x: 2, y: 8), [128, 128, 128, 255], 2))
        #expect(within(F.pixel(bytes, width: 16, x: 13, y: 8), [255, 255, 255, 255], 1))   // clipped, not wrapped
    }

    @Test func formatsWithoutProfilesAreConvertedToSRGB() throws {
        // P3 red is outside sRGB; its closest sRGB colour is pure red.
        let p3Red = F.solid(CGColor(colorSpace: F.displayP3, components: [1, 0, 0, 1])!, space: F.displayP3)
        let srgbRed = F.solid(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), space: F.displayP3)
        for format in [ExportFormat.bmp, .tga, .gif] {
            let data = try ImageEncoder.encode(srgbRed, options: options(format) { $0.colorProfile = .displayP3 }, metadataSource: nil)
            let decoded = try #require(ImageEncoder.decodePreview(data))
            // Untagged files are read as sRGB, so the stored numbers must already be sRGB.
            let stored = F.pixels(of: decoded, in: decoded.colorSpace ?? F.sRGB)
            #expect(within(F.pixel(stored, width: decoded.width, x: 3, y: 3), [255, 0, 0, 255], 2), "\(format)")
        }
        // JPEG 2000 can't embed Display P3 (ImageIO would tag the P3 numbers
        // as sRGB); it falls back to a real conversion into sRGB.
        let data = try ImageEncoder.encode(p3Red, options: options(.jpeg2000) { $0.colorProfile = .displayP3; $0.quality = 1 }, metadataSource: nil)
        #expect(F.properties(data)[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1")
        let decoded = try #require(ImageEncoder.decodePreview(data))
        #expect(within(F.pixel(F.pixels(of: decoded), width: decoded.width, x: 3, y: 3), [255, 0, 0, 255], 2))
    }

    // MARK: - Quality, depth, compression

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleJPEG)))
    func lossySizesShrinkWithQuality() throws {
        let source = try #require(CGImageSourceCreateWithURL(F.sampleJPEG as CFURL, nil))
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1500,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
        #expect(max(image.width, image.height) == 1500)
        for format in [ExportFormat.jpeg, .heic, .jpeg2000] {
            let sizes = try [0.2, 0.5, 0.9].map { quality in
                try ImageEncoder.encode(image, options: options(format) { $0.quality = quality }, metadataSource: nil).count
            }
            #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "\(format): \(sizes)")
            #expect(sizes[2] > sizes[0] * 2, "\(format): \(sizes)")
        }
    }

    @Test func sixteenBitAndTIFFCompression() throws {
        let image = TestImages.gradient(width: 256, height: 256)
        for format in [ExportFormat.png, .tiff] {
            let deep = try ImageEncoder.encode(image, options: options(format) { $0.sixteenBit = true }, metadataSource: nil)
            #expect(F.properties(deep)[kCGImagePropertyDepth as String] as? Int == 16, "\(format)")
            let shallow = try ImageEncoder.encode(image, options: options(format), metadataSource: nil)
            #expect(F.properties(shallow)[kCGImagePropertyDepth as String] as? Int == 8, "\(format)")
        }
        // With alpha, and in gray.
        let alpha = try ImageEncoder.encode(TestImages.gradient(alpha: true), options: options(.png) { $0.sixteenBit = true }, metadataSource: nil)
        #expect(F.properties(alpha)[kCGImagePropertyDepth as String] as? Int == 16)
        #expect(F.properties(alpha)[kCGImagePropertyHasAlpha as String] as? Bool == true)
        let grayContext = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        grayContext.setFillColor(gray: 0.5, alpha: 1)
        grayContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let gray = try ImageEncoder.encode(try #require(grayContext.makeImage()), options: options(.tiff) { $0.sixteenBit = true }, metadataSource: nil)
        #expect(F.properties(gray)[kCGImagePropertyDepth as String] as? Int == 16)
        #expect(F.properties(gray)[kCGImagePropertyColorModel as String] as? String == "Gray")

        // Ignored where the format has no 16-bit form.
        let jpeg = try ImageEncoder.encode(image, options: options(.jpeg) { $0.sixteenBit = true }, metadataSource: nil)
        #expect(F.properties(jpeg)[kCGImagePropertyDepth as String] as? Int == 8)

        var sizes: [TIFFCompression: Int] = [:]
        for compression in TIFFCompression.allCases {
            let data = try ImageEncoder.encode(image, options: options(.tiff) { $0.tiffCompression = compression }, metadataSource: nil)
            let tiff = F.properties(data)[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            #expect(tiff?[kCGImagePropertyTIFFCompression as String] as? Int == compression.tagValue)
            sizes[compression] = data.count
            // Lossless: identical pixels.
            #expect(F.pixels(of: try #require(ImageEncoder.decodePreview(data))) == F.pixels(of: image))
        }
        #expect(sizes[.lzw]! < sizes[.none]!)
    }

    @Test func progressiveJPEG() throws {
        let data = try ImageEncoder.encode(TestImages.gradient(), options: options(.jpeg) { $0.progressive = true }, metadataSource: nil)
        let jfif = F.properties(data)[kCGImagePropertyJFIFDictionary as String] as? [String: Any]
        #expect(jfif?[kCGImagePropertyJFIFIsProgressive as String] as? Bool == true)
        let baseline = try ImageEncoder.encode(TestImages.gradient(), options: options(.jpeg), metadataSource: nil)
        let baselineJFIF = F.properties(baseline)[kCGImagePropertyJFIFDictionary as String] as? [String: Any]
        #expect(baselineJFIF?[kCGImagePropertyJFIFIsProgressive as String] as? Bool != true)
    }

    // MARK: - Alpha and icons

    @Test func opaqueFormatsFlattenOverTheBackground() throws {
        let halfRed = F.solid(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), alpha: true)
        let overBlack = try ImageEncoder.encode(halfRed, options: options(.jpeg) { $0.quality = 1; $0.backgroundForOpaqueFormats = .black }, metadataSource: nil)
        let black = try #require(ImageEncoder.decodePreview(overBlack))
        #expect(within(F.pixel(F.pixels(of: black), width: black.width, x: 4, y: 4), [128, 0, 0, 255], 3))

        // A see-through background colour is used opaque, not faded towards black.
        let overClearBlue = try ImageEncoder.encode(halfRed, options: options(.jpeg) {
            $0.quality = 1; $0.backgroundForOpaqueFormats = ExportColor(red: 0, green: 0, blue: 1, alpha: 0.2)
        }, metadataSource: nil)
        let blue = try #require(ImageEncoder.decodePreview(overClearBlue))
        #expect(within(F.pixel(F.pixels(of: blue), width: blue.width, x: 4, y: 4), [128, 0, 127, 255], 3))

        let overWhite = try ImageEncoder.encode(halfRed, options: options(.bmp), metadataSource: nil)
        let white = try #require(ImageEncoder.decodePreview(overWhite))
        #expect(within(F.pixel(F.pixels(of: white), width: white.width, x: 4, y: 4), [255, 128, 128, 255], 2))

        let png = try ImageEncoder.encode(halfRed, options: options(.png), metadataSource: nil)
        #expect(F.properties(png)[kCGImagePropertyHasAlpha as String] as? Bool == true)
        let kept = try #require(ImageEncoder.decodePreview(png))
        #expect(within(F.pixel(F.pixels(of: kept), width: kept.width, x: 4, y: 4), [128, 0, 0, 128], 2))
    }

    @Test func iconsAreSquareAndAtMost256Pixels() throws {
        // Wide and opaque: scaled to 256 wide, centred on transparency.
        let wide = F.solid(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), width: 600, height: 300)
        let data = try ImageEncoder.encode(wide, options: options(.ico), metadataSource: nil)
        let icon = try #require(ImageEncoder.decodePreview(data))
        #expect(icon.width == 256 && icon.height == 256)
        let bytes = F.pixels(of: icon)
        #expect(F.pixel(bytes, width: 256, x: 128, y: 10)[3] == 0)            // padding above
        #expect(within(F.pixel(bytes, width: 256, x: 128, y: 128), [0, 0, 255, 255], 1))

        let small = try ImageEncoder.encode(F.solid(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5), width: 48, height: 48, alpha: true),
                                            options: options(.ico), metadataSource: nil)
        let smallIcon = try #require(ImageEncoder.decodePreview(small))
        #expect(smallIcon.width == 48 && smallIcon.height == 48)   // never enlarged
        #expect(F.properties(small)[kCGImagePropertyHasAlpha as String] as? Bool == true)
    }

    // MARK: - Metadata

    @Test func metadataIsCarriedOverAndCleanedUp() throws {
        let t = try TemporaryFolder()
        let source = try F.taggedJPEG(in: t.url, orientation: .right, comment: "Carried along")
        // The upright pixels of a rotated 64 x 48 source.
        let upright = TestImages.gradient(width: 48, height: 64)

        let data = try ImageEncoder.encode(upright, options: options(.jpeg), metadataSource: source)
        let props = F.properties(data)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 1)
        let exif = try #require(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == 48)
        #expect(exif[kCGImagePropertyExifPixelYDimension as String] as? Int == 64)
        #expect(exif[kCGImagePropertyExifFNumber as String] as? Double == 2.8)
        #expect(exif[kCGImagePropertyExifColorSpace as String] as? Int == 1)
        let tiff = try #require(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON CORPORATION")
        #expect(tiff[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
        let gps = try #require(props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - 48.858222) < 0.0001)
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords as String] as? [String] == ["paris", "tower"])
        #expect(F.metadataValue(data, "xmp:Rating") == "4")
        #expect(F.metadataValue(data, "tiff:Orientation") == "1")
        #expect(F.metadataValue(data, "crs:Exposure2012") == nil)
        #expect(JPEGComment.commentPayloads(in: data).map(JPEGComment.decode) == ["Carried along"])

        // Another profile: the source's "ColorSpace = sRGB" must not survive, or
        // readers would ignore the Adobe RGB profile. (ImageIO drops the
        // "uncalibrated" value we ask for and writes no tag, which means the same.)
        let adobe = try ImageEncoder.encode(upright, options: options(.jpeg) { $0.colorProfile = .adobeRGB }, metadataSource: source)
        let adobeProps = F.properties(adobe)
        #expect(adobeProps[kCGImagePropertyProfileName as String] as? String == "Adobe RGB (1998)")
        let adobeExif = adobeProps[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(adobeExif?[kCGImagePropertyExifColorSpace as String] as? Int != 1)
        #expect(adobeExif?[kCGImagePropertyExifFNumber as String] as? Double == 2.8)

        // Other metadata formats get the same.
        for format in [ExportFormat.png, .heic, .tiff] {
            let other = try ImageEncoder.encode(upright, options: options(format), metadataSource: source)
            let p = F.properties(other)
            #expect((p[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String == "NIKON CORPORATION", "\(format)")
            #expect(p[kCGImagePropertyOrientation as String] as? Int ?? 1 == 1, "\(format)")
        }

        // Without keepMetadata: the profile and nothing from the source.
        let bare = try ImageEncoder.encode(upright, options: options(.jpeg) { $0.keepMetadata = false }, metadataSource: source)
        let bareProps = F.properties(bare)
        #expect(bareProps[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1")
        #expect((bareProps[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] == nil)
        #expect(bareProps[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(F.metadataValue(bare, "xmp:Rating") == nil)
        #expect(JPEGComment.commentPayloads(in: bare).isEmpty)
    }

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleNEF)))
    func nikonRawToJPEGKeepsTheCamera() throws {
        let source = try #require(CGImageSourceCreateWithURL(F.sampleNEF as CFURL, nil))
        let rawProps = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let rawExif = try #require(rawProps[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))

        let data = try ImageEncoder.encode(image, options: options(.jpeg), metadataSource: F.sampleNEF)
        let props = F.properties(data)
        let tiff = try #require(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON CORPORATION")
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == "NIKON D750")
        // Raw storage details must not leak into the JPEG.
        #expect(tiff[kCGImagePropertyTIFFPhotometricInterpretation as String] == nil)
        #expect(tiff[kCGImagePropertyTIFFCompression as String] == nil)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 1)
        let exif = try #require(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifExposureTime as String] as? Double == rawExif[kCGImagePropertyExifExposureTime as String] as? Double)
        #expect(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] == rawExif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == image.width)
        #expect(exif[kCGImagePropertyExifPixelYDimension as String] as? Int == image.height)
        #expect(ImageEncoder.decodePreview(data)?.width == image.width)
    }

    // MARK: - Writing

    @Test func writeReplacesAtomicallyAndKeepsTheCreationDate() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("out.jpg")
        try ImageEncoder.write(TestImages.gradient(), to: url, options: options(.jpeg), metadataSource: nil)
        #expect(F.decode(url)?.width == 64)

        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        try ImageEncoder.write(TestImages.gradient(width: 32, height: 16), to: url, options: options(.png), metadataSource: nil)
        #expect(F.decode(url)?.width == 32)
        #expect(CGImageSourceGetType(CGImageSourceCreateWithURL(url as CFURL, nil)!) as String? == UTType.png.identifier)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.creationDate] as? Date == created)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["out.jpg"])

        // With a carried comment the in-memory path is used; same result on disk.
        let source = try F.taggedJPEG(in: t.url, comment: "From the source")
        let copy = t.url.appendingPathComponent("copy.jpg")
        try ImageEncoder.write(TestImages.gradient(), to: copy, options: options(.jpeg), metadataSource: source)
        #expect(JPEGComment.read(from: copy) == "From the source")

        // Comments are carried as raw segments: a Latin-1 caption stays Latin-1.
        let latin1 = t.url.appendingPathComponent("latin1.jpg")
        var bytes = [UInt8](try Data(contentsOf: TestImages.write(TestImages.gradient(), to: latin1)))
        bytes.insert(contentsOf: [0xFF, 0xFE, 0x00, 0x06, 0x63, 0x61, 0x66, 0xE9], at: 2)
        try Data(bytes).write(to: latin1)
        let exported = try ImageEncoder.encode(TestImages.gradient(), options: options(.jpeg), metadataSource: latin1)
        #expect(JPEGComment.commentPayloads(in: exported) == [Data([0x63, 0x61, 0x66, 0xE9])])
    }

    @Test func decodePreviewRejectsGarbage() {
        #expect(ImageEncoder.decodePreview(Data([1, 2, 3, 4])) == nil)
        #expect(ImageEncoder.decodePreview(Data()) == nil)
    }
}
