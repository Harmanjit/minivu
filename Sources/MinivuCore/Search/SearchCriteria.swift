import Foundation
import ImageIO

/// What the browser's filters and Find look at in a file beyond its name,
/// type and marks (G3): read from the header in one pass, never decoding a
/// pixel, and cached in the catalog (`Catalog.filterMetadata(for:)`).
public struct FilterMetadata: Sendable, Equatable {
    /// When the picture was taken, as the camera's clock showed it,
    /// written yyyymmddhhmmss so it sorts and compares as a number. Wall
    /// clock rather than an instant, as Edit Metadata keeps it: a photo
    /// taken at 9 in the morning in Tokyo was taken in the morning wherever
    /// it is searched for.
    public var dateTaken: Int64?
    public var camera: String?
    public var lens: String?
    public var iso: Double?
    public var aperture: Double?
    public var focalLength: Double?
    /// The file's keywords (and its sidecar's, which win), as Edit Metadata
    /// and the info panel show them.
    public var keywords: [String]
    public var hasLocation: Bool
    /// Oriented pixel size: width and height as the picture is shown.
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(dateTaken: Int64? = nil, camera: String? = nil, lens: String? = nil, iso: Double? = nil,
                aperture: Double? = nil, focalLength: Double? = nil, keywords: [String] = [], hasLocation: Bool = false,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.dateTaken = dateTaken
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.focalLength = focalLength
        self.keywords = keywords
        self.hasLocation = hasLocation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Reads a file's header (and its XMP sidecar, for a file whose metadata
    /// lives in one). Disk work, a few milliseconds even for a RAW file:
    /// call it off the main thread. A file ImageIO can't open gives empty
    /// metadata, so it is read once and then fails every metadata filter.
    public static func read(from url: URL) -> FilterMetadata {
        guard let kind = ImageFormats.kind(of: url) else { return FilterMetadata() }
        guard kind == .raster || kind == .raw else {
            // PDF and SVG have a size and nothing else to search by.
            let size = ImageDecoder.info(for: url)?.pixelSize
            return FilterMetadata(pixelWidth: size.map { Int($0.width) }, pixelHeight: size.map { Int($0.height) })
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return FilterMetadata() }
        let index = ImageDecoder.primaryIndex(source)
        let root = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let p = MetadataReader.Properties(root: root, type: CGImageSourceGetType(source) as String?)
        var fields = MetadataFields.read(properties: root, metadata: CGImageSourceCopyMetadataAtIndex(source, index, nil))
        if MetadataWriter.method(for: url) == .sidecar,
           let data = try? Data(contentsOf: MetadataSidecar.url(for: url)),
           let sidecar = CGImageMetadataCreateFromXMPData(data as CFData) {
            fields.overlay(sidecar: sidecar)
        }
        let size = p.orientedPixelSize
        return FilterMetadata(
            dateTaken: fields.dateTaken.map(Self.stamp),
            camera: MetadataReader.cameraName(make: p.string(p.tiff, kCGImagePropertyTIFFMake),
                                              model: p.string(p.tiff, kCGImagePropertyTIFFModel)),
            lens: p.lensModel,
            iso: p.iso.map(Double.init),
            aperture: p.double(p.exif, kCGImagePropertyExifFNumber).flatMap { $0 > 0 ? $0 : nil },
            focalLength: p.double(p.exif, kCGImagePropertyExifFocalLength).flatMap { $0 > 0 ? $0 : nil },
            keywords: fields.keywords,
            hasLocation: fields.hasLocation,
            pixelWidth: size.flatMap { Int(exactly: $0.width.rounded()) },
            pixelHeight: size.flatMap { Int(exactly: $0.height.rounded()) })
    }

    /// yyyymmddhhmmss.
    public static func stamp(_ clock: WallClock) -> Int64 {
        Int64(day(clock)) * 1_000_000 + Int64(clock.hour * 10_000 + clock.minute * 100 + clock.second)
    }

    /// yyyymmdd: the day part of a stamp, and what date ranges compare.
    public static func day(_ clock: WallClock) -> Int {
        clock.year * 10_000 + clock.month * 100 + clock.day
    }
}

/// The groups of file types the filter offers, by extension: what a
/// photographer thinks of as a type ("RAW", "HEIF"), not the dozens of
/// extensions behind them.
public enum FileTypeGroup: String, CaseIterable, Sendable, Codable {
    case jpeg, heif, png, raw, tiff, gif, webp, psd, pdf, svg, other

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heif: "HEIF and AVIF"
        case .png: "PNG"
        case .raw: "RAW"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .webp: "WebP"
        case .psd: "Photoshop"
        case .pdf: "PDF"
        case .svg: "SVG"
        case .other: "Other"
        }
    }

    public static func of(_ url: URL) -> FileTypeGroup {
        let ext = url.pathExtension.lowercased()
        if ImageFormats.rawExtensions.contains(ext) { return .raw }
        return switch ext {
        case "jpg", "jpeg", "jpe", "jfif": .jpeg
        case "heic", "heif", "hif", "avif": .heif
        case "png", "apng": .png
        case "tif", "tiff": .tiff
        case "gif": .gif
        case "webp": .webp
        case "psd": .psd
        case "pdf": .pdf
        case "svg": .svg
        default: .other
        }
    }
}

