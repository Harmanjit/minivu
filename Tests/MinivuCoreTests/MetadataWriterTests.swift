import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Edit Metadata's writer (G1) and the location removal it shares with
/// Save As and Batch Convert (S4).
@Suite(.offCooperativePool) struct MetadataWriterTests {
    typealias F = ExportFixtures

    /// The formats rewritten in place, with the extension each is written under.
    static let inPlaceTypes: [(UTType, String)] = [(.jpeg, "jpg"), (.heic, "heic"), (.png, "png"), (.tiff, "tif")]

    /// A unique place name, so a leftover is found by searching the bytes.
    static let city = "Lutetiaville"
    static let oldTitle = "Zanzibar sunset draft"

    /// A file with every field Edit Metadata touches, a location in all its
    /// forms, and things that must survive (camera make, F-number, Apple
    /// maker note, rating).
    static func tagged(_ type: UTType, ext: String, in folder: URL, name: String = "photo") -> URL {
        let url = folder.appendingPathComponent("\(name).\(ext)")
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "4" as CFString)
        // In XMP as well as IPTC: HEIC keeps no IPTC record of its own, and
        // ImageIO reads these back from the XMP for it.
        CGImageMetadataSetValueWithPath(metadata, nil, "dc:title[x-default]" as CFString, oldTitle as CFString)
        let subject = CGImageMetadataTagCreate(MetadataWriter.dublinCore as CFString, "dc" as CFString, "subject" as CFString,
                                               .arrayUnordered, ["paris", "tower"] as CFArray)!
        CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, subject)
        CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:City" as CFString, city as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:Country" as CFString, "France" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "Iptc4xmpCore:Location" as CFString, "Champ de Mars" as CFString)
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                                             kCGImagePropertyExifDateTimeDigitized: "2020:01:02 03:04:05",
                                             kCGImagePropertyExifFNumber: 2.8],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON", kCGImagePropertyTIFFImageDescription: "old caption",
                                             kCGImagePropertyTIFFArtist: "Old Artist", kCGImagePropertyTIFFCopyright: "old rights"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.858, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.294, kCGImagePropertyGPSLongitudeRef: "E",
                                            kCGImagePropertyGPSAltitude: 35],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["paris", "tower"], kCGImagePropertyIPTCObjectName: oldTitle,
                                             kCGImagePropertyIPTCCity: city, kCGImagePropertyIPTCSubLocation: "Champ de Mars",
                                             kCGImagePropertyIPTCProvinceState: "Ile-de-France",
                                             kCGImagePropertyIPTCCountryPrimaryLocationCode: "FRA",
                                             kCGImagePropertyIPTCCountryPrimaryLocationName: "France"],
            kCGImagePropertyMakerAppleDictionary: ["1": 14],
        ]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(destination, TestImages.gradient(width: 64, height: 48), metadata, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func dictionary(_ url: URL, _ key: CFString) -> [String: Any] {
        F.properties(url)[key as String] as? [String: Any] ?? [:]
    }

    static func xmp(_ url: URL) -> CGImageMetadata? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
    }

    static let fullEdit = MetadataEdit(title: "New Title", caption: "A new caption", creator: "Anna Smith; Ben Jones",
                                       copyright: "© 2026 Anna Smith", addedKeywords: ["Seine", "Paris"],
                                       removedKeywords: ["tower"], date: .shift(seconds: -3 * 3600 - 5))

    // MARK: - Round trips

    @Test(arguments: inPlaceTypes.map(\.1))
    func everyFieldIsWrittenWithIdenticalPixels(_ ext: String) throws {
        let type = Self.inPlaceTypes.first { $0.1 == ext }!.0
        let t = try TemporaryFolder()
        let url = Self.tagged(type, ext: ext, in: t.url)
        let pixels = F.pixels(of: try #require(F.decode(url)))
        let scan = type == .jpeg ? try F.scanData(url) : nil
        let imageChunks = type == .png ? try Self.pngChunks(url, "IDAT") : nil

        let outcome = try MetadataWriter.apply(Self.fullEdit, to: url)
        #expect(outcome.written == url && !outcome.usedSidecar && !outcome.hadNoDateToShift)

        let fields = MetadataFields.read(from: url)
        #expect(fields.title == "New Title")
        #expect(fields.caption == "A new caption")
        #expect(fields.creator == "Anna Smith; Ben Jones")
        #expect(fields.copyright == "© 2026 Anna Smith")
        // "Paris" isn't added beside "paris"; "tower" goes.
        #expect(Set(fields.keywords) == ["paris", "Seine"])
        #expect(fields.dateTaken == WallClock(year: 2020, month: 1, day: 2, hour: 0, minute: 4, second: 0))

        // The IPTC and EXIF/TIFF equivalents other applications read.
        let iptc = Self.dictionary(url, kCGImagePropertyIPTCDictionary)
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "New Title", "\(ext)")
        #expect(Set(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []) == ["paris", "Seine"], "\(ext)")
        #expect(iptc[kCGImagePropertyIPTCByline as String] as? [String] == ["Anna Smith", "Ben Jones"], "\(ext)")
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© 2026 Anna Smith", "\(ext)")
        let tiff = Self.dictionary(url, kCGImagePropertyTIFFDictionary)
        #expect(tiff[kCGImagePropertyTIFFImageDescription as String] as? String == "A new caption", "\(ext)")
        #expect(tiff[kCGImagePropertyTIFFCopyright as String] as? String == "© 2026 Anna Smith", "\(ext)")
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON", "\(ext)")
        let exif = Self.dictionary(url, kCGImagePropertyExifDictionary)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2020:01:02 00:04:00", "\(ext)")
        #expect(exif[kCGImagePropertyExifDateTimeDigitized as String] as? String == "2020:01:02 00:04:00", "\(ext)")
        #expect((exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue == 2.8, "\(ext)")
        // Untouched: the location, the rating.
        #expect(fields.hasLocation)
        #expect(Self.xmp(url).flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) } as String? == "4")

        // Not re-encoded.
        #expect(F.pixels(of: try #require(F.decode(url))) == pixels, "\(ext)")
        if let scan { #expect(try F.scanData(url) == scan) }
        if let imageChunks { #expect(try Self.pngChunks(url, "IDAT") == imageChunks) }
        #expect(CGImageSourceGetType(CGImageSourceCreateWithURL(url as CFURL, nil)!) as String? == type.identifier)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == [url.lastPathComponent])
    }

    @Test(arguments: inPlaceTypes.map(\.1))
    func removingLocationRemovesEveryPartOfIt(_ ext: String) throws {
        let type = Self.inPlaceTypes.first { $0.1 == ext }!.0
        let t = try TemporaryFolder()
        let url = Self.tagged(type, ext: ext, in: t.url)
        #expect(MetadataFields.read(from: url).hasLocation)
        try MetadataWriter.apply(MetadataEdit(removeLocation: true), to: url)
        Self.expectNoLocation(url, ext)
        // Everything else stays.
        let fields = MetadataFields.read(from: url)
        #expect(fields.title == Self.oldTitle && Set(fields.keywords) == ["paris", "tower"], "\(ext)")
        #expect(Self.dictionary(url, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String == "NIKON")
        #expect(Self.dictionary(url, kCGImagePropertyExifDictionary)[kCGImagePropertyExifDateTimeOriginal as String] as? String
            == "2020:01:02 03:04:05")
        if type != .png {
            // A PNG keeps only what XMP can say; the maker note has no XMP form.
            #expect(F.properties(url)[kCGImagePropertyMakerAppleDictionary as String] != nil, "\(ext)")
        }
    }

    /// Property by property: nothing of the location in the GPS
    /// dictionary, the XMP or the IPTC record, nor anywhere in the bytes.
    static func expectNoLocation(_ url: URL, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let properties = F.properties(url)
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil, "\(label)", sourceLocation: sourceLocation)
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        for key in LocationMetadata.placeIPTCKeys {
            #expect(iptc[key as String] == nil, "\(label) \(key)", sourceLocation: sourceLocation)
        }
        let metadata = xmp(url)
        for path in LocationMetadata.placeXMPPaths {
            #expect(metadata.flatMap { CGImageMetadataCopyTagWithPath($0, nil, path as CFString) } == nil,
                    "\(label) \(path)", sourceLocation: sourceLocation)
        }
        let gps = metadata.map(LocationMetadata.gpsPaths) ?? []
        #expect(gps.isEmpty, "\(label) \(gps)", sourceLocation: sourceLocation)
        #expect(!MetadataFields.read(from: url).hasLocation, "\(label)", sourceLocation: sourceLocation)
        let bytes = (try? Data(contentsOf: url)) ?? Data()
        #expect(bytes.range(of: Data(city.utf8)) == nil, "\(label): the city is still in the file", sourceLocation: sourceLocation)
    }

    @Test(arguments: inPlaceTypes.map(\.1))
    func clearingAFieldRemovesItEverywhere(_ ext: String) throws {
        let type = Self.inPlaceTypes.first { $0.1 == ext }!.0
        let t = try TemporaryFolder()
        let url = Self.tagged(type, ext: ext, in: t.url)
        try MetadataWriter.apply(MetadataEdit(title: "", removedKeywords: ["paris", "tower"]), to: url)
        let fields = MetadataFields.read(from: url)
        #expect(fields.title.isEmpty && fields.keywords.isEmpty, "\(ext)")
        let iptc = Self.dictionary(url, kCGImagePropertyIPTCDictionary)
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] == nil && iptc[kCGImagePropertyIPTCKeywords as String] == nil, "\(ext)")
        // PNG's own copy used to leave the old XMP's tail in the file.
        #expect((try Data(contentsOf: url)).range(of: Data(Self.oldTitle.utf8)) == nil, "\(ext)")
        #expect(fields.caption == "old caption", "\(ext)")
    }

    @Test func everyPageOfAMultiPageTIFFStays() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("pages.tif")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, TestImages.gradient(width: 64, height: 48),
                                   [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.5]] as CFDictionary)
        CGImageDestinationAddImage(destination, TestImages.gradient(width: 32, height: 24, alpha: true), nil)
        #expect(CGImageDestinationFinalize(destination))
        func page(_ index: Int) -> [UInt8] {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            return F.pixels(of: CGImageSourceCreateImageAtIndex(source, index, nil)!)
        }
        let pages = [page(0), page(1)]
        try MetadataWriter.apply(MetadataEdit(title: "Two pages", removeLocation: true), to: url)
        #expect(CGImageSourceGetCount(CGImageSourceCreateWithURL(url as CFURL, nil)!) == 2)
        #expect([page(0), page(1)] == pages)
        #expect(MetadataFields.read(from: url).title == "Two pages")
        #expect(F.properties(url)[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func tiffScrubberRefusesWhatItCantFollow() {
        var notTIFF = Data("hello, world".utf8)
        #expect(!TIFFScrubber.zeroUnreferencedBytes(in: &notTIFF))
        #expect(notTIFF == Data("hello, world".utf8))
        // A directory said to be past the end of the file.
        var broken = Data([0x49, 0x49, 42, 0, 0xFF, 0, 0, 0, 1, 2, 3])
        #expect(!TIFFScrubber.zeroUnreferencedBytes(in: &broken))
    }

    // MARK: - Gain maps

    static func gainMapData(_ url: URL) -> Data? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [String: Any],
               let data = info[kCGImageAuxiliaryDataInfoData as String] as? Data { return data }
        }
        return nil
    }

    @Test func gainMapsSurviveInJPEGAndHEIC() throws {
        let t = try TemporaryFolder()
        let base = CIImage(cgImage: TestImages.gradient(width: 256, height: 128))
        // Core Image derives the gain map from the HDR picture (since macOS
        // 27.2 a ready-made `.hdrGainMapImage` is left out).
        let hdr = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])
        let jpeg = t.url.appendingPathComponent("gainmap.jpg")
        try CIContext().writeJPEGRepresentation(of: base, to: jpeg, colorSpace: F.displayP3, options: [.hdrImage: hdr])
        try JPEGComment.write("gm", to: jpeg)
        let heic = t.url.appendingPathComponent("gainmap.heic")
        try CIContext().writeHEIFRepresentation(of: base, to: heic, format: .RGBA8, colorSpace: F.displayP3, options: [.hdrImage: hdr])

        for url in [jpeg, heic] {
            let before = try #require(Self.gainMapData(url), "\(url.lastPathComponent)")
            let pixels = F.pixels(of: try #require(F.decode(url)))
            try MetadataWriter.apply(MetadataEdit(title: "HDR", addedKeywords: ["bright"], date: .set(WallClock(year: 2025, month: 7, day: 1, hour: 12))), to: url)
            #expect(Self.gainMapData(url) == before, "\(url.lastPathComponent)")
            #expect(F.pixels(of: try #require(F.decode(url))) == pixels)
            #expect(MetadataFields.read(from: url).title == "HDR")
            #expect(MetadataFields.read(from: url).dateTaken == WallClock(year: 2025, month: 7, day: 1, hour: 12))
        }
        // The JPEG keeps its comment and an MPF index that points at the gain map.
        #expect(JPEGComment.read(from: jpeg) == "gm")
        let data = try Data(contentsOf: jpeg)
        let offsets = try #require(ExportJPEGCommentTests().mpfImageOffsets(in: data))
        #expect(offsets.count == 2)
        let position = offsets[1].headerPosition + offsets[1].offset
        #expect(data[position] == 0xFF && data[position + 1] == 0xD8)
    }

    // MARK: - JPEG header

    @Test func jpegKeepsOtherPhotoshopResourcesAndSegments() throws {
        let t = try TemporaryFolder()
        let url = Self.tagged(.jpeg, ext: "jpg", in: t.url)
        try JPEGComment.write("caption by hand", to: url)
        // Add a resolution resource (0x03ED) beside the IPTC record, and an
        // APP segment ImageIO doesn't know.
        var data = try Data(contentsOf: url)
        let resolution = Data(Array("8BIM".utf8) + [0x03, 0xED, 0, 0, 0, 0, 0, 4, 1, 2, 3, 4])
        let custom = Data([0xFF, 0xEA, 0, 6] + Array("abcd".utf8))
        data = try data.withUnsafeBytes { raw -> Data in
            let header = try #require(JPEGComment.header(of: raw))
            var pieces: [JPEGComment.Piece] = []
            var hadPhotoshop = false
            for segment in header.segments {
                if LosslessTransform.hasSignature(segment, marker: 0xED, MetadataWriter.photoshopSignature, in: raw) {
                    let payload = Data(raw[(segment.payloadStart + MetadataWriter.photoshopSignature.count)..<segment.end])
                    let resources = try #require(MetadataWriter.photoshopResources(payload))
                    #expect(resources.contains { $0.id == 0x0404 })
                    pieces.append(.bytes(try MetadataWriter.photoshopSegment(resources.map(\.bytes) + [resolution])))
                    hadPhotoshop = true
                } else {
                    pieces.append(.segment(segment))
                }
            }
            #expect(hadPhotoshop)
            pieces.append(.bytes(custom))
            var out = JPEGComment.assemble(pieces, from: raw, scanStart: header.scanStart!)
            out.append(contentsOf: raw[header.scanStart!...])
            return out
        }
        try data.write(to: url)

        try MetadataWriter.apply(MetadataEdit(title: "Kept around", removeLocation: true), to: url)
        let after = try Data(contentsOf: url)
        #expect(after.range(of: resolution) != nil)
        #expect(after.range(of: custom) != nil)
        #expect(JPEGComment.read(from: url) == "caption by hand")
        #expect(MetadataFields.read(from: url).title == "Kept around")
        Self.expectNoLocation(url, "jpeg")
    }

    @Test func splicingRefusesChangedImageData() throws {
        let t = try TemporaryFolder()
        let original = try Data(contentsOf: TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("a.jpg")))
        var reencoded = original
        reencoded[reencoded.count - 10] ^= 0xFF
        #expect(throws: MetadataWriter.Error.copyFailed("the image data would have changed")) {
            try MetadataWriter.splicedHeader(from: reencoded, into: original)
        }
    }

    // MARK: - Dates

    @Test func datesShiftAndSet() throws {
        let t = try TemporaryFolder()
        let url = Self.tagged(.jpeg, ext: "jpg", in: t.url)
        // Later across a month and year end.
        let shifted = try MetadataWriter.apply(MetadataEdit(date: .shift(seconds: -(2 * 86_400 + 3 * 3600 + 4 * 60 + 6))), to: url)
        #expect(!shifted.hadNoDateToShift)
        #expect(MetadataFields.read(from: url).dateTaken == WallClock(year: 2019, month: 12, day: 30, hour: 23, minute: 59, second: 59))
        try MetadataWriter.apply(MetadataEdit(date: .set(WallClock(year: 2024, month: 2, day: 29, hour: 18, minute: 30))), to: url)
        let exif = Self.dictionary(url, kCGImagePropertyExifDictionary)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2024:02:29 18:30:00")
        #expect(exif[kCGImagePropertyExifDateTimeDigitized as String] as? String == "2024:02:29 18:30:00")
        let xmp = try #require(Self.xmp(url))
        #expect(MetadataFields.xmpText(xmp, "photoshop:DateCreated").flatMap(XMPDate.init)?.clock
            == WallClock(year: 2024, month: 2, day: 29, hour: 18, minute: 30))
        let iptc = Self.dictionary(url, kCGImagePropertyIPTCDictionary)
        #expect(iptc[kCGImagePropertyIPTCDateCreated as String] as? String == "20240229")
    }

    @Test func shiftingAPhotoWithoutADateSaysSo() throws {
        let t = try TemporaryFolder()
        let url = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("plain.jpg"))
        let outcome = try MetadataWriter.apply(MetadataEdit(title: "x", date: .shift(seconds: 60)), to: url)
        #expect(outcome.hadNoDateToShift)
        #expect(MetadataFields.read(from: url).dateTaken == nil)
        #expect(MetadataFields.read(from: url).title == "x")
    }

    @Test func wallClockAndXMPDates() throws {
        let clock = try #require(WallClock(exif: "2024:05:01 14:30:00"))
        #expect(clock.exifText == "2024:05:01 14:30:00" && clock.xmpText == "2024-05-01T14:30:00")
        #expect(clock.adding(seconds: 10 * 3600).exifText == "2024:05:02 00:30:00")
        #expect(WallClock(date: clock.date) == clock)
        #expect(WallClock(exif: "0000:00:00 00:00:00") == nil)
        let zoned = try #require(XMPDate("2024-05-01T14:30:00.25+09:00"))
        #expect(zoned.clock == clock && zoned.suffix == ".25+09:00")
        #expect(XMPDate(clock: clock.adding(seconds: 60), suffix: zoned.suffix).text == "2024-05-01T14:31:00.25+09:00")
        #expect(XMPDate("2024-05-01T14:30-05:00")?.suffix == "-05:00")
        #expect(XMPDate("2024-05-01")?.hasTime == false)
        #expect(XMPDate("2024:05:01 14:30:00")?.clock == clock)
        #expect(XMPDate("2024") == nil)
        #expect(DateChange.shift(seconds: 5).applied(to: nil) == nil)
        #expect(DateChange.set(clock).applied(to: nil) == clock)
    }

    // MARK: - Edits

    @Test func keywordsAreAddedAndRemovedPerFile() {
        let edit = MetadataEdit(addedKeywords: ["Seine", " river ", "PARIS"], removedKeywords: ["tower"])
        #expect(edit.keywords(applyingTo: ["paris", "tower", "night"]) == ["paris", "night", "Seine", "river"])
        #expect(edit.keywords(applyingTo: []) == ["Seine", "river", "PARIS"])
        #expect(MetadataEdit().isEmpty && !MetadataEdit(removeLocation: true).isEmpty)
        var fields = MetadataFields(title: "a", creator: "x", keywords: ["k"], hasLocation: true)
        fields = MetadataEdit(creator: " Anna ;; Ben ", removeLocation: true).applied(to: fields)
        #expect(fields.creator == "Anna; Ben" && fields.title == "a" && !fields.hasLocation)
    }

    @Test func methodsByKind() {
        func method(_ name: String) -> MetadataWriter.Method { MetadataWriter.method(for: URL(fileURLWithPath: "/x/" + name)) }
        for name in ["a.jpg", "a.JPEG", "a.heic", "a.png", "a.tif"] { #expect(method(name) == .inPlace, "\(name)") }
        for name in ["a.NEF", "a.dng", "a.cr3", "a.gif", "a.webp", "a.bmp"] { #expect(method(name) == .sidecar, "\(name)") }
        for name in ["a.pdf", "a.svg", "a.txt"] { #expect(method(name) == .unsupported, "\(name)") }
        #expect(MetadataSidecar.url(for: URL(fileURLWithPath: "/x/IMG_1.CR2")).path == "/x/IMG_1.xmp")
    }

    // MARK: - Sidecars

    @Test func formatsImageIOCantRewriteGetASidecar() throws {
        let t = try TemporaryFolder()
        let gif = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("anim.gif"), type: .gif)
        let bytes = try Data(contentsOf: gif)
        let outcome = try MetadataWriter.apply(MetadataEdit(title: "Moving", caption: "Loop", addedKeywords: ["gif"],
                                                            date: .set(WallClock(year: 2001, month: 2, day: 3))), to: gif)
        let sidecar = t.url.appendingPathComponent("anim.xmp")
        #expect(outcome.usedSidecar && outcome.written == sidecar)
        #expect(try Data(contentsOf: gif) == bytes)
        let fields = MetadataFields.read(from: gif)
        #expect(fields.title == "Moving" && fields.caption == "Loop" && fields.keywords == ["gif"])
        #expect(fields.dateTaken == WallClock(year: 2001, month: 2, day: 3))
        #expect(fields.sidecar == sidecar)
        // Lightroom's tags are there.
        let xmp = try #require(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData))
        #expect(MetadataFields.xmpText(xmp, "exif:DateTimeOriginal") != nil)
        #expect(OwnWrites.isOwn(sidecar, stamp: FileStamp.read(sidecar)))
        // A second edit merges into the sidecar.
        try MetadataWriter.apply(MetadataEdit(copyright: "mine", removedKeywords: ["gif"]), to: gif)
        let again = MetadataFields.read(from: gif)
        #expect(again.title == "Moving" && again.copyright == "mine" && again.keywords.isEmpty)
    }

    @Test func rawFilesAreNeverModified() throws {
        let t = try TemporaryFolder()
        // A DNG by name: never written, whatever is inside.
        let dng = Self.tagged(.tiff, ext: "dng", in: t.url, name: "camera")
        let tiffNamedRaw = try Data(contentsOf: dng)
        let sidecar = t.url.appendingPathComponent("camera.xmp")
        // An existing sidecar from Lightroom keeps what minivu doesn't touch.
        let existing = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(existing, nil, "xmp:Rating" as CFString, "5" as CFString)
        try (CGImageMetadataCreateXMPData(existing, nil)! as Data).write(to: sidecar)

        let outcome = try MetadataWriter.apply(MetadataEdit(title: "Raw title", date: .shift(seconds: 3600), removeLocation: true), to: dng)
        #expect(outcome.usedSidecar && outcome.locationLeftInFile && !outcome.hadNoDateToShift)
        #expect(try Data(contentsOf: dng) == tiffNamedRaw)
        let xmp = try #require(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData))
        #expect(MetadataFields.xmpText(xmp, "xmp:Rating") == "5")
        let fields = MetadataFields.read(from: dng)
        #expect(fields.title == "Raw title")
        #expect(fields.dateTaken == WallClock(year: 2020, month: 1, day: 2, hour: 4, minute: 4, second: 5))
        #expect(!LocationMetadata.isPresent(properties: [:], metadata: xmp))
    }

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleNEF)))
    func aRawRenamedTIFFGetsASidecar() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("disguised.tif")
        try FileManager.default.copyItem(at: F.sampleNEF, to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        let outcome = try MetadataWriter.apply(MetadataEdit(title: "t"), to: url)
        #expect(outcome.usedSidecar)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == size)
    }

    @Test func anUnreadableSidecarIsLeftAlone() throws {
        let t = try TemporaryFolder()
        let gif = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("a.gif"), type: .gif)
        let sidecar = t.url.appendingPathComponent("a.xmp")
        try Data("not xmp at all".utf8).write(to: sidecar)
        #expect(throws: MetadataWriter.Error.unreadableSidecar("a.xmp")) {
            try MetadataWriter.apply(MetadataEdit(title: "t"), to: gif)
        }
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "not xmp at all")
    }

    // MARK: - The write itself

    @Test func writesAreAtomicAndKeepTheFilesAttributes() throws {
        let t = try TemporaryFolder()
        let url = Self.tagged(.jpeg, ext: "jpg", in: t.url)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: old, .posixPermissions: 0o640], ofItemAtPath: url.path)
        #expect(setxattr(url.path, "com.example.minivu-test", "kept", 4, 0, 0) == 0)
        try MetadataWriter.apply(MetadataEdit(caption: "attributes"), to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.creationDate] as? Date == old)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        var value = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(url.path, "com.example.minivu-test", &value, 8, 0, 0) == 4)
        #expect(OwnWrites.isOwn(url, stamp: FileStamp.read(url)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["photo.jpg"])
    }

    @Test func pdfAndUnknownFilesAreRefused() throws {
        let t = try TemporaryFolder()
        let text = t.url.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        #expect(throws: MetadataWriter.Error.unsupported) { try MetadataWriter.apply(MetadataEdit(title: "t"), to: text) }
    }

    // MARK: - Helpers

    static func pngChunks(_ url: URL, _ type: String) throws -> [Data] {
        let data = try Data(contentsOf: url)
        return try #require(PNGChunks.parse(data)).filter { $0.type == type }.map { data[$0.range] }
    }
}
