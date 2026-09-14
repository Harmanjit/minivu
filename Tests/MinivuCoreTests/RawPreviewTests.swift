import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

@Suite struct RawPreviewTests {
    static let folder = URL(fileURLWithPath: "/Users/harman/latent/TestAssets")
    static let hasAssets = FileManager.default.fileExists(atPath: folder.path)

    @Test func previewsWithinThreePercentCountAsFullSize() {
        #expect(ImageDecoder.isFullSizePreview(longEdge: 6016, imageLongEdge: 6016))
        #expect(ImageDecoder.isFullSizePreview(longEdge: 6000, imageLongEdge: 6048))
        #expect(ImageDecoder.isFullSizePreview(longEdge: 5836, imageLongEdge: 6016))   // 97.0%
        #expect(!ImageDecoder.isFullSizePreview(longEdge: 5830, imageLongEdge: 6016))
        #expect(!ImageDecoder.isFullSizePreview(longEdge: 1616, imageLongEdge: 6016))
    }

    @Test(.enabled(if: hasAssets))
    func fullSizeEmbeddedPreviewIsOrientedAndFull() throws {
        let preview = try #require(try ImageDecoder.decodeRawPreview(Self.folder.appendingPathComponent("HSB_2615.NEF")))
        #expect(preview.imageSize == CGSize(width: 4016, height: 6016))
        #expect(preview.image.width == 4016 && preview.image.height == 6016)
        #expect(preview.orientation == .up)
        #expect(preview.isFullResolution)
        #expect(!preview.isHDR)
    }

    @Test(.enabled(if: hasAssets))
    func smallerPreviewRequestsAreScaledNotRendered() throws {
        let preview = try #require(try ImageDecoder.decodeRawPreview(Self.folder.appendingPathComponent("HSB_6548.NEF"),
                                                                     maxPixelSize: 1000))
        #expect(max(preview.image.width, preview.image.height) == 1000)
        #expect(!preview.isFullResolution)
    }

    @Test func nonRawFilesHaveNoRawPreviewToDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-raw-\(UUID()).nef")
        try Data("not a raw file".utf8).write(to: url)
        #expect(throws: DecodeError.self) { try ImageDecoder.decodeRawPreview(url) }
    }
}
