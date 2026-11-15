import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuRender

/// Auto enhance, noise reduction, vignette, perspective correction, canvas
/// size and the watermark through `EditGraph`, rendered and read back in
/// the working space (extended linear Display P3).
@Suite(.offCooperativePool) struct CorrectionsTests {
    typealias F = EditFixtures

    /// What Core Image's analysis suggested for a dull, flat photo (measured
    /// on macOS 27), stored as Auto Enhance stores it.
    static let dullPhotoEnhancement = AutoEnhance(filters: [
        .init(name: "CIVibrance", numbers: ["inputAmount": 0.109]),
        .init(name: "CIToneCurve", numbers: ["inputExtrapolate": 1], vectors: [
            "inputPoint0": [0.248, 0], "inputPoint1": [0.422, 0.231], "inputPoint2": [0.549, 0.462],
            "inputPoint3": [0.697, 0.731], "inputPoint4": [0.9, 1],
        ]),
        .init(name: "CIHighlightShadowAdjust", numbers: ["inputRadius": 0, "inputShadowAmount": 0.457,
                                                         "inputHighlightAmount": 1]),
    ])

    static var textWatermark: Watermark {
        var w = Watermark()
        w.text = "© minivu"
        return w
    }

    func render(_ ops: [EditOperation], source: CIImage, scale: Double = 1, fullSize: CGSize? = nil) -> F.Pixels {
        let size = fullSize ?? source.extent.size
        let image = EditGraph.image(source: source, sourceSize: size, operations: ops, scale: scale)
        #expect(image.extent.origin == .zero, "extent \(image.extent)")
        let expected = EditGraph.outputSize(source: size, operations: ops)
        #expect(Int(image.extent.width) == EditGraph.workingLength(Int(expected.width), scale: scale))
        #expect(Int(image.extent.height) == EditGraph.workingLength(Int(expected.height), scale: scale))
        return F.pixels(image)
    }

