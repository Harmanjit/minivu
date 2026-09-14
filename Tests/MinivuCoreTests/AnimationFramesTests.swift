import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

@Suite struct AnimationFramesTests {
    typealias F = DocumentFixtures

    @Test func browserDelayRule() {
        #expect(AnimationFrames.effectiveDelay(0) == 0.1)
        #expect(AnimationFrames.effectiveDelay(0.01) == 0.1)
        #expect(AnimationFrames.effectiveDelay(0.02) == 0.02)
        #expect(AnimationFrames.effectiveDelay(0.5) == 0.5)
    }

    @Test func gifTimingAndLoops() throws {
        let url = F.animatedGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delays: [0.05, 0.02, 0.01], loopCount: 0)
        let frames = try #require(AnimationFrames(url: url))
        #expect(frames.frameCount == 3)
        #expect(frames.pixelSize == CGSize(width: 40, height: 30))
        #expect(zip(frames.delays, [0.05, 0.02, 0.1]).allSatisfy { abs($0 - $1) < 0.001 }, "\(frames.delays)")
        #expect(frames.loopCount == 0)
        #expect(abs(frames.duration - 0.17) < 0.003)

        let info = try #require(ImageDecoder.info(for: url))
        #expect(info.isAnimated && info.pageCount == 3)
        #expect(info.documentPageCount == 1)   // frames aren't pages

        let once = F.animatedGIF(colors: [(1, 0, 0), (0, 1, 0)], delays: [0.1, 0.1], loopCount: 3)
        #expect(AnimationFrames(url: once)?.loopCount == 3)
    }

    @Test func apngTiming() throws {
        let url = F.animatedPNG(colors: [(1, 0, 0), (0, 0, 1)], delays: [0.04, 0.25])
        let frames = try #require(AnimationFrames(url: url))
        #expect(frames.frameCount == 2)
        #expect(zip(frames.delays, [0.04, 0.25]).allSatisfy { abs($0 - $1) < 0.001 }, "\(frames.delays)")
        #expect(frames.loopCount == 0)
        #expect(ImageDecoder.info(for: url)?.isAnimated == true)
        #expect(F.Pixels(try #require(frames.frame(at: 1, maxPixelSize: 64))).isNear(10, 10, F.blue))
    }

    @Test func stillImagesAreNotAnimations() {
        let url = F.multiPageTIFF()   // two images, but pages
        #expect(ImageDecoder.info(for: url)?.isAnimated == false)
        let single = F.animatedGIF(colors: [(1, 0, 0)], delays: [0.1], loopCount: 0)
        #expect(AnimationFrames(url: single) == nil)
    }

    /// ImageIO composites: a frame that only repaints a corner comes back as
    /// the whole picture, with earlier frames' patches still in place.
    @Test func framesComeBackComposited() throws {
        let frames = try #require(AnimationFrames(url: F.patchedGIF()))
        #expect(frames.frameCount == 3)
        #expect(frames.pixelSize == CGSize(width: 16, height: 16))
        #expect(frames.loopCount == 0)
        #expect(abs(frames.delays[0] - 0.05) < 0.001)

        let first = F.Pixels(try #require(frames.frame(at: 0, maxPixelSize: 16)))
        #expect(first.isNear(1, 1, F.white) && first.isNear(14, 14, F.white))

        let second = F.Pixels(try #require(frames.frame(at: 1, maxPixelSize: 16)))
        #expect(second.width == 16 && second.height == 16)
        #expect(second.isNear(1, 1, F.red))
        #expect(second.isNear(14, 14, F.white))
        #expect(second.isNear(8, 8, F.white))

        let third = F.Pixels(try #require(frames.frame(at: 2, maxPixelSize: 16)))
        #expect(third.isNear(1, 1, F.red))
        #expect(third.isNear(14, 14, F.blue))
        #expect(third.isNear(8, 8, F.white))

        // Out of order too (going back to the start of a loop, or seeking).
        let again = F.Pixels(try #require(frames.frame(at: 1, maxPixelSize: 16)))
        #expect(again.isNear(1, 1, F.red) && again.isNear(14, 14, F.white))
        // And downscaled.
        let small = try #require(frames.frame(at: 2, maxPixelSize: 8))
        #expect(small.width == 8)
        #expect(F.Pixels(small).isNear(7, 7, F.blue, tolerance: 40))
    }
}
