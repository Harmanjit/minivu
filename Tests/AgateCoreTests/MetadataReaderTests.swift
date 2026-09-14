import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AgateCore

@Suite struct MetadataReaderTests {
    // MARK: - Formatting

    @Test func shutterSpeeds() {
        #expect(MetadataReader.formatShutter(0.004) == "1/250 s")
        #expect(MetadataReader.formatShutter(0.0125) == "1/80 s")
        #expect(MetadataReader.formatShutter(1.0 / 8000) == "1/8000 s")
        #expect(MetadataReader.formatShutter(1.0 / 3) == "1/3 s")
        #expect(MetadataReader.formatShutter(0.4) == "1/2.5 s")
        #expect(MetadataReader.formatShutter(0.5) == "1/2 s")
        #expect(MetadataReader.formatShutter(1) == "1 s")
        #expect(MetadataReader.formatShutter(2.5) == "2.5 s")
        #expect(MetadataReader.formatShutter(30) == "30 s")
    }

    @Test func apertureBiasAndFocalLength() {
        #expect(MetadataReader.formatAperture(2.8) == "f/2.8")
        #expect(MetadataReader.formatAperture(8) == "f/8")
        #expect(MetadataReader.formatAperture(1.4) == "f/1.4")
        #expect(MetadataReader.formatBias(0.6667) == "+0.7 EV")
        #expect(MetadataReader.formatBias(-1) == "-1 EV")
        #expect(MetadataReader.formatBias(-0.3333) == "-0.3 EV")
        #expect(MetadataReader.formatBias(0.01) == "0 EV")
        #expect(MetadataReader.formatFocalLength(35) == "35 mm")
        #expect(MetadataReader.formatFocalLength(4.25) == "4.2 mm" || MetadataReader.formatFocalLength(4.25) == "4.3 mm")
    }

    @Test func coordinatesInDegreesMinutesSeconds() {
        #expect(MetadataReader.formatCoordinate(48.858222, ref: "N", positive: "N", negative: "S") == "48° 51′ 29.6″ N")
        #expect(MetadataReader.formatCoordinate(33.8688, ref: "S", positive: "N", negative: "S") == "33° 52′ 7.7″ S")
        #expect(MetadataReader.formatCoordinate(-122.4194, ref: nil, positive: "E", negative: "W") == "122° 25′ 9.8″ W")
        // 0.99999 degrees rounds up into a whole degree, not 60″.
        #expect(MetadataReader.formatCoordinate(0.999999, ref: "E", positive: "E", negative: "W") == "1° 0′ 0.0″ E")
    }

    @Test func cameraNamesAvoidRepeatingTheBrand() {
        #expect(MetadataReader.cameraName(make: "NIKON CORPORATION", model: "NIKON D750") == "NIKON D750")
        #expect(MetadataReader.cameraName(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(MetadataReader.cameraName(make: "FUJIFILM", model: "X-T5") == "FUJIFILM X-T5")
        #expect(MetadataReader.cameraName(make: "OLYMPUS IMAGING CORP.", model: "E-M1") == "OLYMPUS E-M1")
        #expect(MetadataReader.cameraName(make: nil, model: "X100V") == "X100V")
        #expect(MetadataReader.cameraName(make: nil, model: nil) == nil)
    }

    @Test func exifDatesWithAndWithoutOffset() throws {
        let withOffset = try #require(MetadataReader.parseExifDate("2024:05:01 14:30:00", subseconds: "25", offset: "+02:00"))
        #expect(withOffset.hasOffset)
        // 14:30:00.25 at UTC+2 is 12:30:00.25 UTC.
        let utc = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                                 year: 2024, month: 5, day: 1, hour: 12, minute: 30).date!
        #expect(abs(withOffset.date.timeIntervalSince(utc) - 0.25) < 0.001)
        #expect(MetadataReader.formatExifDate(withOffset).hasSuffix("+02:00"))
        #expect(MetadataReader.formatExifDate(withOffset).contains("2:30:00") || MetadataReader.formatExifDate(withOffset).contains("14:30:00"))

        let local = try #require(MetadataReader.parseExifDate("2024:05:01 14:30:00"))
        #expect(!local.hasOffset)
        #expect(Calendar.current.component(.hour, from: local.date) == 14)

