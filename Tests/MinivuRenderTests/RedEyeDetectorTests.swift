import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender

/// The detector's check that an eye is red before proposing a circle.
@Suite struct RedEyeDetectorTests {
    /// 400 x 200 sRGB: skin, a red-eyed pupil at (100, 100) and a brown eye
    /// with a dark pupil at (300, 100), each with a catchlight.
    static func eyes() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func disc(_ x: Double, _ y: Double, _ r: Double, _ c: (Double, Double, Double)) {
            context.setFillColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
            // CGContext is y-up: flip so coordinates read top-left.
            context.fillEllipse(in: CGRect(x: x - r, y: 200 - y - r, width: 2 * r, height: 2 * r))
        }
        context.setFillColor(red: 224 / 255, green: 172 / 255, blue: 140 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        for x in [100.0, 300] { disc(x, 100, 20, (120, 70, 40)) }
        disc(100, 100, 10, (200, 40, 40))
        disc(300, 100, 10, (30, 25, 25))
        for x in [97.0, 297] { disc(x, 97, 3, (255, 255, 255)) }
        return context.makeImage()!
    }

    @Test func onlyRedPupilsBecomeSpots() {
        let image = Self.eyes()
        #expect(RedEyeDetector.redFraction(in: image, center: CGPoint(x: 100, y: 100), radius: 10) > 0.5)
        #expect(RedEyeDetector.redFraction(in: image, center: CGPoint(x: 300, y: 100), radius: 10) == 0)
        #expect(RedEyeDetector.redFraction(in: image, center: CGPoint(x: 200, y: 50), radius: 10) == 0, "skin")
        let spots = RedEyeDetector.redSpots([(CGPoint(x: 100, y: 100), 20), (CGPoint(x: 300, y: 100), 20)], in: image)
        #expect(spots.count == 1)
        #expect(spots.first?.center == CGPoint(x: 0.25, y: 0.5))
        #expect(spots.first?.radius == 0.1)
    }

    /// Linear light, from sRGB 8-bit.
    static func linear(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func d(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return (d(r), d(g), d(b))
    }

    @Test func aDarkBrownEyeIsNotPupilRed() {
        for (colour, red) in [((200.0, 40.0, 40.0), true), ((170, 70, 55), true), ((140, 20, 45), true),
                              ((90, 40, 20), false), ((120, 70, 40), false), ((224, 172, 140), false),
                              ((250, 250, 250), false)] {
            let c = Self.linear(colour.0, colour.1, colour.2)
            #expect(RedEyeTuning.isPupilRed(red: c.0, green: c.1, blue: c.2) == red, "\(colour)")
        }
    }

    @Test func noFacesNoSpots() {
        #expect(RedEyeDetector.detect(in: Self.eyes()).isEmpty)
    }
}
