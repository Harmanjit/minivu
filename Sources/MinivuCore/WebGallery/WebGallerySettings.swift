import Foundation
import ImageIO

/// The picture format a web gallery's thumbnails and large pictures are
/// written in. JPEG is read by every browser; HEIC by Safari (17 and later)
/// only; AVIF by current Safari, Chrome and Firefox.
public enum WebGalleryFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg, heic, avif

    public var id: Self { self }

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .avif: "avif"
        }
    }

    /// The ImageIO destination type.
    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .avif: "public.avif"
        }
    }

    /// The Save As format whose rules (quality, alpha, metadata) the encode
    /// follows. AVIF isn't a Save As format; it is a HEIF file like HEIC.
    public var exportFormat: ExportFormat {
        switch self {
        case .jpeg: .jpeg
        case .heic, .avif: .heic
        }
    }

    /// Whether this Mac's ImageIO can write the format. AVIF needs a recent
    /// macOS; the dialog leaves out what can't be written.
    public var isAvailable: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(typeIdentifier)
    }
}

/// Everything Create Web Gallery asks about except the title (which
/// belongs to each gallery): sizes, layout, look, captions, order, the
/// picture format and its metadata, and whether the originals go too.
///
/// `Codable` and remembered between launches; a missing or unreadable field
/// takes its default, so settings saved by another version still load.
public struct WebGallerySettings: Codable, Hashable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
        case light, dark
        /// Follows the light or dark appearance of whoever looks at it.
        case automatic

        public var id: Self { self }

        public var title: String {
            switch self {
            case .light: "Light"
            case .dark: "Dark"
            case .automatic: "Automatic"
            }
        }
    }

    public enum Sort: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The order the browser shows them in.
        case asShown
        case name
        /// The date the photo was taken, else when the file last changed.
        case dateTaken
        case dateModified

        public var id: Self { self }

        public var title: String {
            switch self {
            case .asShown: "As Shown"
            case .name: "Name"
            case .dateTaken: "Date Taken"
            case .dateModified: "Date Modified"
            }
        }
    }

    /// The thumbnails' long side in CSS pixels. The files are written at
    /// twice that, so they are sharp on Retina screens.
    public var thumbnailSize = 200
    /// The large pictures' long side in pixels. Smaller pictures keep their
    /// size.
    public var largeSize = 1600
    /// Columns in the thumbnail grid; 0 for as many as fit the window.
    public var columns = 0
    public var theme: Theme = .automatic
    public var showsFileName = true
    /// The title from the metadata under each thumbnail, and the title and
    /// caption on each picture's page.
    public var showsTitle = true
    public var showsDate = false
    public var sort: Sort = .asShown
    /// Copies each original file into the gallery, linked from its page.
    public var includesOriginals = false
    public var format: WebGalleryFormat = .jpeg
    /// 0...1, as Save As's quality.
    public var quality = 0.85
    public var keepsMetadata = true
    /// With `keepsMetadata`: leaves out where each photo was taken. On by
    /// default, a gallery being made to be shared (S4 in
    /// docs/SECURITY-REVIEW.md).
    public var removesLocation = true

    public static let thumbnailRange = 64...512
    public static let largeRange = 320...8192
    public static let columnRange = 0...12
    public static let qualityRange = 0.1...1.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case thumbnailSize, largeSize, columns, theme, showsFileName, showsTitle, showsDate, sort, includesOriginals
        case format, quality, keepsMetadata, removesLocation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WebGallerySettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        thumbnailSize = value(.thumbnailSize, d.thumbnailSize)
        largeSize = value(.largeSize, d.largeSize)
        columns = value(.columns, d.columns)
        theme = value(.theme, d.theme)
        showsFileName = value(.showsFileName, d.showsFileName)
        showsTitle = value(.showsTitle, d.showsTitle)
        showsDate = value(.showsDate, d.showsDate)
        sort = value(.sort, d.sort)
        includesOriginals = value(.includesOriginals, d.includesOriginals)
        format = value(.format, d.format)
        quality = value(.quality, d.quality)
        keepsMetadata = value(.keepsMetadata, d.keepsMetadata)
        removesLocation = value(.removesLocation, d.removesLocation)
        self = validated
    }

    /// Every number brought into its range, so a value typed out of range
    /// (or a damaged preference) shows what will be used.
    public var validated: WebGallerySettings {
        var copy = self
        copy.thumbnailSize = Self.clamp(thumbnailSize, Self.thumbnailRange)
        copy.largeSize = Self.clamp(largeSize, Self.largeRange)
        copy.columns = Self.clamp(columns, Self.columnRange)
        copy.quality = quality.isFinite ? min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
                                        : WebGallerySettings().quality
        return copy
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether planning must read each file's metadata (a header read, never
    /// pixels): for titles, dates, or sorting by date taken.
    public var needsMetadata: Bool {
        showsTitle || showsDate || sort == .dateTaken
    }

    /// Whether the original files copied into the gallery may keep where
    /// each photo was taken: only when the large pictures keep it too, so
    /// including the originals never shares a location the dialog said it
    /// would leave out.
    public var originalsKeepLocation: Bool {
        keepsMetadata && !removesLocation
    }

    /// The thumbnails' long side in pixels, as written.
    public var thumbnailPixels: Int { thumbnailSize * 2 }

    /// The Save As options the large pictures are encoded with: always sRGB,
    /// which every browser assumes for an untagged picture and shows right
    /// even where colour management is missing; progressive JPEG, which
    /// shows a whole picture early while it loads.
    public var exportOptions: ExportOptions {
        var options = ExportOptions.defaults(for: format.exportFormat)
        options.quality = validated.quality
        options.colorProfile = .sRGB
        options.keepMetadata = keepsMetadata
        options.removeLocation = removesLocation
        options.progressive = format == .jpeg
        return options
    }

    /// The thumbnails' options: as the large pictures', without metadata
    /// (a thumbnail is a few kilobytes, and its EXIF would often be more).
    public var thumbnailOptions: ExportOptions {
        var options = exportOptions
        options.keepMetadata = false
        return options
    }
}
