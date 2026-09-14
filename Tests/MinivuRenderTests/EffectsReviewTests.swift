import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import MinivuRender

/// Regression tests from the effects review: transparent input, exports
/// that Core Image renders in tiles, HDR through the colour-preserving
/// effects, and kernels staying inside a moved image.
@Suite struct EffectsReviewTests {
    typealias F = EditFixtures

    /// Deterministic noise (Core Image's random generator, opaque) at any size.
    func noise(_ width: Int, _ height: Int) -> CIImage {
        CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 8-bit sRGB bytes of `rect` (Core Image coordinates), top row first, as
    /// the export path renders them.
    func exportBytes(_ image: CIImage, _ rect: CGRect) throws -> [UInt8] {
        let cg = try #require(F.context.createCGImage(image, from: rect, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false))
        let data = try #require(cg.dataProvider?.data) as Data
        return [UInt8](data)
    }

    /// The oil paint kernel filters alpha with the colours. It once kept the
    /// centre pixel's alpha, so an antialiased transparent edge (a rotation
    /// without auto-crop) took opaque neighbours' premultiplied colour into a
    /// small alpha: 86 invalid pixels, up to 2.5 times the photo's brightness.
    @Test func oilPaintKeepsPremultipliedAlphaOnTransparentEdges() {
        let source = F.flat(0.5, width: 200, height: 120)
        let p = F.pixels(EditGraph.image(source: source, sourceSize: source.extent.size,
                                         operations: [.rotate(degrees: 10, autoCrop: false), .oilPaint(OilPaint())],
                                         scale: 1))
        var invalid = 0
        var brightest: Float = 0
        for v in p.all {
            if v.x > v.w + 1e-3 { invalid += 1 }
            if v.w > 0.01 { brightest = max(brightest, v.x / v.w) }
        }
        #expect(invalid == 0)
        #expect(brightest < 0.51, "unpremultiplied \(brightest) on a 0.5 grey")
        // The corners stay transparent and the middle stays the photo.
        #expect(p[0, 0].w < 1e-3 && nearly(p[p.width / 2, p.height / 2], SIMD4(0.5, 0.5, 0.5, 1), 5e-3))

        // A hard transparent edge stays sharp too.
        let square = F.image(width: 64, height: 64) { x, y in
            (16..<48).contains(x) && (16..<48).contains(y) ? SIMD4(0.5, 0.5, 0.5, 1) : .zero
        }
        let q = F.pixels(EditGraph.image(source: square, sourceSize: square.extent.size,
                                         operations: [.oilPaint(OilPaint())], scale: 1))
        #expect(q[18, 32].w > 0.99 && q[13, 32].w < 0.01, "\(q[18, 32]) \(q[13, 32])")
    }

    /// The grey relief is of the photo only: transparent corners stay
    /// transparent at any colour blend (they once filled with grey as the
    /// blend went down, opaque at 0).
    @Test func bumpMapKeepsTransparentAreasTransparent() {
        let source = F.flat(0.5, width: 200, height: 120)
        for blend in [0.0, 0.5] {
            var bump = BumpMap()
            bump.blend = blend
            let p = F.pixels(EditGraph.image(source: source, sourceSize: source.extent.size,
                                             operations: [.rotate(degrees: 10, autoCrop: false), .bumpMap(bump)], scale: 1))
            #expect(p[0, 0] == .zero && p[p.width - 1, p.height - 1] == .zero, "blend \(blend): \(p[0, 0])")
            #expect(p[p.width / 2, p.height / 2].w > 0.999)
            #expect(p.all.allSatisfy { $0.x <= $0.w + 1e-3 })
        }
    }

    /// An export large enough for Core Image to split into tiles: regions of
    /// the whole render match the same regions rendered on their own (which
    /// read exactly what the kernels' regions of interest ask for), so no
    /// tile border shows. Noise makes any misplaced read visible.
    ///
    /// Measured: Core Image renders this export in four tiles, and pads the
    /// oil paint's colour input by 7 px anyway (the structure tensor reads
    /// it too), which hid a region of interest of zero at the default radius
    /// 4. Radius 10 reads 21 px around each pixel, so a short region of
    /// interest shows (differences of up to 127).
    @Test func tiledExportsMatchRegionRenders() throws {
        let width = 8192, height = 4700
        let source = noise(width, height)
        var paint = OilPaint()
        paint.radius = 10
        for op in [EditOperation.oilPaint(paint), .bumpMap(BumpMap()), .lens(LensEffect())] {
            let image = EditGraph.image(source: source, sourceSize: source.extent.size, operations: [op], scale: 1)
            let whole = try exportBytes(image, image.extent)
            var worst = 0
            // Around likely tile borders (powers of two) and the middle.
            for (cx, cy) in [(4096, 4096), (2048, 2048), (1024, 3072), (6144, 1024), (width / 2, height / 2)] {
                let rect = CGRect(x: cx - 24, y: cy - 24, width: 48, height: 48)
                let region = try exportBytes(image, rect)
                for row in 0..<48 {
                    let wholeRow = height - Int(rect.maxY) + row
                    for column in 0..<48 {
                        let i = (wholeRow * width + Int(rect.minX) + column) * 4, j = (row * 48 + column) * 4
                        for c in 0..<3 { worst = max(worst, abs(Int(whole[i + c]) - Int(region[j + c]))) }
                    }
                }
            }
            #expect(worst <= 1, "\(op.title): regions differ by up to \(worst)")
        }
    }

    /// The sketch reads clamped, infinite inputs, yet stays inside its image
    /// when a later shadow moves it.
    @Test func sketchStaysInsideItsImageWhenMoved() {
        let source = F.image(width: 200, height: 100) { x, _ in x < 100 ? F.red : F.green }
        var shadow = DropShadow()
        shadow.opacity = 0
        shadow.margin = 0.05
        shadow.background = EditColor(red: 0, green: 0, blue: 1)
        let image = EditGraph.image(source: source, sourceSize: source.extent.size,
                                    operations: [.sketch(Sketch()), .dropShadow(shadow)], scale: 1)
        let p = F.pixels(image)
        let blue = shadow.background.working
        #expect((0..<5).allSatisfy { nearly(p[$0, 52], blue, 1e-3) }, "\(p[2, 52])")
        #expect(p[7, 52].x > 0.9, "paper at \(p[7, 52])")
    }

    /// HDR highlights survive the effects that keep the photo's colours: a
    /// relief over the full colours, a frame and a shadow around the photo.
    @Test func hdrSurvivesReliefFrameAndShadow() {
        let ramp = F.image(width: 96, height: 64) { x, y in
            let v = Float(x) / 95 * 4 + (y % 8 < 4 ? 0.2 : 0)
            return SIMD4(v, v, v, 1)
        }
        let relief = F.pixels(EditGraph.image(source: ramp, sourceSize: ramp.extent.size,
                                              operations: [.bumpMap(BumpMap())], scale: 1))
        #expect(relief.all.filter { $0.x > 3 }.count > 200)

        let framed = F.pixels(EditGraph.image(source: ramp, sourceSize: ramp.extent.size,
                                              operations: [.frame(FrameStyle()), .dropShadow(DropShadow())], scale: 1))
        #expect(framed.all.contains { $0.x > 3.9 })
    }
}