/// An inclusive range with either end open; nil at both ends is no range.
public struct NumberRange: Sendable, Equatable, Codable {
    public var minimum: Double?
    public var maximum: Double?

    public init(minimum: Double? = nil, maximum: Double? = nil) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var isActive: Bool { minimum != nil || maximum != nil }

    /// A missing value is outside any range that is set.
    public func contains(_ value: Double?) -> Bool {
        guard isActive else { return true }
        guard let value else { return false }
        if let minimum, value < minimum - Self.tolerance { return false }
        if let maximum, value > maximum + Self.tolerance { return false }
        return true
    }

    /// EXIF stores f/2.8 as 28/10 or as 2.8 rounded either way, and a
    /// focal length as a rational: a range typed as 2.8 must still hold it.
    static let tolerance = 0.005
}

/// Which way round the picture is, as it is shown.
public enum ShapeFilter: String, CaseIterable, Sendable, Codable {
    case landscape, portrait, square

    public var title: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        }
    }
}

extension ColorLabel: Codable {}

/// The browser's filters past rating, tag and Finder tag (G3), and the
/// same conditions in Find and smart folders. Every condition that is set
/// must hold; one left at its default doesn't filter. Text matches ignore
/// case and accents and match anywhere in the value ("5d" finds "Canon EOS
/// 5D Mark IV").
public struct MetadataCriteria: Sendable, Equatable, Codable {
    /// Empty shows every type.
    public var fileTypes: Set<FileTypeGroup> = []
    /// yyyymmdd, inclusive. A file with no date taken fails a date range.
    public var takenFrom: Int?
    public var takenTo: Int?
    public var camera = ""
    public var lens = ""
    public var iso = NumberRange()
    public var aperture = NumberRange()
    public var focalLength = NumberRange()
    /// Every one of these, in any letter case.
    public var keywords: [String] = []
    public var colorLabel: ColorLabel?
    public var hasLocation: Bool?
    public var shape: ShapeFilter?
    public var minimumWidth: Int?
    public var minimumHeight: Int?

    public init() {}

    public var isActive: Bool { self != MetadataCriteria() }

    /// Whether any condition needs the file's header (`FilterMetadata`);
    /// type and colour label don't.
    public var needsMetadata: Bool {
        takenFrom != nil || takenTo != nil || !Self.folded(camera).isEmpty || !Self.folded(lens).isEmpty
            || iso.isActive || aperture.isActive || focalLength.isActive || !keywords.isEmpty
            || hasLocation != nil || shape != nil || minimumWidth != nil || minimumHeight != nil
    }

    /// Whether a file passes on its type alone, before anything is read.
    public func passesType(_ url: URL) -> Bool {
        fileTypes.isEmpty || fileTypes.contains(FileTypeGroup.of(url))
    }

    /// Whether a file passes. `metadata` nil means not read yet, which
    /// fails a filter that needs it: a file is shown once it is known to
    /// match, never shown and then taken away.
    public func passes(_ url: URL, metadata: FilterMetadata?, label: ColorLabel) -> Bool {
        guard passesType(url) else { return false }
        if let colorLabel, label != colorLabel { return false }
        guard needsMetadata else { return true }
        guard let m = metadata else { return false }
        if takenFrom != nil || takenTo != nil {
            guard let stamp = m.dateTaken else { return false }
            let day = Int(stamp / 1_000_000)
            if let takenFrom, day < takenFrom { return false }
            if let takenTo, day > takenTo { return false }
        }
        if !Self.contains(m.camera, camera) || !Self.contains(m.lens, lens) { return false }
        guard iso.contains(m.iso), aperture.contains(m.aperture), focalLength.contains(m.focalLength) else { return false }
        if !keywords.isEmpty {
            let have = Set(m.keywords.map(Self.folded))
            for keyword in keywords where !Self.folded(keyword).isEmpty && !have.contains(Self.folded(keyword)) {
                return false
            }
        }
        if let hasLocation, m.hasLocation != hasLocation { return false }
        if shape != nil || minimumWidth != nil || minimumHeight != nil {
            guard let width = m.pixelWidth, let height = m.pixelHeight else { return false }
            if let minimumWidth, width < minimumWidth { return false }
            if let minimumHeight, height < minimumHeight { return false }
            switch shape {
            case .landscape?: if width <= height { return false }
            case .portrait?: if height <= width { return false }
            case .square?: if width != height { return false }
            case nil: break
            }
        }
        return true
    }

