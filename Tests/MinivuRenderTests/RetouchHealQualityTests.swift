import Testing
import Foundation
import CoreGraphics
import CoreImage
import simd
@testable import MinivuRender

/// The healing brush against Latent's rim-ratio heal on synthetic skin, sky
/// and a horizon, measured against the same scene without the blemish. The numbers
/// behind the choice documented on `RetouchGraph.healPatch`.
@Suite struct RetouchHealQualityTests {
    typealias F = EditFixtures

    static let width = 384, height = 256

    /// Value noise in about -1...1 with features `cell` pixels across.
    static func noise(_ x: Int, _ y: Int, cell: Double, seed: UInt32) -> Double {
        func hash(_ i: Int, _ j: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263) ^ seed
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Double(h ^ (h >> 16)) / Double(UInt32.max) * 2 - 1
        }
        let fx = Double(x) / cell, fy = Double(y) / cell
        let i = Int(fx.rounded(.down)), j = Int(fy.rounded(.down))
        let tx = fx - Double(i), ty = fy - Double(j)
        let top = hash(i, j) * (1 - tx) + hash(i + 1, j) * tx
        let bottom = hash(i, j + 1) * (1 - tx) + hash(i + 1, j + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    struct Scene: Sendable {
        let name: String
        /// Linear colour of the clean scene.
        let clean: @Sendable (Int, Int) -> SIMD3<Double>
        let blemishCentre: (x: Int, y: Int)
        let blemishRadius: Double
        let blemishTint: SIMD3<Double>
        let sourceCentre: (x: Int, y: Int)
        let brushRadius: Double
    }

    static let skin = Scene(
        name: "skin",
        clean: { x, y in
            // Light from the right, falling off to a third; pores at 3 px.
            let shade = 0.35 + 0.65 * Double(x) / Double(width - 1)
            let pores = 1 + 0.10 * noise(x, y, cell: 3, seed: 7) + 0.04 * noise(x, y, cell: 11, seed: 3)
            return SIMD3(0.55, 0.36, 0.27) * shade * pores
        },
        blemishCentre: (130, 128), blemishRadius: 7, blemishTint: SIMD3(0.7, 0.45, 0.45),
        sourceCentre: (250, 140), brushRadius: 13)

    static let sky = Scene(
        name: "sky",
        clean: { x, y in
            // Brightening ever faster towards the horizon, past SDR white
            // (an HDR sunset), with a little grain.
            let level = 0.3 + 1.4 * pow(Double(y) / Double(height - 1), 2.5)
            let grain = 1 + 0.02 * noise(x, y, cell: 2, seed: 11)
            return SIMD3(0.12, 0.28, 0.75) * level * grain
        },
        blemishCentre: (200, 190), blemishRadius: 8, blemishTint: SIMD3(0.45, 0.45, 0.5),
        sourceCentre: (110, 120), brushRadius: 14)

    static let edge = Scene(
        name: "edge",
        clean: { x, y in
            // A soft horizon: bright sky over a dark hillside, meeting across
            // the blemish; the source is plain mid-tone ground with grain.
            let t = StrokeMask.smoothstep(118, 138, Double(y))
            let sky = SIMD3(0.5, 0.6, 0.8), hill = SIMD3(0.08, 0.1, 0.06)
            let clean = sky * (1 - t) + hill * t
            let ground = SIMD3(0.25, 0.22, 0.18)
            let grain = 1 + 0.06 * noise(x, y, cell: 2, seed: 5)
            return (x < 200 && y > 180 ? ground : clean) * grain
        },
        blemishCentre: (260, 128), blemishRadius: 8, blemishTint: SIMD3(0.5, 0.5, 0.5),
        sourceCentre: (100, 220), brushRadius: 14)

    static func blemished(_ scene: Scene, _ x: Int, _ y: Int) -> SIMD3<Double> {
        let dx = Double(x - scene.blemishCentre.x), dy = Double(y - scene.blemishCentre.y)
        let d = (dx * dx + dy * dy).squareRoot()
        // A soft-edged spot.
        let w = 1 - StrokeMask.smoothstep(scene.blemishRadius - 1.5, scene.blemishRadius + 0.5, d)
        let c = scene.clean(x, y)
        return c * (SIMD3(repeating: 1) - w * (SIMD3(repeating: 1) - scene.blemishTint))
    }

    /// Latent's heal (Heal.metal): the source scaled by the ratio of the two
    /// rims' means (ring 0.7r...r), feathered over the outer 35%.
    static func rimRatio(_ scene: Scene, image: @escaping (Int, Int) -> SIMD3<Double>) -> (Int, Int) -> SIMD3<Double> {
        let r = scene.brushRadius
        let offset = (x: scene.sourceCentre.x - scene.blemishCentre.x, y: scene.sourceCentre.y - scene.blemishCentre.y)
        var target = SIMD3<Double>(), source = SIMD3<Double>(), n = 0.0
        for dy in -Int(r)...Int(r) {
            for dx in -Int(r)...Int(r) {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                guard d >= 0.7 * r, d <= r else { continue }
                target += image(scene.blemishCentre.x + dx, scene.blemishCentre.y + dy)
                source += image(scene.sourceCentre.x + dx, scene.sourceCentre.y + dy)
                n += 1
            }
        }
        let ratio = simd_clamp(target / simd_max(source, SIMD3(repeating: 1e-4)), SIMD3(repeating: 0.25),
                               SIMD3(repeating: 4))
        return { x, y in
            let dx = Double(x - scene.blemishCentre.x), dy = Double(y - scene.blemishCentre.y)
            let d = (dx * dx + dy * dy).squareRoot()
            let c = image(x, y)
            guard d < r else { return c }
            let v = image(x + offset.x, y + offset.y) * ratio
            let w = 1 - StrokeMask.smoothstep(0.65 * r, r, d)
            return c + (v - c) * w
        }
    }

    struct Score: CustomStringConvertible {
        /// Root mean square error inside the brush, encoded 0...255 units.
        /// Both heals copy the same source texture, so this includes the
        /// unavoidable difference between two patches of pores.
        let rms: Double
        /// The worst error of the 7 x 7 average around any point of the
        /// brush: a tone or colour mismatch, the blotch or seam the eye
        /// notices, with the texture averaged out.
        let tone: Double
        var description: String { String(format: "rms %.2f, tone %.2f", rms, tone) }
    }

    static func score(_ scene: Scene, result: (Int, Int) -> SIMD3<Double>) -> Score {
        func encoded(_ c: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(Double(F.encode(Float(c.x))), Double(F.encode(Float(c.y))), Double(F.encode(Float(c.z)))) * 255
        }
        let r = scene.brushRadius
        var sum = 0.0, n = 0.0, tone = 0.0
        let reach = Int(r) + 1
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = scene.blemishCentre.x + dx, y = scene.blemishCentre.y + dy
                guard Double(dx * dx + dy * dy).squareRoot() <= r else { continue }
                let e = encoded(result(x, y)) - encoded(scene.clean(x, y))
                sum += simd_length_squared(e) / 3
                n += 1
                var local = SIMD3<Double>()
                for oy in -3...3 { for ox in -3...3 {
                    local += encoded(result(x + ox, y + oy)) - encoded(scene.clean(x + ox, y + oy))
                } }
                tone = max(tone, simd_reduce_max(simd_abs(local / 49)))
            }
        }
        return Score(rms: (sum / n).squareRoot(), tone: tone)
    }

    func minivu(_ scene: Scene) -> (Int, Int) -> SIMD3<Double> {
        let w = Self.width, h = Self.height
        let source = F.image(width: w, height: h) { x, y in
            let c = Self.blemished(scene, x, y)
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
        }
        let stroke = RetouchStroke(
            mode: .heal, points: [CGPoint(x: Double(scene.blemishCentre.x) / Double(w), y: Double(scene.blemishCentre.y) / Double(h))],
            radius: scene.brushRadius / Double(min(w, h)), hardness: 0.72,
            sourceOffset: CGVector(dx: Double(scene.sourceCentre.x - scene.blemishCentre.x) / Double(w),
                                   dy: Double(scene.sourceCentre.y - scene.blemishCentre.y) / Double(h)))
        let image = EditGraph.image(source: source, sourceSize: CGSize(width: w, height: h),
                                    operations: [.retouch([stroke])], scale: 1)
        let p = F.pixels(image)
        return { x, y in
            let c = p[min(max(x, 0), w - 1), min(max(y, 0), h - 1)]
            return SIMD3(Double(c.x), Double(c.y), Double(c.z))
        }
    }

    /// On an evenly lit area the two are equally good; where the light or
    /// colour changes across the brush, one ratio for the whole patch can't
    /// be right on both sides, and the masked blur is several times better.
    @Test(arguments: ["skin", "sky", "edge"])
    func maskedBlurHealMatchesOrBeatsTheRimRatio(name: String) {
        let scene = [Self.skin, Self.sky, Self.edge].first { $0.name == name }!
        let blemished: (Int, Int) -> SIMD3<Double> = { x, y in
            Self.blemished(scene, min(max(x, 0), Self.width - 1), min(max(y, 0), Self.height - 1))
        }
        let untouched = Self.score(scene, result: blemished)
        let ours = Self.score(scene, result: minivu(scene))
        let latent = Self.score(scene, result: Self.rimRatio(scene, image: blemished))
        print("heal quality \(name): blemished \(untouched); minivu \(ours); rim ratio \(latent)")
        #expect(ours.rms < untouched.rms / 2)
        #expect(ours.rms < latent.rms * 1.1, "minivu \(ours) vs rim ratio \(latent)")
        #expect(ours.tone < latent.tone * 1.1, "minivu \(ours) vs rim ratio \(latent)")
        if name == "edge" {
            #expect(ours.tone < latent.tone / 3, "minivu \(ours) vs rim ratio \(latent)")
        }
    }
}
