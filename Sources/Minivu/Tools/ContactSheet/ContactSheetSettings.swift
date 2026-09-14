import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import MinivuCore

/// Page sizes a contact sheet is made at, in pixels.
nonisolated enum ContactSheetPageSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4, letter, uhd4K, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4 at 300 dpi"
        case .letter: "US Letter at 300 dpi"
        case .uhd4K: "4K Display"
        case .custom: "Custom"
        }
    }

    /// The size in its natural orientation; nil for Custom.
    var pixelSize: CGSize? {
        switch self {
        case .a4: CGSize(width: 2480, height: 3508)
        case .letter: CGSize(width: 2550, height: 3300)
        case .uhd4K: CGSize(width: 3840, height: 2160)
        case .custom: nil
        }
    }

    /// Pixels per inch, which sets a PDF page's size in points: A4 and
    /// Letter come out at their paper sizes; a screen size or a custom one
    /// is one point per pixel.
    var dotsPerInch: Double {
        switch self {
        case .a4, .letter: 300
        case .uhd4K, .custom: 72
        }
    }
}

nonisolated enum ContactSheetOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var title: String { self == .portrait ? "Portrait" : "Landscape" }
}

/// What a contact sheet is saved as: a picture per page, or one PDF.
nonisolated enum ContactSheetFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg, png, tiff, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tif"
        case .pdf: "pdf"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .pdf: .pdf
        }
    }

    /// The encoder settings for a raster page; nil for PDF.
    var exportOptions: ExportOptions? {
        let format: ExportFormat
        switch self {
        case .jpeg: format = .jpeg
        case .png: format = .png
        case .tiff: format = .tiff
        case .pdf: return nil
        }
        // No metadata to carry (the sheet is new), and the page's own colour
        // space, which is sRGB or Display P3 as chosen.
        return ExportOptions(format: format, quality: 0.9, colorProfile: .original, keepMetadata: false)
    }
}

nonisolated enum ContactSheetColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB, displayP3
    var id: String { rawValue }
    var title: String { self == .sRGB ? "sRGB" : "Display P3" }
    var colorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
    }
}

