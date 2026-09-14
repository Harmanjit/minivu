import Testing
import Foundation
import CoreGraphics
import CoreImage
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// HDR end to end: generated gain-map and PQ files -> decode -> upload ->
/// canvas at several display headrooms -> pixels.
@Suite(.serialized) struct HDRPipelineTests {
    /// Middle row of a rendered or uploaded texture, largest channel per pixel.
    func rowPeaks(_ texture: MTLTexture) -> [Float] {
        (0..<texture.width).map { x in
            let p = Fixtures.pixel(texture, x, texture.height / 2)
            return max(p.x, p.y, p.z)
        }
    }

    // MARK: - Detection

    @Test func infoReportsHDRForGainMapAndPQButNotSDR() throws {
        let gainMap = try Fixtures.gainMapHEIC()
        let pq = try Fixtures.pqHEIC()
        let jpeg = Fixtures.write(Fixtures.quadrants(), name: "sdr-\(UUID()).jpg", type: .jpeg)
        #expect(ImageDecoder.info(for: gainMap)?.isHDR == true)
        #expect(ImageDecoder.info(for: pq)?.isHDR == true)
        #expect(ImageDecoder.info(for: jpeg)?.isHDR == false)
    }

    // MARK: - Decode and upload

    @Test(arguments: ["gainmap", "pq"])
    func hdrDecodeKeepsHighlightsInHalfFloat(kind: String) throws {
        let url = kind == "pq" ? try Fixtures.pqHEIC() : try Fixtures.gainMapHEIC()
        let decoded = try ImageDecoder.decode(url)
        #expect(decoded.isHDR)
        #expect(decoded.contentHeadroom > 3.5)
        let texture = try TextureUploader.upload(decoded)
        #expect(texture.texture.pixelFormat == .rgba16Float)
        #expect(texture.isHDR)
        let peaks = rowPeaks(Fixtures.readable(texture.texture))
        #expect(peaks[peaks.count - 2] > 2.5, "bright end \(peaks.suffix(4))")
        #expect(peaks[1] < 0.1)
    }

    @Test(arguments: ["gainmap", "pq"])
    func withHDROffTheTextureIsSDR(kind: String) throws {
        let url = kind == "pq" ? try Fixtures.pqHEIC() : try Fixtures.gainMapHEIC()
        let decoded = try ImageDecoder.decode(url, allowHDR: false)
        #expect(!decoded.isHDR)
        #expect(decoded.contentHeadroom == 1)
        let texture = try TextureUploader.upload(decoded)
        #expect(texture.texture.pixelFormat == .bgra8Unorm_srgb)
        #expect(!texture.isHDR)
        // Still a ramp, tone mapped into SDR rather than clipped flat early.
        let peaks = rowPeaks(try Fixtures.renderActualSize(texture, displayHeadroom: 8))
        #expect(peaks.max()! <= 1.001)
        #expect(peaks[peaks.count * 3 / 4] > peaks[peaks.count / 2])
    }

    // MARK: - Canvas tone mapping

    @Test func hdrScreenShowsTheHighlights() throws {
        let texture = try TextureUploader.upload(ImageDecoder.decode(Fixtures.gainMapHEIC()))
        let peaks = rowPeaks(try Fixtures.renderActualSize(texture, displayHeadroom: 8))
        #expect(peaks[peaks.count - 2] > 2.5, "bright end \(peaks.suffix(4))")
        // The SDR part is untouched: a quarter of the way along is ~1.0.
        let quarter = peaks[peaks.count / 4]
        #expect(abs(quarter - 1) < 0.1, "quarter \(quarter)")
    }

    @Test(arguments: ["gainmap", "pq"])
    func sdrScreenRollsHighlightsOffWithoutClippingTheRamp(kind: String) throws {
        let url = kind == "pq" ? try Fixtures.pqHEIC() : try Fixtures.gainMapHEIC()
        let texture = try TextureUploader.upload(ImageDecoder.decode(url))
        let peaks = rowPeaks(try Fixtures.renderActualSize(texture, displayHeadroom: 1))
        #expect(peaks.max()! <= 1.0 + 1e-3)
        // Monotonic, within the encoder's rounding.
        for x in 1..<peaks.count {
            #expect(peaks[x] >= peaks[x - 1] - 0.01, "x \(x): \(peaks[x - 1]) -> \(peaks[x])")
        }
        // Highlight detail survives: 1x, 2x and 4x white stay distinct
        // instead of clipping to one flat white.
        let n = peaks.count
        #expect(peaks[n / 2] - peaks[n / 4] > 0.05, "\(peaks[n / 4]) -> \(peaks[n / 2])")
        #expect(peaks[n - 2] - peaks[n / 2] > 0.02, "\(peaks[n / 2]) -> \(peaks[n - 2])")
    }

