import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import MinivuCore

@Suite struct ExportJPEGCommentTests {
    typealias F = ExportFixtures

    func plainJPEG(in t: TemporaryFolder, name: String = "plain.jpg") -> URL {
        TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent(name),
                         properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Maker"]])
    }

    /// Splices raw bytes in at an offset, for building files ImageIO won't write.
    func insert(_ bytes: [UInt8], at offset: Int, into url: URL) throws {
        var data = [UInt8](try Data(contentsOf: url))
        data.insert(contentsOf: bytes, at: offset)
        try Data(data).write(to: url)
    }

    func comSegment(_ text: String) -> [UInt8] {
        let payload = Array(text.utf8)
        return [0xFF, 0xFE, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload
    }

    @Test func aJPEGWithoutACommentGainsOneAfterTheAPPSegments() throws {
        let t = try TemporaryFolder()
        let url = plainJPEG(in: t)
        let before = try F.segments(url)
        let scan = try F.scanData(url)
        #expect(!before.contains { $0.marker == 0xFE })
        let appCount = before.prefix { (0xE0...0xEF).contains($0.marker) }.count
        #expect(appCount >= 2)   // JFIF and EXIF at least

        try JPEGComment.write("A caption", to: url)

        let after = try F.segments(url)
        let expectedMarkers: [UInt8] = before.prefix(appCount).map(\.marker) + [0xFE] + before.dropFirst(appCount).map(\.marker)
        #expect(after.map(\.marker) == expectedMarkers)
        #expect(after.filter { $0.marker != 0xFE }.map(\.bytes) == before.map(\.bytes))
        #expect(try F.scanData(url) == scan)
        #expect(JPEGComment.read(from: url) == "A caption")
        let description = MetadataReader.sections(for: url).first { $0.title == "Description" }
        #expect(description?.items.first { $0.label == "Comment" }?.value == "A caption")
        // Still a valid JPEG with its metadata.
        #expect(F.decode(url)?.width == 64)
        #expect((F.properties(url)[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String == "Maker")
    }

    @Test func multipleCommentsAndFillBytesAreReplacedByOne() throws {
        let t = try TemporaryFolder()
        let url = plainJPEG(in: t)
        let originalSegments = try F.segments(url)
        // One comment before APP0 behind two fill bytes, another just before SOS.
        let sos = try #require(Data(contentsOf: url).withUnsafeBytes { JPEGComment.header(of: $0)?.scanStart })
        try insert([0xFF, 0xFF] + comSegment("second"), at: sos, into: url)
        try insert([0xFF, 0xFF] + comSegment("first"), at: 2, into: url)
        #expect(MetadataReader.jpegComments(url) == ["first", "second"])
        #expect(JPEGComment.read(from: url) == "firstsecond")
        let scan = try F.scanData(url)

        try JPEGComment.write("only", to: url)
        let after = try F.segments(url)
        #expect(after.filter { $0.marker == 0xFE }.count == 1)
        #expect(after.filter { $0.marker != 0xFE }.map(\.bytes) == originalSegments.map(\.bytes))
        #expect(MetadataReader.jpegComments(url) == ["only"])
        #expect(try F.scanData(url) == scan)

        // Fill bytes before a kept segment stay with it, byte for byte.
        let appIndex = try #require(after.firstIndex { $0.marker == 0xDB })
        let padded = t.url.appendingPathComponent("padded.jpg")
        try FileManager.default.copyItem(at: url, to: padded)
        let offset = try Data(contentsOf: padded).withUnsafeBytes { JPEGComment.header(of: $0)!.segments[appIndex].start }
        try insert([0xFF, 0xFF, 0xFF], at: offset, into: padded)
        try JPEGComment.write("changed", to: padded)
        let paddedSegments = try F.segments(padded)
        #expect(paddedSegments.first { $0.marker == 0xDB }?.bytes.prefix(4) == Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(JPEGComment.read(from: padded) == "changed")
    }

    @Test func anEmptyCommentRemovesTheSegment() throws {
        let t = try TemporaryFolder()
        let url = plainJPEG(in: t)
        let original = try Data(contentsOf: url)
        try JPEGComment.write("temporary", to: url)
        try JPEGComment.write("", to: url)
        #expect(JPEGComment.read(from: url) == nil)
        #expect(MetadataReader.jpegComments(url).isEmpty)
        #expect(try Data(contentsOf: url) == original)   // back to the very same bytes
    }

    @Test func longUnicodeCommentsSplitAcrossSegments() throws {
        let t = try TemporaryFolder()
        let url = plainJPEG(in: t)
        let scan = try F.scanData(url)
        // 3-byte and 4-byte characters, so a naive split would land mid-character.
        let text = "Día — 日本 📷 " + String(repeating: "€", count: 25_000) + String(repeating: "🌅", count: 3_000) + " end"
        #expect(text.utf8.count > JPEGComment.maxPayload && text.utf8.count < 2 * JPEGComment.maxPayload)

        try JPEGComment.write(text, to: url)
        let comments = try F.segments(url).filter { $0.marker == 0xFE }
        #expect(comments.count == 2)
        for segment in comments {
            #expect(segment.bytes.count - 4 <= JPEGComment.maxPayload)
            #expect(String(data: segment.bytes.dropFirst(4), encoding: .utf8) != nil)   // each piece is valid UTF-8
        }
        #expect(JPEGComment.read(from: url) == text)
        #expect(MetadataReader.jpegComments(url).joined() == text.trimmingCharacters(in: .whitespaces))
        #expect(try F.scanData(url) == scan)
    }

    @Test func writingTheSameCommentLeavesTheFileAlone() throws {
        let t = try TemporaryFolder()
        let url = plainJPEG(in: t)
        try JPEGComment.write("Same", to: url)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try JPEGComment.write("Same", to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.modificationDate] as? Date == old)
        #expect(attributes[.systemFileNumber] as? Int == inode)
    }

