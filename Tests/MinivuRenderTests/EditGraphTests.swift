import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import MinivuRender

/// Geometry and tone operations through `EditGraph`, rendered and read back.
/// Positions use the 4-colour quadrant image: red top-left, green top-right,
/// blue bottom-left, white bottom-right.
@Suite struct EditGraphTests {
    typealias F = EditFixtures

    func render(_ ops: [EditOperation], source: CIImage = F.quadrants(), scale: Double = 1,
                fullSize: CGSize = CGSize(width: 64, height: 32)) -> F.Pixels {
        let image = EditGraph.image(source: source, sourceSize: fullSize, operations: ops, scale: scale)
        #expect(image.extent.origin == .zero, "extent \(image.extent)")
        return F.pixels(image)
    }

    /// Colours at the centres of the four quadrants: TL, TR, BL, BR.
    func corners(_ p: F.Pixels) -> [SIMD4<Float>] {
        [p.at(0.25, 0.25), p.at(0.75, 0.25), p.at(0.25, 0.75), p.at(0.75, 0.75)]
    }

    // MARK: - Geometry

    @Test func noOperationsIsThePixelsUnchanged() {
        let p = render([])
        #expect(corners(p) == [F.red, F.green, F.blue, F.white])
        #expect(p[0, 0] == F.red && p[63, 31] == F.white)
    }

    @Test func rotateRightMovesTopLeftToTopRight() {
        let p = render([.rotate90(turns: 1)])
        #expect(p.width == 32 && p.height == 64)
        #expect(corners(p) == [F.blue, F.red, F.white, F.green])
    }

    @Test func rotateLeftAnd180() {
        let left = render([.rotate90(turns: 3)])
        #expect(left.width == 32 && left.height == 64)
        #expect(corners(left) == [F.green, F.white, F.red, F.blue])
        let half = render([.rotate90(turns: 2)])
        #expect(half.width == 64 && half.height == 32)
        #expect(corners(half) == [F.white, F.blue, F.green, F.red])
        // Negative and large turn counts normalise.
        #expect(corners(render([.rotate90(turns: -1)])) == corners(left))
    }

    @Test func flips() {
        #expect(corners(render([.flip(horizontal: true)])) == [F.green, F.red, F.white, F.blue])
        #expect(corners(render([.flip(horizontal: false)])) == [F.blue, F.white, F.red, F.green])
    }

