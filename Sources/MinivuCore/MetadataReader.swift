import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public struct MetadataItem: Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct MetadataSection: Sendable, Hashable, Identifiable {
    public var title: String
    public var items: [MetadataItem]
    public var id: String { title }

    public init(title: String, items: [MetadataItem]) {
        self.title = title
        self.items = items
    }
}

/// The few facts the browser shows under a thumbnail or in the status bar.
public struct MetadataSummary: Sendable, Equatable {
    /// Oriented (as displayed) pixel size.
    public var pixelSize: CGSize?
    public var camera: String?
    public var lens: String?
    /// e.g. "1/250 s  f/2.8  ISO 400  35 mm"
    public var exposure: String?
    public var dateTaken: Date?
    public var fileSize: Int64
    /// "JPEG", "Nikon NEF", "HEIC"...
    public var formatName: String

    public init(pixelSize: CGSize? = nil, camera: String? = nil, lens: String? = nil, exposure: String? = nil,
                dateTaken: Date? = nil, fileSize: Int64 = 0, formatName: String) {
        self.pixelSize = pixelSize
        self.camera = camera
        self.lens = lens
        self.exposure = exposure
        self.dateTaken = dateTaken
        self.fileSize = fileSize
        self.formatName = formatName
    }
}

/// Reads and formats image metadata: EXIF, TIFF, GPS, IPTC.
///
/// Everything comes from `CGImageSourceCopyPropertiesAtIndex`, which parses
/// the file's headers without decoding a single pixel, so even a 30 MB RAW
/// file costs a few milliseconds. It still reads the disk, so call these
/// off the main thread.
///
/// Photographic numbers (f/2.8, 1/250 s) are formatted the same in every
/// locale, as cameras and photo software show them; dates and file sizes
/// follow the user's locale.
public enum MetadataReader {
    // MARK: - Summary

    public static func summary(for url: URL) -> MetadataSummary {
        var summary = MetadataSummary(fileSize: fileSize(of: url), formatName: formatName(for: url))
        guard let kind = ImageFormats.kind(of: url) else { return summary }
        guard kind == .raster || kind == .raw else {
            summary.pixelSize = ImageDecoder.info(for: url)?.pixelSize
            return summary
        }
        guard let p = Properties(url: url) else { return summary }
        summary.pixelSize = p.orientedPixelSize
        summary.camera = cameraName(make: p.string(p.tiff, kCGImagePropertyTIFFMake),
                                    model: p.string(p.tiff, kCGImagePropertyTIFFModel))
        summary.lens = p.lensModel
        summary.exposure = exposureLine(p)
        summary.dateTaken = p.dateOriginal?.date ?? p.dateDigitized?.date
        return summary
    }

