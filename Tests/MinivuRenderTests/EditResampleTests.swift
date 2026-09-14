import Testing
import Foundation
import CoreGraphics
import CoreImage
import simd
@testable import MinivuRender

/// The eleven resampling filters (`ResampleKernel`, Resample.metal).
@Suite struct EditResampleTests {
    typealias F = EditFixtures

    func resize(_ image: CIImage, _ width: Int, _ height: Int, _ filter: ResampleFilter) -> F.Pixels {
        let out = ResampleKernel.resize(image, width: width, height: height, filter: filter)
        #expect(out.extent == CGRect(x: 0, y: 0, width: width, height: height))
        return F.pixels(out)
    }

    @Test(arguments: ResampleFilter.allCases)
    func flatFieldStaysFlatAtExactSize(filter: ResampleFilter) {
        let flat = F.flat(0.37, width: 64, height: 48)
        for (w, h) in [(37, 29), (150, 100), (64, 7), (5, 48)] {
            let p = resize(flat, w, h, filter)
            #expect(p.width == w && p.height == h)
            let values = p.all
            let worst = values.map { max(abs($0.x - 0.37), abs($0.w - 1)) }.max()!
            #expect(worst < 1e-3, "\(filter) \(w)x\(h) worst error \(worst)")
        }
    }

    /// A vertical edge between 0.2 and 0.8, enlarged 3x: filters with negative
    /// lobes overshoot beside it, positive-only filters stay within the two.
    @Test(arguments: ResampleFilter.allCases)
    func stepEdgeOvershootMatchesTheFiltersShape(filter: ResampleFilter) {
        let step = F.image(width: 16, height: 4) { x, _ in x < 8 ? SIMD4(0.2, 0.2, 0.2, 1) : SIMD4(0.8, 0.8, 0.8, 1) }
        let row = resize(step, 48, 4, filter)
        let values = (0..<48).map { row[$0, 2].x }
        let overshoot = max(values.max()! - 0.8, 0.2 - values.min()!)
        switch filter {
        case .box, .triangle, .hermite, .bell, .bSpline, .cosine:
            #expect(overshoot < 1e-3, "\(filter) overshoot \(overshoot)")
        case .lanczos3, .lanczos8, .catmullRom, .mitchell, .quadratic:
            #expect(overshoot > 1e-3, "\(filter) should ring, overshoot \(overshoot)")
        }
        // Every filter keeps the ends at their values and moves up across the edge.
        #expect(abs(values[0] - 0.2) < 2e-3 && abs(values[47] - 0.8) < 2e-3)
        #expect(values[30] > values[18])
    }

    @Test func lanczosRingsMoreThanCatmullRomAndBoxNotAtAll() {
        let step = F.image(width: 16, height: 1) { x, _ in x < 8 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        func peak(_ filter: ResampleFilter) -> Float { (0..<64).map { resize(step, 64, 1, filter)[$0, 0].x }.max()! }
        #expect(peak(.box) <= 1.0005)
        #expect(peak(.lanczos3) > 1.02)
        #expect(peak(.lanczos3) > peak(.mitchell))
    }

    /// Triangle against a plain CPU implementation of the same mapping:
    /// output centre (i + 0.5) / scale, filter widened when shrinking,
    /// edges repeated, weights normalised.
    @Test func triangleMatchesACPUReference() {
        let w = 9, h = 7
        var values = [Float](repeating: 0, count: w * h)
        var seed: UInt64 = 12345
        for i in values.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            values[i] = Float(seed >> 40) / Float(1 << 24)
        }
        let source = F.image(width: w, height: h) { x, y in let v = values[y * w + x]; return SIMD4(v, v, v, 1) }
        let outW = 20, outH = 3   // enlarge across, shrink down

        func pass(_ input: [Float], inLength: Int, outLength: Int, count: Int, stride: (Int, Int) -> Int) -> [[Float]] {
            // Returns output lines along the axis for each of `count` lines across it.
            let scale = Double(outLength) / Double(inLength)
            let filterScale = min(scale, 1)
            return (0..<count).map { line in
                (0..<outLength).map { o in
                    let centre = (Double(o) + 0.5) / scale
                    let radius = 1 / filterScale
                    var sum = 0.0, total = 0.0
                    for i in Int((centre - radius).rounded(.down))...Int((centre + radius).rounded(.up)) {
                        let wgt = ResampleFilter.triangle.weight((Double(i) + 0.5 - centre) * filterScale)
                        guard wgt != 0 else { continue }
                        let clamped = min(max(i, 0), inLength - 1)
                        sum += Double(input[stride(line, clamped)]) * wgt
                        total += wgt
                    }
                    return Float(sum / total)
                }
            }
        }
        // Rows first (top-down row order doesn't matter across the axis).
        let rows = pass(values, inLength: w, outLength: outW, count: h) { y, x in y * w + x }
        let flatRows = rows.flatMap { $0 }
        // Columns: CI's y axis points up, so index rows from the bottom.
        let columns = pass(flatRows, inLength: h, outLength: outH, count: outW) { x, yUp in (h - 1 - yUp) * outW + x }

        let gpu = resize(source, outW, outH, .triangle)
        var worst: Float = 0
        for x in 0..<outW {
            for yUp in 0..<outH {
                let expected = columns[x][yUp]
                worst = max(worst, abs(gpu[x, outH - 1 - yUp].x - expected))
            }
        }
        #expect(worst < 1e-3, "worst difference from the CPU reference \(worst)")
    }

