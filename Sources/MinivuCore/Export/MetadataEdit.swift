import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A date and time as a camera writes it: wall-clock fields with no time
/// zone, which is what EXIF's DateTimeOriginal holds ("2024:05:01
/// 14:30:00"). Shifting and setting work on these fields directly, so a
/// photo taken at 14:30 in Tokyo still says 14:30 after an edit made in
/// London, whatever the Mac's own zone; any offset the file stores beside
/// it (EXIF OffsetTimeOriginal, or the "+09:00" of an XMP date) is kept.
public struct WallClock: Hashable, Sendable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// A calendar in GMT, where wall-clock arithmetic has no daylight-saving
    /// gaps: adding an hour across a clock change is still an hour.
    static var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// The same fields as an instant in GMT, for date pickers (shown in GMT
    /// too, so they display exactly these fields).
    public var date: Date {
        Self.gmt.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                           second: second)) ?? .distantPast
    }

    /// The fields of `date` read in GMT; the inverse of `date`.
    public init(date: Date) {
        let c = Self.gmt.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0,
                  minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// Parses EXIF's "2024:05:01 14:30:00", tolerating "-" or "/" between
    /// the date's fields as `MetadataReader.parseExifDate` does. Nil for the
    /// blank "0000:00:00 00:00:00" some cameras write.
    public init?(exif text: String) {
        let fields = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard fields.count >= 6 else { return nil }
        self.init(year: fields[0], month: fields[1], day: fields[2], hour: fields[3], minute: fields[4], second: fields[5])
        guard isValid else { return nil }
    }

    var isValid: Bool {
        (1...9999).contains(year) && (1...12).contains(month) && (1...31).contains(day)
            && (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    /// The fields of `date` as a clock in `zone` shows them.
    public init(date: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0,
                  minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// The date and time as the info panel shows dates taken, in the
    /// user's locale.
    public static func formatted(_ clock: WallClock) -> String {
        clock.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    /// "2024:05:01 14:30:00".
    public var exifText: String {
        String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    /// "2024-05-01T14:30:00", XMP's form without a zone.
    public var xmpText: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    /// These fields moved by `seconds`, carrying into minutes, days, months
    /// and years.
    public func adding(seconds: Int) -> WallClock {
        WallClock(date: date.addingTimeInterval(TimeInterval(seconds)))
    }

    public static func < (a: WallClock, b: WallClock) -> Bool { a.date < b.date }
}

/// An XMP date ("2024-05-01T14:30:00.25+09:00", or just "2024-05-01"),
/// split into the wall clock and what follows the seconds (a fraction and a
/// zone, kept as written). Partial dates (a year, a year and month) can't
/// be shifted and are left alone.
struct XMPDate: Equatable {
    var clock: WallClock
    var hasTime: Bool
    /// Everything after the seconds: ".25+09:00", "Z", or "".
    var suffix: String

    init(clock: WallClock, hasTime: Bool = true, suffix: String = "") {
        self.clock = clock
        self.hasTime = hasTime
        self.suffix = suffix
    }

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "T", maxSplits: 1)
        guard let datePart = parts.first else { return nil }
        let ymd = datePart.split(separator: "-").map(String.init)
        // Some writers put EXIF's colons in an XMP date ("2021:06:07 08:09:10"; ImageIO does, measured).
        guard ymd.count == 3, let year = Int(ymd[0]), let month = Int(ymd[1]), let day = Int(ymd[2]) else {
            guard let exif = WallClock(exif: text) else { return nil }
            self.init(clock: exif)
            return
        }
        var clock = WallClock(year: year, month: month, day: day)
        var suffix = ""
        let hasTime = parts.count == 2
        if hasTime {
            let time = String(parts[1])
            // The zone starts at the first "Z", "+" or "-" after the time.
            let zoneStart = time.firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" } ?? time.endIndex
            var clockPart = String(time[..<zoneStart])
            let zone = String(time[zoneStart...])
            var fraction = ""
            if let dot = clockPart.firstIndex(of: ".") {
                fraction = String(clockPart[dot...])
                clockPart = String(clockPart[..<dot])
            }
            let hms = clockPart.split(separator: ":").compactMap { Int($0) }
            guard hms.count >= 2 else { return nil }
            clock.hour = hms[0]
            clock.minute = hms[1]
            clock.second = hms.count > 2 ? hms[2] : 0
            suffix = fraction + zone
        }
        guard clock.isValid else { return nil }
        self.init(clock: clock, hasTime: hasTime, suffix: suffix)
    }

    var text: String {
        guard hasTime else { return String(format: "%04d-%02d-%02d", clock.year, clock.month, clock.day) }
        return clock.xmpText + suffix
    }
}

/// How Edit Metadata changes the date taken.
public enum DateChange: Hashable, Sendable {
    /// Later (positive) or earlier by this many seconds: a camera clock that
    /// was an hour out, or set to the wrong time zone.
    case shift(seconds: Int)
    /// This wall-clock date and time.
    case set(WallClock)

    /// The new value for a date that is `old` (nil when there is none).
    /// A shift of nothing is still nothing.
    public func applied(to old: WallClock?) -> WallClock? {
        switch self {
        case .shift(let seconds): old?.adding(seconds: seconds)
        case .set(let value): value
        }
    }
}

/// What Edit Metadata writes: only the fields the user changed. Several
/// files are edited with one of these, so a field left alone keeps each
/// file's own value, and keywords are added and removed rather than
/// replaced, keeping each file's others.
public struct MetadataEdit: Hashable, Sendable {
    /// nil leaves the field as it is; an empty string removes it.
    public var title: String?
    public var caption: String?
    /// Names separated by semicolons (XMP's dc:creator is a list of names,
    /// and a name may contain a comma: "Smith, Anna").
    public var creator: String?
    public var copyright: String?
    public var addedKeywords: [String] = []
    public var removedKeywords: [String] = []
    public var date: DateChange?
    public var removeLocation = false
    /// Stars as `xmp:Rating` (G2): 1 to 5, or 0 to clear a rating (a
    /// reject, -1, is kept). Nil leaves it alone.
    public var rating: Int?
    /// The tag as `digiKam:PickLabel` 3 (`MarksXMP`); nil leaves it alone.
    public var tagged: Bool?
    /// The colour label as `xmp:Label`; `.none` removes a colour's name.
    public var colorLabel: ColorLabel?

    public init(title: String? = nil, caption: String? = nil, creator: String? = nil, copyright: String? = nil,
                addedKeywords: [String] = [], removedKeywords: [String] = [], date: DateChange? = nil,
                removeLocation: Bool = false, rating: Int? = nil, tagged: Bool? = nil, colorLabel: ColorLabel? = nil) {
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.addedKeywords = addedKeywords
        self.removedKeywords = removedKeywords
        self.date = date
        self.removeLocation = removeLocation
        self.rating = rating
        self.tagged = tagged
        self.colorLabel = colorLabel
    }

    public var isEmpty: Bool {
        title == nil && caption == nil && creator == nil && copyright == nil && addedKeywords.isEmpty
            && removedKeywords.isEmpty && date == nil && !removeLocation && !changesMarks
    }

    /// Whether this changes the stars, the tag or the colour label.
    public var changesMarks: Bool { rating != nil || tagged != nil || colorLabel != nil }

    /// `fields` as they should read once this edit is written. A date shift
    /// of a photo with no date taken leaves it without one.
    public func applied(to fields: MetadataFields) -> MetadataFields {
        var result = fields
        if let title { result.title = Self.trimmed(title) }
        if let caption { result.caption = Self.trimmed(caption) }
        if let creator { result.creator = MetadataFields.creatorText(Self.names(in: creator)) }
        if let copyright { result.copyright = Self.trimmed(copyright) }
        result.keywords = keywords(applyingTo: fields.keywords)
        if let date { result.dateTaken = date.applied(to: fields.dateTaken) }
        if removeLocation { result.hasLocation = false }
        if let rating {
            let stars = min(max(rating, 0), 5)
            result.rating = stars > 0 ? stars : fields.rating.flatMap { $0 < 0 ? $0 : nil }
        }
        if let tagged {
            result.pickLabel = tagged ? MarksXMP.accepted : fields.pickLabel == MarksXMP.accepted ? nil : fields.pickLabel
        }
        if let colorLabel {
            result.label = colorLabel != .none ? colorLabel.name
                : fields.label.flatMap { ColorLabel(xmpLabel: $0) == nil ? $0 : nil }
        }
        return result
    }

    /// A file's keywords with this edit's removed and added. Removing
    /// matches exactly; adding skips a keyword the file already has in any
    /// letter case, so "Paris" isn't added beside "paris".
    public func keywords(applyingTo old: [String]) -> [String] {
        let removed = Set(removedKeywords)
        var result = old.filter { !removed.contains($0) }
        for keyword in addedKeywords.map(Self.trimmed) where !keyword.isEmpty {
            if !result.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) { result.append(keyword) }
        }
        return result
    }

    public var changesKeywords: Bool { !addedKeywords.isEmpty || !removedKeywords.isEmpty }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Anna Smith; Ben Jones" to its names.
    static func names(in text: String) -> [String] {
        text.split(separator: ";").map { trimmed(String($0)) }.filter { !$0.isEmpty }
    }
}

/// The descriptive fields Edit Metadata shows and changes, as a file holds
/// them now. XMP is read first (it is where minivu writes and where Adobe,
/// Apple and most other applications look first), then the IPTC and
/// EXIF/TIFF tags older software writes. For a file whose metadata lives in
/// an XMP sidecar (a camera raw, or a format ImageIO can't rewrite), the
/// sidecar's values are laid over the file's own.
public struct MetadataFields: Hashable, Sendable {
    public var title = ""
    public var caption = ""
    /// Names joined with "; ".
    public var creator = ""
    public var copyright = ""
    public var keywords: [String] = []
    public var dateTaken: WallClock?
    public var hasLocation = false
    /// `xmp:Rating` as written: 1 to 5 stars, 0, or -1 for a reject.
    public var rating: Int?
    /// digiKam's pick (3 is minivu's tag; see `MarksXMP`).
    public var pickLabel: Int?
    /// `xmp:Label`: a colour's name, or another application's label text.
    public var label: String?
    /// The sidecar the values were partly read from, if any.
    public var sidecar: URL?

    public init(title: String = "", caption: String = "", creator: String = "", copyright: String = "",
                keywords: [String] = [], dateTaken: WallClock? = nil, hasLocation: Bool = false,
                rating: Int? = nil, pickLabel: Int? = nil, label: String? = nil, sidecar: URL? = nil) {
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.keywords = keywords
        self.dateTaken = dateTaken
        self.hasLocation = hasLocation
        self.rating = rating
        self.pickLabel = pickLabel
        self.label = label
        self.sidecar = sidecar
    }

    /// The fields of `url`. Disk work: a header read, plus the sidecar for
    /// a file that has one (unless `includingSidecar` is false). Never
    /// decodes pixels.
    public static func read(from url: URL, includingSidecar: Bool = true) -> MetadataFields {
        var fields = MetadataFields()
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            fields = read(properties: properties, metadata: CGImageSourceCopyMetadataAtIndex(source, index, nil))
        }
        if includingSidecar, MetadataWriter.method(for: url) == .sidecar {
            let sidecar = MetadataSidecar.url(for: url)
            if let data = try? Data(contentsOf: sidecar), let metadata = CGImageMetadataCreateFromXMPData(data as CFData) {
                fields.overlay(sidecar: metadata)
                fields.sidecar = sidecar
            }
        }
        return fields
    }

    static func read(properties: [CFString: Any], metadata: CGImageMetadata?) -> MetadataFields {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        func text(_ dict: [CFString: Any]?, _ key: CFString) -> String? {
            switch dict?[key] {
            case let s as String: clean(s)
            case let a as [Any]: a.compactMap { $0 as? String }.map(clean).first { !$0.isEmpty }
            default: nil
            }
        }
        func list(_ dict: [CFString: Any]?, _ key: CFString) -> [String] {
            switch dict?[key] {
            case let a as [Any]: a.compactMap { $0 as? String }.map(clean).filter { !$0.isEmpty }
            case let s as String: clean(s).isEmpty ? [] : [clean(s)]
            default: []
            }
        }
        var fields = MetadataFields()
        fields.title = xmpText(metadata, "dc:title") ?? text(iptc, kCGImagePropertyIPTCObjectName)
            ?? text(png, kCGImagePropertyPNGTitle) ?? ""
        fields.caption = xmpText(metadata, "dc:description") ?? text(tiff, kCGImagePropertyTIFFImageDescription)
            ?? text(iptc, kCGImagePropertyIPTCCaptionAbstract) ?? text(png, kCGImagePropertyPNGDescription) ?? ""
        let creators = xmpList(metadata, "dc:creator")
        fields.creator = creatorText(!creators.isEmpty ? creators : !list(iptc, kCGImagePropertyIPTCByline).isEmpty
            ? list(iptc, kCGImagePropertyIPTCByline) : text(tiff, kCGImagePropertyTIFFArtist).map { [$0] }
            ?? text(png, kCGImagePropertyPNGAuthor).map { [$0] } ?? [])
        fields.copyright = xmpText(metadata, "dc:rights") ?? text(tiff, kCGImagePropertyTIFFCopyright)
            ?? text(iptc, kCGImagePropertyIPTCCopyrightNotice) ?? text(png, kCGImagePropertyPNGCopyright) ?? ""
        let subjects = xmpList(metadata, "dc:subject")
        fields.keywords = !subjects.isEmpty ? subjects : list(iptc, kCGImagePropertyIPTCKeywords)
        fields.dateTaken = text(exif, kCGImagePropertyExifDateTimeOriginal).flatMap(WallClock.init(exif:))
            ?? xmpDate(metadata, ["exif:DateTimeOriginal", "photoshop:DateCreated"])
        fields.hasLocation = LocationMetadata.isPresent(properties: properties, metadata: metadata)
        fields.rating = MarksXMP.rating(in: metadata)
        fields.pickLabel = MarksXMP.pickLabel(in: metadata)
        fields.label = MarksXMP.label(in: metadata)
        return fields
    }

    /// The sidecar's values win where it has them.
    mutating func overlay(sidecar metadata: CGImageMetadata) {
        if let title = Self.xmpText(metadata, "dc:title") { self.title = title }
        if let caption = Self.xmpText(metadata, "dc:description") { self.caption = caption }
        let creators = Self.xmpList(metadata, "dc:creator")
        if !creators.isEmpty { creator = Self.creatorText(creators) }
        if let rights = Self.xmpText(metadata, "dc:rights") { copyright = rights }
        if CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString) != nil {
            keywords = Self.xmpList(metadata, "dc:subject")
        }
        if let date = Self.xmpDate(metadata, ["exif:DateTimeOriginal", "photoshop:DateCreated"]) { dateTaken = date }
        if LocationMetadata.isPresent(properties: [:], metadata: metadata) { hasLocation = true }
        if let rating = MarksXMP.rating(in: metadata) { self.rating = rating }
        if let pick = MarksXMP.pickLabel(in: metadata) { pickLabel = pick }
        if let label = MarksXMP.label(in: metadata) { self.label = label }
    }

    static func creatorText(_ names: [String]) -> String {
        names.joined(separator: "; ")
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    /// A simple or language-alternative XMP value (ImageIO returns the
    /// x-default entry of an alternative), or nil when absent or blank.
    static func xmpText(_ metadata: CGImageMetadata?, _ path: String) -> String? {
        guard let metadata, let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) else {
            return nil
        }
        let text = clean(value as String)
        return text.isEmpty ? nil : text
    }

    /// The items of an XMP array (dc:subject, dc:creator), or a lone value.
    static func xmpList(_ metadata: CGImageMetadata?, _ path: String) -> [String] {
        guard let metadata, let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let items = value as? [CGImageMetadataTag] {
            return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }.map(clean).filter { !$0.isEmpty }
        }
        if let text = value as? String, !clean(text).isEmpty { return [clean(text)] }
        return []
    }

    static func xmpDate(_ metadata: CGImageMetadata?, _ paths: [String]) -> WallClock? {
        for path in paths {
            if let text = xmpText(metadata, path), let date = XMPDate(text), date.hasTime { return date.clock }
        }
        return nil
    }
}