    /// "1/250 s  f/2.8  ISO 400  35 mm", leaving out whatever is missing.
    static func exposureLine(_ p: Properties) -> String? {
        var parts: [String] = []
        if let t = p.double(p.exif, kCGImagePropertyExifExposureTime), t > 0 { parts.append(formatShutter(t)) }
        if let f = p.double(p.exif, kCGImagePropertyExifFNumber), f > 0 { parts.append(formatAperture(f)) }
        if let iso = p.iso { parts.append("ISO \(iso)") }
        if let mm = p.double(p.exif, kCGImagePropertyExifFocalLength), mm > 0 { parts.append(formatFocalLength(mm)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    // MARK: - Sections

    /// Everything worth showing in the info panel, grouped. Empty sections
    /// and missing values are left out.
    public static func sections(for url: URL) -> [MetadataSection] {
        let p = Properties(url: url)
        var sections: [MetadataSection] = []
        func add(_ title: String, _ items: [MetadataItem]) {
            if !items.isEmpty { sections.append(MetadataSection(title: title, items: items)) }
        }
        add("File", fileItems(url))
        add("Image", imageItems(url, p))
        if let p {
            add("Camera", cameraItems(p))
            add("Exposure", exposureItems(p))
            add("Dates", dateItems(p))
            add("GPS", gpsItems(p))
            add("Description", descriptionItems(url, p))
        }
        return sections
    }

    static func fileItems(_ url: URL) -> [MetadataItem] {
        var items = Items()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        items.add("Name", url.lastPathComponent)
        items.add("Kind", formatName(for: url))
        if let size = values?.fileSize {
            let bytes = Int64(size)
            items.add("Size", "\(bytes.formatted(.byteCount(style: .file))) (\(bytes.formatted(.number)) bytes)")
        }
        items.add("Modified", values?.contentModificationDate?.formatted(date: .abbreviated, time: .standard))
        items.add("Created", values?.creationDate?.formatted(date: .abbreviated, time: .standard))
        return items.list
    }

    static func imageItems(_ url: URL, _ p: Properties?) -> [MetadataItem] {
        var items = Items()
        guard let info = ImageDecoder.info(for: url) else { return [] }
        let w = Int(info.pixelSize.width), h = Int(info.pixelSize.height)
        if w > 0, h > 0 {
            items.add("Dimensions", "\(w) × \(h)")
            items.add("Megapixels", String(format: "%.1f MP", Double(w * h) / 1_000_000))
        }
        items.add("Bit depth", "\(info.bitDepth) bits per channel")
        items.add("Colour model", info.colorModel)
        items.add("Profile", info.profileName)
        if info.kind == .raster || info.kind == .raw {
            items.add("Orientation", orientationName(info.orientation))
        }
        if let p, let dpiW = p.double(p.root, kCGImagePropertyDPIWidth),
           let dpiH = p.double(p.root, kCGImagePropertyDPIHeight) {
            items.add("DPI", dpiW == dpiH ? trimmed(dpiW) : "\(trimmed(dpiW)) × \(trimmed(dpiH))")
        }
        items.add("Alpha", info.hasAlpha ? "Yes" : "No")
        if info.pageCount > 1 { items.add(info.isAnimated ? "Frames" : "Pages", "\(info.pageCount)") }
        if info.isHDR { items.add("HDR", "Yes") }
        return items.list
    }

    static func cameraItems(_ p: Properties) -> [MetadataItem] {
        var items = Items()
        items.add("Make", p.string(p.tiff, kCGImagePropertyTIFFMake))
        items.add("Model", p.string(p.tiff, kCGImagePropertyTIFFModel))
        items.add("Lens", p.lensModel)
        items.add("Lens make", p.string(p.exif, kCGImagePropertyExifLensMake))
        items.add("Serial number", p.string(p.exif, kCGImagePropertyExifBodySerialNumber)
                  ?? p.string(p.exifAux, kCGImagePropertyExifAuxSerialNumber))
        items.add("Lens serial number", p.string(p.exif, kCGImagePropertyExifLensSerialNumber)
                  ?? p.string(p.exifAux, kCGImagePropertyExifAuxLensSerialNumber))
        return items.list
    }

    static func exposureItems(_ p: Properties) -> [MetadataItem] {
        var items = Items()
        if let t = p.double(p.exif, kCGImagePropertyExifExposureTime), t > 0 { items.add("Shutter speed", formatShutter(t)) }
        if let f = p.double(p.exif, kCGImagePropertyExifFNumber), f > 0 { items.add("Aperture", formatAperture(f)) }
        if let iso = p.iso { items.add("ISO", "\(iso)") }
        if let bias = p.double(p.exif, kCGImagePropertyExifExposureBiasValue) { items.add("Exposure bias", formatBias(bias)) }
        items.add("Program", p.int(p.exif, kCGImagePropertyExifExposureProgram).flatMap(programName))
        items.add("Metering", p.int(p.exif, kCGImagePropertyExifMeteringMode).flatMap(meteringName))
        items.add("Flash", p.int(p.exif, kCGImagePropertyExifFlash).map(flashDescription))
        if let mm = p.double(p.exif, kCGImagePropertyExifFocalLength), mm > 0 {
            var text = formatFocalLength(mm)
            if let equivalent = p.double(p.exif, kCGImagePropertyExifFocalLenIn35mmFilm), equivalent > 0,
               abs(equivalent - mm) >= 0.5 {
                text += " (\(formatFocalLength(equivalent)) in 35 mm)"
            }
            items.add("Focal length", text)
        }
        items.add("White balance", p.int(p.exif, kCGImagePropertyExifWhiteBalance).map { $0 == 1 ? "Manual" : "Auto" })
        return items.list
    }

    static func dateItems(_ p: Properties) -> [MetadataItem] {
        var items = Items()
        items.add("Original", p.dateOriginal.map(formatExifDate))
        items.add("Digitized", p.dateDigitized.map(formatExifDate))
        return items.list
    }

    static func gpsItems(_ p: Properties) -> [MetadataItem] {
        var items = Items()
        if let lat = p.double(p.gps, kCGImagePropertyGPSLatitude) {
            items.add("Latitude", formatCoordinate(lat, ref: p.string(p.gps, kCGImagePropertyGPSLatitudeRef),
                                                   positive: "N", negative: "S"))
        }
        if let lon = p.double(p.gps, kCGImagePropertyGPSLongitude) {
            items.add("Longitude", formatCoordinate(lon, ref: p.string(p.gps, kCGImagePropertyGPSLongitudeRef),
                                                    positive: "E", negative: "W"))
        }
        if let altitude = p.double(p.gps, kCGImagePropertyGPSAltitude) {
            let below = p.int(p.gps, kCGImagePropertyGPSAltitudeRef) == 1
            items.add("Altitude", "\(trimmed(altitude)) m" + (below ? " below sea level" : ""))
        }
        if let direction = p.double(p.gps, kCGImagePropertyGPSImgDirection) {
            items.add("Direction", "\(trimmed(direction))°")
        }
        return items.list
    }

    static func descriptionItems(_ url: URL, _ p: Properties) -> [MetadataItem] {
        var items = Items()
        items.add("Title", p.string(p.iptc, kCGImagePropertyIPTCObjectName))
        let descriptions = unique([p.string(p.tiff, kCGImagePropertyTIFFImageDescription),
                                   p.string(p.iptc, kCGImagePropertyIPTCCaptionAbstract),
                                   p.string(p.png, kCGImagePropertyPNGDescription)])
        items.add("Description", descriptions.joined(separator: "\n"))
        var comments = [p.string(p.exif, kCGImagePropertyExifUserComment), p.string(p.png, kCGImagePropertyPNGComment)]
        if p.type == UTType.jpeg.identifier { comments += jpegComments(url).map(Optional.some) }
        items.add("Comment", unique(comments).joined(separator: "\n"))
        items.add("Keywords", p.strings(p.iptc, kCGImagePropertyIPTCKeywords).joined(separator: ", "))
        items.add("Artist", p.string(p.tiff, kCGImagePropertyTIFFArtist)
                  ?? p.strings(p.iptc, kCGImagePropertyIPTCByline).joined(separator: ", "))
        items.add("Copyright", p.string(p.tiff, kCGImagePropertyTIFFCopyright)
                  ?? p.string(p.iptc, kCGImagePropertyIPTCCopyrightNotice))
        items.add("Software", p.string(p.tiff, kCGImagePropertyTIFFSoftware))
        return items.list
    }

    // MARK: - All properties

    /// Every property ImageIO reports, flattened to "Group.Key" = value and
    /// sorted, for the full EXIF table. Top-level values use the group
    /// "Image"; nested dictionaries (maker notes) add a level: "MakerNikon.Quality".
    public static func allProperties(for url: URL) -> [MetadataItem] {
        guard let p = Properties(url: url) else { return [] }
        var items: [MetadataItem] = []
        func walk(_ dict: [String: Any], prefix: String?) {
            for (key, value) in dict {
                let name = key.hasPrefix("{") && key.hasSuffix("}") ? String(key.dropFirst().dropLast()) : key
                if let nested = value as? [String: Any] {
                    walk(nested, prefix: prefix.map { "\($0).\(name)" } ?? name)
                } else if let text = describe(value) {
                    items.append(MetadataItem(label: "\(prefix ?? "Image").\(name)", value: text))
                }
            }
        }
        walk(p.root as NSDictionary as? [String: Any] ?? [:], prefix: nil)
        return items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// A readable value, or nil for an empty one. Long arrays (Nikon's AF
    /// point table has 300 numbers) are cut short: a table cell isn't the
    /// place to read them.
    static func describe(_ value: Any) -> String? {
        let text: String
        switch value {
        case let s as String:
            text = cleaned(s)
        case let n as NSNumber:
            text = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "Yes" : "No") : n.stringValue
        case let array as [Any]:
            text = array.compactMap(describe).joined(separator: ", ")
        case let data as Data:
            text = "\(data.count) bytes"
        default:
            text = cleaned(String(describing: value))
        }
        guard !text.isEmpty else { return nil }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    // MARK: - Formatting

    /// 0.004 -> "1/250 s", 0.4 -> "1/2.5 s", 2.5 -> "2.5 s", 30 -> "30 s".
    static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        if seconds >= 1 { return "\(trimmed(seconds)) s" }
        let denominator = 1 / seconds
        // Cameras step in thirds of a stop, so 1/2.5 and 1/1.3 are real
        // settings; long denominators are always whole numbers. `exactly`
        // because a corrupt tiny value would overflow Int and crash.
        if denominator >= 10 || abs(denominator - denominator.rounded()) < 0.1,
           let whole = Int(exactly: denominator.rounded()) {
            return "1/\(whole) s"
        }
        return "1/\(trimmed(denominator)) s"
    }

    /// 2.8 -> "f/2.8", 8 -> "f/8".
    static func formatAperture(_ f: Double) -> String { "f/\(trimmed(f))" }

    /// 0.6667 -> "+0.7 EV", -1 -> "-1 EV", 0 -> "0 EV".
    static func formatBias(_ ev: Double) -> String {
        let rounded = (ev * 10).rounded() / 10
        if rounded == 0 { return "0 EV" }
        return (rounded > 0 ? "+" : "-") + "\(trimmed(abs(rounded))) EV"
    }

    static func formatFocalLength(_ mm: Double) -> String { "\(trimmed(mm)) mm" }

    /// Degrees, minutes and seconds with a hemisphere: 48.858222 N ->
    /// "48° 51′ 29.6″ N". ImageIO gives positive numbers plus a reference
    /// letter; a negative number flips the hemisphere too.
    static func formatCoordinate(_ value: Double, ref: String?, positive: String, negative: String) -> String {
        var hemisphere = ref?.uppercased() == negative ? negative : positive
        if value < 0 { hemisphere = hemisphere == positive ? negative : positive }
        // Work in tenths of a second so rounding carries into minutes and
        // degrees (59.96″ becomes 1′ 0.0″, never 60.0″).
        guard let tenths = Int(exactly: (abs(value) * 36_000).rounded()) else {
            return "\(trimmed(value))° \(hemisphere)"   // a corrupt, absurdly large value
        }
        let degrees = tenths / 36_000
        let minutes = (tenths % 36_000) / 600
        let seconds = Double(tenths % 600) / 10
        return "\(degrees)° \(minutes)′ \(String(format: "%.1f", seconds))″ \(hemisphere)"
    }

    /// One decimal, without a trailing ".0". Locale-independent on purpose.
    static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func orientationName(_ o: CGImagePropertyOrientation) -> String {
        switch o {
        case .up: "Normal"
        case .upMirrored: "Mirrored horizontally"
        case .down: "Rotated 180°"
        case .downMirrored: "Mirrored vertically"
        case .leftMirrored: "Mirrored horizontally, rotated 270° clockwise"
        case .right: "Rotated 90° clockwise"
        case .rightMirrored: "Mirrored horizontally, rotated 90° clockwise"
        case .left: "Rotated 270° clockwise"
        @unknown default: "Unknown"
        }
    }

    static func programName(_ value: Int) -> String? {
        switch value {
        case 1: "Manual"
        case 2: "Program"
        case 3: "Aperture priority"
        case 4: "Shutter priority"
        case 5: "Creative"
        case 6: "Action"
        case 7: "Portrait"
        case 8: "Landscape"
        default: nil
        }
    }

    static func meteringName(_ value: Int) -> String? {
        switch value {
        case 1: "Average"
        case 2: "Centre-weighted"
        case 3: "Spot"
        case 4: "Multi-spot"
        case 5: "Matrix"
        case 6: "Partial"
        default: nil
        }
    }

    /// The EXIF Flash tag is a bit field: bit 0 fired, bits 3-4 the mode
    /// (1 forced on, 2 forced off, 3 auto), bit 5 "no flash function", bit
    /// 6 red-eye reduction. 16 is the common "Off, did not fire".
    static func flashDescription(_ value: Int) -> String {
        if value & 0x20 != 0 { return "No flash function" }
        let fired = value & 1 != 0 ? "fired" : "did not fire"
        var text = switch (value >> 3) & 3 {
        case 1: "On, \(fired)"
        case 2: "Off, \(fired)"
        case 3: "Auto, \(fired)"
        default: fired.prefix(1).uppercased() + fired.dropFirst()
        }
        if value & 0x40 != 0 { text += ", red-eye reduction" }
        return text
    }

    /// "NIKON CORPORATION" + "NIKON D750" -> "NIKON D750";
    /// "FUJIFILM" + "X-T5" -> "FUJIFILM X-T5". Only the brand's first word
    /// is prefixed, so "OLYMPUS IMAGING CORP." doesn't become part of the name.
    static func cameraName(make: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return make }
        guard let make, !make.isEmpty else { return model }
        let brand = make.split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            ?? make
        return model.lowercased().hasPrefix(brand.lowercased()) ? model : "\(brand) \(model)"
    }

    /// "Nikon NEF", "JPEG", "HEIC"... by extension, which is how people
    /// name formats. Unknown extensions fall back to the system's name.
    public static func formatName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let name = formatNames[ext] { return name }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }

    static let formatNames: [String: String] = [
        "jpg": "JPEG", "jpeg": "JPEG", "jpe": "JPEG", "jfif": "JPEG", "png": "PNG", "apng": "APNG", "gif": "GIF",
        "heic": "HEIC", "heif": "HEIF", "hif": "HEIF", "avif": "AVIF", "webp": "WebP", "jxl": "JPEG XL",
        "jp2": "JPEG 2000", "j2k": "JPEG 2000", "jpf": "JPEG 2000", "jpx": "JPEG 2000", "tif": "TIFF",
        "tiff": "TIFF", "bmp": "BMP", "dib": "BMP", "tga": "TGA", "ico": "Windows icon", "cur": "Windows cursor",
        "psd": "Photoshop", "exr": "OpenEXR", "icns": "Apple icon", "pdf": "PDF", "svg": "SVG",
        "cr2": "Canon CR2", "cr3": "Canon CR3", "crw": "Canon CRW", "nef": "Nikon NEF", "nrw": "Nikon NRW",
        "pef": "Pentax PEF", "raf": "Fujifilm RAF", "rwl": "Leica RWL", "mrw": "Minolta MRW",
        "orf": "Olympus ORF", "srw": "Samsung SRW", "arw": "Sony ARW", "sr2": "Sony SR2", "srf": "Sony SRF",
        "rw2": "Panasonic RW2", "dng": "DNG", "3fr": "Hasselblad 3FR", "fff": "Hasselblad FFF",
        "iiq": "Phase One IIQ", "erf": "Epson ERF", "raw": "Panasonic RAW", "rwz": "Rawzor RWZ",
    ]

    // MARK: - Dates

    /// A date as the camera recorded it. `timeZone` is the offset stored
    /// with it (EXIF 2.31 OffsetTimeOriginal) or, for older files that
    /// don't say, the Mac's own zone. Formatting in that zone shows the
    /// wall-clock time at which the photo was taken either way.
    struct ExifDate {
        var date: Date
        var timeZone: TimeZone
        var hasOffset: Bool
    }

    /// Parses "2024:05:01 14:30:00" plus optional subseconds ("25" is .25 s)
    /// and offset ("+02:00"). Tolerates "-" or "/" as the date separator.
    static func parseExifDate(_ text: String, subseconds: String? = nil, offset: String? = nil) -> ExifDate? {
        let fields = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard fields.count >= 6, fields[0] > 0, (1...12).contains(fields[1]), (1...31).contains(fields[2]) else {
            return nil
        }
        let zone = offset.flatMap(parseOffset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .current
        let components = DateComponents(year: fields[0], month: fields[1], day: fields[2],
                                        hour: fields[3], minute: fields[4], second: fields[5])
        guard var date = calendar.date(from: components) else { return nil }
        if let subseconds, let digits = Double("0." + subseconds.filter(\.isNumber)) {
            date += digits
        }
        return ExifDate(date: date, timeZone: zone ?? .current, hasOffset: zone != nil)
    }

    /// "+02:00", "-0530" or "Z" to a time zone.
    static func parseOffset(_ text: String) -> TimeZone? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
            return nil
        }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    static func formatExifDate(_ d: ExifDate) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: d.timeZone)
        var text = d.date.formatted(style)
        if d.hasOffset {
            let seconds = d.timeZone.secondsFromGMT(for: d.date)
            text += String(format: " %@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        }
        return text
    }

    // MARK: - JPEG comments

    /// Text in JPEG COM segments, which ImageIO doesn't report. Walks the
    /// segment headers from the start of the file and stops at the first
    /// scan, so it reads a few kilobytes, never the compressed image.
    static func jpegComments(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        func read(_ count: Int) -> [UInt8]? {
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        guard read(2) == [0xFF, 0xD8] else { return [] }
        var comments: [String] = []
        while let prefix = read(1), prefix[0] == 0xFF {
            // A marker may be padded with any number of extra 0xFF bytes.
            var type: UInt8 = 0xFF
            while type == 0xFF {
                guard let next = read(1) else { return comments }
                type = next[0]
            }
            if type == 0xDA || type == 0xD9 { break }                     // start of scan / end
            if type == 0x01 || (0xD0...0xD7).contains(type) { continue }   // no length field
            guard let lengthBytes = read(2) else { break }
            let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
            guard length >= 2 else { break }
            if type == 0xFE {
                guard let payload = read(length - 2) else { break }
                let text = String(bytes: payload, encoding: .utf8) ?? String(bytes: payload, encoding: .isoLatin1) ?? ""
                let clean = cleaned(text)
                if !clean.isEmpty { comments.append(clean) }
            } else {
                guard let offset = try? handle.offset(),
                      (try? handle.seek(toOffset: offset + UInt64(length - 2))) != nil else { break }
            }
        }
        return comments
    }

    // MARK: - Helpers

    static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Strips the padding cameras leave in fixed-width fields (spaces, NULs).
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    static func unique(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// Collects items, skipping missing and blank values.
    struct Items {
        var list: [MetadataItem] = []
        mutating func add(_ label: String, _ value: String?) {
            guard let value else { return }
            let clean = MetadataReader.cleaned(value)
            if !clean.isEmpty { list.append(MetadataItem(label: label, value: clean)) }
        }
    }

    /// The property dictionaries of a file's primary image, with typed
    /// lookups that tolerate the loose types found in real files (numbers
    /// stored as strings, single values stored as arrays).
    struct Properties {
        let root: [CFString: Any]
        let type: String?

        init(root: [CFString: Any], type: String? = nil) {
            self.root = root
            self.type = type
        }

        init?(url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, ImageDecoder.primaryIndex(source), nil)
                    as? [CFString: Any]
            else { return nil }
            root = props
            type = CGImageSourceGetType(source) as String?
        }

        var exif: [CFString: Any]? { root[kCGImagePropertyExifDictionary] as? [CFString: Any] }
        var exifAux: [CFString: Any]? { root[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] }
        var tiff: [CFString: Any]? { root[kCGImagePropertyTIFFDictionary] as? [CFString: Any] }
        var gps: [CFString: Any]? { root[kCGImagePropertyGPSDictionary] as? [CFString: Any] }
        var iptc: [CFString: Any]? { root[kCGImagePropertyIPTCDictionary] as? [CFString: Any] }
        var png: [CFString: Any]? { root[kCGImagePropertyPNGDictionary] as? [CFString: Any] }

        func string(_ dict: [CFString: Any]?, _ key: CFString) -> String? {
            guard let value = dict?[key] else { return nil }
            let text: String? = switch value {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            case let a as [Any]: a.first.flatMap { $0 as? String }
            default: nil
            }
            guard let text else { return nil }
            let clean = MetadataReader.cleaned(text)
            return clean.isEmpty ? nil : clean
        }

        func strings(_ dict: [CFString: Any]?, _ key: CFString) -> [String] {
            switch dict?[key] {
            case let a as [Any]: a.compactMap { $0 as? String }.map(MetadataReader.cleaned).filter { !$0.isEmpty }
            case let s as String: MetadataReader.cleaned(s).isEmpty ? [] : [MetadataReader.cleaned(s)]
            default: []
            }
        }

        /// nil for NaN and infinity too: damaged files contain both, and
        /// no photographic value is either.
        func double(_ dict: [CFString: Any]?, _ key: CFString) -> Double? {
            let value: Double? = switch dict?[key] {
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
            case let a as [Any]: (a.first as? NSNumber)?.doubleValue
            default: nil
            }
            return value.flatMap { $0.isFinite ? $0 : nil }
        }

        /// `Int(exactly:)`, because a plain `Int(double)` crashes the app on
        /// an out-of-range value.
        func int(_ dict: [CFString: Any]?, _ key: CFString) -> Int? {
            double(dict, key).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        }

        var orientedPixelSize: CGSize? {
            guard let w = double(root, kCGImagePropertyPixelWidth), let h = double(root, kCGImagePropertyPixelHeight)
            else { return nil }
            let raw = int(root, kCGImagePropertyOrientation).flatMap { UInt32(exactly: $0) } ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw)
            return orientation?.swapsAxes == true ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }

        var lensModel: String? {
            string(exif, kCGImagePropertyExifLensModel) ?? string(exifAux, kCGImagePropertyExifAuxLensModel)
        }

        var iso: Int? {
            guard let value = int(exif, kCGImagePropertyExifISOSpeedRatings), value > 0 else { return nil }
            return value
        }

        var dateOriginal: ExifDate? {
            string(exif, kCGImagePropertyExifDateTimeOriginal).flatMap {
                MetadataReader.parseExifDate($0, subseconds: string(exif, kCGImagePropertyExifSubsecTimeOriginal),
                                             offset: string(exif, kCGImagePropertyExifOffsetTimeOriginal))
            }
        }

        var dateDigitized: ExifDate? {
            string(exif, kCGImagePropertyExifDateTimeDigitized).flatMap {
                MetadataReader.parseExifDate($0, subseconds: string(exif, kCGImagePropertyExifSubsecTimeDigitized),
                                             offset: string(exif, kCGImagePropertyExifOffsetTimeDigitized))
            }
        }
    }
}