/// Everything the Contact Sheet dialog sets. Lengths are in pixels of the
/// page. Remembered between sheets, except the header text, which starts
/// as the folder's name each time.
nonisolated struct ContactSheetSettings: Codable, Equatable, Sendable {
    var pageSize: ContactSheetPageSize = .a4
    var customWidth = 3000
    var customHeight = 2000
    var orientation: ContactSheetOrientation = .portrait
    var columns = 4
    /// 0 is "auto": every picture on one page.
    var rows = 5
    var spacing = 40
    var margin = 120
    var background: ExportColor = .white
    var caption: CaptionContent = .name
    /// Caption text height in pixels; the header is set larger.
    var captionSize = 36
    var showsHeader = true
    var showsPageNumbers = true
    var scaling: LayoutScaling = .fit
    var format: ContactSheetFormat = .jpeg
    var colorSpace: ContactSheetColorSpace = .sRGB

    static let columnRange = 1...20
    static let rowRange = 0...30
    static let customSideRange = 256...16384
    static let spacingRange = 0...400
    static let marginRange = 0...800
    static let captionSizeRange = 8...200

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = ContactSheetSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decode(T.self, forKey: key) { value = decoded }
        }
        read(.pageSize, &s.pageSize)
        read(.customWidth, &s.customWidth)
        read(.customHeight, &s.customHeight)
        read(.orientation, &s.orientation)
        read(.columns, &s.columns)
        read(.rows, &s.rows)
        read(.spacing, &s.spacing)
        read(.margin, &s.margin)
        read(.background, &s.background)
        read(.caption, &s.caption)
        read(.captionSize, &s.captionSize)
        read(.showsHeader, &s.showsHeader)
        read(.showsPageNumbers, &s.showsPageNumbers)
        read(.scaling, &s.scaling)
        read(.format, &s.format)
        read(.colorSpace, &s.colorSpace)
        self = s.validated
    }

    /// Every number within its range, so a page can always be drawn.
    var validated: ContactSheetSettings {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
        var s = self
        s.customWidth = clamp(s.customWidth, Self.customSideRange)
        s.customHeight = clamp(s.customHeight, Self.customSideRange)
        s.columns = clamp(s.columns, Self.columnRange)
        s.rows = clamp(s.rows, Self.rowRange)
        s.spacing = clamp(s.spacing, Self.spacingRange)
        s.margin = clamp(s.margin, Self.marginRange)
        s.captionSize = clamp(s.captionSize, Self.captionSizeRange)
        s.background.alpha = 1
        return s
    }

    /// The page in pixels: a preset turned to the orientation chosen, a
    /// custom size exactly as typed (its width and height already say which
    /// way up it is, so the dialog hides Orientation for it).
    var pagePixelSize: CGSize {
        guard let natural = pageSize.pixelSize else {
            let s = validated
            return CGSize(width: s.customWidth, height: s.customHeight)
        }
        let long = max(natural.width, natural.height), short = min(natural.width, natural.height)
        return orientation == .portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    /// Points per page pixel in a PDF: from the preset's resolution, and
    /// never so many that a side passes 14,400 points (200 inches), the
    /// largest page PDF readers such as Acrobat open.
    var pdfPointsPerPixel: Double {
        let longSide = Double(max(pagePixelSize.width, pagePixelSize.height))
        return min(72 / pageSize.dotsPerInch, 14_400 / max(longSide, 1))
    }

    var headerFontSize: Double { Double(captionSize) * 1.6 }

    func layout(imageCount: Int, header: String?) -> PageLayout {
        let s = validated
        let hasHeader = s.showsHeader && !(header ?? "").isEmpty
        return PageLayout(pageSize: s.pagePixelSize, margins: LayoutInsets(all: Double(s.margin)),
                          columns: s.columns, rows: s.rows == 0 ? nil : s.rows, spacing: Double(s.spacing),
                          captionHeight: s.caption.height(fontSize: Double(s.captionSize)),
                          headerHeight: hasHeader ? s.headerFontSize * 2 : 0,
                          footerHeight: s.showsPageNumbers ? Double(s.captionSize) * 2.2 : 0,
                          scaling: s.scaling, autoRotate: false, centersPartialPages: false)
    }

    func style(header: String?) -> LayoutPageStyle {
        let s = validated
        return LayoutPageStyle(background: s.background, caption: s.caption, captionFontSize: Double(s.captionSize),
                               header: s.showsHeader ? header : nil, headerFontSize: s.headerFontSize,
                               showsPageNumbers: s.showsPageNumbers)
    }

    func pageCount(imageCount: Int) -> Int {
        layout(imageCount: imageCount, header: nil).pageCount(forImageCount: imageCount)
    }
}

/// Remembers the contact sheet settings in their own key.
struct ContactSheetStore {
    let defaults: UserDefaults
    static let key = "contactSheet"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: ContactSheetSettings {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let settings = try? JSONDecoder().decode(ContactSheetSettings.self, from: data)
            else { return ContactSheetSettings() }
            return settings
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: Self.key) }
        }
    }
}

/// File names for the pages written.
nonisolated enum ContactSheetNaming {
    /// "Trip Contact Sheet" from the folder "Trip" (or the header typed).
    /// The header is free text, so it is made a safe file name first: a
    /// "/" or ":" ("2024/09 Trip") would otherwise name a folder that isn't
    /// there, or one outside the folder chosen ("../Trip"), and a leading
    /// dot would hide the pages.
    static func baseName(folderName: String?) -> String {
        var name = (folderName ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name.unicodeScalars.removeAll { $0.value < 0x20 || $0.value == 0x7F }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        // Room for " Contact Sheet 999.tif" within APFS's 255 bytes.
        while name.utf8.count > 200 { name.removeLast() }
        return name.isEmpty ? "Contact Sheet" : "\(name) Contact Sheet"
    }

    /// One name per page, "Trip 1.jpg", "Trip 2.jpg"…; when any of them is
    /// taken the base becomes "Trip 2", "Trip 3"… until none is, so pages
    /// of one sheet always share a base and nothing is ever replaced.
    static func pageNames(base: String, count: Int, fileExtension: String, exists: (String) -> Bool) -> [String] {
        guard count > 0 else { return [] }
        var stem = base, attempt = 1
        while true {
            let names = (1...count).map { "\(stem) \($0).\(fileExtension)" }
            if !names.contains(where: exists) { return names }
            attempt += 1
            stem = "\(base) \(attempt)"
        }
    }

    /// "Trip Contact Sheet.pdf" — the save panel asks before replacing.
    static func singleName(base: String, format: ContactSheetFormat) -> String {
        "\(base).\(format.fileExtension)"
    }
}
