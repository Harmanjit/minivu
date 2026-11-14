import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes Edit Metadata's changes: title, caption, keywords, creator,
/// copyright, the date taken and the location, into the file itself
/// without re-encoding a pixel, or into an XMP sidecar beside it.
///
/// **In the file** (JPEG, HEIC/HEIF, PNG, TIFF): the descriptive fields are
/// written as XMP (dc:title, dc:description, dc:subject, dc:creator,
/// dc:rights) and ImageIO mirrors them into their IPTC and EXIF/TIFF
/// equivalents (ObjectName, Caption/Abstract and ImageDescription,
/// Keywords, By-line and Artist, CopyrightNotice and Copyright), so
/// software that reads only the older tags sees the change too. The date
/// taken is written as XMP's photoshop:DateCreated and xmp:CreateDate,
/// which ImageIO turns into EXIF DateTimeOriginal and DateTimeDigitized and
/// IPTC's DateCreated and DigitalCreationDate. All measured on macOS 27.
///
/// How, per format, from what was measured:
/// - The file's whole XMP view is copied, changed and handed back to
///   `CGImageDestinationCopyImageSource` without merging. Merging is
///   ImageIO's other mode, but it can't delete a tag in HEIC, PNG or TIFF
///   (its documented null value removes nothing there), and Remove location
///   and clearing a field are deletions. The full copy keeps what has no
///   XMP form, such as Apple's maker note and the EXIF auxiliary tags.
///   `kCGImageMetadataShouldExcludeGPS` drops the GPS directory with it.
/// - JPEG: the copy is made in memory and only its EXIF, XMP and IPTC are
///   spliced into the original's header, as `LosslessTransform` does for
///   orientation, so comments, unknown APPn segments, an HDR gain map and
///   its MPF index stay exactly as they were. The image data is compared
///   byte for byte first: a JPEG is never re-encoded.
/// - HEIC and TIFF: ImageIO's copy is the new file. Their pixels are copied,
///   not decoded, and an HEIC gain map is carried over (both measured). A
///   TIFF copy writes a shorter IPTC record over the old one and leaves the
///   old one's end in the file, unreferenced but readable in the bytes (a
///   removed city name, measured), so every byte no directory points at
///   is zeroed before the file is written (`TIFFScrubber`).
/// - PNG: ImageIO's copy is not used. It writes the new XMP over the old
///   one's space and leaves the end of the old text in the file (a title
///   meant to be removed still readable in the bytes), and its eXIf chunk
///   keeps the old GPS directory (both measured). Instead the new eXIf and
///   XMP chunks come from a blank image of the same size that ImageIO
///   encodes with the new metadata, and replace the old ones; every other
///   chunk, the image data among them, is copied as it was.
///
/// **In a sidecar** (camera raw files, which minivu never modifies, and
/// formats ImageIO can't rewrite: GIF, BMP, WebP and the rest): the changes
/// go into "name.xmp" beside the file, the convention Lightroom and Bridge
/// use, merged into the sidecar already there. Reading metadata lays the
/// sidecar over the file's own (`MetadataFields`).
///
/// Every write is atomic (`SafeFileWriter`, so creation date, permissions
/// and extended attributes are kept), checked by reading the result back
/// before it replaces anything, and recorded as minivu's own
/// (`OwnWrites`). Callers queue it on the app's `FileWriteQueue`.
public enum MetadataWriter {
    public enum Method: Equatable, Sendable {
        /// Rewritten in the file without re-encoding.
        case inPlace
        /// Written to an XMP sidecar beside the file.
        case sidecar
        /// Neither: PDF, SVG and files that aren't images.
        case unsupported
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case unsupported
        case unreadable
        /// ImageIO's copy failed or the result couldn't be assembled; the
        /// file is unchanged.
        case copyFailed(String)
        /// The file written back didn't say what was asked; it wasn't used
        /// and the original is unchanged.
        case didNotTake(String)
        /// An existing sidecar couldn't be read as XMP, so it is left alone
        /// rather than replaced.
        case unreadableSidecar(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported: "Metadata can’t be written for this kind of file."
            case .unreadable: "The file couldn’t be read."
            case .copyFailed(let detail): "The metadata couldn’t be written (\(detail))."
            case .didNotTake(let field): "The new \(field) didn’t take, so the file was left as it was."
            case .unreadableSidecar(let name): "The sidecar “\(name)” isn’t readable XMP, so it was left as it was."
            }
        }
    }

    /// What one file's write did.
    public struct Outcome: Equatable, Sendable {
        /// The file written: the image, or its sidecar.
        public var written: URL
        public var usedSidecar: Bool
        /// Remove location was asked of a file minivu doesn't modify (a
        /// camera raw) that has a location of its own, which stays in it.
        public var locationLeftInFile = false
        /// A date shift was asked of a file with no date taken to shift.
        public var hadNoDateToShift = false

        public init(written: URL, usedSidecar: Bool, locationLeftInFile: Bool = false, hadNoDateToShift: Bool = false) {
            self.written = written
            self.usedSidecar = usedSidecar
            self.locationLeftInFile = locationLeftInFile
            self.hadNoDateToShift = hadNoDateToShift
        }
    }

    /// How `url` would be written, by kind and extension only, so it is
    /// cheap enough for menu validation and a large selection. `apply`
    /// checks the contents: a camera raw renamed .tif still gets a sidecar.
    public static func method(for url: URL) -> Method {
        switch ImageFormats.kind(of: url) {
        case .raw?: .sidecar
        case .raster?: LosslessTransform.canApply(to: url) ? .inPlace : .sidecar
        case .pdf?, .svg?, nil: .unsupported
        }
    }

    /// Writes `edit` into `url` or its sidecar. Disk work: call it off the
    /// main thread, through the write queue.
    @discardableResult
    public static func apply(_ edit: MetadataEdit, to url: URL) throws -> Outcome {
        switch method(for: url) {
        case .unsupported: throw Error.unsupported
        case .sidecar: return try writeSidecar(edit, for: url)
        case .inPlace: break
        }
        // Extensions can lie: a raw renamed .jpg, a GIF named .png.
        guard !LosslessTransform.isCameraRaw(url) else { return try writeSidecar(edit, for: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            throw Error.unreadable
        }
        guard let type = UTType(typeIdentifier as String), LosslessTransform.isSupported(type) else {
            return try writeSidecar(edit, for: url)
        }
        if type.conforms(to: .jpeg) {
            try writeJPEG(edit, to: url, typeIdentifier: typeIdentifier)
        } else if type.conforms(to: .png) {
            try writePNG(edit, to: url)
        } else {
            try writeCopy(edit, to: url, from: source, typeIdentifier: typeIdentifier)
        }
        OwnWrites.record(url)
        return Outcome(written: url, usedSidecar: false,
                       hadNoDateToShift: hasNoDateToShift(edit, MetadataFields.read(from: url, includingSidecar: false)))
    }

    // MARK: - The new metadata

    /// The file's metadata with `edit` applied, as a whole XMP view for a
    /// write without merging, and what the file should read as afterwards.
    struct Rewrite {
        var metadata: CGMutableImageMetadata
        var expected: MetadataFields
        var options: [CFString: Any]
    }

    static func rewrite(_ edit: MetadataEdit, source: CGImageSource) -> Rewrite {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let original = CGImageSourceCopyMetadataAtIndex(source, index, nil)
        let metadata = original.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        let current = MetadataFields.read(properties: properties, metadata: original)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let digitized = (exif?[kCGImagePropertyExifDateTimeDigitized] as? String).flatMap(WallClock.init(exif:))
            ?? MetadataFields.xmpDate(original, ["exif:DateTimeDigitized", "xmp:CreateDate"])
        apply(edit, to: metadata, current: current, digitized: digitized, sidecar: false)
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        if edit.removeLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
        return Rewrite(metadata: metadata, expected: edit.applied(to: current), options: options)
    }

    static let dublinCore = "http://purl.org/dc/elements/1.1/"

    /// Changes `metadata` (a file's XMP view, or a sidecar's) as `edit`
    /// asks. `current` is what the file reads as now, which keyword edits
    /// and date shifts start from. A sidecar gets the EXIF namespace's date
    /// tags as well, which Lightroom reads from sidecars; in a file ImageIO
    /// writes the EXIF tags themselves from the photoshop: and xmp: ones.
    static func apply(_ edit: MetadataEdit, to metadata: CGMutableImageMetadata, current: MetadataFields,
                      digitized: WallClock?, sidecar: Bool) {
        setAlternative(edit.title, at: "dc:title", in: metadata)
        setAlternative(edit.caption, at: "dc:description", in: metadata)
        setAlternative(edit.copyright, at: "dc:rights", in: metadata)
        if let creator = edit.creator {
            setList(MetadataEdit.names(in: creator), at: "creator", type: .arrayOrdered, in: metadata)
        }
        if edit.changesKeywords {
            setList(edit.keywords(applyingTo: current.keywords), at: "subject", type: .arrayUnordered, in: metadata)
        }
        if let change = edit.date {
            let original = change.applied(to: current.dateTaken)
            // A set date is both when the photo was taken and when it was
            // digitised, as cameras record it.
            let digital = change.applied(to: digitized)
            setDate(original, paths: ["photoshop:DateCreated", "exif:DateTimeOriginal", "photoshop:DateTimeOriginal"],
                    creating: sidecar ? ["photoshop:DateCreated", "exif:DateTimeOriginal"] : ["photoshop:DateCreated"],
                    in: metadata)
            setDate(digital, paths: ["xmp:CreateDate", "exif:DateTimeDigitized"],
                    creating: sidecar ? ["xmp:CreateDate", "exif:DateTimeDigitized"] : ["xmp:CreateDate"],
                    in: metadata)
        }
        if edit.removeLocation { LocationMetadata.strip(metadata) }
    }

    /// A language alternative (title, description, rights) as its default
    /// entry. Other languages a file may hold go with the old value: one
    /// field in the sheet can't say which of them it replaces.
    static func setAlternative(_ value: String?, at path: String, in metadata: CGMutableImageMetadata) {
        guard let value else { return }
        CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        let text = MetadataEdit.trimmed(value)
        guard !text.isEmpty else { return }
        CGImageMetadataSetValueWithPath(metadata, nil, "\(path)[x-default]" as CFString, text as CFString)
    }

    /// An XMP array of `values` in the Dublin Core namespace, or none when empty.
    static func setList(_ values: [String], at name: String, type: CGImageMetadataType,
                        in metadata: CGMutableImageMetadata) {
        let path = "dc:\(name)" as CFString
        CGImageMetadataRemoveTagWithPath(metadata, nil, path)
        guard !values.isEmpty,
              let tag = CGImageMetadataTagCreate(dublinCore as CFString, "dc" as CFString, name as CFString, type, values as CFArray)
        else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
    }

    /// Writes `clock` into each of `paths` the metadata already has, keeping
    /// its fraction of a second and zone, and creates those in `creating`.
    static func setDate(_ clock: WallClock?, paths: [String], creating: [String], in metadata: CGMutableImageMetadata) {
        guard let clock else { return }
        for path in paths {
            let old = MetadataFields.xmpText(metadata, path).flatMap(XMPDate.init)
            guard old != nil || creating.contains(path) else { continue }
            // Always with a time: EXIF's date tags need one.
            let suffix = old?.hasTime == true ? old?.suffix ?? "" : ""
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString,
                                            XMPDate(clock: clock, suffix: suffix).text as CFString)
        }
    }

    static func hasNoDateToShift(_ edit: MetadataEdit, _ before: MetadataFields) -> Bool {
        if case .shift? = edit.date { return before.dateTaken == nil }
        return false
    }

    /// Throws unless `actual` (the file written, read back) says what
    /// `expected` does for every field `edit` changed.
    static func verify(_ actual: MetadataFields, expected: MetadataFields, edit: MetadataEdit,
                       checkLocation: Bool = true) throws {
        if edit.title != nil, actual.title != expected.title { throw Error.didNotTake("title") }
        if edit.caption != nil, actual.caption != expected.caption { throw Error.didNotTake("caption") }
        if edit.creator != nil, actual.creator != expected.creator { throw Error.didNotTake("creator") }
        if edit.copyright != nil, actual.copyright != expected.copyright { throw Error.didNotTake("copyright") }
        if edit.changesKeywords, Set(actual.keywords) != Set(expected.keywords) { throw Error.didNotTake("keywords") }
        if edit.date != nil, let date = expected.dateTaken, actual.dateTaken != date { throw Error.didNotTake("date taken") }
        if checkLocation, edit.removeLocation, actual.hasLocation { throw Error.didNotTake("location removal") }
    }

    // MARK: - HEIC and TIFF

    static func writeCopy(_ edit: MetadataEdit, to url: URL, from source: CGImageSource, typeIdentifier: CFString) throws {
        let rewrite = rewrite(edit, source: source)
        let isTIFF = UTType(typeIdentifier as String)?.conforms(to: .tiff) == true
        try SafeFileWriter.replace(url) { temp in
            if isTIFF {
                // In memory, so the bytes ImageIO's copy leaves behind can be
                // cleared before anything reaches the disk.
                let copied = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(copied, typeIdentifier,
                                                                         CGImageSourceGetCount(source), nil) else {
                    throw Error.copyFailed("no destination for \(typeIdentifier)")
                }
                try copy(source, into: destination, options: rewrite.options)
                var data = copied as Data
                guard TIFFScrubber.zeroUnreferencedBytes(in: &data) else {
                    throw Error.copyFailed("the TIFF’s structure couldn’t be followed")
                }
                try data.write(to: temp, options: .withoutOverwriting)
            } else {
                guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, typeIdentifier,
                                                                         CGImageSourceGetCount(source), nil) else {
                    throw Error.copyFailed("no destination for \(typeIdentifier)")
                }
                try copy(source, into: destination, options: rewrite.options)
            }
            try verify(MetadataFields.read(from: temp, includingSidecar: false), expected: rewrite.expected, edit: edit)
        }
    }

    static func copy(_ source: CGImageSource, into destination: CGImageDestination, options: [CFString: Any]) throws {
        var error: Unmanaged<CFError>?
        // CopyImageSource finalizes the destination itself.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw Error.copyFailed(reason)
        }
    }

    // MARK: - JPEG

    static func writeJPEG(_ edit: MetadataEdit, to url: URL, typeIdentifier: CFString) throws {
        // Read, not mapped: the file is about to be replaced. The source is
        // made from these same bytes, so both sides of the splice agree.
        let original = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw Error.unreadable }
        let rewrite = rewrite(edit, source: source)
        let copied = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(copied, typeIdentifier, CGImageSourceGetCount(source), nil) else {
            throw Error.copyFailed("no destination for \(typeIdentifier)")
        }
        try copy(source, into: destination, options: rewrite.options)
        let spliced = try splicedHeader(from: copied as Data, into: original)
        try SafeFileWriter.replace(url) { temp in
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
            }
            let handle = try FileHandle(forWritingTo: temp)
            do {
                try handle.write(contentsOf: spliced.header)
                try handle.write(contentsOf: original[(original.startIndex + spliced.scanStart)...])
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try verify(MetadataFields.read(from: temp, includingSidecar: false), expected: rewrite.expected, edit: edit)
        }
    }

    static let photoshopSignature = Array("Photoshop 3.0\0".utf8)
    static let xmpExtensionSignature = Array("http://ns.adobe.com/xmp/extension/\0".utf8)

    /// The original JPEG's header with its metadata replaced by that of
    /// ImageIO's `rewritten` copy, and where the original's scan starts.
    /// Everything from the first scan on must be identical in both, or this
    /// throws: the promise that the image data is untouched.
    ///
    /// Replaced: the EXIF segment, the XMP segment and any extended-XMP
    /// segments (all taken from the copy, wherever the original had its
    /// first of them, or after JFIF), and the IPTC record inside the
    /// Photoshop APP13 segment. That segment can hold other resources too
    /// (clipping paths, print settings), so only the IPTC record and its
    /// digest are swapped and the rest kept. Every other segment, COM
    /// comments and an MPF gain-map index among them, stays; the index's
    /// offsets are corrected for the new size by `JPEGComment.assemble`.
    static func splicedHeader(from rewritten: Data, into original: Data) throws -> (header: Data, scanStart: Int) {
        try original.withUnsafeBytes { o -> (header: Data, scanStart: Int) in
            try rewritten.withUnsafeBytes { r -> (header: Data, scanStart: Int) in
                guard let oldHeader = JPEGComment.header(of: o), let oldScan = oldHeader.scanStart,
                      let newHeader = JPEGComment.header(of: r), let newScan = newHeader.scanStart else {
                    throw Error.copyFailed("unreadable JPEG header")
                }
                let tail = o.count - oldScan
                guard tail == r.count - newScan, memcmp(o.baseAddress! + oldScan, r.baseAddress! + newScan, tail) == 0 else {
                    throw Error.copyFailed("the image data would have changed")
                }
                func isMetadata(_ segment: JPEGComment.Segment, in raw: UnsafeRawBufferPointer) -> Bool {
                    LosslessTransform.isEXIF(segment, in: raw) || LosslessTransform.isXMP(segment, in: raw)
                        || LosslessTransform.hasSignature(segment, marker: 0xE1, xmpExtensionSignature, in: raw)
                }
                func isPhotoshop(_ segment: JPEGComment.Segment, in raw: UnsafeRawBufferPointer) -> Bool {
                    LosslessTransform.hasSignature(segment, marker: 0xED, photoshopSignature, in: raw)
                }
                let newMetadata = newHeader.segments.filter { isMetadata($0, in: r) }
                    .map { JPEGComment.Piece.bytes(Data(r[$0.start..<$0.end])) }
                var newIPTC: Data?
                if let segment = newHeader.segments.first(where: { isPhotoshop($0, in: r) }) {
                    let payload = Data(r[(segment.payloadStart + photoshopSignature.count)..<segment.end])
                    guard let resources = photoshopResources(payload) else { throw Error.copyFailed("unreadable IPTC") }
                    newIPTC = resources.first { $0.id == 0x0404 }?.bytes
                }

                var pieces: [JPEGComment.Piece] = []
                var metadataPlaced = false
                for segment in oldHeader.segments {
                    if isMetadata(segment, in: o) {
                        if !metadataPlaced { pieces += newMetadata }
                        metadataPlaced = true
                    } else if isPhotoshop(segment, in: o) {
                        let payload = Data(o[(segment.payloadStart + photoshopSignature.count)..<segment.end])
                        guard var resources = photoshopResources(payload) else {
                            throw Error.copyFailed("unreadable Photoshop data")
                        }
                        // 0x0404 is the IPTC record, 0x0425 its MD5 digest,
                        // which would no longer match it.
                        resources.removeAll { $0.id == 0x0404 || $0.id == 0x0425 }
                        if let iptc = newIPTC {
                            resources.append((0x0404, iptc))
                            newIPTC = nil
                        }
                        if !resources.isEmpty { pieces.append(.bytes(try photoshopSegment(resources.map(\.bytes)))) }
                    } else {
                        pieces.append(.segment(segment))
                    }
                }
                var inserted: [JPEGComment.Piece] = metadataPlaced ? [] : newMetadata
                if let iptc = newIPTC { inserted.append(.bytes(try photoshopSegment([iptc]))) }
                let afterJFIF = pieces.prefix {
                    if case .segment(let segment) = $0 { segment.marker == 0xE0 } else { false }
                }.count
                pieces.insert(contentsOf: inserted, at: afterJFIF)
                return (JPEGComment.assemble(pieces, from: o, scanStart: oldScan), oldScan)
            }
        }
    }

    /// The resources of a Photoshop APP13 payload (after its signature),
    /// each as its id and its whole block: "8BIM", the id, a padded Pascal
    /// name, a length and the data, padded to an even length. Nil when they
    /// don't parse.
    ///
    /// The format pads odd-sized data with a zero byte, but ImageIO leaves
    /// the IPTC record unpadded when it is odd (measured), so a missing pad
    /// is accepted, and added to the block returned: a resource put after
    /// it must start on an even offset for stricter readers.
    static func photoshopResources(_ payload: Data) -> [(id: UInt16, bytes: Data)]? {
        let bytes = [UInt8](payload)
        var resources: [(id: UInt16, bytes: Data)] = []
        var position = 0
        while position < bytes.count {
            // Trailing padding after the last resource is allowed.
            if bytes[position...].allSatisfy({ $0 == 0 }) { break }
            guard position + 8 <= bytes.count, bytes[position..<position + 4].elementsEqual(Array("8BIM".utf8)) else {
                return nil
            }
            let id = UInt16(bytes[position + 4]) << 8 | UInt16(bytes[position + 5])
            let nameLength = Int(bytes[position + 6])
            let sizeAt = position + 6 + ((nameLength + 2) & ~1)   // the length byte and name, padded to even
            guard sizeAt + 4 <= bytes.count else { return nil }
            let size = Int(bytes[sizeAt]) << 24 | Int(bytes[sizeAt + 1]) << 16 | Int(bytes[sizeAt + 2]) << 8 | Int(bytes[sizeAt + 3])
            let dataEnd = sizeAt + 4 + size
            guard size >= 0, dataEnd <= bytes.count else { return nil }
            var block = Data(bytes[position..<dataEnd])
            var next = dataEnd
            if size & 1 == 1 {
                block.append(0)
                if next < bytes.count, bytes[next] == 0 { next += 1 }
            }
            resources.append((id, block))
            position = next
        }
        return resources
    }

    /// An APP13 segment holding `resources`.
    static func photoshopSegment(_ resources: [Data]) throws -> Data {
        var payload = Data(photoshopSignature)
        for resource in resources { payload.append(resource) }
        let length = payload.count + 2
        guard length <= 0xFFFF else { throw Error.copyFailed("the IPTC record is too large") }
        var segment = Data([0xFF, 0xED, UInt8(length >> 8), UInt8(length & 0xFF)])
        segment.append(payload)
        return segment
    }

    // MARK: - PNG

    /// The largest PNG whose blank stand-in (1 bit a pixel) is made for its
    /// metadata: 64 MB, a 512 MP image. Past that the write is refused.
    static let pngStandInLimit = 64 << 20

    static func writePNG(_ edit: MetadataEdit, to url: URL) throws {
        let original = try Data(contentsOf: url)
        guard let chunks = PNGChunks.parse(original),
              let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw Error.unreadable
        }
        let rewrite = rewrite(edit, source: source)
        let replacement = try metadataChunks(rewrite.metadata, width: width, height: height)
        let legacy = legacyTextKeywords(for: edit)
        let rebuilt = PNGChunks.replacingMetadata(in: original, chunks: chunks, with: replacement, droppingText: legacy)
        try SafeFileWriter.replace(url) { temp in
            try rebuilt.write(to: temp, options: .withoutOverwriting)
            try verify(MetadataFields.read(from: temp, includingSidecar: false), expected: rewrite.expected, edit: edit)
        }
    }

    /// PNG's own text keywords for the fields being changed (tEXt, iTXt or
    /// zTXt chunks other software writes). They are dropped rather than
    /// left saying the old value; the XMP holds the new one.
    static func legacyTextKeywords(for edit: MetadataEdit) -> Set<String> {
        var keywords: Set<String> = []
        if edit.title != nil { keywords.insert("Title") }
        if edit.caption != nil { keywords.insert("Description") }
        if edit.creator != nil { keywords.insert("Author") }
        if edit.copyright != nil { keywords.insert("Copyright") }
        return keywords
    }

    /// The eXIf and XMP chunks ImageIO writes for `metadata` into a blank
    /// image of the file's size (so the EXIF pixel dimensions it fills in
    /// are the file's): one bit a pixel, all zero, which compresses to
    /// almost nothing.
    static func metadataChunks(_ metadata: CGImageMetadata, width: Int, height: Int) throws -> [Data] {
        let bytesPerRow = (width + 7) / 8
        guard bytesPerRow.multipliedReportingOverflow(by: height).partialValue <= pngStandInLimit,
              !bytesPerRow.multipliedReportingOverflow(by: height).overflow else {
            throw Error.copyFailed("the image is too large")
        }
        guard let provider = CGDataProvider(data: Data(count: bytesPerRow * height) as CFData),
              let blank = CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Error.copyFailed("no stand-in image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Error.copyFailed("no PNG destination")
        }
        CGImageDestinationAddImageAndMetadata(destination, blank, metadata, nil)
        guard CGImageDestinationFinalize(destination), let chunks = PNGChunks.parse(data as Data) else {
            throw Error.copyFailed("the metadata couldn’t be encoded")
        }
        return chunks.filter { PNGChunks.isMetadata($0, in: data as Data) }.map { Data((data as Data)[$0.range]) }
    }

    // MARK: - Sidecars

    static func writeSidecar(_ edit: MetadataEdit, for url: URL) throws -> Outcome {
        let sidecar = MetadataSidecar.url(for: url)
        let own = MetadataFields.read(from: url, includingSidecar: false)
        let current = MetadataFields.read(from: url)
        var existing: CGImageMetadata?
        if FileManager.default.fileExists(atPath: sidecar.path) {
            guard let data = try? Data(contentsOf: sidecar), let parsed = CGImageMetadataCreateFromXMPData(data as CFData) else {
                throw Error.unreadableSidecar(sidecar.lastPathComponent)
            }
            existing = parsed
        }
        let metadata = existing.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        let digitized = MetadataFields.xmpDate(existing, ["exif:DateTimeDigitized", "xmp:CreateDate"])
            ?? fileDigitizedDate(url)
        apply(edit, to: metadata, current: current, digitized: digitized, sidecar: true)
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else {
            throw Error.copyFailed("the sidecar couldn’t be encoded")
        }
        // What the file will read as: its own values with the new sidecar over them.
        var result = own
        if let parsed = CGImageMetadataCreateFromXMPData(data as CFData) { result.overlay(sidecar: parsed) }
        try verify(result, expected: edit.applied(to: current), edit: edit, checkLocation: false)
        if edit.removeLocation, LocationMetadata.isPresent(properties: [:], metadata: CGImageMetadataCreateFromXMPData(data as CFData)) {
            throw Error.didNotTake("location removal")
        }
        try SafeFileWriter.write(data, to: sidecar)
        OwnWrites.record(sidecar)
        return Outcome(written: sidecar, usedSidecar: true, locationLeftInFile: edit.removeLocation && own.hasLocation,
                       hadNoDateToShift: hasNoDateToShift(edit, current))
    }

    static func fileDigitizedDate(_ url: URL) -> WallClock? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return (exif?[kCGImagePropertyExifDateTimeDigitized] as? String).flatMap(WallClock.init(exif:))
    }
}