    @Test func refusesFilesThatAreNotIntactJPEGs() throws {
        let t = try TemporaryFolder()
        let png = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("image.jpg"), type: .png)
        let pngBytes = try Data(contentsOf: png)
        #expect(throws: JPEGComment.Error.notJPEG) { try JPEGComment.write("x", to: png) }
        #expect(try Data(contentsOf: png) == pngBytes)
        #expect(JPEGComment.read(from: png) == nil)

        // Cut off in the middle of the header.
        let url = plainJPEG(in: t)
        let truncated = t.url.appendingPathComponent("truncated.jpg")
        try Data(contentsOf: url).prefix(100).write(to: truncated)
        #expect(throws: JPEGComment.Error.malformed) { try JPEGComment.write("x", to: truncated) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted() == ["image.jpg", "plain.jpg", "truncated.jpg"])
    }

    /// An HDR gain map is a second JPEG after the first, found through the
    /// MPF index whose offsets count from inside the header. Inserting a
    /// comment in front of the index must move those offsets.
    @Test func gainMapsSurviveAComment() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("gainmap.jpg")
        let base = CIImage(cgImage: TestImages.gradient(width: 256, height: 128))
        let gainMap = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        try CIContext().writeJPEGRepresentation(of: base, to: url, colorSpace: F.displayP3, options: [.hdrGainMapImage: gainMap])
        func gainMapData() -> Data? {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [String: Any]
            return info?[kCGImageAuxiliaryDataInfoData as String] as? Data
        }
        let before = try #require(gainMapData())
        let segments = try F.segments(url)
        #expect(segments.contains { $0.marker == 0xE2 && $0.bytes.dropFirst(4).starts(with: Array("MPF".utf8)) })

        try JPEGComment.write("HDR photo with a comment", to: url)
        #expect(gainMapData() == before)
        #expect(JPEGComment.read(from: url) == "HDR photo with a comment")

        // The index really points at the second image's SOI.
        let data = try Data(contentsOf: url)
        let offsets = try #require(mpfImageOffsets(in: data))
        #expect(offsets.count == 2 && offsets[0].offset == 0)
        #expect(data[offsets[1].headerPosition + offsets[1].offset] == 0xFF && data[offsets[1].headerPosition + offsets[1].offset + 1] == 0xD8)

        try JPEGComment.write("", to: url)
        #expect(gainMapData() == before)
    }

    /// (MP header position, image offset) for each MP entry, big- or little-endian.
    func mpfImageOffsets(in data: Data) -> [(headerPosition: Int, offset: Int)]? {
        let bytes = [UInt8](data)
        guard let segment = bytes.withUnsafeBytes({ raw in
            JPEGComment.header(of: raw)?.segments.first { JPEGComment.isMPF($0, in: raw) }
        }) else { return nil }
        let h = segment.payloadStart + 4
        let little = bytes[h] == 0x49
        func u16(_ o: Int) -> Int { little ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : Int(bytes[o]) << 8 | Int(bytes[o + 1]) }
        func u32(_ o: Int) -> Int {
            little ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
                   : Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
        }
        let ifd = h + u32(h + 4)
        for i in 0..<u16(ifd) where u16(ifd + 2 + i * 12) == 0xB002 {
            let entry = ifd + 2 + i * 12
            let table = h + u32(entry + 8)
            return stride(from: 0, to: u32(entry + 4), by: 16).map { (h, u32(table + $0 + 8)) }
        }
        return nil
    }

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleJPEG)))
    func realPhotoKeepsItsImageDataByteForByte() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: F.sampleJPEG, to: url)
        let before = try F.segments(url)
        let scan = try F.scanData(url)
        try JPEGComment.write("Día 1 — ünïcode ✓", to: url)
        #expect(try F.scanData(url) == scan)
        #expect(try F.segments(url).filter { $0.marker != 0xFE }.map(\.bytes) == before.filter { $0.marker != 0xFE }.map(\.bytes))
        #expect(JPEGComment.read(from: url) == "Día 1 — ünïcode ✓")
        #expect(MetadataReader.summary(for: url).pixelSize == MetadataReader.summary(for: F.sampleJPEG).pixelSize)
    }

    @Test func chunksNeverSplitCharacters() {
        #expect(JPEGComment.chunks(of: "").isEmpty)
        #expect(JPEGComment.chunks(of: "abc").map(Array.init) == [Array("abc".utf8)])
        let text = String(repeating: "a", count: JPEGComment.maxPayload - 1) + "€"   // the € straddles the limit
        let chunks = JPEGComment.chunks(of: text)
        #expect(chunks.map(\.count) == [JPEGComment.maxPayload - 1, 3])
        #expect(chunks.reduce([], +) == Array(text.utf8))
    }
}
