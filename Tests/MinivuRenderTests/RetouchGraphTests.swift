import Testing
import Foundation
import CoreGraphics
import CoreImage
import simd
@testable import MinivuRender

/// Clone stamp, healing brush and red-eye removal through `EditGraph`,
/// rendered and read back in the working space (linear, extended range).
@Suite struct RetouchGraphTests {
    typealias F = EditFixtures

    func render(_ ops: [EditOperation], source: CIImage, scale: Double = 1, fullSize: CGSize? = nil) -> F.Pixels {
        let size = fullSize ?? source.extent.size
        let image = EditGraph.image(source: source, sourceSize: size, operations: ops, scale: scale)
        #expect(image.extent == source.extent, "extent \(image.extent)")
        return F.pixels(image)
    }

    static let grey = SIMD4<Float>(0.2, 0.2, 0.2, 1)
    static let green = SIMD4<Float>(0.1, 0.8, 0.2, 1)

    /// 200 x 100, grey, with a green square at x 20..<60, y 10..<40 (top-left).
    static func squareImage() -> CIImage {
        F.image(width: 200, height: 100) { x, y in
            (20..<60).contains(x) && (10..<40).contains(y) ? green : grey
        }
    }

    /// A normalised point for pixel coordinates of a `w` x `h` image.
    func n(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CGPoint {
        CGPoint(x: x / w, y: y / h)
    }

    // MARK: - Payloads

    @Test func strokesAndSpotsDecodeMissingKeysWithDefaults() throws {
        let stroke = try JSONDecoder().decode(RetouchStroke.self, from: Data("{}".utf8))
        #expect(stroke == RetouchStroke(mode: .heal))
        let clone = try JSONDecoder().decode(RetouchStroke.self, from: Data(#"{"mode":"clone","opacity":0.5}"#.utf8))
        #expect(clone.mode == .clone && clone.opacity == 0.5 && clone.radius == RetouchStroke.defaultRadius)
        #expect(try JSONDecoder().decode(RedEyeSpot.self, from: Data("{}".utf8)) == RedEyeSpot())

        let op = EditOperation.retouch([RetouchStroke(mode: .clone, points: [n(1, 2), n(3, 4)], radius: 0.05,
                                                      hardness: 0.3, opacity: 0.7,
                                                      sourceOffset: CGVector(dx: 0.1, dy: -0.2))])
        #expect(try JSONDecoder().decode(EditOperation.self, from: JSONEncoder().encode(op)) == op)
        let eyes = EditOperation.redEye([RedEyeSpot(center: n(5, 6), radius: 0.03, strength: 0.8)])
        #expect(try JSONDecoder().decode(EditOperation.self, from: JSONEncoder().encode(eyes)) == eyes)
    }

    @Test func identityStrokes() {
        let offset = CGVector(dx: 0.1, dy: 0)
        #expect(RetouchStroke(mode: .clone).isIdentity)
        #expect(RetouchStroke(mode: .clone, points: [n(1, 1)]).isIdentity, "no source offset")
        #expect(!RetouchStroke(mode: .clone, points: [n(1, 1)], sourceOffset: offset).isIdentity)
        #expect(RetouchStroke(mode: .heal, points: [n(1, 1)], opacity: 0, sourceOffset: offset).isIdentity)
        #expect(RetouchStroke(mode: .heal, points: [n(1, 1)], radius: 0, sourceOffset: offset).isIdentity)
        #expect(EditOperation.retouch([RetouchStroke(mode: .clone)]).isIdentity)
        #expect(EditOperation.retouch([RetouchStroke(mode: .clone)]).title == "Clone Stamp")
    }

    // MARK: - Clone

    @Test func cloneCopiesTheSourceOntoTheDestination() {
        // Destination at (140, 25), source 100 px to the left inside the square.
        let stroke = RetouchStroke(mode: .clone, points: [n(140, 25)], radius: 0.1, hardness: 1,
                                   sourceOffset: CGVector(dx: -0.5, dy: 0))
        let p = render([.retouch([stroke])], source: Self.squareImage())
        #expect(nearly(p[140, 25], Self.green), "\(p[140, 25])")
        #expect(nearly(p[146, 25], Self.green), "within the radius")
        // Top-left origin: a flipped y would have copied grey from y = 75.
        #expect(p[140, 75] == Self.grey)
        #expect(p[140, 37] == Self.grey && p[152, 25] == Self.grey, "outside the radius")
        #expect(p[40, 25] == Self.green, "the source stays")
        #expect(p[100, 50] == Self.grey)
    }

    @Test func hardnessAndOpacityShapeTheBlend() {
        let soft = RetouchStroke(mode: .clone, points: [n(140, 25)], radius: 0.1, hardness: 0, opacity: 0.5,
                                 sourceOffset: CGVector(dx: -0.5, dy: 0))
        let p = render([.retouch([soft])], source: Self.squareImage())
        // Centre: half opacity, full coverage.
        #expect(nearly(p[140, 25], (Self.grey + Self.green) / 2, 0.02), "\(p[140, 25])")
        // Coverage falls off towards the rim with hardness 0.
        let halfway = p[145, 25].y
        #expect(halfway > Self.grey.y + 0.05 && halfway < p[140, 25].y - 0.05, "\(halfway)")
    }

    @Test func eachStrokeReadsTheOnesBefore() {
        let first = RetouchStroke(mode: .clone, points: [n(140, 25)], radius: 0.1, hardness: 1,
                                  sourceOffset: CGVector(dx: -0.5, dy: 0))
        // From the first stroke's result, 50 px up.
        let second = RetouchStroke(mode: .clone, points: [n(140, 75)], radius: 0.1, hardness: 1,
                                   sourceOffset: CGVector(dx: 0, dy: -0.5))
        let p = render([.retouch([first, second])], source: Self.squareImage())
        #expect(nearly(p[140, 75], Self.green), "\(p[140, 75])")
        // In the other order the second stroke copies grey.
        let q = render([.retouch([second, first])], source: Self.squareImage())
        #expect(nearly(q[140, 75], Self.grey))
        #expect(nearly(q[140, 25], Self.green))
    }

    @Test func aDraggedStrokeCoversItsPath() {
        let points = stride(from: 120.0, through: 180, by: 2).map { n($0, 25) }
        let stroke = RetouchStroke(mode: .clone, points: points, radius: 0.08, hardness: 1,
                                   sourceOffset: CGVector(dx: -0.5, dy: 0))
        let source = F.image(width: 200, height: 100) { x, _ in x < 100 ? Self.green : Self.grey }
        let p = render([.retouch([stroke])], source: source)
        for x in stride(from: 120, through: 180, by: 10) {
            #expect(nearly(p[x, 25], Self.green), "x \(x)")
        }
        #expect(p[100, 25] == Self.grey && p[150, 40] == Self.grey)
    }

    @Test func cloneKeepsHDRAndWideGamutValues() {
        let hdr = SIMD4<Float>(4, 2.5, -0.1, 1)
        let source = F.image(width: 200, height: 100) { x, _ in x < 100 ? hdr : Self.grey }
        let stroke = RetouchStroke(mode: .clone, points: [n(150, 50)], radius: 0.1, hardness: 1,
                                   sourceOffset: CGVector(dx: -0.5, dy: 0))
        let p = render([.retouch([stroke])], source: source)
        #expect(nearly(p[150, 50], hdr, 0.01), "\(p[150, 50])")
    }

    // MARK: - Heal

    /// `width` x 256: the left half a brighter textured area (the source),
    /// the right half `tone(x, y)` with a dark blemish of radius 6 at
    /// (width - 66, 128).
    static func healScene(width: Int = 256, tone: @escaping (Int, Int) -> Float, blemish: Bool = true,
                          scale: Float = 1) -> CIImage {
        F.image(width: width, height: 256) { x, y in
            if x < width / 2 {
                let t: Float = ((x / 3 + y / 3) % 2 == 0) ? 1.08 : 0.92
                let v = 0.6 * t * scale
                return SIMD4(v, v, v, 1)
            }
            let dx = Float(x - (width - 66)), dy = Float(y - 128)
            if blemish, dx * dx + dy * dy <= 36 { return SIMD4(0.05, 0.03, 0.03, 1) * SIMD4(scale, scale, scale, 1) }
            let v = tone(x, y) * scale
            return SIMD4(v, v, v, 1)
        }
    }

    static func healStroke(radius: Double = 12.0 / 256) -> RetouchStroke {
        RetouchStroke(mode: .heal, points: [CGPoint(x: 190.0 / 256, y: 0.5)], radius: radius,
                      hardness: 0.5, sourceOffset: CGVector(dx: -120.0 / 256, dy: 0))
    }

    @Test func healTakesToneFromTheDestinationAndTextureFromTheSource() {
        let p = render([.retouch([Self.healStroke()])], source: Self.healScene(tone: { _, _ in 0.3 }))
        var values: [Float] = []
        for y in 122...134 { for x in 184...196 { values.append(p[x, y].x) } }
        let mean = values.reduce(0, +) / Float(values.count)
        #expect(abs(mean - 0.3) < 0.015, "mean \(mean)")
        #expect(values.min()! > 0.24, "the blemish is gone: min \(values.min()!)")
        // The source's texture (±8%) came along, scaled to the darker tone.
        #expect(values.max()! - values.min()! > 0.03, "texture \(values.min()!)...\(values.max()!)")
        // Outside the brush nothing changed.
        #expect(p[170, 128] == SIMD4(0.3, 0.3, 0.3, 1) && p[190, 100] == SIMD4(0.3, 0.3, 0.3, 1))
    }

    @Test func healFollowsAGradientUnderTheStroke() {
        // Sky: brighter towards the bottom, 0.25 to 0.85 over the image.
        let tone: (Int, Int) -> Float = { _, y in 0.25 + 0.6 * Float(y) / 255 }
        let p = render([.retouch([Self.healStroke()])], source: Self.healScene(tone: tone))
        for y in [120, 128, 136] {
            let expected = tone(190, y)
            let row = (186...194).map { p[$0, y].x }
            let mean = row.reduce(0, +) / Float(row.count)
            #expect(abs(mean - expected) < 0.02, "y \(y): \(mean) vs \(expected)")
        }
    }

    @Test func healWorksOnHDRInput() {
        let p = render([.retouch([Self.healStroke()])], source: Self.healScene(tone: { _, _ in 0.3 }, scale: 8))
        var values: [Float] = []
        for y in 124...132 { for x in 186...194 { values.append(p[x, y].x) } }
        let mean = values.reduce(0, +) / Float(values.count)
        #expect(abs(mean - 2.4) < 0.12, "mean \(mean)")
        #expect(values.min()! > 1.9)
    }

    @Test func aScribbleCoveringAWideAreaStillFillsFromItsSurroundings() {
        // A zigzag four radii deep: its middle is far from any unbrushed
        // pixel. The scene is wide enough that the source's blur stays on
        // the textured half.
        var points: [CGPoint] = []
        for row in 0..<5 {
            let y = 104.0 + Double(row) * 12
            let xs = stride(from: 550.0, through: 598, by: 3).map { $0 }
            for x in row % 2 == 0 ? xs : xs.reversed() { points.append(CGPoint(x: x / 640, y: y / 256)) }
        }
        let stroke = RetouchStroke(mode: .heal, points: points, radius: 12.0 / 256, hardness: 0.5,
                                   sourceOffset: CGVector(dx: -400.0 / 640, dy: 0))
        let p = render([.retouch([stroke])], source: Self.healScene(width: 640, tone: { _, _ in 0.3 }))
        for (x, y) in [(574, 128), (559, 112), (589, 144)] {
            #expect(abs(p[x, y].x - 0.3) < 0.04, "(\(x), \(y)): \(p[x, y].x)")
        }
    }

    // MARK: - Proxy

    @Test func aHalfSizeProxyMatchesFullResolution() {
        // Smooth texture, so resampling differences stay small.
        func value(_ x: Double, _ y: Double) -> SIMD4<Float> {
            let v = 0.4 + 0.25 * sin(x / 7) * cos(y / 9) + 0.1 * sin((x + y) / 23)
            return SIMD4(Float(v), Float(v * 0.8), Float(v * 0.6), 1)
        }
        let full = F.image(width: 400, height: 300) { x, y in value(Double(x) + 0.5, Double(y) + 0.5) }
        // The proxy is the full image averaged 2 x 2, as a resample would.
        let proxy = F.image(width: 200, height: 150) { x, y in
            (value(Double(2 * x) + 0.5, Double(2 * y) + 0.5) + value(Double(2 * x) + 1.5, Double(2 * y) + 0.5)
                + value(Double(2 * x) + 0.5, Double(2 * y) + 1.5) + value(Double(2 * x) + 1.5, Double(2 * y) + 1.5)) / 4
        }
        let size = CGSize(width: 400, height: 300)
        let path = stride(from: 0.3, through: 0.7, by: 0.01).map { CGPoint(x: $0, y: 0.5 + 0.1 * sin($0 * 20)) }
        let ops: [EditOperation] = [
            .retouch([
                RetouchStroke(mode: .clone, points: path, radius: 0.04, hardness: 0.6,
                              sourceOffset: CGVector(dx: 0.05, dy: -0.3)),
                RetouchStroke(mode: .heal, points: path.map { CGPoint(x: $0.x, y: $0.y + 0.2) }, radius: 0.05,
                              hardness: 0.4, sourceOffset: CGVector(dx: -0.2, dy: 0.1)),
            ]),
            .redEye([RedEyeSpot(center: CGPoint(x: 0.2, y: 0.2), radius: 0.05)]),
        ]
        let big = render(ops, source: full, fullSize: size)
        let small = render(ops, source: proxy, scale: 0.5, fullSize: size)
        let reference = render([], source: proxy, scale: 0.5, fullSize: size)
        var total: Float = 0, worst: Float = 0, changed = 0
        for y in 0..<150 {
            for x in 0..<200 {
                let averaged = (big[2 * x, 2 * y] + big[2 * x + 1, 2 * y] + big[2 * x, 2 * y + 1]
                    + big[2 * x + 1, 2 * y + 1]) / 4
                let d = abs(averaged.x - small[x, y].x)
                total += d
                worst = max(worst, d)
                if abs(small[x, y].x - reference[x, y].x) > 0.01 { changed += 1 }
            }
        }
        let mean = total / Float(200 * 150)
        #expect(changed > 1000, "the strokes changed the image: \(changed) px")
        #expect(mean < 0.004, "mean difference \(mean)")
        #expect(worst < 0.08, "worst difference \(worst)")
    }

    // MARK: - Red-eye

    static func linear(_ r: Double, _ g: Double, _ b: Double) -> SIMD4<Float> {
        SIMD4(F.decode(Float(r / 255)), F.decode(Float(g / 255)), F.decode(Float(b / 255)), 1)
    }

    static let skin = linear(224, 172, 140)
    static let iris = linear(120, 70, 40)
    static let pupil = linear(200, 40, 40)
    static let highlight = SIMD4<Float>(1, 1, 1, 1)

    /// 300 x 200: skin, a brown iris of radius 20 at (100, 100), a red pupil
    /// of radius 10 with a white catchlight of radius 3 at (97, 97); the
    /// same eye with a dark, unreddened pupil at (220, 100).
    static func eyes(scale: Float = 1) -> CIImage {
        F.image(width: 300, height: 200) { x, y in
            func d(_ cx: Int, _ cy: Int) -> Float { Float((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() }
            let s = SIMD4<Float>(scale, scale, scale, 1)
            if d(97, 97) <= 3 { return highlight * s }
            if d(100, 100) <= 10 { return pupil * s }
            if d(220, 100) <= 10 { return linear(30, 25, 25) * s }
            if d(100, 100) <= 20 || d(220, 100) <= 20 { return iris * s }
            return skin * s
        }
    }

    static let spots = [RedEyeSpot(center: CGPoint(x: 100.0 / 300, y: 0.5), radius: 0.13),
                        RedEyeSpot(center: CGPoint(x: 220.0 / 300, y: 0.5), radius: 0.13)]

    func relativeChange(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let d = simd_abs(a - b) / simd_max(simd_abs(b), SIMD4(repeating: 1e-3))
        return max(d.x, d.y, d.z)
    }

    @Test(arguments: [Float(1), 3])
    func redEyeMakesThePupilANeutralDarkGrey(scale: Float) {
        let before = F.pixels(Self.eyes(scale: scale))
        let p = render([.redEye(Self.spots)], source: Self.eyes(scale: scale))
        for (x, y) in [(100, 100), (106, 104), (94, 106), (104, 92)] {
            let c = p[x, y]
            #expect(c.x <= max(c.y, c.z) * 1.15 + 1e-3, "(\(x), \(y)) still red: \(c)")
            #expect(c.x < 0.06 * scale, "(\(x), \(y)) dark: \(c)")
            #expect(c.y > 0.005 * scale, "(\(x), \(y)) not pure black: \(c)")
        }
        // The catchlight, the iris and the skin stay as they were.
        #expect(relativeChange(p[97, 97], before[97, 97]) < 0.01, "catchlight \(p[97, 97])")
        for (x, y) in [(115, 100), (100, 117), (86, 88), (123, 100), (100, 75), (40, 40)] {
            #expect(relativeChange(p[x, y], before[x, y]) < 0.01, "(\(x), \(y)): \(p[x, y]) was \(before[x, y])")
        }
        // An eye that isn't red is left alone (to the half-float precision
        // of the working format the patch is rendered in).
        var worst: Float = 0
        for y in 80...120 { for x in 200...240 { worst = max(worst, relativeChange(p[x, y], before[x, y])) } }
        #expect(worst < 0.002, "unreddened eye changed by \(worst)")
    }

    /// A dark, saturated brown iris measures as red as a pupil by redness
    /// alone, and a catchlight's soft edge is a pink blend of white and
    /// pupil: the iris must stay, the pink must go neutral.
    @Test func redEyeKeepsADarkBrownIrisAndClearsTheCatchlightsPinkEdge() {
        let darkIris = Self.linear(90, 40, 20)
        let pupil = Self.pupil
        let edge = Self.highlight * 0.7 + pupil * 0.3
        let source = F.image(width: 300, height: 200) { x, y in
            let d = Float((x - 100) * (x - 100) + (y - 100) * (y - 100)).squareRoot()
            let c = Float((x - 97) * (x - 97) + (y - 97) * (y - 97)).squareRoot()
            if c <= 2 { return Self.highlight }
            if c <= 3.5 { return SIMD4(edge.x, edge.y, edge.z, 1) }
            if d <= 10 { return pupil }
            if d <= 20 { return darkIris }
            return Self.skin
        }
        let before = F.pixels(source)
        #expect(RedEyeTuning.redness(red: Double(darkIris.x), green: Double(darkIris.y), blue: Double(darkIris.z))
            > RedEyeTuning.highThreshold, "the test's iris is as red as a pupil by redness")
        let p = render([.redEye([Self.spots[0]])], source: source)
        for (x, y) in [(97, 100), (100, 97), (94, 97)] {   // on the catchlight's edge ring
            let e = p[x, y]
            #expect(e.x <= max(e.y, e.z) * 1.12, "(\(x), \(y)) still pink: \(e) was \(before[x, y])")
        }
        #expect(relativeChange(p[97, 97], before[97, 97]) < 0.01, "catchlight \(p[97, 97])")
        #expect(p[100, 106].x < 0.06, "pupil corrected: \(p[100, 106])")
        for (x, y) in [(114, 100), (100, 115), (88, 112), (86, 100)] {
            #expect(relativeChange(p[x, y], before[x, y]) < 0.02, "iris (\(x), \(y)): \(p[x, y]) was \(before[x, y])")
        }
    }

    @Test func redEyeStrengthBlends() {
        var half = Self.spots[0]
        half.strength = 0.5
        let full = render([.redEye([Self.spots[0]])], source: Self.eyes())[100, 100]
        let blended = render([.redEye([half])], source: Self.eyes())[100, 100]
        #expect(nearly(blended.x, (Self.pupil.x + full.x) / 2, 0.01), "\(blended) between \(Self.pupil) and \(full)")
    }

    // MARK: - Masks

    @Test func strokeMaskCoverageAndDepth() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        for radius in [10.0, 100.0] {   // drawn at full size, then at 1/4 and magnified
            let mask = StrokeMask(points: [CGPoint(x: 200, y: 150)], radius: radius, hardness: 1, bounds: bounds)!
            let p = F.pixels(mask.image, bounds: bounds)
            // Pixels rows are top first: y up 150 is row 250.
            #expect(nearly(p[200, 249].x, 1, 0.01), "radius \(radius) centre \(p[200, 249])")
            #expect(p[Int(200 + radius * 1.02) + 1, 249].x < 0.01, "radius \(radius) outside")
            #expect(nearly(p[Int(200 + radius * 0.8), 249].x, 1, 0.02), "radius \(radius) hard until 90%")
            #expect(abs(mask.innerDistance - radius * 0.95) < radius * 0.15 + 1, "depth \(mask.innerDistance)")
        }
        // Clipped to the image, and nothing at all outside it.
        #expect(StrokeMask(points: [CGPoint(x: -50, y: 10)], radius: 20, hardness: 1, bounds: bounds) == nil)
        let edge = StrokeMask(points: [CGPoint(x: 5, y: 395)], radius: 20, hardness: 1, bounds: bounds)!
        #expect(edge.rect == CGRect(x: 0, y: 375, width: 25, height: 25))
    }
}