/// Where a file's XMP sidecar lives: "IMG_0001.xmp" beside "IMG_0001.CR2",
/// the name Lightroom, Bridge and Capture One use, so they and minivu share
/// one. (A raw and a JPEG of the same name share it too, which is the
/// convention's intent: the JPEG is written in place and never reads it.)
public enum MetadataSidecar {
    public static func url(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }
}

/// The chunks of a PNG file, enough to swap its metadata: each is a length,
/// a four-letter type, the data and a CRC, and a chunk copied whole stays
/// valid wherever it goes.
enum PNGChunks {
    struct Chunk: Equatable {
        var type: String
        /// The whole chunk, length to CRC.
        var range: Range<Int>
        /// The data alone.
        var data: Range<Int>
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The chunks in order, or nil if this isn't a whole PNG.
    static func parse(_ bytes: Data) -> [Chunk]? {
        let b = [UInt8](bytes)
        guard b.count >= 8, b[0..<8].elementsEqual(signature) else { return nil }
        var chunks: [Chunk] = []
        var position = 8
        while position + 12 <= b.count {
            let length = Int(b[position]) << 24 | Int(b[position + 1]) << 16 | Int(b[position + 2]) << 8 | Int(b[position + 3])
            let end = position + 12 + length
            guard length >= 0, end <= b.count, let type = String(bytes: b[position + 4..<position + 8], encoding: .ascii) else {
                return nil
            }
            chunks.append(Chunk(type: type, range: position..<end, data: position + 8..<position + 8 + length))
            position = end
            if type == "IEND" { return chunks }
        }
        return nil
    }

