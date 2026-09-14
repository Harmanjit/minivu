import Testing
import Foundation
import CoreGraphics
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// Transition frame times at 5K (5120 × 2880, a Studio Display), the
/// slideshow's budget being 4 ms a frame. Runs only when MINIVU_BENCH is set:
///     MINIVU_BENCH=1 swift test --filter SlideshowBenchmark
///
/// M4, debug build (the work is all on the GPU), two 5K gradients, median
/// of 30 frames each after a warm-up, draw to completion (2026-09-14):
///     cross-fade 1.9 ms, fade through black 1.3, slide 1.0, push 1.0,
///     wipe 1.0, zoom 1.3, iris 1.0, dissolve 2.5
/// Fade through black, slide, push, wipe and iris sample one image for most
/// pixels; cross-fade and zoom always sample both; dissolve adds the noise.
@Suite(.serialized) struct SlideshowBenchmark {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MINIVU_BENCH"] != nil }

    static func photo(_ hue: CGFloat) throws -> ImageTexture {
        let width = 5120, height = 2880
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(srgbRed: hue, green: 0.4, blue: 1 - hue, alpha: 1),
                      CGColor(srgbRed: 1 - hue, green: 0.8, blue: hue, alpha: 1)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                               locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let decoded = DecodedImage(image: try #require(context.makeImage()), orientation: .up,
                                   imageSize: CGSize(width: width, height: height), isFullResolution: true,
                                   isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        return try TextureUploader.upload(decoded)
    }

    @Test(.enabled(if: SlideshowBenchmark.enabled))
    func transitionFrameTimesAt5K() throws {
        let renderer = try SlideshowRenderer()
        let old = try Self.photo(0.2), new = try Self.photo(0.8)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SlideshowRenderer.pixelFormat, width: 5120,
                                                         height: 2880, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        let target = try #require(GPU.shared.device.makeTexture(descriptor: d))
        // Wake the GPU up first, or the first transition measures that.
        let warmUp = SlideshowFrame(from: old, to: new, transition: .crossFade, progress: 0.5)
        for _ in 0..<30 { renderer.draw(warmUp, into: target) }
        var report: [String] = []
        for transition in SlideshowTransition.allCases {
            var times: [Double] = []
            for i in 0..<40 {
                let frame = SlideshowFrame(from: old, to: new, transition: transition, progress: Float(i % 10) / 10 + 0.05)
                let start = ContinuousClock.now
                renderer.draw(frame, into: target)
                let elapsed = ContinuousClock.now - start
                if i >= 10 { times.append(Double(elapsed.components.attoseconds) / 1e15) }
            }
            let median = times.sorted()[times.count / 2]
            report.append("\(transition.rawValue) \(String(format: "%.2f", median)) ms")
            #expect(median < 4, "\(transition) took \(median) ms")
        }
        print("Slideshow at 5K: " + report.joined(separator: ", "))
    }
}
