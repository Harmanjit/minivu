import Testing
import Foundation
import CoreGraphics
import CoreImage
import Metal
@testable import MinivuRender

/// The Phase 6 effects through `EditGraph`, rendered and read back in the
/// working space (extended linear Display P3).
@Suite struct EffectsTests {
    typealias F = EditFixtures

    func render(_ ops: [EditOperation], source: CIImage, scale: Double = 1, fullSize: CGSize? = nil) -> F.Pixels {
        let size = fullSize ?? source.extent.size
        let image = EditGraph.image(source: source, sourceSize: size, operations: ops, scale: scale)
        #expect(image.extent.origin == .zero, "extent \(image.extent)")
        let expected = EditGraph.outputSize(source: size, operations: ops)
        #expect(Int(image.extent.width) == EditGraph.workingLength(Int(expected.width), scale: scale))
        #expect(Int(image.extent.height) == EditGraph.workingLength(Int(expected.height), scale: scale))
        return F.pixels(image)
    }

    /// The quadrant image (red, green / blue, white) at any size.
    func quadrants(_ width: Int, _ height: Int) -> CIImage { F.quadrants(width: width, height: height) }

    /// Mean of the pixels in a top-left-origin rectangle.
    func mean(_ p: F.Pixels, x: Range<Int>, y: Range<Int>) -> SIMD4<Float> {
        var sum = SIMD4<Float>(), count: Float = 0
        for yy in y { for xx in x { sum += p[xx, yy]; count += 1 } }
        return sum / count
    }