        #expect(MetadataReader.parseExifDate("    :  :     :  :  ") == nil)
        #expect(MetadataReader.parseOffset("-05:30")?.secondsFromGMT() == -19_800)
    }

    @Test func flashBits() {
        #expect(MetadataReader.flashDescription(0) == "Did not fire")
        #expect(MetadataReader.flashDescription(16) == "Off, did not fire")
        #expect(MetadataReader.flashDescription(25) == "Auto, fired")
        #expect(MetadataReader.flashDescription(9 | 0x40) == "On, fired, red-eye reduction")
        #expect(MetadataReader.flashDescription(32) == "No flash function")
    }

    /// Damaged files carry NaN, infinity and absurd numbers. They must be
    /// skipped or shown as-is, never crash the app.
    @Test func corruptNumbersDoNotCrash() {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifExposureTime: 1e-320,                 // 1/x overflows Int
            kCGImagePropertyExifFNumber: NSNumber(value: Double.nan),
            kCGImagePropertyExifISOSpeedRatings: [1e300],
            kCGImagePropertyExifFocalLength: "inf",
            kCGImagePropertyExifFlash: -1e40,
        ]
        let p = MetadataReader.Properties(root: [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyPixelWidth: 40, kCGImagePropertyPixelHeight: 30,
            kCGImagePropertyOrientation: -6,
        ])
        #expect(p.double(p.exif, kCGImagePropertyExifFNumber) == nil)
        #expect(p.double(p.exif, kCGImagePropertyExifFocalLength) == nil)
        #expect(p.int(p.exif, kCGImagePropertyExifISOSpeedRatings) == nil)
        #expect(p.iso == nil)
        #expect(p.orientedPixelSize == CGSize(width: 40, height: 30))
        #expect(MetadataReader.exposureLine(p)?.hasPrefix("1/") == true)
        #expect(!MetadataReader.exposureItems(p).isEmpty)
        #expect(MetadataReader.formatCoordinate(1e300, ref: "N", positive: "N", negative: "S").hasSuffix("N"))
    }

    /// JPEG allows 0xFF fill bytes before a marker; the comment reader must
    /// skip them rather than lose its place.
    @Test func jpegCommentAfterFillBytes() throws {
        let t = try TemporaryFolder()
        let plain = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("plain.jpg"))
        var bytes = [UInt8](try Data(contentsOf: plain))
        let comment = Array("Padded".utf8)
        let length = comment.count + 2
        // One fill byte: an odd count is what throws a two-bytes-at-a-time reader off.
        bytes.insert(contentsOf: [0xFF, 0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + comment, at: 2)
        let url = t.url.appendingPathComponent("padded.jpg")
        try Data(bytes).write(to: url)
        #expect(MetadataReader.jpegComments(url) == ["Padded"])
    }

    @Test func formatNames() {
        #expect(MetadataReader.formatName(for: URL(fileURLWithPath: "/a/b.NEF")) == "Nikon NEF")
        #expect(MetadataReader.formatName(for: URL(fileURLWithPath: "/a/b.jpeg")) == "JPEG")
        #expect(MetadataReader.formatName(for: URL(fileURLWithPath: "/a/b.heic")) == "HEIC")
    }

    // MARK: - A real file

    /// A JPEG written by ImageIO with EXIF, TIFF, GPS and IPTC metadata, plus
    /// a JPEG COM segment spliced in by hand (ImageIO can't write one).
    func makeTaggedJPEG(in folder: TemporaryFolder) throws -> URL {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 35,
            kCGImagePropertyExifFocalLenIn35mmFilm: 52, kCGImagePropertyExifExposureBiasValue: 0.6667,
            kCGImagePropertyExifDateTimeOriginal: "2024:05:01 14:30:00", kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            kCGImagePropertyExifLensModel: "NIKKOR Z 35mm f/1.8 S", kCGImagePropertyExifUserComment: "Exif comment",
            kCGImagePropertyExifExposureProgram: 3, kCGImagePropertyExifMeteringMode: 5,
            kCGImagePropertyExifFlash: 16, kCGImagePropertyExifWhiteBalance: 0,
            kCGImagePropertyExifBodySerialNumber: "123456",
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 6_2",
            kCGImagePropertyTIFFArtist: "Ansel", kCGImagePropertyTIFFCopyright: "(c) Ansel",
            kCGImagePropertyTIFFSoftware: "Agate", kCGImagePropertyTIFFImageDescription: "A gradient",
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 48.858222, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 35.5, kCGImagePropertyGPSAltitudeRef: 0,
        ]
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCKeywords: ["paris", "tower"], kCGImagePropertyIPTCObjectName: "Eiffel"]
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
            kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps, kCGImagePropertyIPTCDictionary: iptc,
        ]
        let plain = TestImages.write(TestImages.gradient(width: 64, height: 48),
                                     to: folder.url.appendingPathComponent("plain.jpg"), properties: properties)
        var bytes = [UInt8](try Data(contentsOf: plain))
        let comment = Array("Written by hand".utf8)
        let length = comment.count + 2
        bytes.insert(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + comment, at: 2)
        let url = folder.url.appendingPathComponent("tagged.jpg")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func summaryOfTaggedJPEG() throws {
        let t = try TemporaryFolder()
        let url = try makeTaggedJPEG(in: t)
        let summary = MetadataReader.summary(for: url)
        #expect(summary.pixelSize == CGSize(width: 48, height: 64))   // orientation 6 swaps axes
        #expect(summary.camera == "NIKON Z 6_2")
        #expect(summary.lens == "NIKKOR Z 35mm f/1.8 S")
        #expect(summary.exposure == "1/250 s  f/2.8  ISO 400  35 mm")
        #expect(summary.formatName == "JPEG")
        #expect(summary.fileSize == Int64(try Data(contentsOf: url).count))
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                                      year: 2024, month: 5, day: 1, hour: 12, minute: 30).date
        #expect(summary.dateTaken == expected)
    }

    @Test func sectionsOfTaggedJPEG() throws {
        let t = try TemporaryFolder()
        let sections = MetadataReader.sections(for: try makeTaggedJPEG(in: t))
        func value(_ section: String, _ label: String) -> String? {
            sections.first { $0.title == section }?.items.first { $0.label == label }?.value
        }
        #expect(sections.map(\.title) == ["File", "Image", "Camera", "Exposure", "Dates", "GPS", "Description"])
        #expect(value("File", "Name") == "tagged.jpg")
        #expect(value("File", "Kind") == "JPEG")
        #expect(value("Image", "Dimensions") == "48 × 64")
        #expect(value("Image", "Orientation") == "Rotated 90° clockwise")
        #expect(value("Image", "DPI") == "300")
        #expect(value("Image", "Alpha") == "No")
        #expect(value("Camera", "Make") == "NIKON CORPORATION")
        #expect(value("Camera", "Serial number") == "123456")
        #expect(value("Exposure", "Shutter speed") == "1/250 s")
        #expect(value("Exposure", "Aperture") == "f/2.8")
        #expect(value("Exposure", "ISO") == "400")
        #expect(value("Exposure", "Exposure bias") == "+0.7 EV")
        #expect(value("Exposure", "Program") == "Aperture priority")
        #expect(value("Exposure", "Metering") == "Matrix")
        #expect(value("Exposure", "Flash") == "Off, did not fire")
        #expect(value("Exposure", "Focal length") == "35 mm (52 mm in 35 mm)")
        #expect(value("Exposure", "White balance") == "Auto")
        #expect(value("Dates", "Original")?.hasSuffix("+02:00") == true)
        #expect(value("GPS", "Latitude") == "48° 51′ 29.6″ N")
        #expect(value("GPS", "Longitude") == "2° 17′ 40.2″ E")
        #expect(value("GPS", "Altitude") == "35.5 m")
        #expect(value("Description", "Title") == "Eiffel")
        #expect(value("Description", "Description") == "A gradient")
        #expect(value("Description", "Comment") == "Exif comment\nWritten by hand")
        #expect(value("Description", "Keywords") == "paris, tower")
        #expect(value("Description", "Artist") == "Ansel")
        #expect(value("Description", "Copyright") == "(c) Ansel")
        #expect(value("Description", "Software") == "Agate")
    }

    @Test func plainImageOmitsEmptySections() throws {
        let t = try TemporaryFolder()
        let url = TestImages.write(TestImages.gradient(alpha: true), to: t.url.appendingPathComponent("plain.png"), type: .png)
        let sections = MetadataReader.sections(for: url)
        #expect(sections.map(\.title) == ["File", "Image"])
        #expect(sections[1].items.first { $0.label == "Alpha" }?.value == "Yes")
        #expect(MetadataReader.jpegComments(url).isEmpty)
    }

    @Test func allPropertiesAreFlattenedAndSorted() throws {
        let t = try TemporaryFolder()
        let items = MetadataReader.allProperties(for: try makeTaggedJPEG(in: t))
        let table = Dictionary(items.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(table["Exif.FNumber"] == "2.8")
        #expect(table["Exif.ISOSpeedRatings"] == "400")
        #expect(table["TIFF.Make"] == "NIKON CORPORATION")
        #expect(table["GPS.LatitudeRef"] == "N")
        #expect(table["IPTC.Keywords"] == "paris, tower")
        #expect(table["Image.PixelWidth"] == "64")
        #expect(items.map(\.label) == items.map(\.label).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    static let sampleNEF = URL(fileURLWithPath: "/Users/harman/latent/TestAssets/HSB_6548.NEF")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sampleNEF.path)))
    func realNikonRaw() throws {
        let summary = MetadataReader.summary(for: Self.sampleNEF)
        #expect(summary.formatName == "Nikon NEF")
        #expect(summary.camera?.hasPrefix("NIKON") == true)
        #expect(summary.pixelSize != nil)
        #expect(summary.exposure?.contains("ISO") == true)
        let sections = MetadataReader.sections(for: Self.sampleNEF)
        #expect(sections.contains { $0.title == "Camera" })
        #expect(sections.contains { $0.title == "Exposure" })
        #expect(!MetadataReader.allProperties(for: Self.sampleNEF).isEmpty)
    }
}
