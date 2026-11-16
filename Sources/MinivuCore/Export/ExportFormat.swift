import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The file formats Save As and batch convert can write. Every one is an
/// ImageIO destination type, so encoding needs no code of our own.
///
/// AVIF is written only where ImageIO says it can be (`isWritable`): menus
/// offer `writableCases`, not `allCases`.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, avif, tiff, bmp, gif, tga, jpeg2000, ico

    /// The name shown in format menus.
    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
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
        case .avif: "avif"
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
        // Declared by the system on macOS 13 and later; the SDK has no constant.
        case .avif: UTType(importedAs: "public.avif")
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        // No UTType constants for these two; ImageIO declares the identifiers.
        case .tga: UTType(importedAs: "com.truevision.tga-image")
        case .jpeg2000: UTType(importedAs: "public.jpeg-2000")
        case .ico: .ico
        }
    }

    /// Whether ImageIO on this Mac can write the format. Every format but
    /// AVIF has been writable since long before macOS 15; AVIF's encoder
    /// arrived later and may be missing, so this asks ImageIO at run time
    /// (`CGImageDestinationCopyTypeIdentifiers`) rather than trusting the OS
    /// version.
    public var isWritable: Bool { Self.isWritable(self, among: Self.writableTypeIdentifiers) }

    /// The formats a menu offers: every one ImageIO can write here, in
    /// `allCases` order.
    public static var writableCases: [ExportFormat] { allCases.filter(\.isWritable) }

    /// The destination types ImageIO reports, read once a launch.
    static let writableTypeIdentifiers: Set<String> =
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// `isWritable` against a given list of types, for tests.
    static func isWritable(_ format: ExportFormat, among identifiers: Set<String>) -> Bool {
        identifiers.contains(format.utType.identifier)
    }

    /// Lossy formats, where `ExportOptions.quality` trades size for fidelity.
    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .jpeg2000: true
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
    /// 2000, GIF, BMP, TGA and ICO files come back with none of it. AVIF
    /// keeps EXIF, GPS and XMP (IPTC only through its XMP mirror), as HEIC
    /// does.
    public var supportsMetadata: Bool {
        switch self {
        case .jpeg, .png, .heic, .avif, .tiff: true
        default: false
        }
    }

    /// Formats with more than 8 bits per channel, where the "16 bits"
    /// option (`ExportOptions.sixteenBit`) means something. AVIF is in:
    /// given a 16-bit image ImageIO writes 10 bits a channel (measured), so
    /// gradients and tone edits keep their smoothness. (HEIC is written with
    /// 8: ImageIO could store 10 there too, but it isn't offered, to keep
    /// Save's existing HEIC files as they were.)
    public var supports16Bit: Bool { deepBitDepth != nil }

    /// The bits per channel a file gets with the "16 bits" option on: 16 for
    /// PNG and TIFF, 10 for AVIF (the most it holds); nil for formats with 8
    /// only. The option's title names this number.
    public var deepBitDepth: Int? {
        switch self {
        case .png, .tiff: 16
        case .avif: 10
        default: nil
        }
    }

    /// Formats that embed an ICC profile, so a colour profile choice means
    /// something. BMP, TGA and ICO have nowhere to put one and GIF is always
    /// sRGB, so those are always converted to sRGB: that is what every
    /// reader assumes for an untagged file.
    public var supportsColorProfile: Bool {
        switch self {
        case .jpeg, .png, .heic, .avif, .tiff, .jpeg2000: true
        default: false
        }
    }

    /// The format a file name asks for, by extension, or nil if we can't
    /// write it (on this Mac: AVIF only where ImageIO can).
    public static func format(for url: URL) -> ExportFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": .jpeg
        case "png": .png
        case "heic", "heif", "hif": .heic
        case "avif": ExportFormat.avif.isWritable ? .avif : nil
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
        case .original: localized(.init("Keep original", comment: "Colour profile choice: keep the image's own profile"))
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
        case .none: localized(.init("export.compression.none", defaultValue: "None", comment: "TIFF compression: none"))
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
    /// With `keepMetadata`: leaves out where the photo was taken (the GPS
    /// dictionary, its `exif:GPS…` XMP mirror and the IPTC place names) and
    /// keeps everything else. On by default, since a copy is usually made to
    /// be shared (S4 in docs/SECURITY-REVIEW.md); Save over the original
    /// turns it off (`SavePolicy.inPlaceOptions`), as Save keeps all metadata.
    public var removeLocation: Bool
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
                keepMetadata: Bool = true, removeLocation: Bool = true, progressive: Bool = false,
                sixteenBit: Bool = false, tiffCompression: TIFFCompression = .lzw,
                backgroundForOpaqueFormats: ExportColor = .white) {
        self.format = format
        self.quality = quality
        self.colorProfile = colorProfile
        self.keepMetadata = keepMetadata
        self.removeLocation = removeLocation
        self.progressive = progressive
        self.sixteenBit = sixteenBit
        self.tiffCompression = tiffCompression
        self.backgroundForOpaqueFormats = backgroundForOpaqueFormats
    }

    private enum CodingKeys: String, CodingKey {
        case format, quality, colorProfile, keepMetadata, removeLocation, progressive, sixteenBit, tiffCompression
        case backgroundForOpaqueFormats
    }

    /// Options are saved in preferences and batch presets, so decoding
    /// fills anything missing (a preset saved before an option existed)
    /// from `defaults(for:)` instead of failing and losing the preset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var options = ExportOptions.defaults(for: try container.decode(ExportFormat.self, forKey: .format))
        if let value = try container.decodeIfPresent(Double.self, forKey: .quality) { options.quality = value }
        if let value = try container.decodeIfPresent(ExportColorProfile.self, forKey: .colorProfile) { options.colorProfile = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .keepMetadata) { options.keepMetadata = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .removeLocation) { options.removeLocation = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .progressive) { options.progressive = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .sixteenBit) { options.sixteenBit = value }
        if let value = try container.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression) { options.tiffCompression = value }
        if let value = try container.decodeIfPresent(ExportColor.self, forKey: .backgroundForOpaqueFormats) { options.backgroundForOpaqueFormats = value }
        self = options
    }

    /// Sensible starting values. JPEG at 0.9 is where artefacts stop being
    /// visible on photos; HEIC's and AVIF's encoders are more efficient, so
    /// 0.8 looks the same at about half the size.
    public static func defaults(for format: ExportFormat) -> ExportOptions {
        var options = ExportOptions(format: format)
        switch format {
        case .heic, .avif: options.quality = 0.8
        default: break
        }
        options.keepMetadata = format.supportsMetadata
        return options
    }
}