    /// The shader and its Swift copy agree, pixel for pixel.
    @Test(arguments: [Float(1), 2, 3])
    func shaderMatchesTheSwiftCurve(displayHeadroom: Float) throws {
        let texture = try TextureUploader.upload(ImageDecoder.decode(Fixtures.gainMapHEIC()))
        let source = Fixtures.readable(texture.texture)
        let out = try Fixtures.renderActualSize(texture, displayHeadroom: displayHeadroom)
        let y = out.height / 2
        for x in stride(from: 4, to: out.width, by: 12) {
            let input = Fixtures.pixel(source, x, y)
            let peak = max(input.x, input.y, input.z)
            let expected = HeadroomToneMap.map(peak: peak, displayHeadroom: displayHeadroom,
                                               contentHeadroom: texture.contentHeadroom)
            let actual = Fixtures.pixel(out, x, y)
            #expect(abs(max(actual.x, actual.y, actual.z) - expected) < 0.01,
                    "x \(x): in \(peak), expected \(expected), got \(actual)")
        }
    }

    // MARK: - Loader settings

    @MainActor @Test func loaderFollowsTheHDRSetting() async throws {
        let loader = ImageLoader(cache: TextureCache(budgetBytes: 64 << 20))
        let entry = try #require(FolderEntry(url: try Fixtures.gainMapHEIC()))
        func load() async throws -> ImageTexture {
            try await withCheckedContinuation { done in
                loader.load(entry, pixelSize: 256) { done.resume(returning: $0) }
            }.get()
        }
        let hdr = try await load()
        #expect(hdr.texture.pixelFormat == .rgba16Float)

        loader.settings.showHDR = false
        #expect(loader.cache.usedBytes == 0)   // HDR textures are now wrong
        let sdr = try await load()
        #expect(sdr.texture.pixelFormat == .bgra8Unorm_srgb)
        #expect(loader.decodeCount == 2)

        loader.settings.showHDR = false   // no change: the cache stays
        #expect(loader.cache.usedBytes > 0)
    }
}

/// The canvas's HDR roll-off (Canvas.metal `toneMapToHeadroom`), through its
/// Swift copy.
@Suite struct HeadroomToneMapTests {
    /// (display, content) pairs: an SDR screen with a 4x photo, a 2x screen
    /// with 8x content, and content just over a screen's headroom.
    static let pairs: [(display: Float, content: Float)] = [(1, 4), (2, 8), (3, 3.97), (1.5, 16), (4, 4.5)]

    func samples(upTo limit: Float, step: Float = 0.001) -> [Float] {
        Array(stride(from: Float(0), through: limit, by: step))
    }

    @Test func monotonicContinuousAndNeverBrighter() {
        for (display, content) in Self.pairs {
            let step: Float = 0.001
            var previous = HeadroomToneMap.map(peak: 0, displayHeadroom: display, contentHeadroom: content)
            for x in samples(upTo: content * 1.5, step: step).dropFirst() {
                let y = HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: content)
                #expect(y >= previous, "not monotonic at \(x) for \(display)/\(content)")
                // Slope at most 1 (plus float slack): no jumps, no added contrast.
                #expect(y - previous <= step * 1.01, "jump at \(x) for \(display)/\(content)")
                #expect(y <= x + 1e-5, "brighter at \(x) for \(display)/\(content)")
                #expect(y <= display + 1e-5)
                previous = y
            }
        }
    }

    @Test func reachesTheDisplayHeadroomExactlyAtTheContentHeadroom() {
        for (display, content) in Self.pairs {
            let top = HeadroomToneMap.map(peak: content, displayHeadroom: display, contentHeadroom: content)
            #expect(abs(top - display) < 1e-4, "\(display)/\(content): \(top)")
            // And just below it is just below the display headroom.
            let below = HeadroomToneMap.map(peak: content - 0.001, displayHeadroom: display, contentHeadroom: content)
            #expect(below < display && display - below < 0.002)
        }
    }

    @Test func contentThatFitsPassesThrough() {
        for (display, content) in [(Float(1), Float(1)), (4, 1), (4, 3.97), (16, 8)] {
            for x in samples(upTo: content * 1.2, step: 0.01) {
                #expect(HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: content) == x)
            }
        }
    }

    @Test func sdrRangeIsUntouchedWhereverTheScreenHasRoom() {
        // From 4/3 of headroom up, the knee sits at or above SDR white.
        for display in [Float(4) / 3, 2, 3, 8] {
            for x in samples(upTo: 1, step: 0.01) {
                #expect(HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: 16) == x)
            }
        }
        // An SDR screen gives up only its top quarter.
        for x in samples(upTo: 0.75, step: 0.01) {
            #expect(HeadroomToneMap.map(peak: x, displayHeadroom: 1, contentHeadroom: 4) == x)
        }
    }

    @Test func slopeIsOneAtTheKnee() {
        let display: Float = 2, knee = display * 0.75, h: Float = 1e-3
        let y = HeadroomToneMap.map(peak: knee + h, displayHeadroom: display, contentHeadroom: 8)
        #expect(abs((y - knee) / h - 1) < 0.01)
    }
}
