import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Helpers shared by the Export suites.
enum ExportFixtures {
    static let assets = URL(fileURLWithPath: "/Users/harman/latent/TestAssets")
    static let sampleJPEG = assets.appendingPathComponent("HSB_6548.jpg")
    static let sampleHEIC = assets.appendingPathComponent("HSB_6548.heic")
    static let sampleNEF = assets.appendingPathComponent("HSB_6548.NEF")
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A flat colour, drawn into a bitmap of the given space.
    static func solid(_ color: CGColor, width: Int = 32, height: Int = 24, space: CGColorSpace = sRGB,
                      alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: info.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// RGBA, 8 bits, premultiplied, top row first, converted into `space`.
    static func pixels(of image: CGImage, in space: CGColorSpace = sRGB) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// The pixel at (x, y), top-left origin, as [r, g, b, a].
    static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return bytes[i..<i + 4].map(Int.init)
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
    }

    static func properties(_ url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [String: Any] ?? [:]
    }

    static func properties(_ data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [String: Any] ?? [:]
    }

    static func metadataValue(_ data: Data, _ path: String) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        return "\(value)"
    }

    /// Everything from the first SOS marker to the end: the compressed image.
    static func scanData(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let start = data.withUnsafeBytes { JPEGComment.header(of: $0)?.scanStart }
        return data[(start ?? data.count)...]
    }

    /// The header segments (bytes, marker) before the first scan.
    static func segments(_ url: URL) throws -> [(marker: UInt8, bytes: Data)] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            (JPEGComment.header(of: raw)?.segments ?? []).map { ($0.marker, Data(raw[$0.start..<$0.end])) }
        }
    }

    /// A JPEG written by ImageIO with EXIF, TIFF, GPS, IPTC and XMP
    /// (including a Camera Raw tag that export must drop).
    static func taggedJPEG(in folder: URL, orientation: CGImagePropertyOrientation = .right, comment: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent("tagged-\(UUID().uuidString.prefix(6)).jpg")
        let metadata = CGImageMetadataCreateMutable()
        let rating = CGImageMetadataTagCreate("http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, "Rating" as CFString, .string, "4" as CFString)!
        CGImageMetadataSetTagWithPath(metadata, nil, "xmp:Rating" as CFString, rating)
        #expect(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/camera-raw-settings/1.0/" as CFString, "crs" as CFString, nil))
        let crs = CGImageMetadataTagCreate("http://ns.adobe.com/camera-raw-settings/1.0/" as CFString, "crs" as CFString, "Exposure2012" as CFString, .string, "+1.00" as CFString)!
        CGImageMetadataSetTagWithPath(metadata, nil, "crs:Exposure2012" as CFString, crs)
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifColorSpace: 1, kCGImagePropertyExifPixelXDimension: 64],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 6_2"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.858222, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["paris", "tower"]],
        ]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(destination, TestImages.gradient(width: 64, height: 48), metadata, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        if let comment { try JPEGComment.write(comment, to: url) }
        return url
    }
}
