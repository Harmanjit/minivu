import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// The file formats Save As and batch convert can write. Every one is an
/// ImageIO destination type, so encoding needs no code of our own.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, bmp, gif, tga, jpeg2000, ico

    /// The name shown in format menus.
    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .tga: "TGA"
        case .jpeg2000: "JPEG 2000"
        case .ico: "ICO"
        }
    }

    /// The extension new files get. "jpg" and "tif" rather than Apple's
    /// preferred "jpeg" and "tiff", because that is what cameras, Windows
    /// and most photo software write, and people recognise them.
    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tif"
        case .bmp: "bmp"
        case .gif: "gif"
        case .tga: "tga"
        case .jpeg2000: "jp2"
        case .ico: "ico"
        }
    }

    /// The type ImageIO's destination is created with (and save panels filter by).
    public var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        // No UTType constants for these two; ImageIO declares the identifiers.
        case .tga: UTType(importedAs: "com.truevision.tga-image")
        case .jpeg2000: UTType(importedAs: "public.jpeg-2000")
        case .ico: .ico
        }
    }

    /// Lossy formats, where `ExportOptions.quality` trades size for fidelity.
    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .jpeg2000: true
        default: false
        }
    }

    /// Formats that keep transparency. JPEG and BMP are flattened over
    /// `ExportOptions.backgroundForOpaqueFormats`: ImageIO can write a 32-bit
    /// BMP, but most readers ignore its alpha and show garbage colours in
    /// the transparent parts, so an honest opaque file is the safer choice.
    /// GIF keeps alpha as a single transparent palette entry.
    public var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: false
        default: true
        }
    }

    /// Formats ImageIO writes EXIF, GPS, IPTC and XMP into. Measured: JPEG
    /// 2000, GIF, BMP, TGA and ICO files come back with none of it.
    public var supportsMetadata: Bool {
        switch self {
        case .jpeg, .png, .heic, .tiff: true
        default: false
        }
    }

    /// Formats with 16 bits per channel. (HEIC stores at most 10, which
    /// ImageIO picks by itself, so it isn't offered as a choice.)
    public var supports16Bit: Bool {
        switch self {
        case .png, .tiff: true
        default: false
        }
    }

    /// Formats that embed an ICC profile, so a colour profile choice means
    /// something. BMP, TGA and ICO have nowhere to put one and GIF is always
    /// sRGB, so those are always converted to sRGB: that is what every
    /// reader assumes for an untagged file.
    public var supportsColorProfile: Bool {
        switch self {
        case .jpeg, .png, .heic, .tiff, .jpeg2000: true
        default: false
        }
    }

    /// The format a file name asks for, by extension, or nil if we can't write it.
    public static func format(for url: URL) -> ExportFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": .jpeg
        case "png": .png
        case "heic", "heif", "hif": .heic
        case "tif", "tiff": .tiff
        case "bmp", "dib": .bmp
        case "gif": .gif
        case "tga": .tga
        case "jp2", "j2k", "jpf", "jpx": .jpeg2000
        case "ico": .ico
        default: nil
        }
    }
}

/// The colour space pixels are converted to and whose profile is embedded.
public enum ExportColorProfile: String, Codable, CaseIterable, Sendable {
    /// The image's own colour space. Linear, extended-range and HDR working
    /// spaces (what an edit renders in) become their ordinary SDR
    /// equivalents first, since an 8- or 16-bit file can't hold values
    /// above 1.0 and few readers understand a linear profile.
    case original
    case sRGB
    case displayP3
    case adobeRGB

    public var title: String {
        switch self {
        case .original: "Keep original"
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        }
    }
}

/// TIFF compression schemes ImageIO writes. All three are lossless.
public enum TIFFCompression: String, Codable, CaseIterable, Sendable {
    case none, lzw, packBits

    public var title: String {
        switch self {
        case .none: "None"
        case .lzw: "LZW"
        case .packBits: "PackBits"
        }
    }

    /// The value of the TIFF Compression tag (259).
    var tagValue: Int {
        switch self {
        case .none: 1
        case .lzw: 5
        case .packBits: 32773
        }
    }
}

/// An sRGB colour with alpha, 0...1 per component. `CGColor` isn't
/// `Codable`, and options are saved in preferences and batch presets, so
/// they carry this instead.
public struct ExportColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Converts any colour (a colour well's pick, say) to sRGB components.
    /// Nil for colours that can't be converted, such as patterns.
    public init?(_ color: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4 else { return nil }
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
    }

    public static let white = ExportColor(red: 1, green: 1, blue: 1)
    public static let black = ExportColor(red: 0, green: 0, blue: 0)

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// Everything Save As asks about. Options that don't apply to the chosen
/// format (quality for PNG, 16-bit for JPEG) are kept, not cleared, so
/// switching formats back and forth in the dialog doesn't lose them.
public struct ExportOptions: Codable, Hashable, Sendable {
    public var format: ExportFormat
    /// 0...1, for lossy formats. 1 is visually lossless for JPEG and HEIC,
    /// and truly lossless for JPEG 2000.
    public var quality: Double
    public var colorProfile: ExportColorProfile
    /// Copies EXIF, GPS, IPTC, TIFF and XMP from the source file, with the
    /// orientation reset to 1 (the pixels are already upright), the pixel
    /// dimensions updated and any embedded thumbnail dropped. For JPEG to
    /// JPEG the COM comment is carried over too. Without it, only the
    /// colour profile is written.
    public var keepMetadata: Bool
    /// JPEG only: a progressive file shows a coarse whole image early while
    /// it downloads, and is usually a few percent smaller.
    public var progressive: Bool
    /// PNG and TIFF: 16 bits per channel, which keeps the smooth gradients
    /// of a 16-bit or RAW source and of heavy tone edits.
    public var sixteenBit: Bool
    public var tiffCompression: TIFFCompression
    /// What transparent pixels are composited over for JPEG and BMP.
    public var backgroundForOpaqueFormats: ExportColor

    public init(format: ExportFormat, quality: Double = 0.9, colorProfile: ExportColorProfile = .original,
                keepMetadata: Bool = true, progressive: Bool = false, sixteenBit: Bool = false,
                tiffCompression: TIFFCompression = .lzw, backgroundForOpaqueFormats: ExportColor = .white) {
        self.format = format
        self.quality = quality
        self.colorProfile = colorProfile
        self.keepMetadata = keepMetadata
        self.progressive = progressive
        self.sixteenBit = sixteenBit
        self.tiffCompression = tiffCompression
        self.backgroundForOpaqueFormats = backgroundForOpaqueFormats
    }

    /// Sensible starting values. JPEG at 0.9 is where artefacts stop being
    /// visible on photos; HEIC's encoder is more efficient, so 0.8 looks
    /// the same at about half the size.
    public static func defaults(for format: ExportFormat) -> ExportOptions {
        var options = ExportOptions(format: format)
        switch format {
        case .heic: options.quality = 0.8
        default: break
        }
        options.keepMetadata = format.supportsMetadata
        return options
    }
}
