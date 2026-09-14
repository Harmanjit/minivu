import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

@Suite struct ExportFormatTests {
    @Test func everyFormatHasAnImageIOEncoderAndRoundTrips() throws {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        let image = TestImages.gradient(width: 64, height: 48)
        for format in ExportFormat.allCases {
            #expect(writable.contains(format.utType.identifier), "\(format)")
            let data = try ImageEncoder.encode(image, options: .defaults(for: format), metadataSource: nil)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == format.utType.identifier, "\(format)")
            let decoded = try #require(ImageEncoder.decodePreview(data), "\(format)")
            // Icons are padded to a square.
            #expect(decoded.width == 64 && decoded.height == (format == .ico ? 64 : 48), "\(format)")
        }
    }

    @Test func formatsByExtension() {
        let cases: [(String, ExportFormat?)] = [
            ("a.jpg", .jpeg), ("a.JPEG", .jpeg), ("a.jfif", .jpeg), ("a.png", .png), ("a.HEIC", .heic), ("a.heif", .heic),
            ("a.tif", .tiff), ("a.tiff", .tiff), ("a.bmp", .bmp), ("a.gif", .gif), ("a.tga", .tga), ("a.jp2", .jpeg2000),
            ("a.j2k", .jpeg2000), ("a.ico", .ico), ("a.nef", nil), ("a.webp", nil), ("noextension", nil),
        ]
        for (name, expected) in cases {
            #expect(ExportFormat.format(for: URL(fileURLWithPath: "/x/" + name)) == expected, "\(name)")
        }
        for format in ExportFormat.allCases {
            #expect(ExportFormat.format(for: URL(fileURLWithPath: "/x/a." + format.fileExtension)) == format)
        }
    }

    @Test func capabilities() {
        #expect(ExportFormat.allCases.filter(\.supportsQuality) == [.jpeg, .heic, .jpeg2000])
        #expect(ExportFormat.allCases.filter(\.supports16Bit) == [.png, .tiff])
        #expect(ExportFormat.allCases.filter(\.supportsMetadata) == [.jpeg, .png, .heic, .tiff])
        #expect(ExportFormat.allCases.filter { !$0.supportsAlpha } == [.jpeg, .bmp])
        #expect(ExportFormat.allCases.filter { !$0.supportsColorProfile } == [.bmp, .gif, .tga, .ico])
    }

    @Test func defaultsAndCodableRoundTrip() throws {
        #expect(ExportOptions.defaults(for: .jpeg).quality == 0.9)
        #expect(ExportOptions.defaults(for: .heic).quality == 0.8)
        #expect(ExportOptions.defaults(for: .jpeg).keepMetadata)
        #expect(!ExportOptions.defaults(for: .gif).keepMetadata)
        #expect(ExportOptions.defaults(for: .tiff).tiffCompression == .lzw)
        #expect(ExportOptions.defaults(for: .png).backgroundForOpaqueFormats == .white)

        var options = ExportOptions.defaults(for: .tiff)
        options.quality = 0.42
        options.colorProfile = .adobeRGB
        options.sixteenBit = true
        options.tiffCompression = .packBits
        options.backgroundForOpaqueFormats = ExportColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let json = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(ExportOptions.self, from: json) == options)

        // A preset saved with fewer options still loads, the rest defaulted.
        let old = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"format":"heic","quality":0.5}"#.utf8))
        var expected = ExportOptions.defaults(for: .heic)
        expected.quality = 0.5
        #expect(old == expected)
    }

    @Test func exportColorConvertsToSRGB() throws {
        let color = try #require(ExportColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)))
        #expect(abs(color.red - 0.2) < 0.001 && abs(color.green - 0.4) < 0.001 && abs(color.blue - 0.6) < 0.001)
        #expect(color.alpha == 0.5)
        // Mid gray in a gray space comes back as equal sRGB components.
        let gray = try #require(ExportColor(CGColor(gray: 0.5, alpha: 1)))
        #expect(abs(gray.red - gray.green) < 0.001 && abs(gray.green - gray.blue) < 0.001)
        #expect(gray.red > 0.3 && gray.red < 0.7)
    }
}