    @Test func boxHalvingAveragesPairs() {
        let source = F.image(width: 8, height: 2) { x, _ in let v = Float(x) / 8; return SIMD4(v, v, v, 1) }
        let p = resize(source, 4, 1, .box)
        for i in 0..<4 {
            #expect(abs(p[i, 0].x - (Float(2 * i) + 0.5) / 8) < 1e-3)
        }
    }

    @Test func tilesAgreeWithTheWholeRender() {
        // Rendering part of the output makes Core Image ask the kernel for a
        // region away from the origin; it must match the same pixels of a
        // whole render.
        let source = F.image(width: 200, height: 150) { x, y in
            SIMD4(Float(x % 13) / 13, Float(y % 7) / 7, Float((x + y) % 5) / 5, 1)
        }
        let out = ResampleKernel.resize(source, width: 73, height: 111, filter: .lanczos3)
        let whole = F.pixels(out)
        let tile = F.pixels(out, bounds: CGRect(x: 40, y: 50, width: 20, height: 30))
        // Tile row 0 is its top, at Core Image y = 79, which is whole-image row 111 - 80 = 31.
        var worst: Float = 0
        for y in 0..<30 {
            for x in 0..<20 {
                let d = abs(tile[x, y] - whole[40 + x, 31 + y])
                worst = max(worst, d.x, d.y, d.z, d.w)
            }
        }
        #expect(worst < 1e-3, "tile differs by \(worst)")
    }

    @Test func extremeReductionCapsTapsAndStaysFlat() {
        #expect(ResampleKernel.filterScale(from: 2000, to: 10, support: 8) == 16.0 / 510)
        #expect(ResampleKernel.filterScale(from: 100, to: 50, support: 3) == 0.5)
        #expect(ResampleKernel.filterScale(from: 50, to: 100, support: 3) == 1)
        let p = resize(F.flat(0.6, width: 2000, height: 4), 10, 4, .lanczos8)
        #expect(p.all.allSatisfy { abs($0.x - 0.6) < 1e-3 })
    }

    @Test func weightFunctionsHaveTheirShapes() {
        for filter in ResampleFilter.allCases {
            #expect(filter.weight(filter.support + 0.01) == 0, "\(filter) reaches past its support")
            #expect(filter.weight(0) > 0)
            #expect(filter.weight(0.3) == filter.weight(-0.3))
        }
        // Interpolating filters are 1 at the sample and 0 at its neighbours.
        for filter in [ResampleFilter.triangle, .hermite, .catmullRom, .cosine, .quadratic, .lanczos3, .lanczos8] {
            #expect(abs(filter.weight(0) - 1) < 1e-12 && abs(filter.weight(1)) < 1e-12, "\(filter)")
        }
        #expect(abs(ResampleFilter.bSpline.weight(0) - 2.0 / 3) < 1e-12)
        #expect(abs(ResampleFilter.mitchell.weight(0) - 8.0 / 9) < 1e-12)
        #expect(ResampleFilter.allCases.map(\.title) == ["Box", "Triangle (Bilinear)", "Hermite", "Bell", "B-Spline",
                                                          "Mitchell", "Catmull-Rom", "Cosine", "Quadratic", "Lanczos 3",
                                                          "Lanczos 8"])
        #expect(Set(ResampleFilter.allCases.map(\.shaderID)).count == 11)
    }

    @Test func resizeOperationOnAProxyMatchesTheSavedProportions() {
        // 400x200 resized to 300x120, rendered on a quarter-size proxy.
        let op = EditOperation.resize(width: 300, height: 120, filter: .catmullRom)
        let proxy = EditGraph.image(source: F.quadrants(width: 100, height: 50), sourceSize: CGSize(width: 400, height: 200),
                                    operations: [op], scale: 0.25)
        #expect(proxy.extent == CGRect(x: 0, y: 0, width: 75, height: 30))
        let p = F.pixels(proxy)
        #expect(nearly(p.at(0.25, 0.25), F.red, 0.01) && nearly(p.at(0.75, 0.75), F.white, 0.01))
    }
}
