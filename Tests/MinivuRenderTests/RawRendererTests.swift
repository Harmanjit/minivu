import Testing
import Foundation
import CoreGraphics
import ImageIO
import Metal
@testable import MinivuRender
@testable import MinivuCore

@Suite struct RawRendererTests {
    static let folder = URL(fileURLWithPath: "/Users/harman/latent/TestAssets")
    static let hasAssets = FileManager.default.fileExists(atPath: folder.path)
    /// Portrait: stored 6016x4016 with EXIF orientation 8.
    static let portraitNEF = folder.appendingPathComponent("HSB_2615.NEF")

    // MARK: - Sizes and amounts

    @Test func renderScaleShrinksOnlyWhenAsked() {
        #expect(RawRenderer.renderScale(longestEdge: 6016, maxPixelSize: nil) == 1)
        #expect(RawRenderer.renderScale(longestEdge: 6016, maxPixelSize: 8000) == 1)
        #expect(RawRenderer.renderScale(longestEdge: 6016, maxPixelSize: 3008) == 0.5)
        // Beyond Metal's texture limit even a full-resolution render shrinks.
        #expect(RawRenderer.renderScale(longestEdge: 32768, maxPixelSize: nil) == 0.5)
    }

    @Test func headroomMapsToEDRAmount() {
        #expect(RawRenderer.edrAmount(forHeadroom: 1) == 0)
        #expect(RawRenderer.edrAmount(forHeadroom: 0.5) == 0)
        #expect(abs(RawRenderer.edrAmount(forHeadroom: 1.4142) - 0.5) < 1e-3)
        #expect(RawRenderer.edrAmount(forHeadroom: 2) == 1)
        #expect(RawRenderer.edrAmount(forHeadroom: 16) == 1)
        #expect(RawRenderer.edrAmount(forHeadroom: .nan) == 0)
    }

    // MARK: - Real RAW files

    @Test(.enabled(if: hasAssets))
    func fullResolutionRenderIsUprightAndSensorSized() throws {
        let texture = try RawRenderer.render(url: Self.portraitNEF, maxPixelSize: nil, hdr: false, headroom: 1)
        #expect(texture.imageSize == CGSize(width: 4016, height: 6016))
        #expect(texture.texture.width == 4016 && texture.texture.height == 6016)
        #expect(texture.isFullResolution)
        #expect(!texture.isHDR && texture.contentHeadroom == 1)
        #expect(texture.texture.pixelFormat == .bgra8Unorm_srgb)
        #expect(texture.texture.mipmapLevelCount > 1)
    }

    /// Orientation and flip, checked against the camera's own preview: the
    /// brightness pattern of a 6x6 grid must match ImageIO's oriented
    /// decode, and would not if the render were rotated or upside down.
    @Test(.enabled(if: hasAssets))
    func renderMatchesTheEmbeddedPreviewLayout() throws {
        let texture = try RawRenderer.render(url: Self.portraitNEF, maxPixelSize: 600, hdr: false, headroom: 1)
        #expect(max(texture.texture.width, texture.texture.height) == 600)
        #expect(!texture.isFullResolution)
        #expect(texture.imageSize == CGSize(width: 4016, height: 6016))
        let rendered = try Fixtures.renderActualSize(texture.resized(to: texture.textureSize), displayHeadroom: 1)
        let preview = try TextureUploader.upload(ImageDecoder.decode(Self.portraitNEF, maxPixelSize: 600))
        let reference = try Fixtures.renderActualSize(preview.resized(to: preview.textureSize), displayHeadroom: 1)

        let a = gridLuminance(rendered), b = gridLuminance(reference)
        let correlation = pearson(a, b)
        #expect(correlation > 0.8, "grid correlation \(correlation)")
        // A 180° turn of the same picture must correlate far worse.
        #expect(pearson(a, b.reversed()) < correlation - 0.3)
    }

    @Test(.enabled(if: hasAssets))
    func hdrRenderReachesAboveWhite() throws {
        let url = Self.folder.appendingPathComponent("nikon_d750_sample.nef")
        let texture = try RawRenderer.render(url: url, maxPixelSize: nil, hdr: true, headroom: 2)
        #expect(texture.isHDR)
        #expect(texture.texture.pixelFormat == .rgba16Float)
        // The measured peak of this file at full size is about 2.5. (Small
        // renders average the specular highlights away: 1.28 at half size.)
        #expect(texture.contentHeadroom > 2 && texture.contentHeadroom < 3, "headroom \(texture.contentHeadroom)")

        let sdr = try RawRenderer.render(url: url, maxPixelSize: 1000, hdr: true, headroom: 1)
        #expect(sdr.contentHeadroom <= 1.05, "headroom 1 asks for no extended range: \(sdr.contentHeadroom)")
    }

    // MARK: - Helpers

    func gridLuminance(_ texture: MTLTexture, cells: Int = 6) -> [Float] {
        var values: [Float] = []
        for gy in 0..<cells {
            for gx in 0..<cells {
                var sum: Float = 0, count: Float = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let x = (gx * 4 + sx) * texture.width / (cells * 4)
                        let y = (gy * 4 + sy) * texture.height / (cells * 4)
                        let p = Fixtures.pixel(texture, x, y)
                        sum += 0.2 * p.x + 0.7 * p.y + 0.1 * p.z
                        count += 1
                    }
                }
                values.append(sum / count)
            }
        }
        return values
    }

    func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb)
            da += (x - ma) * (x - ma)
            db += (y - mb) * (y - mb)
        }
        return num / max((da * db).squareRoot(), 1e-9)
    }
}

extension ImageTexture {
    /// The same texture, claiming `size` as its image size, so a test can
    /// draw a reduced texture at 100% of its own pixels.
    func resized(to size: CGSize) -> ImageTexture {
        ImageTexture(texture: texture, imageSize: size, isFullResolution: true, isHDR: isHDR,
                     contentHeadroom: contentHeadroom)
    }
}