    /// The keyword of a tEXt, zTXt or iTXt chunk: the bytes before its first NUL.
    static func keyword(_ chunk: Chunk, in bytes: Data) -> String? {
        guard ["tEXt", "zTXt", "iTXt"].contains(chunk.type) else { return nil }
        let data = bytes[chunk.data]
        guard let nul = data.firstIndex(of: 0) else { return nil }
        return String(data: data[data.startIndex..<nul], encoding: .isoLatin1)
    }

    /// The chunks minivu's metadata write replaces: EXIF (eXIf), XMP (an
    /// iTXt keyed "XML:com.adobe.xmp") and the raw EXIF, IPTC and XMP
    /// profiles ImageMagick keeps in text chunks, which would be stale
    /// second copies of what was rewritten.
    static func isMetadata(_ chunk: Chunk, in bytes: Data) -> Bool {
        if chunk.type == "eXIf" { return true }
        guard let keyword = keyword(chunk, in: bytes) else { return false }
        return keyword == "XML:com.adobe.xmp" || keyword.hasPrefix("Raw profile type ")
    }

    /// `original` with its metadata chunks and any text chunks keyed
    /// `droppingText` removed, and `replacement` put where the first of them
    /// was, or just before the image data if that comes first.
    static func replacingMetadata(in original: Data, chunks: [Chunk], with replacement: [Data],
                                  droppingText: Set<String>) -> Data {
        var out = Data(signature)
        var placed = false
        for chunk in chunks {
            // Before the image data (and an animation's control chunks),
            // where eXIf must be: at the first chunk replaced, or else there.
            if !placed, ["IDAT", "acTL", "fcTL"].contains(chunk.type) {
                replacement.forEach { out.append($0) }
                placed = true
            }
            let dropped = isMetadata(chunk, in: original) || keyword(chunk, in: original).map(droppingText.contains) == true
            if dropped {
                if !placed { replacement.forEach { out.append($0) } }
                placed = true
                continue
            }
            out.append(original[chunk.range])
        }
        return out
    }
}