    /// Case-, accent- and width-insensitive, trimmed: how every text
    /// condition compares.
    public static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func contains(_ value: String?, _ wanted: String) -> Bool {
        let wanted = folded(wanted)
        guard !wanted.isEmpty else { return true }
        guard let value else { return false }
        return folded(value).contains(wanted)
    }
}

/// A search across a folder tree (G3): Find's form, and what a smart folder
/// keeps. Stored as JSON in the catalog, so every field has a default and
/// a query saved by an older minivu still decodes.
public struct SearchQuery: Sendable, Equatable, Codable {
    /// The folder searched, as a path: the sandbox's access comes from the
    /// sidebar's bookmarks (or Pictures), not from the query.
    public var scope: String
    public var includeSubfolders = true
    /// Part of the file name, case and accents ignored. Empty matches all.
    public var name = ""
    public var minimumRating = 0
    public var taggedOnly = false
    public var criteria = MetadataCriteria()

    public init(scope: URL, includeSubfolders: Bool = true, name: String = "", minimumRating: Int = 0,
                taggedOnly: Bool = false, criteria: MetadataCriteria = MetadataCriteria()) {
        self.scope = scope.standardizedFileURL.path
        self.includeSubfolders = includeSubfolders
        self.name = name
        self.minimumRating = minimumRating
        self.taggedOnly = taggedOnly
        self.criteria = criteria
    }

    public var scopeURL: URL { URL(fileURLWithPath: scope, isDirectory: true) }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decoded(_ json: String) throws -> SearchQuery {
        try JSONDecoder().decode(SearchQuery.self, from: Data(json.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case scope, includeSubfolders, name, minimumRating, taggedOnly, criteria
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        minimumRating = try c.decodeIfPresent(Int.self, forKey: .minimumRating) ?? 0
        taggedOnly = try c.decodeIfPresent(Bool.self, forKey: .taggedOnly) ?? false
        criteria = try c.decodeIfPresent(MetadataCriteria.self, forKey: .criteria) ?? MetadataCriteria()
    }
}

extension MetadataCriteria {
    private enum CodingKeys: String, CodingKey {
        case fileTypes, takenFrom, takenTo, camera, lens, iso, aperture, focalLength, keywords, colorLabel,
             hasLocation, shape, minimumWidth, minimumHeight
    }

    /// Every key optional, so criteria saved before a condition existed
    /// still decode, and a value that no longer decodes (a type group since
    /// renamed) drops that condition rather than the whole smart folder.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let types = (try? c.decodeIfPresent([String].self, forKey: .fileTypes))
        fileTypes = Set((types ?? []).compactMap(FileTypeGroup.init(rawValue:)))
        takenFrom = (try? c.decodeIfPresent(Int.self, forKey: .takenFrom))
        takenTo = (try? c.decodeIfPresent(Int.self, forKey: .takenTo))
        camera = (try? c.decodeIfPresent(String.self, forKey: .camera)) ?? ""
        lens = (try? c.decodeIfPresent(String.self, forKey: .lens)) ?? ""
        iso = (try? c.decodeIfPresent(NumberRange.self, forKey: .iso)) ?? NumberRange()
        aperture = (try? c.decodeIfPresent(NumberRange.self, forKey: .aperture)) ?? NumberRange()
        focalLength = (try? c.decodeIfPresent(NumberRange.self, forKey: .focalLength)) ?? NumberRange()
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        colorLabel = (try? c.decodeIfPresent(ColorLabel.self, forKey: .colorLabel))
        hasLocation = (try? c.decodeIfPresent(Bool.self, forKey: .hasLocation))
        shape = (try? c.decodeIfPresent(ShapeFilter.self, forKey: .shape))
        minimumWidth = (try? c.decodeIfPresent(Int.self, forKey: .minimumWidth))
        minimumHeight = (try? c.decodeIfPresent(Int.self, forKey: .minimumHeight))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !fileTypes.isEmpty { try c.encode(fileTypes.map(\.rawValue).sorted(), forKey: .fileTypes) }
        try c.encodeIfPresent(takenFrom, forKey: .takenFrom)
        try c.encodeIfPresent(takenTo, forKey: .takenTo)
        if !camera.isEmpty { try c.encode(camera, forKey: .camera) }
        if !lens.isEmpty { try c.encode(lens, forKey: .lens) }
        if iso.isActive { try c.encode(iso, forKey: .iso) }
        if aperture.isActive { try c.encode(aperture, forKey: .aperture) }
        if focalLength.isActive { try c.encode(focalLength, forKey: .focalLength) }
        if !keywords.isEmpty { try c.encode(keywords, forKey: .keywords) }
        try c.encodeIfPresent(colorLabel, forKey: .colorLabel)
        try c.encodeIfPresent(hasLocation, forKey: .hasLocation)
        try c.encodeIfPresent(shape, forKey: .shape)
        try c.encodeIfPresent(minimumWidth, forKey: .minimumWidth)
        try c.encodeIfPresent(minimumHeight, forKey: .minimumHeight)
    }
}