    func standardDeviation(_ values: [Float]) -> Float {
        let m = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(values.count)).squareRoot()
    }

    /// A grey of `value` with deterministic noise of about `amplitude`.
    func noisy(_ width: Int, _ height: Int, value: Float = 0.5, amplitude: Float = 0.08) -> CIImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return F.image(width: width, height: height) { _, _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let n = Float(Int(state >> 40) % 2001 - 1000) / 1000 * amplitude
            let v = value + n
            return SIMD4(v, v, v, 1)
        }
    }

    /// The bounding box (top-left origin) of pixels that differ from `value`.
    func changedBox(_ p: F.Pixels, from value: Float, tolerance: Float = 0.05) -> CGRect {
        var box = CGRect.null
        for y in 0..<p.height {
            for x in 0..<p.width where abs(p[x, y].x - value) > tolerance {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    // MARK: - The operations as values

    @Test func everyNewOperationRoundTripsThroughJSON() throws {
        var picture = Watermark()
        picture.kind = .image
        picture.imageBookmark = Data([1, 2, 3, 4])
        picture.imageName = "logo.png"
        picture.tiled = true
        let ops: [EditOperation] = [
            .autoEnhance(Self.dullPhotoEnhancement),
            .noiseReduction(level: 0.4, sharpness: 0.8),
            .vignette(amount: -0.3, radius: 0.4, feather: 0.6),
            .perspective(PerspectiveQuad(topLeft: CGPoint(x: 0.1, y: 0.05), topRight: CGPoint(x: 0.9, y: 0),
                                         bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 0.95))),
            .canvasSize(CanvasSize(width: 1200, height: 800, anchor: .bottomLeft,
                                   fill: EditColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0))),
            .watermark(Self.textWatermark),
            .watermark(picture),
        ]
        let data = try JSONEncoder().encode(ops)
        #expect(try JSONDecoder().decode([EditOperation].self, from: data) == ops)
    }

    /// Documents saved before a field existed keep loading, with defaults.
    @Test func missingFieldsDecodeAsDefaults() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Watermark.self, from: Data("{}".utf8)) == Watermark())
        #expect(try decoder.decode(PerspectiveQuad.self, from: Data("{}".utf8)) == PerspectiveQuad())
        #expect(try decoder.decode(CanvasSize.self, from: Data(#"{"width":10,"height":20}"#.utf8))
                == CanvasSize(width: 10, height: 20))
        #expect(try decoder.decode(AutoEnhance.self, from: Data("{}".utf8)) == AutoEnhance())
    }

    @Test func titlesIdentityAndGeometry() {
        let quad = PerspectiveQuad(topLeft: CGPoint(x: 0.1, y: 0), topRight: CGPoint(x: 0.9, y: 0),
                                   bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
        let cases: [(EditOperation, String, identity: Bool, geometry: Bool)] = [
            (.autoEnhance(Self.dullPhotoEnhancement), "Auto Enhance", false, false),
            (.autoEnhance(AutoEnhance()), "Auto Enhance", true, false),
            // A filter this Mac doesn't render is never instantiated.
            (.autoEnhance(AutoEnhance(filters: [.init(name: "CIRedEyeCorrection")])), "Auto Enhance", true, false),
            (.noiseReduction(level: 0.5, sharpness: 0), "Noise Reduction", false, false),
            (.noiseReduction(level: 0, sharpness: 0.4), "Noise Reduction", false, false),
            (.noiseReduction(level: 0, sharpness: 0), "Noise Reduction", true, false),
            (.vignette(amount: 0.5, radius: 0.5, feather: 0.5), "Vignette", false, false),
            (.vignette(amount: 0, radius: 0.5, feather: 0.5), "Vignette", true, false),
            (.perspective(quad), "Perspective", false, true),
            (.perspective(PerspectiveQuad()), "Perspective", true, true),
            (.canvasSize(CanvasSize(width: 100, height: 50)), "Canvas Size", false, true),
            (.canvasSize(CanvasSize(width: 0, height: 50)), "Canvas Size", true, true),
            (.watermark(Self.textWatermark), "Watermark", false, false),
            (.watermark(Watermark()), "Watermark", true, false),
        ]
        for (op, title, identity, geometry) in cases {
            #expect(op.title == title)
            #expect(op.isIdentity == identity, "\(op)")
            #expect(op.changesGeometry == geometry, "\(op)")
        }
        var invisible = Self.textWatermark
        invisible.opacity = 0
        #expect(invisible.isIdentity)
        var blank = Self.textWatermark
        blank.text = " \n "
        #expect(blank.isIdentity)
        var noPicture = Watermark()
        noPicture.kind = .image
        #expect(noPicture.isIdentity)
    }

    // MARK: - Auto enhance

    /// A dull, low-contrast warm picture as the analysis would see it.
    func dullPhoto() -> CGImage {
        let width = 400, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
            CGColor(srgbRed: 0.45, green: 0.4, blue: 0.33, alpha: 1), CGColor(srgbRed: 0.7, green: 0.64, blue: 0.55, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        return context.makeImage()!
    }

    @Test func autoEnhanceStoresWhatTheAnalysisSuggestsAndRendersIt() throws {
        let photo = dullPhoto()
        let enhance = AutoEnhance.analyse(CIImage(cgImage: photo))
        #expect(!enhance.isIdentity, "nothing suggested for a dull photo")
        #expect(enhance.filters.allSatisfy { AutoEnhance.knownFilters.contains($0.name) })
        // Measured once, then plain values: the same suggestion every time.
        #expect(AutoEnhance.analyse(CIImage(cgImage: photo)) == enhance)

        let source = F.image(width: 200, height: 20) { x, _ in
            let v = 0.15 + 0.25 * Float(x) / 199
            return SIMD4(v, v, v, 1)
        }
        let before = F.pixels(source)
        let after = render([.autoEnhance(enhance)], source: source)
        let spread = { (p: F.Pixels) in p[199, 10].x - p[0, 10].x }
        #expect(spread(after) > spread(before) * 1.2, "contrast \(spread(before)) -> \(spread(after))")

        // The same stored filters on a half-size proxy give the same picture.
        let half = F.image(width: 100, height: 10) { x, _ in
            let v = 0.15 + 0.25 * Float(x) / 99
            return SIMD4(v, v, v, 1)
        }
        let proxy = render([.autoEnhance(enhance)], source: half, scale: 0.5, fullSize: CGSize(width: 200, height: 20))
        for f in [0.1, 0.5, 0.9] {
            #expect(nearly(proxy.at(f, 0.5).x, after.at(f, 0.5).x, 0.02), "at \(f)")
        }
    }

    @Test func autoEnhanceStoresLengthsInFullResolutionPixels() throws {
        // A radius suggested for a quarter-size rendering is four times as
        // many pixels of the full image; the graph scales it back per render.
        let filter = try #require(CIFilter(name: "CIHighlightShadowAdjust"))
        filter.setValue(3, forKey: "inputRadius")
        filter.setValue(0.4, forKey: "inputShadowAmount")
        let stored = try #require(AutoEnhance.store(filter, analysedScale: 0.25))
        #expect(stored.numbers["inputRadius"] == 12)
        #expect(abs((stored.numbers["inputShadowAmount"] ?? 0) - 0.4) < 1e-6)
        #expect(AutoEnhance.store(try #require(CIFilter(name: "CIRedEyeCorrection")), analysedScale: 1) == nil)
    }

    // MARK: - Noise reduction

    @Test func noiseReductionSmoothsNoiseAndKeepsTheEdgesOpaque() {
        let source = noisy(160, 120)
        let before = standardDeviation(F.pixels(source).all.map(\.x))
        let after = render([.noiseReduction(level: 1, sharpness: 0)], source: source)
        let smoothed = standardDeviation(after.all.map(\.x))
        #expect(smoothed < before * 0.6, "noise \(before) -> \(smoothed)")
        // Repeated edges: the border isn't faded towards transparent.
        for (x, y) in [(0, 0), (159, 0), (0, 119), (159, 119), (80, 0)] {
            #expect(nearly(after[x, y].w, 1, 1e-3), "alpha at \(x), \(y)")
        }

        // On a proxy the level shrinks with the scale, as the noise a
        // downsample leaves does: the same pixels smooth far less at 0.1.
        let asProxy = render([.noiseReduction(level: 1, sharpness: 0)], source: source, scale: 0.1,
                             fullSize: CGSize(width: 1600, height: 1200))
        #expect(standardDeviation(asProxy.all.map(\.x)) > smoothed * 1.3)
    }

    // MARK: - Vignette

    @Test func vignetteDarkensTheCornersByItsStops() {
        let source = F.flat(0.5, width: 400, height: 200)
        let dark = render([.vignette(amount: 0.5, radius: 0, feather: 1)], source: source)
        #expect(nearly(dark[200, 100].x, 0.5, 0.005), "centre \(dark[200, 100])")
        // One stop at the corners for amount 0.5 (the corner pixel's centre is
        // a hair inside the corner itself).
        #expect(nearly(dark[0, 0].x, 0.25, 0.01), "corner \(dark[0, 0])")
        #expect(nearly(dark[399, 199].x, 0.25, 0.01))
        #expect(dark[0, 0].w == 1)

        let light = render([.vignette(amount: -0.5, radius: 0, feather: 1)], source: source)
        #expect(nearly(light[0, 0].x, 1, 0.02), "lightened corner \(light[0, 0])")

        // Inside the radius nothing changes.
        let ringed = render([.vignette(amount: 1, radius: 0.6, feather: 0.2)], source: source)
        #expect(ringed[200 + 100, 100].x == 0.5)

        // Fractions of the image: the proxy darkens the same places as much.
        let proxy = render([.vignette(amount: 0.5, radius: 0.3, feather: 0.6)], source: F.flat(0.5, width: 200, height: 100),
                           scale: 0.5, fullSize: CGSize(width: 400, height: 200))
        let full = render([.vignette(amount: 0.5, radius: 0.3, feather: 0.6)], source: source)
        for (fx, fy) in [(0.1, 0.1), (0.3, 0.8), (0.95, 0.5)] {
            #expect(nearly(proxy.at(fx, fy).x, full.at(fx, fy).x, 0.01), "at \(fx), \(fy)")
        }
    }

    // MARK: - Perspective

    @Test func perspectiveOutputSizeFollowsTheLongerEdges() {
        let quad = PerspectiveQuad(topLeft: CGPoint(x: 0.1, y: 0), topRight: CGPoint(x: 0.9, y: 0),
                                   bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
        let size = quad.outputSize(width: 1000, height: 500)
        #expect(size.width == 1000 && size.height == 510)   // the bottom edge; hypot(100, 500) = 509.9
        #expect(EditGraph.outputSize(source: CGSize(width: 1000, height: 500), operations: [.perspective(quad)])
                == CGSize(width: 1000, height: 510))

        // A crossed quadrilateral (top corners swapped) has no correction.
        var crossed = quad
        crossed.corners = [quad.topRight, quad.topLeft, quad.bottomRight, quad.bottomLeft]
        #expect(!crossed.isValid && crossed.isIdentity)
        // Corners off the image are held to it.
        var outside = PerspectiveQuad()
        outside.topLeft = CGPoint(x: -3, y: -1)
        #expect(outside.isIdentity)
    }

    @Test func squareToQuadMapsTheCornersExactly() {
        let p = [CGPoint(x: 10, y: 20), CGPoint(x: 300, y: 5), CGPoint(x: 280, y: 210), CGPoint(x: 30, y: 190)]
        let m = PerspectiveQuad.squareToQuad(p[0], p[1], p[2], p[3])
        func map(_ u: Double, _ v: Double) -> CGPoint {
            let w = m[6] * u + m[7] * v + 1
            return CGPoint(x: (m[0] * u + m[1] * v + m[2]) / w, y: (m[3] * u + m[4] * v + m[5]) / w)
        }
        for (i, (u, v)) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].enumerated() {
            let q = map(u, v)
            #expect(abs(q.x - p[i].x) < 1e-6 && abs(q.y - p[i].y) < 1e-6, "corner \(i): \(q)")
        }
    }

    @Test func perspectivePullsTheQuadOntoTheRectangle() {
        // An upright quadrilateral is a crop: the middle half of the
        // quadrants keeps all four colours, a quadrant each.
        let inner = PerspectiveQuad(topLeft: CGPoint(x: 0.25, y: 0.25), topRight: CGPoint(x: 0.75, y: 0.25),
                                    bottomRight: CGPoint(x: 0.75, y: 0.75), bottomLeft: CGPoint(x: 0.25, y: 0.75))
        let out = render([.perspective(inner)], source: F.quadrants(width: 200, height: 100))
        #expect(out.width == 100 && out.height == 50)
        #expect(nearly(out.at(0.25, 0.25), F.red) && nearly(out.at(0.75, 0.25), F.green))
        #expect(nearly(out.at(0.25, 0.75), F.blue) && nearly(out.at(0.75, 0.75), F.white))

        // A trapezoid: a converging pair of verticals drawn on the image
        // comes out vertical. Lines at x 0.3 -> 0.2 and 0.7 -> 0.8 from top
        // to bottom, inside the quad whose sides follow them.
        let w = 400, h = 200
        let source = F.image(width: w, height: h) { x, y in
            let t = Double(y) / Double(h - 1)
            let left = (0.3 - 0.1 * t) * Double(w), right = (0.7 + 0.1 * t) * Double(w)
            let onLine = abs(Double(x) - left) < 2 || abs(Double(x) - right) < 2
            return onLine ? F.white : SIMD4(0, 0, 0, 1)
        }
        let quad = PerspectiveQuad(topLeft: CGPoint(x: 0.3, y: 0), topRight: CGPoint(x: 0.7, y: 0),
                                   bottomRight: CGPoint(x: 0.8, y: 1), bottomLeft: CGPoint(x: 0.2, y: 1))
        let corrected = render([.perspective(quad)], source: source)
        // The lines are now the left and right edges, top to bottom.
        for fy in [0.1, 0.5, 0.9] {
            let y = Int(fy * Double(corrected.height))
            #expect(corrected[0, y].x > 0.4, "left edge at \(fy)")
            #expect(corrected[corrected.width - 1, y].x > 0.4, "right edge at \(fy)")
            #expect(corrected[corrected.width / 2, y].x < 0.05, "middle at \(fy)")
        }
    }

    @Test func perspectiveDetectorFindsADrawnRectangle() throws {
        let width = 800, height = 600
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Corners in top-left coordinates; the context's y points up.
        let corners = [CGPoint(x: 220, y: 140), CGPoint(x: 600, y: 110), CGPoint(x: 640, y: 470), CGPoint(x: 180, y: 450)]
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.92, alpha: 1))
        context.move(to: CGPoint(x: corners[0].x, y: CGFloat(height) - corners[0].y))
        for c in corners.dropFirst() { context.addLine(to: CGPoint(x: c.x, y: CGFloat(height) - c.y)) }
        context.closePath()
        context.fillPath()
        let found = try #require(PerspectiveDetector.detect(in: context.makeImage()!))
        for (got, want) in zip(found.corners, corners) {
            #expect(abs(got.x - want.x / CGFloat(width)) < 0.03 && abs(got.y - want.y / CGFloat(height)) < 0.03,
                    "\(got) for \(want)")
        }
        // Nothing four-sided on a plain grey.
        let plain = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        plain.setFillColor(CGColor(gray: 0.5, alpha: 1))
        plain.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(PerspectiveDetector.detect(in: plain.makeImage()!) == nil)
    }

    // MARK: - Canvas size

    @Test func canvasSizePlacesTheImageAtTheAnchor() {
        let source = F.quadrants(width: 64, height: 32)
        let black = EditColor.black
        let topLeft = render([.canvasSize(CanvasSize(width: 100, height: 50, anchor: .topLeft, fill: black))], source: source)
        #expect(topLeft.width == 100 && topLeft.height == 50)
        #expect(nearly(topLeft[5, 5], F.red) && nearly(topLeft[63, 31], F.white))
        #expect(nearly(topLeft[64, 0], SIMD4(0, 0, 0, 1)) && nearly(topLeft[99, 49], SIMD4(0, 0, 0, 1)))

        let corner = render([.canvasSize(CanvasSize(width: 100, height: 50, anchor: .bottomRight, fill: black))],
                            source: source)
        #expect(nearly(corner[99, 49], F.white) && nearly(corner[36, 18], F.red) && nearly(corner[35, 17], SIMD4(0, 0, 0, 1)))

        // Centred: 36 and 18 spare pixels, half each side.
        let centred = render([.canvasSize(CanvasSize(width: 100, height: 50, fill: black))], source: source)
        #expect(nearly(centred[18, 9], F.red) && nearly(centred[17, 9], SIMD4(0, 0, 0, 1)))

        // Smaller than the image: cropped about the anchor.
        let cropped = render([.canvasSize(CanvasSize(width: 32, height: 16))], source: source)
        #expect(cropped.width == 32 && cropped.height == 16)
        #expect(nearly(cropped[0, 0], F.red) && nearly(cropped[31, 15], F.white) && nearly(cropped[31, 0], F.green))

        // A transparent fill stays transparent.
        let clear = render([.canvasSize(CanvasSize(width: 80, height: 40, fill: EditColor(red: 1, green: 1, blue: 1, alpha: 0)))],
                           source: source)
        #expect(clear[0, 0].w == 0 && clear[40, 20].w == 1)

        // On a half-size proxy the image sits at the same place, scaled.
        let proxy = render([.canvasSize(CanvasSize(width: 100, height: 50, fill: black))],
                           source: F.quadrants(width: 32, height: 16), scale: 0.5, fullSize: CGSize(width: 64, height: 32))
        #expect(proxy.width == 50 && proxy.height == 25)
        #expect(nearly(proxy[9, 5], F.red) && nearly(proxy[8, 5], SIMD4(0, 0, 0, 1)))
    }

    // MARK: - Watermark

    @Test func textWatermarkStampsItsCornerAndLeavesTheRestAlone() {
        let source = F.flat(3, width: 800, height: 400)   // HDR
        var mark = Self.textWatermark
        mark.color = .black
        mark.opacity = 1
        mark.size = 0.1
        let out = render([.watermark(mark)], source: source)
        let box = changedBox(out, from: 3)
        #expect(!box.isNull)
        // Inside the margin (0.03 of 400 = 12 px) at the bottom right.
        #expect(box.maxX <= 800 - 12 + 1 && box.maxY <= 400 - 12 + 1 && box.minX > 400 && box.minY > 300, "\(box)")
        // Everywhere else the HDR value is untouched.
        #expect(out[10, 10] == SIMD4(3, 3, 3, 1) && out[400, 200] == SIMD4(3, 3, 3, 1))

        mark.position = .topLeft
        let topLeft = changedBox(render([.watermark(mark)], source: source), from: 3)
        #expect(topLeft.minX >= 12 && topLeft.minY >= 12 && topLeft.maxX < 400, "\(topLeft)")
    }

    @Test func watermarkLooksTheSameInPreviewAndFullResolution() {
        var mark = Self.textWatermark
        mark.color = .black
        mark.opacity = 1
        mark.position = .center
        mark.size = 0.12
        let full = changedBox(render([.watermark(mark)], source: F.flat(0.5, width: 800, height: 400)), from: 0.5)
        let proxy = changedBox(render([.watermark(mark)], source: F.flat(0.5, width: 400, height: 200), scale: 0.5,
                                      fullSize: CGSize(width: 800, height: 400)), from: 0.5)
        #expect(!full.isNull && !proxy.isNull)
        for (a, b) in [(full.minX / 2, proxy.minX), (full.maxX / 2, proxy.maxX), (full.minY / 2, proxy.minY),
                       (full.maxY / 2, proxy.maxY)] {
            #expect(abs(a - b) <= 2, "full \(full) proxy \(proxy)")
        }
    }

    @Test func tiledWatermarkCoversThePhoto() {
        var mark = Self.textWatermark
        mark.color = .black
        mark.opacity = 1
        mark.tiled = true
        mark.spacing = 0.5
        let out = render([.watermark(mark)], source: F.flat(0.5, width: 800, height: 400))
        for (x, y) in [(0, 0), (400, 0), (0, 200), (400, 200)] {
            let quarter = CGRect(x: x, y: y, width: 400, height: 200)
            var touched = false
            for yy in Int(quarter.minY)..<Int(quarter.maxY) where !touched {
                for xx in Int(quarter.minX)..<Int(quarter.maxX) where abs(out[xx, yy].x - 0.5) > 0.05 {
                    touched = true
                    break
                }
            }
            #expect(touched, "nothing in the quarter at \(x), \(y)")
        }
    }

    /// At the sliders' far ends the bitmap stays the stamp's size, never
    /// the stamp plus the gap between tiles, and a stamp wider than the
    /// photo is shrunk to fit rather than dropped. A 6000 x 4000 photo at
    /// full resolution, measured without rendering.
    @Test func watermarkBitmapNeverOutgrowsThePhoto() throws {
        let photo = CGSize(width: 6000, height: 4000)
        var tiled = Self.textWatermark
        tiled.text = "© 2026"
        tiled.size = 1
        tiled.tiled = true
        tiled.spacing = 5
        let tiles = try #require(WatermarkGraph.Layout(tiled, imageSize: photo, scale: 1))
        #expect(tiles.stamp.width <= 6000 && tiles.stamp.height <= 4000, "\(tiles.stamp.width) x \(tiles.stamp.height)")
        #expect(tiles.gap > 0)
        let bitmap = try #require(tiles.stamp.draw(opacity: 1))
        #expect(Double(bitmap.width) == tiles.stamp.width && Double(bitmap.height) == tiles.stamp.height)

        var long = Self.textWatermark
        long.text = "© minivu 2026, every photograph in this folder, all rights reserved"
        long.size = 1
        let line = try #require(WatermarkGraph.Layout(long, imageSize: photo, scale: 1))
        // Inside the margins (0.03 of 4000 = 120 px), give or take rounding up.
        #expect(line.stamp.width <= 6000 - 240 + 1, "\(line.stamp.width)")
        #expect(line.x >= 119 && line.stamp.height > 0)
        #expect(try #require(line.stamp.draw(opacity: 1)).width == Int(line.stamp.width))
    }

    /// The same far ends rendered: the saved file and a quarter-size preview
    /// show the watermark in the same place.
    @Test(arguments: [true, false])
    func watermarkAtItsLimitsLooksTheSameInPreviewAndFullResolution(tiled: Bool) {
        var mark = Self.textWatermark
        mark.color = .black
        mark.opacity = 1
        mark.size = 1
        mark.position = .center
        if tiled {
            mark.tiled = true
            mark.spacing = 5
        } else {
            mark.text = "© minivu 2026, every photograph in this folder, all rights reserved"
        }
        let full = render([.watermark(mark)], source: F.flat(0.5, width: 800, height: 400))
        let proxy = render([.watermark(mark)], source: F.flat(0.5, width: 200, height: 100), scale: 0.25,
                           fullSize: CGSize(width: 800, height: 400))
        let fullBox = changedBox(full, from: 0.5), proxyBox = changedBox(proxy, from: 0.5)
        #expect(!fullBox.isNull && !proxyBox.isNull, "the watermark is drawn at both sizes")
        for (a, b) in [(fullBox.minX / 4, proxyBox.minX), (fullBox.maxX / 4, proxyBox.maxX),
                       (fullBox.minY / 4, proxyBox.minY), (fullBox.maxY / 4, proxyBox.maxY)] {
            #expect(abs(a - b) <= 2, "full \(fullBox) proxy \(proxyBox)")
        }
        // Inside the margins: the long text is shrunk to the photo's width.
        #expect(fullBox.minX >= 11 && fullBox.maxX <= 800 - 11, "\(fullBox)")
    }

    /// With a gap narrower than the photo the tiles repeat, and the second
    /// and later ones start at the same places, scaled, in the preview and
    /// the saved file: `CIAffineTile`'s cells line up at both sizes.
    @Test func tiledWatermarkRepeatsAtTheSamePlacesInPreviewAndFullResolution() throws {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let url = Fixtures.write(context.makeImage()!, name: "watermark-tile-\(UUID()).png", type: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        var mark = Watermark()
        mark.kind = .image
        mark.imageBookmark = try #require(Watermark.bookmark(for: url))
        mark.position = .topLeft
        mark.size = 0.1        // 40 x 80 px at full size, 10 x 20 in the preview
        mark.margin = 0.03     // the first tile 12 px in, 3 in the preview
        mark.opacity = 1
        mark.tiled = true
        mark.spacing = 0.5     // a 20 px gap, 5 in the preview
        let full = render([.watermark(mark)], source: F.flat(0.5, width: 800, height: 400))
        let proxy = render([.watermark(mark)], source: F.flat(0.5, width: 200, height: 100), scale: 0.25,
                           fullSize: CGSize(width: 800, height: 400))
        /// Where tiles start along a row or a column: dark after grey.
        func starts(_ p: F.Pixels, count: Int, at: (Int) -> SIMD4<Float>) -> [Int] {
            var result: [Int] = []
            var inside = false
            for i in 0..<count {
                let dark = at(i).x < 0.25
                if dark && !inside { result.append(i) }
                inside = dark
            }
            return result
        }
        // A row and a column through the first tile (the image's y points
        // down here, as the stamp's top does).
        let fullAcross = starts(full, count: full.width) { full[$0, 30] }
        let proxyAcross = starts(proxy, count: proxy.width) { proxy[$0, 7] }
        let fullDown = starts(full, count: full.height) { full[30, $0] }
        let proxyDown = starts(proxy, count: proxy.height) { proxy[7, $0] }
        #expect(fullAcross.count >= 7 && fullDown.count >= 3, "across \(fullAcross), down \(fullDown)")
        #expect(fullAcross.prefix(3) == [12, 112, 212], "\(fullAcross)")
        #expect(fullAcross.count == proxyAcross.count && fullDown.count == proxyDown.count,
                "full \(fullAcross) \(fullDown), proxy \(proxyAcross) \(proxyDown)")
        for (a, b) in zip(fullAcross + fullDown, proxyAcross + proxyDown) {
            #expect(abs(Double(a) / 4 - Double(b)) <= 1, "full \(a) proxy \(b)")
        }
    }

    @Test func imageWatermarkReadsItsFileThroughTheBookmark() throws {
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let url = Fixtures.write(context.makeImage()!, name: "watermark-\(UUID()).png", type: .png)
        var mark = Watermark()
        mark.kind = .image
        mark.imageBookmark = try #require(Watermark.bookmark(for: url))
        mark.position = .center
        mark.size = 0.25
        mark.opacity = 1
        let source = F.flat(0.5, width: 800, height: 400)
        let out = render([.watermark(mark)], source: source)
        // 100 px high (a quarter of 400) and twice as wide, in the middle.
        // sRGB red, which in linear Display P3 is about (0.82, 0.03, 0.02).
        let middle = out[400, 200]
        #expect(middle.x > 0.75 && middle.y < 0.1 && middle.z < 0.1 && middle.w == 1, "\(middle)")
        let box = changedBox(out, from: 0.5)
        #expect(abs(box.width - 200) <= 1 && abs(box.height - 100) <= 1, "\(box)")
        #expect(out[10, 10] == SIMD4(0.5, 0.5, 0.5, 1))

        // The file gone: nothing is drawn, and the render doesn't fail.
        try FileManager.default.removeItem(at: url)
        WatermarkImages.shared.removeAll()
        let gone = render([.watermark(mark)], source: source)
        #expect(changedBox(gone, from: 0.5).isNull)
    }
}
