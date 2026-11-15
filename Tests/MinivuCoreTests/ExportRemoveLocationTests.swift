import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

/// S4 in docs/SECURITY-REVIEW.md: Save As and Batch Convert's "Remove
/// location", on by default, which leaves out the GPS dictionary, its XMP
/// mirror and the IPTC place names and keeps the rest.
@Suite(.offCooperativePool) struct ExportRemoveLocationTests {
    typealias F = ExportFixtures

    @Test(arguments: [ExportFormat.jpeg, .png, .heic, .tiff])
    func exportRemovesLocationOnlyWhenAsked(_ format: ExportFormat) throws {
        let t = try TemporaryFolder()
        let source = MetadataWriterTests.tagged(.jpeg, ext: "jpg", in: t.url, name: "source")
        let image = try #require(F.decode(source))
        var options = ExportOptions.defaults(for: format)
        #expect(options.keepMetadata && options.removeLocation)

        let removed = t.url.appendingPathComponent("removed.\(format.fileExtension)")
        try ImageEncoder.write(image, to: removed, options: options, metadataSource: source)
        MetadataWriterTests.expectNoLocation(removed, "\(format) removed")
        let fields = MetadataFields.read(from: removed)
        #expect(fields.title == MetadataWriterTests.oldTitle && Set(fields.keywords) == ["paris", "tower"], "\(format)")
        #expect(MetadataWriterTests.dictionary(removed, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String == "NIKON")

        options.removeLocation = false
        let kept = t.url.appendingPathComponent("kept.\(format.fileExtension)")
        try ImageEncoder.write(image, to: kept, options: options, metadataSource: source)
        let gps = MetadataWriterTests.dictionary(kept, kCGImagePropertyGPSDictionary)
        #expect((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? 0 > 48, "\(format)")
        #expect(MetadataWriterTests.dictionary(kept, kCGImagePropertyIPTCDictionary)[kCGImagePropertyIPTCCity as String] as? String == MetadataWriterTests.city)
    }

    @Test func optionsSavedBeforeRemoveLocationExistedTurnItOn() throws {
        let old = #"{"format":"jpeg","quality":0.7,"keepMetadata":true}"#
        let options = try JSONDecoder().decode(ExportOptions.self, from: Data(old.utf8))
        #expect(options.removeLocation && options.quality == 0.7)
        var off = options
        off.removeLocation = false
        #expect(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(off)) == off)
    }
}