    @Test func cropUsesTopLeftNormalisedCoordinates() {
        let quadrants: [(CGRect, SIMD4<Float>)] = [
            (CGRect(x: 0, y: 0, width: 0.5, height: 0.5), F.red),
            (CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), F.green),
            (CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), F.blue),
            (CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), F.white),
        ]
        for (rect, colour) in quadrants {
            let p = render([.crop(rect)])
            #expect(p.width == 32 && p.height == 16)
            #expect(p.all.allSatisfy { $0 == colour }, "crop \(rect)")
        }
        // A strip across the top half's boundary: 8 px of red then green.
        let strip = render([.crop(CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.25))])
        #expect(strip.width == 16 && strip.height == 8)
        #expect(strip[7, 7] == F.red && strip[8, 0] == F.green)
    }

    @Test func cropOnAHalfSizeProxyMatchesFullResolution() {
        let ops: [EditOperation] = [.crop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1)), .rotate90(turns: 1)]
        let full = render(ops)
        let proxy = render(ops, source: F.quadrants(width: 32, height: 16), scale: 0.5)
        #expect(full.width == 32 && full.height == 32)
        #expect(proxy.width == 16 && proxy.height == 16)
        // Right half turned clockwise: white (bottom) comes to the left, green to the right.
        #expect(corners(full) == [F.white, F.green, F.white, F.green])
        #expect(corners(proxy) == corners(full))
    }

    @Test func arbitraryRotationBy90MatchesQuarterTurn() {
        let p = render([.rotate(degrees: 90, autoCrop: false)])
        #expect(p.width == 32 && p.height == 64)
        #expect(corners(p).map { nearly($0, F.blue, 0.01) } == [true, false, false, false])
        #expect(nearly(p.at(0.75, 0.25), F.red, 0.01) && nearly(p.at(0.25, 0.75), F.white, 0.01))
    }

    @Test func rotationWithoutCropHasTransparentCorners() {
        let p = render([.rotate(degrees: 30, autoCrop: false)])
        let c = cos(Double.pi / 6), s = sin(Double.pi / 6)
        #expect(p.width == Int((64 * c + 32 * s).rounded()) && p.height == Int((64 * s + 32 * c).rounded()))
        #expect(p[0, 0].w < 0.01 && p[p.width - 1, p.height - 1].w < 0.01)
        #expect(nearly(p.at(0.5, 0.5).w, 1))
        // Clockwise: the red top-left corner turns up and right, so the top
        // edge's first opaque pixels (left of centre) are red.
        let topRow = (0..<p.width).map { p[$0, 1] }
        let firstOpaque = topRow.first { $0.w > 0.99 }
        #expect(firstOpaque.map { $0.x > 0.9 && $0.y < 0.1 } == true, "\(String(describing: firstOpaque))")
    }

    @Test func autoCropLeavesNoTransparentPixels() {
        for degrees in [3.0, -12.0, 45.0, 100.0] {
            let p = render([.rotate(degrees: degrees, autoCrop: true)], source: F.flat(0.5, width: 64, height: 32))
            let expected = EditGraph.rotatedSize(width: 64, height: 32, degrees: degrees, autoCrop: true)
            #expect(p.width == expected.width && p.height == expected.height)
            let minAlpha = p.all.map(\.w).min()!
            #expect(minAlpha > 0.98, "\(degrees)° min alpha \(minAlpha)")
        }
    }

    @Test func largestInscribedRectangle() {
        // A square turned 45°: the inscribed square has half the area.
        let r = EditGraph.largestInscribedRectangle(width: 100, height: 100, sine: sin(.pi / 4), cosine: cos(.pi / 4))
        #expect(abs(r.width - 70.7107) < 1e-3 && abs(r.height - 70.7107) < 1e-3)
        // No turn: the whole rectangle.
        let none = EditGraph.largestInscribedRectangle(width: 64, height: 32, sine: 0, cosine: 1)
        #expect(none.width == 64 && none.height == 32)
        // A thin strip turned a lot is limited by its short side.
        let a = 30.0 * .pi / 180
        let thin = EditGraph.largestInscribedRectangle(width: 100, height: 10, sine: sin(a), cosine: cos(a))
        #expect(abs(thin.width - 5 / sin(a)) < 1e-9 && abs(thin.height - 5 / cos(a)) < 1e-9)
    }

    @Test func outputSizeMatchesRenderedExtentAtFullAndProxyScale() {
        let ops: [EditOperation] = [
            .crop(CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)), .rotate(degrees: 7, autoCrop: true),
            .resize(width: 50, height: 21, filter: .mitchell), .rotate90(turns: 1), .flip(horizontal: true),
            .rotate(degrees: -20, autoCrop: false), .blur(radius: 2), .lighting(brightness: 0.1, contrast: 0, gamma: 1, shadows: 0, highlights: 0),
        ]
        let size = EditGraph.outputSize(source: CGSize(width: 640, height: 320), operations: ops)
        let full = EditGraph.image(source: F.quadrants(width: 640, height: 320), sourceSize: CGSize(width: 640, height: 320),
                                   operations: ops, scale: 1)
        #expect(full.extent == CGRect(origin: .zero, size: size))
        for scale in [0.5, 0.3] {
            let source = F.quadrants(width: EditGraph.workingLength(640, scale: scale),
                                     height: EditGraph.workingLength(320, scale: scale))
            let proxy = EditGraph.image(source: source, sourceSize: CGSize(width: 640, height: 320), operations: ops, scale: scale)
            #expect(proxy.extent == CGRect(x: 0, y: 0, width: EditGraph.workingLength(Int(size.width), scale: scale),
                                           height: EditGraph.workingLength(Int(size.height), scale: scale)))
        }
    }

    @Test func identityOperationsAreSkipped() {
        let ops: [EditOperation] = [
            .rotate90(turns: 4), .rotate(degrees: 360, autoCrop: true), .crop(CGRect(x: -1, y: 0, width: 3, height: 1)),
            .blur(radius: 0), .sharpen(amount: 0, radius: 3), .lighting(brightness: 0, contrast: 0, gamma: 1, shadows: 0, highlights: 0),
            .curves(.identity), .levels(.identity), .sepia(intensity: 0), .resize(width: 0, height: 10, filter: .box),
        ]
        let p = render(ops)
        #expect(p.width == 64 && p.height == 32)
        #expect(corners(p) == [F.red, F.green, F.blue, F.white])
    }

    // MARK: - Filters with a radius

    @Test func blurKeepsSizeAndOpaqueEdges() {
        let p = render([.blur(radius: 4)])
        #expect(p.width == 64 && p.height == 32)
        #expect(p.all.allSatisfy { nearly($0.w, 1, 1e-3) })
        // The corner is still red (edges repeat rather than fade), the
        // boundary between red and green is a mix.
        #expect(p[0, 0].x > 0.95)
        let boundary = p[32, 4]
        #expect(boundary.x > 0.2 && boundary.x < 0.8 && boundary.y > 0.2 && boundary.y < 0.8)
    }

    @Test func blurRadiusScalesWithTheProxy() {
        // A 1 px wide transition blurred by 8 full-resolution pixels spreads
        // over the same fraction of the image on a half-size proxy.
        let step = { (w: Int) in F.image(width: w, height: 4) { x, _ in x < w / 2 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) } }
        let full = render([.blur(radius: 8)], source: step(128), fullSize: CGSize(width: 128, height: 4))
        let half = render([.blur(radius: 8)], source: step(64), scale: 0.5, fullSize: CGSize(width: 128, height: 4))
        // 8 full-res px left of the edge vs 4 proxy px left of it.
        #expect(abs(full[56, 2].x - half[28, 2].x) < 0.03, "\(full[56, 2].x) vs \(half[28, 2].x)")
        #expect(full[56, 2].x > 0.05)
    }

    @Test func sharpenLeavesFlatAreasAndOvershootsEdges() {
        let step = F.image(width: 64, height: 8) { x, _ in x < 32 ? SIMD4(0.2, 0.2, 0.2, 1) : SIMD4(0.6, 0.6, 0.6, 1) }
        let p = render([.sharpen(amount: 1, radius: 2)], source: step, fullSize: CGSize(width: 64, height: 8))
        #expect(nearly(p[2, 4].x, 0.2) && nearly(p[61, 4].x, 0.6))
        #expect(p[33, 4].x > 0.62 && p[30, 4].x < 0.18)
    }

    // MARK: - Colour

    @Test func grayscaleUsesDisplayP3Luminance() {
        let p = render([.grayscale])
        #expect(nearly(p.at(0.25, 0.25), SIMD4(0.2289746, 0.2289746, 0.2289746, 1)))
        #expect(nearly(p.at(0.75, 0.75), F.white))
    }

    @Test func negativeInvertsEncodedValuesAndKeepsAlpha() {
        // Linear 0.2140 is encoded 0.5, which inverts to itself; 0 and 1 swap.
        let grey = F.decode(0.5)
        let source = F.image(width: 4, height: 1) { x, _ in
            switch x {
            case 0: SIMD4(0, 0, 0, 1)
            case 1: SIMD4(1, 1, 1, 1)
            case 2: SIMD4(grey, grey, grey, 1)
            default: SIMD4(0.1 * 0.5, 0.1 * 0.5, 0.1 * 0.5, 0.5)   // premultiplied, half transparent
            }
        }
        let p = render([.negative], source: source, fullSize: CGSize(width: 4, height: 1))
        #expect(nearly(p[0, 0], F.white) && nearly(p[1, 0], SIMD4(0, 0, 0, 1)))
        #expect(nearly(p[2, 0].x, grey))
        let inverted = F.decode(1 - F.encode(0.1))
        #expect(nearly(p[3, 0], SIMD4(inverted * 0.5, inverted * 0.5, inverted * 0.5, 0.5)))
    }

    @Test func rgbAdjustIsAGainOfUpToOneStop() {
        let p = render([.rgbAdjust(red: 1, green: -1, blue: 0.5)], source: F.flat(0.4, width: 2, height: 2),
                       fullSize: CGSize(width: 2, height: 2))
        #expect(nearly(p[0, 0], SIMD4(0.8, 0.2, 0.4 * Float(pow(2, 0.5)), 1)))
    }

    @Test func sepiaTintsGreyWarm() {
        let p = render([.sepia(intensity: 1)], source: F.flat(0.5, width: 2, height: 2), fullSize: CGSize(width: 2, height: 2))
        #expect(p[0, 0].x > p[0, 0].y && p[0, 0].y > p[0, 0].z)
    }

    @Test func colorsTemperatureTintHueSaturationLightness() {
        let grey = F.flat(0.3, width: 2, height: 2)
        let size = CGSize(width: 2, height: 2)
        let warm = render([.colors(hue: 0, saturation: 0, lightness: 0, temperature: 1, tint: 0)], source: grey, fullSize: size)[0, 0]
        let cool = render([.colors(hue: 0, saturation: 0, lightness: 0, temperature: -1, tint: 0)], source: grey, fullSize: size)[0, 0]
        #expect(warm.x > warm.z + 0.05 && cool.z > cool.x + 0.05)
        let magenta = render([.colors(hue: 0, saturation: 0, lightness: 0, temperature: 0, tint: 1)], source: grey, fullSize: size)[0, 0]
        #expect(magenta.y < magenta.x - 0.02 && magenta.y < magenta.z - 0.02)

        let redImage = F.image(width: 2, height: 2) { _, _ in SIMD4(0.8, 0.1, 0.1, 1) }
        let cyan = render([.colors(hue: 180, saturation: 0, lightness: 0, temperature: 0, tint: 0)], source: redImage, fullSize: size)[0, 0]
        #expect(cyan.y > cyan.x && cyan.z > cyan.x)
        let desaturated = render([.colors(hue: 0, saturation: -1, lightness: 0, temperature: 0, tint: 0)], source: redImage, fullSize: size)[0, 0]
        #expect(nearly(desaturated.x, desaturated.y) && nearly(desaturated.y, desaturated.z))
        let white = render([.colors(hue: 0, saturation: 0, lightness: 1, temperature: 0, tint: 0)], source: redImage, fullSize: size)[0, 0]
        let black = render([.colors(hue: 0, saturation: 0, lightness: -1, temperature: 0, tint: 0)], source: redImage, fullSize: size)[0, 0]
        #expect(nearly(white, F.white) && nearly(black, SIMD4(0, 0, 0, 1)))
        // Half way to white on the encoded scale.
        let half = render([.colors(hue: 0, saturation: 0, lightness: 0.5, temperature: 0, tint: 0)], source: grey, fullSize: size)[0, 0]
        #expect(nearly(half.x, F.decode(F.encode(0.3) * 0.5 + 0.5)))
    }

    // MARK: - Lighting

    /// A horizontal ramp of `count` pixels from `from` to `to` (linear), opaque.
    func ramp(from: Float, to: Float, count: Int = 256) -> CIImage {
        F.image(width: count, height: 1) { x, _ in
            let v = from + (to - from) * Float(x) / Float(count - 1)
            return SIMD4(v, v, v, 1)
        }
    }

    func renderRamp(_ op: EditOperation, from: Float = 0, to: Float = 4, count: Int = 256) -> [Float] {
        let p = render([op], source: ramp(from: from, to: to, count: count), fullSize: CGSize(width: count, height: 1))
        return (0..<count).map { p[$0, 0].x }
    }

    @Test func brightnessContrastGammaOnTheEncodedScale() {
        let size = CGSize(width: 1, height: 1)
        func one(_ encoded: Float, _ op: EditOperation) -> Float {
            let v = F.decode(encoded)
            return F.encode(render([op], source: F.flat(v, width: 1, height: 1), fullSize: size)[0, 0].x)
        }
        #expect(nearly(one(0.3, .lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0)), 0.4))
        #expect(nearly(one(0.6, .lighting(brightness: 0, contrast: 1, gamma: 1, shadows: 0, highlights: 0)), 0.8))
        #expect(nearly(one(0.8, .lighting(brightness: 0, contrast: -1, gamma: 1, shadows: 0, highlights: 0)), 0.6))
        #expect(nearly(one(0.25, .lighting(brightness: 0, contrast: 0, gamma: 2, shadows: 0, highlights: 0)), 0.5))
        // HDR values aren't clamped by any of them.
        #expect(one(F.encode(3), .lighting(brightness: 0.1, contrast: 0.2, gamma: 1.2, shadows: 0, highlights: 0)) > 1.5)
    }

    @Test(arguments: [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (0.7, -0.7)])
    func shadowsAndHighlightsStayMonotoneAndKeepBlack(shadows: Double, highlights: Double) {
        let out = renderRamp(.lighting(brightness: 0, contrast: 0, gamma: 1, shadows: shadows, highlights: highlights))
        #expect(abs(out[0]) < 1e-4)
        for i in 1..<out.count {
            #expect(out[i] >= out[i - 1] - 1e-4, "not monotone at \(i): \(out[i - 1]) -> \(out[i])")
        }
    }

    @Test func shadowsLiftDarksAndHighlightsDarkenHDRWithoutTouchingTheOtherEnd() {
        let count = 256
        let input = (0..<count).map { 4 * Float($0) / Float(count - 1) }
        let lifted = renderRamp(.lighting(brightness: 0, contrast: 0, gamma: 1, shadows: 1, highlights: 0))
        let dark = 3   // linear 0.047
        #expect(lifted[dark] > input[dark] * 2)
        #expect(nearly(lifted[count - 1], 4, 1e-2))   // HDR highlight untouched
        let recovered = renderRamp(.lighting(brightness: 0, contrast: 0, gamma: 1, shadows: 0, highlights: -1))
        #expect(nearly(recovered[count - 1], 4 * Float(pow(2, -1.5)), 1e-2))   // darker, never brighter
        #expect(nearly(recovered[1], input[1], 1e-3))
    }

    // MARK: - Curves and levels

    @Test func curvesKernelMatchesTheCPUCurve() {
        let curves = ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.6), CurvePoint(x: 1, y: 1)],
                                red: ToneCurves.diagonal, green: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)],
                                blue: ToneCurves.diagonal)
        let table = curves.toneTable()
        let out = render([.curves(curves)], source: ramp(from: 0, to: 1), fullSize: CGSize(width: 256, height: 1))
        for x in stride(from: 0, to: 256, by: 17) {
            let v = Float(x) / 255
            let e = F.encode(v)
            let expected = SIMD4(F.decode(table.apply(e, channel: 0)), F.decode(table.apply(e, channel: 1)),
                                 F.decode(table.apply(e, channel: 2)), 1)
            #expect(nearly(out[x, 0], expected, 2e-3), "x \(x): \(out[x, 0]) vs \(expected)")
        }
        // The master curve lifts encoded 0.4 to 0.6 on red, whose own curve is the diagonal.
        let p = render([.curves(curves)], source: F.flat(F.decode(0.4), width: 1, height: 1), fullSize: CGSize(width: 1, height: 1))
        #expect(nearly(F.encode(p[0, 0].x), 0.6))
    }

    @Test func curvesKeepHDRHighlightsWhenTheCurveEndsOnTheDiagonal() {
        let sCurve = ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8),
                                         CurvePoint(x: 1, y: 1)])
        let out = renderRamp(.curves(sCurve))
        // Continued with the end segment's slope (0.8 here) past encoded 1.
        let expected = F.decode(sCurve.toneTable().apply(F.encode(4), channel: 0))
        #expect(nearly(out.last!, expected, 1e-2) && expected > 3, "\(out.last!) vs \(expected)")
        // A curve that flattens at the top clips HDR too, as it clips SDR.
        let clip = ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.8, y: 1), CurvePoint(x: 1, y: 1)])
        #expect(nearly(renderRamp(.curves(clip)).last!, 1, 1e-2))
    }

    @Test func levelsStretchClipAndBend() {
        let whitePoint = Levels(master: LevelsChannel(inputBlack: 0, inputWhite: 0.5, gamma: 1, outputBlack: 0, outputWhite: 1))
        let size = CGSize(width: 1, height: 1)
        func encodedResult(_ levels: Levels, _ encoded: Float) -> SIMD4<Float> {
            let p = render([.levels(levels)], source: F.flat(F.decode(encoded), width: 1, height: 1), fullSize: size)[0, 0]
            return SIMD4(F.encode(p.x), F.encode(p.y), F.encode(p.z), p.w)
        }
        #expect(nearly(encodedResult(whitePoint, 0.25).x, 0.5))
        #expect(nearly(encodedResult(whitePoint, 0.7).x, 1))   // clipped
        let red = Levels(red: LevelsChannel(inputBlack: 0, inputWhite: 1, gamma: 2, outputBlack: 0.1, outputWhite: 0.9))
        let r = encodedResult(red, 0.25)
        #expect(nearly(r.x, 0.1 + 0.5 * 0.8) && nearly(r.y, 0.25) && nearly(r.z, 0.25))
        // Default white point: HDR highlights keep their headroom.
        let lifted = Levels(master: LevelsChannel(inputBlack: 0.1, inputWhite: 1, gamma: 1, outputBlack: 0, outputWhite: 1))
        #expect(renderRamp(.levels(lifted)).last! > 3.5)
    }
}
