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
    /// Localized, for display.
    public var title: String
    public var items: [MetadataItem]
    /// The English title, the same in every language: "File", "Description"…
    public var key: String
    public var id: String { key }

    public init(title: String, items: [MetadataItem], key: String? = nil) {
        self.title = title
        self.items = items
        self.key = key ?? title
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
        sectionsAndFields(for: url).sections
    }

    /// The sections, and the fields Edit Metadata edits for a file whose
    /// metadata can be written (nil otherwise): the info panel's keyword
    /// editor works on them. One read of the file for both.
    public static func sectionsAndFields(for url: URL) -> (sections: [MetadataSection], fields: MetadataFields?) {
        let p = Properties(url: url)
        var sections: [MetadataSection] = []
        func add(_ title: LocalizedStringResource, _ items: [MetadataItem]) {
            if !items.isEmpty {
                sections.append(MetadataSection(title: localized(title), items: items, key: title.key))
            }
        }
        add("File", fileItems(url))
        // A video's header, read once for the sections below as well.
        let videoMetadata = ImageFormats.isVideo(url) ? VideoFrames.metadata(for: url) : nil
        if ImageFormats.isVideo(url) {
            add("Video", videoItems(url, metadata: videoMetadata))
        } else {
            add("Image", imageItems(url, p))
        }
        let writable = MetadataWriter.method(for: url) != .unsupported
        let fields = p != nil || writable ? MetadataFields.read(from: url) : nil
        if ImageFormats.isVideo(url), let metadata = videoMetadata {
            add("Camera", videoCameraItems(metadata))
            add("Dates", videoDateItems(metadata))
            add("GPS", videoLocationItems(metadata))
        }
        if let p, let fields {
            add("Camera", cameraItems(p))
            add("Exposure", exposureItems(p))
            add("Dates", dateItems(p, sidecarDate: fields.sidecar == nil ? nil : fields.dateTaken))
            add("GPS", gpsItems(p))
            add("Description", descriptionItems(url, p, fields))
        }
        return (sections, writable ? fields : nil)
    }

    static func fileItems(_ url: URL) -> [MetadataItem] {
        var items = Items()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        items.add("Name", url.lastPathComponent)
        items.add(.init("Kind", comment: "File format"), formatName(for: url))
        if let size = values?.fileSize {
            let bytes = Int64(size)
            items.add("Size", localized(.init("\(bytes.formatted(.byteCount(style: .file))) (\(bytes) bytes)",
                                             comment: "File size: rounded, then exact")))
        }
        items.add(.init("Modified", comment: "Date the file was last changed"), values?.contentModificationDate?.formatted(date: .abbreviated, time: .standard))
        items.add(.init("Created", comment: "Date the file was created"), values?.creationDate?.formatted(date: .abbreviated, time: .standard))
        return items.list
    }

    static func imageItems(_ url: URL, _ p: Properties?) -> [MetadataItem] {
        var items = Items()
        guard let info = ImageDecoder.info(for: url) else { return [] }
        let w = Int(saturating: info.pixelSize.width), h = Int(saturating: info.pixelSize.height)
        if w > 0, h > 0 {
            items.add("Dimensions", "\(w) × \(h)")
            // In Double: the product of two sizes a file declared can be
            // past what an Int holds.
            items.add("Megapixels", String(format: "%.1f MP", Double(w) * Double(h) / 1_000_000))
        }
        items.add("Bit depth", localized("\(info.bitDepth) bits per channel"))
        items.add("Color model", info.colorModel)
        items.add(.init("Profile", comment: "Colour profile"), info.profileName)
        if info.kind == .raster || info.kind == .raw {
            items.add("Orientation", orientationName(info.orientation))
        }
        if let p, let dpiW = p.double(p.root, kCGImagePropertyDPIWidth),
           let dpiH = p.double(p.root, kCGImagePropertyDPIHeight) {
            items.add("DPI", dpiW == dpiH ? trimmed(dpiW) : "\(trimmed(dpiW)) × \(trimmed(dpiH))")
        }
        items.add("Alpha", info.hasAlpha ? localized(.init("Yes", comment: "Info panel value")) : localized(.init("No", comment: "Info panel value")))
        if info.pageCount > 1 {
            items.add(info.isAnimated ? .init("Frames", comment: "Info panel label: frames in an animation") : "Pages", "\(info.pageCount)")
        }
        if info.isHDR { items.add("HDR", localized(.init("Yes", comment: "Info panel value"))) }
        return items.list
    }

    /// A video's size, length, frame rate, codec and data rate (G18), from
    /// its tracks and header.
    static func videoItems(_ url: URL, metadata: VideoMetadata? = nil) -> [MetadataItem] {
        var items = Items()
        guard let info = VideoFrames.info(for: url) else { return [] }
        let w = Int(saturating: info.pixelSize.width), h = Int(saturating: info.pixelSize.height)
        items.add("Dimensions", "\(w) × \(h)")
        items.add("Duration", VideoFrames.durationText(info.duration))
        items.add("Frame rate", info.frameRate.map { "\(trimmed(($0 * 100).rounded() / 100)) fps" })
        items.add("Codec", info.codec)
        items.add("Data rate", metadata?.dataRate.map(formatDataRate))
        items.add("Audio", info.hasAudio ? localized(.init("Yes", comment: "Info panel value")) : localized(.init("No", comment: "Info panel value")))
        if info.isHDR { items.add("HDR", localized(.init("Yes", comment: "Info panel value"))) }
        if !info.isPlayable { items.add("Playable", localized(.init("No", comment: "Info panel value"))) }
        return items.list
    }

    /// "12.4 Mbit/s" or "850 kbit/s", in decimal units as QuickTime Player
    /// gives them.
    static func formatDataRate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "0 kbit/s" }
        if bitsPerSecond >= 1_000_000 { return "\(trimmed(bitsPerSecond / 1_000_000)) Mbit/s" }
        return "\(Int((bitsPerSecond / 1000).rounded())) kbit/s"
    }

    static func videoCameraItems(_ m: VideoMetadata) -> [MetadataItem] {
        var items = Items()
        items.add(.init("Make", comment: "Camera or lens maker"), m.make)
        items.add(.init("Model", comment: "Camera model"), m.model)
        return items.list
    }

    /// When recording began, on the camera's clock where the file keeps its
    /// zone (with the offset, as for a photo), otherwise in this Mac's zone.
    static func videoDateItems(_ m: VideoMetadata) -> [MetadataItem] {
        var items = Items()
        items.add(.init("Original", comment: "Date the photo was taken"), m.created.map {
            formatExifDate(ExifDate(date: $0.date, timeZone: $0.timeZone ?? .current, hasOffset: $0.timeZone != nil))
        })
        return items.list
    }

    /// Shown only: a video's location can't be removed (see the video
    /// feature notes).
    static func videoLocationItems(_ m: VideoMetadata) -> [MetadataItem] {
        guard let location = m.location else { return [] }
        var items = Items()
        items.add("Latitude", formatCoordinate(location.latitude, ref: nil, positive: "N", negative: "S"))
        items.add("Longitude", formatCoordinate(location.longitude, ref: nil, positive: "E", negative: "W"))
        if let altitude = location.altitude {
            items.add("Altitude", altitude < 0 ? localized("\(trimmed(-altitude)) m below sea level") : "\(trimmed(altitude)) m")
        }
        return items.list
    }

    static func cameraItems(_ p: Properties) -> [MetadataItem] {
        var items = Items()
        items.add(.init("Make", comment: "Camera or lens maker"), p.string(p.tiff, kCGImagePropertyTIFFMake))
        items.add(.init("Model", comment: "Camera model"), p.string(p.tiff, kCGImagePropertyTIFFModel))
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
        items.add(.init("Program", comment: "Camera exposure program"), p.int(p.exif, kCGImagePropertyExifExposureProgram).flatMap(programName))
        items.add("Metering", p.int(p.exif, kCGImagePropertyExifMeteringMode).flatMap(meteringName))
        items.add("Flash", p.int(p.exif, kCGImagePropertyExifFlash).map(flashDescription))
        if let mm = p.double(p.exif, kCGImagePropertyExifFocalLength), mm > 0 {
            var text = formatFocalLength(mm)
            if let equivalent = p.double(p.exif, kCGImagePropertyExifFocalLenIn35mmFilm), equivalent > 0,
               abs(equivalent - mm) >= 0.5 {
                text = localized(.init("\(text) (\(formatFocalLength(equivalent)) in 35 mm)",
                                       comment: "A focal length, then its 35 mm film equivalent"))
            }
            items.add("Focal length", text)
        }
        items.add("White balance", p.int(p.exif, kCGImagePropertyExifWhiteBalance).map {
            $0 == 1 ? localized(.init("Manual", comment: "Camera setting")) : localized(.init("Auto", comment: "Camera setting: automatic"))
        })
        return items.list
    }

    /// `sidecarDate` is the date taken an XMP sidecar gives a file minivu
    /// doesn't modify (Edit Metadata's date shift of a camera raw), which
    /// is shown in place of the file's own.
    static func dateItems(_ p: Properties, sidecarDate: WallClock? = nil) -> [MetadataItem] {
        var items = Items()
        if let sidecarDate, sidecarDate != p.dateOriginal.map({ WallClock(date: $0.date, in: $0.timeZone) }) {
            items.add(.init("Original", comment: "Date the photo was taken"), WallClock.formatted(sidecarDate))
        } else {
            items.add(.init("Original", comment: "Date the photo was taken"), p.dateOriginal.map(formatExifDate))
        }
        items.add(.init("Digitized", comment: "Date the photo was digitized"), p.dateDigitized.map(formatExifDate))
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
            items.add("Altitude", below ? localized("\(trimmed(altitude)) m below sea level") : "\(trimmed(altitude)) m")
        }
        if let direction = p.double(p.gps, kCGImagePropertyGPSImgDirection) {
            items.add(.init("Direction", comment: "Compass direction the camera faced"), "\(trimmed(direction))°")
        }
        return items.list
    }

    /// Title, caption, keywords, creator and copyright as Edit Metadata
    /// reads them (`MetadataFields`: XMP first, then IPTC and EXIF/TIFF, with
    /// an XMP sidecar laid over a file that has one), plus the comments and
    /// software, which it doesn't edit.
    /// The Description section's keywords label, as shown.
    public static var keywordsLabel: String { localized("Keywords") }

    static func descriptionItems(_ url: URL, _ p: Properties, _ fields: MetadataFields) -> [MetadataItem] {
        var items = Items()
        items.add(.init("Title", comment: "Image title (metadata)"), fields.title)
        items.add("Description", fields.caption)
        var comments = [p.string(p.exif, kCGImagePropertyExifUserComment), p.string(p.png, kCGImagePropertyPNGComment)]
        if p.type == UTType.jpeg.identifier { comments += jpegComments(url).map(Optional.some) }
        items.add(.init("Comment", comment: "Image comment (metadata)"), unique(comments).joined(separator: "\n"))
        items.add("Keywords", fields.keywords.joined(separator: ", "))
        items.add(.init("Artist", comment: "Image creator (metadata)"), fields.creator)
        items.add("Copyright", fields.copyright)
        items.add("Software", p.string(p.tiff, kCGImagePropertyTIFFSoftware))
        items.add(.init("Sidecar", comment: "XMP sidecar file name"), fields.sidecar?.lastPathComponent)
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
        case .up: localized(.init("Normal", comment: "Image orientation: not rotated"))
        case .upMirrored: localized("Mirrored horizontally")
        case .down: localized("Rotated 180°")
        case .downMirrored: localized("Mirrored vertically")
        case .leftMirrored: localized("Mirrored horizontally, rotated 270° clockwise")
        case .right: localized("Rotated 90° clockwise")
        case .rightMirrored: localized("Mirrored horizontally, rotated 90° clockwise")
        case .left: localized("Rotated 270° clockwise")
        @unknown default: localized(.init("Unknown", comment: "Image orientation"))
        }
    }

    static func programName(_ value: Int) -> String? {
        switch value {
        case 1: localized(.init("Manual", comment: "Camera setting"))
        case 2: localized(.init("Program", comment: "Camera exposure program"))
        case 3: localized("Aperture priority")
        case 4: localized("Shutter priority")
        case 5: localized(.init("Creative", comment: "Camera exposure program"))
        case 6: localized(.init("Action", comment: "Camera exposure program: sports"))
        case 7: localized(.init("metadata.program.portrait", defaultValue: "Portrait", comment: "Camera exposure program: portrait mode"))
        case 8: localized(.init("metadata.program.landscape", defaultValue: "Landscape", comment: "Camera exposure program: landscape mode"))
        default: nil
        }
    }

    static func meteringName(_ value: Int) -> String? {
        switch value {
        case 1: localized("Average")
        case 2: localized("Center-weighted")
        case 3: localized("Spot")
        case 4: localized("Multi-spot")
        case 5: localized("Matrix")
        case 6: localized("Partial")
        default: nil
        }
    }

    /// The EXIF Flash tag is a bit field: bit 0 fired, bits 3-4 the mode
    /// (1 forced on, 2 forced off, 3 auto), bit 5 "no flash function", bit
    /// 6 red-eye reduction. 16 is the common "Off, did not fire".
    static func flashDescription(_ value: Int) -> String {
        if value & 0x20 != 0 { return localized(.init("No flash function", comment: "Camera flash")) }
        let fired = value & 1 != 0
        let text = switch ((value >> 3) & 3, fired) {
        case (1, true): localized(.init("On, fired", comment: "Camera flash"))
        case (1, false): localized(.init("On, did not fire", comment: "Camera flash"))
        case (2, true): localized(.init("Off, fired", comment: "Camera flash"))
        case (2, false): localized(.init("Off, did not fire", comment: "Camera flash"))
        case (3, true): localized(.init("Auto, fired", comment: "Camera flash"))
        case (3, false): localized(.init("Auto, did not fire", comment: "Camera flash"))
        case (_, true): localized(.init("Fired", comment: "Camera flash"))
        case (_, false): localized(.init("Did not fire", comment: "Camera flash"))
        }
        guard value & 0x40 != 0 else { return text }
        return localized(.init("\(text), red-eye reduction", comment: "%@ is the flash's mode, such as “On, fired”"))
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

    /// Text in JPEG COM segments, which ImageIO doesn't report. The segment
    /// walk lives in `JPEGComment`, shared with the comment writer; it stops
    /// at the first scan, so only the header pages of the file are read.
    static func jpegComments(_ url: URL) -> [String] {
        JPEGComment.commentTexts(at: url).map(cleaned).filter { !$0.isEmpty }
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
        mutating func add(_ label: LocalizedStringResource, _ value: String?) {
            guard let value else { return }
            let clean = MetadataReader.cleaned(value)
            if !clean.isEmpty { list.append(MetadataItem(label: localized(label), value: clean)) }
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
            Perf.count("file.open")
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