    func standardDeviation(_ values: [Float]) -> Float {
        let m = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(values.count)).squareRoot()
    }

    // MARK: - Drop shadow geometry

    @Test func shadowGrowsTheCanvasByItsReachAndMargin() {
        let shadow = DropShadow()   // offset 0.02, blur 0.02, margin 0.02
        // Short side 500: offset 10, reach 30, margin 10.
        let m = shadow.margins(width: 1000, height: 500)
        #expect(m == EdgeMargins(left: 30, top: 30, right: 50, bottom: 50))
        #expect(EditGraph.outputSize(source: CGSize(width: 1000, height: 500), operations: [.dropShadow(shadow)])
                == CGSize(width: 1080, height: 580))

        var left = shadow
        left.offsetX = -0.1
        left.blur = 0
        // A shadow thrown 50 px left needs 50 px on the left and none beyond the margin elsewhere.
        #expect(left.margins(width: 1000, height: 500) == EdgeMargins(left: 60, top: 10, right: 10, bottom: 20))

        var invisible = shadow
        invisible.opacity = 0
        #expect(invisible.margins(width: 1000, height: 500) == EdgeMargins(left: 10, top: 10, right: 10, bottom: 10))
        invisible.margin = 0
        #expect(invisible.isIdentity)
        #expect(!shadow.isIdentity)
    }

    @Test func shadowPlacesThePhotoInsideTheGrownCanvasAtFullAndHalfScale() {
        var shadow = DropShadow()
        shadow.opacity = 1
        let full = render([.dropShadow(shadow)], source: quadrants(400, 200))
        // Short side 200: offset 4, reach 12, margin 4 -> left/top 12, right/bottom 20.
        #expect(full.width == 432 && full.height == 232)
        #expect(full[12, 12] == F.red && full[211, 12] == F.red && full[212, 12] == F.green)
        #expect(full[12, 111] == F.red && full[12, 112] == F.blue && full[411, 211] == F.white)
        // Outside the shadow's reach the canvas is the white background.
        #expect(nearly(full[0, 0], F.white, 1e-3) && nearly(full[431, 0], F.white, 1e-3))
        // Right of and below the photo, the black shadow.
        let beside = full[414, 116]
        #expect(beside.x < 0.5 && beside.w > 0.999, "\(beside)")
        // Above the photo's top-right corner the shadow hasn't reached (it's moved down).
        #expect(nearly(full[430, 2], F.white, 2e-3))

        let half = render([.dropShadow(shadow)], source: quadrants(200, 100), scale: 0.5,
                          fullSize: CGSize(width: 400, height: 200))
        #expect(half.width == 216 && half.height == 116)
        #expect(half[6, 6] == F.red && half[205, 105] == F.white && half[105, 6] == F.red && half[106, 6] == F.green)
        // The same places at either scale agree.
        for (fx, fy) in [(0.02, 0.02), (0.97, 0.5), (0.5, 0.97), (0.99, 0.99), (0.3, 0.3)] {
            #expect(nearly(full.at(fx, fy), half.at(fx, fy), 0.05), "at \(fx), \(fy): \(full.at(fx, fy)) vs \(half.at(fx, fy))")
        }
    }

    @Test func transparentBackgroundAndRoundedCorners() {
        var shadow = DropShadow()
        shadow.background = EditColor(red: 1, green: 1, blue: 1, alpha: 0)
        shadow.cornerRadius = 0.2
        let p = render([.dropShadow(shadow)], source: F.flat(0.5, width: 200, height: 200))
        #expect(p[0, 0].w < 1e-3)
        // The photo's own corner (12, 12) is cut away by the rounding; its middle stays.
        #expect(p[12, 12].w < 0.05)
        #expect(nearly(p[112, 112], SIMD4(0.5, 0.5, 0.5, 1), 1e-3))
    }

    @Test func shadowColourIsTheChosenColour() {
        var shadow = DropShadow()
        shadow.opacity = 1
        shadow.blur = 0
        shadow.offsetX = 0.1
        shadow.offsetY = 0.1
        shadow.color = EditColor(red: 1, green: 0, blue: 0)
        let p = render([.dropShadow(shadow)], source: F.flat(0.5, width: 100, height: 100))
        // Offset 10, margin 2: photo at 2...101; the shadow's corner below right of it.
        let red = shadow.color.working
        #expect(nearly(p[108, 108], red, 2e-3), "\(p[108, 108]) vs \(red)")
        #expect(red.x > 0.8 && red.y > 0.02 && red.y < 0.05)   // sRGB red in linear Display P3
    }

    // MARK: - Frame

    @Test func frameMarginsForEachKind() {
        var frame = FrameStyle()   // width 0.04
        #expect(frame.margins(width: 1000, height: 500) == EdgeMargins(left: 20, top: 20, right: 20, bottom: 20))
        frame.kind = .polaroid
        #expect(frame.margins(width: 1000, height: 500) == EdgeMargins(left: 20, top: 20, right: 20, bottom: 70))
        #expect(EditGraph.outputSize(source: CGSize(width: 1000, height: 500), operations: [.frame(frame)])
                == CGSize(width: 1040, height: 590))
        frame.width = 0
        #expect(frame.isIdentity)
    }

    @Test func solidAndPolaroidFramesSurroundThePhotoWithTheirColour() {
        var frame = FrameStyle()
        frame.width = 0.1
        frame.color = EditColor(red: 0.5, green: 0.5, blue: 0.5)
        let grey = F.decode(0.5)
        let p = render([.frame(frame)], source: quadrants(200, 100))
        // Short side 100: 10 px all round.
        #expect(p.width == 220 && p.height == 120)
        let border = SIMD4<Float>(grey, grey, grey, 1)
        for (x, y) in [(0, 0), (219, 119), (9, 60), (210, 60), (110, 9), (110, 110)] {
            #expect(nearly(p[x, y], border, 2e-3), "(\(x), \(y)) \(p[x, y])")
        }
        #expect(p[10, 10] == F.red && p[209, 10] == F.green && p[10, 109] == F.blue && p[209, 109] == F.white)

        frame.kind = .polaroid
        let polaroid = render([.frame(frame)], source: quadrants(200, 100))
        #expect(polaroid.width == 220 && polaroid.height == 145)
        #expect(polaroid[10, 10] == F.red && polaroid[209, 109] == F.white)
        #expect(nearly(polaroid[110, 140], border, 2e-3) && nearly(polaroid[110, 110], border, 2e-3))

        // Half scale: the photo lands in the same place, proportionally.
        let half = render([.frame(frame)], source: quadrants(100, 50), scale: 0.5, fullSize: CGSize(width: 200, height: 100))
        #expect(half.width == 110 && half.height == 73)
        #expect(half[5, 5] == F.red && half[104, 54] == F.white && nearly(half[4, 4], border, 2e-3))
    }

    @Test func matteHasAnOuterBandAMatAndAKeyline() {
        var frame = FrameStyle()
        frame.kind = .matte
        frame.width = 0.2          // 40 px on a 200 px short side
        frame.lineWidth = 0.02     // 4 px keyline
        frame.color = .white
        frame.accentColor = .black
        frame.lineColor = EditColor(red: 1, green: 0, blue: 0)
        let p = render([.frame(frame)], source: F.flat(0.25, width: 200, height: 200))
        #expect(p.width == 280 && p.height == 280)
        // Band 0.3 of 40 = 12 px.
        #expect(nearly(p[0, 140], SIMD4(0, 0, 0, 1), 1e-3) && nearly(p[11, 140], SIMD4(0, 0, 0, 1), 1e-3))
        #expect(nearly(p[12, 140], F.white, 1e-3) && nearly(p[35, 140], F.white, 1e-3))
        let red = frame.lineColor.working
        #expect(nearly(p[36, 140], red, 1e-3) && nearly(p[39, 140], red, 1e-3), "\(p[36, 140])")
        #expect(nearly(p[40, 140], SIMD4(0.25, 0.25, 0.25, 1), 1e-3))
    }

    @Test func bevelIsLitFromTheTopLeft() {
        var frame = FrameStyle()
        frame.kind = .bevel
        frame.width = 0.2
        let p = render([.frame(frame)], source: F.flat(0.25, width: 200, height: 200))
        let top = p[140, 8].x, bottom = p[140, 271].x, left = p[8, 140].x, right = p[271, 140].x
        #expect(top > bottom + 0.2 && left > right + 0.1, "top \(top) bottom \(bottom) left \(left) right \(right)")
        // Shading only darkens: a white frame never turns HDR.
        #expect(p.all.allSatisfy { $0.x <= 1.0001 })
    }

    /// Operations after a frame move it as pixels: a flip mirrors it, and a
    /// shadow puts it on a larger canvas with the border still around the photo.
    @Test func laterOperationsMoveTheFrameWithThePhoto() {
        var frame = FrameStyle()
        frame.kind = .matte
        frame.width = 0.2          // 40 px: a 12 px black band, then white
        frame.lineWidth = 0
        frame.color = .white
        frame.accentColor = .black
        let source = F.image(width: 200, height: 100) { x, _ in x < 100 ? F.red : F.green }
        let flipped = render([.frame(frame), .flip(horizontal: true)], source: source)
        #expect(flipped.width == 240 && flipped.height == 140)
        #expect(nearly(flipped[5, 70], SIMD4(0, 0, 0, 1), 1e-3) && nearly(flipped[15, 70], F.white, 1e-3))
        #expect(nearly(flipped[234, 70], SIMD4(0, 0, 0, 1), 1e-3) && flipped[20, 70] == F.green && flipped[219, 70] == F.red)

        var shadow = DropShadow()
        shadow.opacity = 0
        shadow.margin = 0.05       // 5% of 140 = 7 px of white canvas
        let shadowed = render([.frame(frame), .dropShadow(shadow)], source: source)
        #expect(shadowed.width == 254 && shadowed.height == 154)
        #expect(nearly(shadowed[3, 77], F.white, 1e-3))
        #expect(nearly(shadowed[10, 77], SIMD4(0, 0, 0, 1), 1e-3) && nearly(shadowed[22, 77], F.white, 1e-3))
        #expect(shadowed[27, 77] == F.red)
    }

    /// Effects whose kernels read around a pixel stay inside the image when a
    /// later operation moves it: a shadow's margin stays background.
    @Test func effectsStayInsideTheirImageWhenMoved() {
        let source = F.image(width: 200, height: 100) { x, _ in x < 100 ? F.red : F.green }
        var shadow = DropShadow()
        shadow.opacity = 0
        shadow.margin = 0.05       // 5 px
        var ring = LensEffect()
        ring.ring = true
        ring.centerX = 0.02
        ring.radius = 0.5
        var frame = FrameStyle()
        frame.color = .black
        let effects: [EditOperation] = [.bumpMap(BumpMap()), .lens(LensEffect()), .lens(ring), .oilPaint(OilPaint()),
                                        .frame(frame)]
        for effect in effects {
            let p = render([effect, .dropShadow(shadow)], source: source)
            #expect((0..<5).allSatisfy { nearly(p[$0, p.height / 2], F.white, 1e-3) }, "\(effect.title): \(p[2, p.height / 2])")
            #expect(p[5, p.height / 2].y < 0.5, "\(effect.title): \(p[5, p.height / 2])")
        }
    }

    /// A full-resolution render large enough for Core Image to split the oil
    /// paint kernel into tiles comes out whole, through the renderer's own
    /// texture path.
    @Test func tiledOilPaintIsSeamless() throws {
        // A small ramp stretched to 24 MP (building it pixel by pixel takes
        // seconds in a debug build): green follows y, blue x, to within 1/64.
        let small = F.image(width: 64, height: 64) { x, y in SIMD4(0.5, (Float(y) + 0.5) / 64, (Float(x) + 0.5) / 64, 1) }
        let ramp = small.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 6032.0 / 64, y: 4032.0 / 64))
            .cropped(to: CGRect(x: 0, y: 0, width: 6032, height: 4032))
        let image = EditGraph.image(source: ramp, sourceSize: ramp.extent.size, operations: [.oilPaint(OilPaint())], scale: 1)
        let texture = Fixtures.readable(try EditRenderer.renderTexture(image, context: F.context, gpu: GPU.shared))
        for (x, y) in [(100, 100), (5900, 100), (100, 3900), (5900, 3900), (3010, 2010), (3022, 2022)] {
            var half = [Float16](repeating: 0, count: 4)
            texture.getBytes(&half, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let pixel = SIMD4<Float>(Float(half[0]), Float(half[1]), Float(half[2]), Float(half[3]))
            let expected = SIMD4<Float>(0.5, Float(y) / 4032, Float(x) / 6032, 1)
            #expect(nearly(pixel, expected, 0.03), "(\(x), \(y)): \(pixel)")
        }
    }

    // MARK: - Bump map

    @Test func bumpMapOnAFlatImageIsFlat() {
        let flat = F.flat(0.4, width: 48, height: 32)
        let over = render([.bumpMap(BumpMap())], source: flat)
        #expect(over.all.allSatisfy { nearly($0, SIMD4(0.4, 0.4, 0.4, 1), 1e-3) })
        var relief = BumpMap()
        relief.blend = 0
        let grey = render([.bumpMap(relief)], source: flat)
        let mid = F.decode(0.5)
        #expect(grey.all.allSatisfy { nearly($0, SIMD4(mid, mid, mid, 1), 1e-3) })
        // Flat HDR stays HDR under the relief.
        let hdr = render([.bumpMap(BumpMap())], source: F.flat(2.5, width: 48, height: 32))
        #expect(hdr.all.allSatisfy { nearly($0.x, 2.5, 1e-2) })
    }

    @Test func bumpMapLightsSlopesFacingTheLight() {
        // A bright square on dark: with light from the top left its left edge
        // (a slope facing left) is lit and its right edge is in shadow.
        let square = F.image(width: 64, height: 64) { x, y in
            (16..<48).contains(x) && (16..<48).contains(y) ? SIMD4(0.6, 0.6, 0.6, 1) : SIMD4(0.2, 0.2, 0.2, 1)
        }
        var bump = BumpMap()
        bump.blend = 0
        let p = render([.bumpMap(bump)], source: square)
        let mid = F.decode(0.5)
        #expect(p[16, 32].x > mid + 0.05 && p[47, 32].x < mid - 0.05, "left \(p[16, 32].x) right \(p[47, 32].x)")
        #expect(p[32, 16].x > mid + 0.05 && p[32, 47].x < mid - 0.05)
        #expect(nearly(p[32, 32].x, mid, 1e-3))

        // Proxy and full resolution light the same shapes.
        let big = F.image(width: 256, height: 256) { x, y in
            let d = hypot(Double(x) - 128, Double(y) - 128)
            let v = Float(0.2 + 0.4 * max(0, 1 - d / 80))
            return SIMD4(v, v, v, 1)
        }
        let small = F.image(width: 128, height: 128) { x, y in
            let d = hypot(Double(x) * 2 + 1 - 128, Double(y) * 2 + 1 - 128)
            let v = Float(0.2 + 0.4 * max(0, 1 - d / 80))
            return SIMD4(v, v, v, 1)
        }
        let full = render([.bumpMap(bump)], source: big)
        let half = render([.bumpMap(bump)], source: small, scale: 0.5, fullSize: CGSize(width: 256, height: 256))
        for (fx, fy) in [(0.35, 0.35), (0.65, 0.65), (0.5, 0.3), (0.3, 0.5), (0.5, 0.5)] {
            #expect(nearly(full.at(fx, fy).x, half.at(fx, fy).x, 0.02), "\(fx), \(fy): \(full.at(fx, fy).x) vs \(half.at(fx, fy).x)")
        }
    }

    /// Kernels first used on two threads at once stay themselves (see
    /// `EffectsKernels.kernel`): a bump map rendered beside oil paintings,
    /// whose structure tensor once stood in for the bump map's heights.
    @Test func effectsRenderedTogetherKeepTheirOwnKernels() async {
        let failures = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<60 {
                group.addTask {
                    let square = F.image(width: 64, height: 64) { x, y in
                        (16..<48).contains(x) && (16..<48).contains(y) ? SIMD4(0.6, 0.6, 0.6, 1) : SIMD4(0.2, 0.2, 0.2, 1)
                    }
                    let step = F.image(width: 96, height: 64) { x, _ in
                        x < 48 ? SIMD4(0.08, 0.08, 0.08, 1) : SIMD4(0.6, 0.6, 0.6, 1)
                    }
                    var bump = BumpMap()
                    bump.blend = 0
                    if i % 2 == 1 {
                        _ = F.pixels(EditGraph.image(source: step, sourceSize: CGSize(width: 96, height: 64),
                                                     operations: [.oilPaint(OilPaint())], scale: 1))
                        return true
                    }
                    let p = F.pixels(EditGraph.image(source: square, sourceSize: CGSize(width: 64, height: 64),
                                                     operations: [.bumpMap(bump)], scale: 1))
                    return p[16, 32].x > F.decode(0.5) + 0.05 && p[47, 32].x < F.decode(0.5) - 0.05
                }
            }
            var failures = 0
            for await ok in group where !ok { failures += 1 }
            return failures
        }
        #expect(failures == 0)
    }

    // MARK: - Sketch

    @Test func sketchTurnsFlatAreasToPaperAndEdgesDark() {
        for style in Sketch.Style.allCases {
            var sketch = Sketch()
            sketch.style = style
            sketch.radius = 4
            let step = F.image(width: 80, height: 40) { x, _ in
                x < 40 ? SIMD4(0.03, 0.05, 0.08, 1) : SIMD4(0.9, 0.85, 0.8, 1)
            }
            let p = render([.sketch(sketch)], source: step)
            // Far from the edge, on both sides: white paper (charcoal smudges
            // its shadows a little).
            let paper: Float = style == .charcoal ? 0.3 : 0.9
            #expect(p[2, 20].x > paper && p[77, 20].x > 0.9, "\(style): \(p[2, 20]) \(p[77, 20])")
            // Just on the dark side of the edge: a dark line.
            let line = p[38, 20]
            #expect(line.x < 0.3 && line.y < 0.3 && line.z < 0.3, "\(style): \(line)")
        }
        // Flat photos become blank paper, HDR ones too (paper is white, never brighter).
        let blank = render([.sketch(Sketch())], source: F.flat(3, width: 32, height: 32))
        #expect(blank.all.allSatisfy { nearly($0, F.white, 1e-2) })
        let grey = render([.sketch(Sketch())], source: F.flat(0.2, width: 32, height: 32))
        #expect(grey.all.allSatisfy { $0.x > 0.95 })
    }

    @Test func coloredPencilTintsLinesWithTheColour() {
        var sketch = Sketch()
        sketch.style = .coloredPencil
        sketch.strength = 1
        let step = F.image(width: 80, height: 40) { x, _ in x < 40 ? SIMD4(0.6, 0.02, 0.02, 1) : F.white }
        let p = render([.sketch(sketch)], source: step)
        let line = p[38, 20]
        #expect(line.x > line.y + 0.1 && line.x > line.z + 0.1, "\(line)")
    }

    // MARK: - Oil paint

    @Test func kuwaharaKeepsAStepSharpAndSmoothsNoise() {
        // Deterministic noise on a two-colour step.
        var generator = SystemRandomNumberGenerator.seeded(42)
        let noise = (0..<(96 * 64)).map { _ in Float.random(in: -0.06...0.06, using: &generator) }
        let step = F.image(width: 96, height: 64) { x, y in
            let base: Float = x < 48 ? 0.08 : 0.6
            let v = max(base + noise[y * 96 + x] * base, 0)
            return SIMD4(v, v, v, 1)
        }
        var paint = OilPaint()
        paint.radius = 4
        paint.levels = 60
        let p = render([.oilPaint(paint)], source: step)
        let input = F.pixels(step)
        // The edge stays within a pixel: two pixels either side keep their colours.
        #expect(abs(p[45, 32].x - 0.08) < 0.02 && abs(p[50, 32].x - 0.6) < 0.08, "\(p[45, 32].x) \(p[50, 32].x)")
        #expect(p[47, 32].x < 0.2 && p[48, 32].x > 0.4, "\(p[47, 32].x) \(p[48, 32].x)")
        // Noise in the flat right half is much reduced (on the encoded scale the kernel works in).
        let region = (60..<90).flatMap { x in (10..<54).map { y in (x, y) } }
        let before = standardDeviation(region.map { F.encode(input[$0.0, $0.1].x) })
        let after = standardDeviation(region.map { F.encode(p[$0.0, $0.1].x) })
        #expect(after < before * 0.5, "noise \(before) -> \(after)")
        #expect(p.all.allSatisfy { $0.w > 0.999 })
    }

    @Test func oilPaintKeepsHDRAndMatchesAtHalfScale() {
        let ramp = F.image(width: 128, height: 64) { x, _ in
            let v = Float(x) / 127 * 3
            return SIMD4(v, v * 0.5, v * 0.25, 1)
        }
        let rampHalf = F.image(width: 64, height: 32) { x, _ in
            let v = (Float(x) * 2 + 0.5) / 127 * 3
            return SIMD4(v, v * 0.5, v * 0.25, 1)
        }
        let paint = OilPaint()
        let full = render([.oilPaint(paint)], source: ramp)
        #expect(full.at(0.95, 0.5).x > 2)
        let half = render([.oilPaint(paint)], source: rampHalf, scale: 0.5, fullSize: CGSize(width: 128, height: 64))
        for fx in [0.2, 0.5, 0.8] {
            let a = F.encode(full.at(fx, 0.5).x), b = F.encode(half.at(fx, 0.5).x)
            #expect(abs(a - b) < 0.06, "\(fx): \(a) vs \(b)")
        }
    }

    // MARK: - Lens

    /// Where the lens samples for an output point `d` pixels from its centre.
    func lensSample(distance d: Double, radius: Double, magnification: Double) -> Double {
        let t = d / radius
        guard t < 1 else { return d }
        let h = t * t * (3 - 2 * t)
        return d * ((1 / magnification) * (1 - h) + h)
    }

    @Test func lensMagnifiesTheCentreAndLeavesTheRestAlone() {
        // Red is x, green is y (top row 0), both in pixels / 10, up to 6.4: HDR.
        let grid = F.image(width: 64, height: 64) { x, y in SIMD4((Float(x) + 0.5) / 10, (Float(y) + 0.5) / 10, 0, 1) }
        var lens = LensEffect()
        lens.centerX = 0.5
        lens.centerY = 0.5
        lens.radius = 0.4          // 25.6 px
        lens.magnification = 2
        let p = render([.lens(lens)], source: grid)
        // Pixel (36, 32) is 4.5 px right of the centre (32, 32).
        let d = 4.5
        let sampled = 32 + lensSample(distance: d, radius: 25.6, magnification: 2)
        #expect(nearly(p[36, 31].x, Float(sampled / 10), 0.01), "\(p[36, 31].x) vs \(sampled / 10)")
        #expect(p[36, 31].x < Float(36.5 / 10) - 0.15)   // magnified: closer to the centre's value
        // Outside the lens nothing moves.
        #expect(nearly(p[2, 2], SIMD4(0.25, 0.25, 0, 1), 1e-3) && nearly(p[63, 40], SIMD4(6.35, 4.05, 0, 1), 1e-3))
        #expect(p.all.contains { $0.x > 6 })   // HDR values survive

        // Half scale: the same image, smaller.
        let small = F.image(width: 32, height: 32) { x, y in SIMD4((Float(x) * 2 + 1) / 10, (Float(y) * 2 + 1) / 10, 0, 1) }
        let half = render([.lens(lens)], source: small, scale: 0.5, fullSize: CGSize(width: 64, height: 64))
        for (fx, fy) in [(0.55, 0.5), (0.4, 0.6), (0.7, 0.3), (0.1, 0.9)] {
            #expect(nearly(p.at(fx, fy), half.at(fx, fy), 0.12), "\(fx), \(fy): \(p.at(fx, fy)) vs \(half.at(fx, fy))")
        }
    }

    @Test func pinchAndRing() {
        let grid = F.image(width: 64, height: 64) { x, _ in SIMD4((Float(x) + 0.5) / 64, 0.2, 0.2, 1) }
        var lens = LensEffect()
        lens.magnification = 0.5
        lens.radius = 0.4
        let p = render([.lens(lens)], source: grid)
        // Pinched: a point right of the centre shows something further right.
        #expect(p[36, 31].x > Float(36.5 / 64) + 0.02)
        lens.magnification = 1
        #expect(lens.isIdentity)
        lens.ring = true
        #expect(!lens.isIdentity)
        let ring = render([.lens(lens)], source: grid)
        // The rim sits just inside the radius (25.6 px) and lightens towards the top left.
        let rim = ring[14, 14]   // 24.7 px from the centre, up and left
        #expect(rim.y > 0.3, "\(rim)")
        #expect(nearly(ring[32, 32], grid.pixel(32, 32), 1e-3))
    }

    // MARK: - Codable

    @Test func payloadsRoundTripAndDecodeMissingKeysWithDefaults() throws {
        var shadow = DropShadow()
        shadow.opacity = 0.3
        shadow.background = EditColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0)
        var frame = FrameStyle()
        frame.kind = .matte
        var bump = BumpMap()
        bump.angle = 45
        var sketch = Sketch()
        sketch.style = .charcoal
        var paint = OilPaint()
        paint.levels = 12
        var lens = LensEffect()
        lens.ring = true
        let ops: [EditOperation] = [.dropShadow(shadow), .frame(frame), .bumpMap(bump), .sketch(sketch),
                                    .oilPaint(paint), .lens(lens)]
        let data = try JSONEncoder().encode(ops)
        #expect(try JSONDecoder().decode([EditOperation].self, from: data) == ops)

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try decoder.decode(type, from: Data(json.utf8))
        }
        #expect(try decode(DropShadow.self, "{}") == DropShadow())
        var partial = DropShadow()
        partial.opacity = 0.3
        partial.color = EditColor(red: 1, green: 0, blue: 0)
        #expect(try decode(DropShadow.self, #"{"opacity": 0.3, "color": {"red": 1}}"#) == partial)
        #expect(try decode(FrameStyle.self, "{}") == FrameStyle())
        #expect(try decode(FrameStyle.self, #"{"kind": "bevel"}"#).kind == .bevel)
        #expect(try decode(BumpMap.self, "{}") == BumpMap())
        #expect(try decode(Sketch.self, "{}") == Sketch())
        #expect(try decode(OilPaint.self, #"{"radius": 7}"#).levels == OilPaint().levels)
        #expect(try decode(LensEffect.self, #"{"centerX": 0.2}"#).radius == LensEffect().radius)
        // A wrong type is still an error, not a silent default.
        #expect(throws: DecodingError.self) { try decode(OilPaint.self, #"{"levels": "many"}"#) }
    }

    @Test func defaultRadiiScaleWithThePhoto() {
        #expect(OilPaint.defaultRadius(width: 6000, height: 4000) == 4)
        #expect(OilPaint.defaultRadius(width: 1500, height: 1000) == 1)
        #expect(OilPaint.defaultRadius(width: 12000, height: 8000) == 8)
        #expect(Sketch.defaultRadius(width: 6000, height: 4000) == 6)
        #expect(Sketch.defaultRadius(width: 3000, height: 2000) == 3)
    }
}

extension CIImage {
    /// One pixel of an image at the origin, top row first.
    func pixel(_ x: Int, _ yTop: Int) -> SIMD4<Float> {
        EditFixtures.pixels(self)[x, yTop]
    }
}

extension SystemRandomNumberGenerator {
    /// A tiny deterministic generator for test noise.
    static func seeded(_ seed: UInt64) -> SeededGenerator { SeededGenerator(state: seed) }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
