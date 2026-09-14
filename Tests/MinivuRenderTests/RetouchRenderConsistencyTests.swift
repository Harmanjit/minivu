import Testing
import Foundation
import CoreGraphics
import CoreImage
import simd
@testable import MinivuRender

/// The retouch graph renders the same pixels however Core Image divides the
/// work: on the GPU or the CPU, in one piece or in small tiles (as a large
/// export is), and whatever the GPU rendered before.
@Suite(.serialized) struct RetouchRenderConsistencyTests {
    typealias F = EditFixtures

    static let size = CGSize(width: 700, height: 500)

    /// Texture, with two red pupils (and catchlights) under the red-eye circles.
    static func texture(pupils: Bool = true) -> CIImage {
        F.image(width: 700, height: 500) { x, y in
            let v = 0.4 + 0.2 * sin(Float(x) / 5) * cos(Float(y) / 7) + 0.1 * Float((x * 7 + y * 13) % 11) / 11
            for (cx, cy) in pupils ? [(350, 250), (392, 240)] : [] {
                let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d2 < 9 { return SIMD4(1, 1, 1, 1) }
                if d2 < 900 { return SIMD4(0.5 * v + 0.3, 0.04, 0.03, 1) }
            }
            return SIMD4(v, v * 0.9, v * 0.7, 1)
        }
    }

    /// Two heals and a clone that cross, so later strokes read earlier
    /// patches through the heal's blurs, then red-eye circles that overlap.
    static let operations: [EditOperation] = [
        .retouch([
            RetouchStroke(mode: .heal, points: stride(from: 0.2, through: 0.8, by: 0.01).map { CGPoint(x: $0, y: 0.5) },
                          radius: 0.06, hardness: 0.3, sourceOffset: CGVector(dx: 0, dy: -0.3)),
            RetouchStroke(mode: .clone, points: stride(from: 0.2, through: 0.8, by: 0.01).map { CGPoint(x: 0.5, y: $0) },
                          radius: 0.05, hardness: 0.7, sourceOffset: CGVector(dx: 0.2, dy: 0)),
            RetouchStroke(mode: .heal, points: stride(from: 0.3, through: 0.7, by: 0.01).map { CGPoint(x: $0, y: $0) },
                          radius: 0.04, hardness: 0.5, sourceOffset: CGVector(dx: -0.1, dy: 0.1)),
        ]),
        .redEye([RedEyeSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.1),
                 RedEyeSpot(center: CGPoint(x: 0.56, y: 0.52), radius: 0.08)]),
        // A heal reading the red-eye patches, and a blur that clamps it all.
        .retouch([RetouchStroke(mode: .heal, points: stride(from: 0.4, through: 0.6, by: 0.01).map { CGPoint(x: $0, y: 0.45) },
                                radius: 0.05, hardness: 0.5, sourceOffset: CGVector(dx: 0.05, dy: 0.08))]),
        .blur(radius: 2),
    ]

    static func worst(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// Leaves the GPU's recycled textures full of other renders' pixels
    /// (retouches of another image, read in pieces), so a kernel reading
    /// outside what Core Image rendered for it shows.
    static func dirtyTheGPU() {
        let other = F.image(width: 1024, height: 768) { x, y in
            let v = 0.4 + 0.2 * sin(Float(x) / 5) * cos(Float(y) / 7) + 0.1 * Float((x * 7 + y * 13) % 11) / 11
            return SIMD4(v, v * 0.9, v * 0.7, 1)
        }
        for count in [10, 20, 30] {
            let strokes = (0..<count).map { i in
                let cx = 0.4 + 0.004 * Double(i)
                return RetouchStroke(mode: .heal,
                                     points: (0..<8).map { CGPoint(x: cx + Double($0) * 0.002, y: 0.5 + 0.002 * Double(i % 3)) },
                                     radius: 0.03, hardness: 0.5, sourceOffset: CGVector(dx: 0.02, dy: 0.01))
            }
            let image = EditGraph.image(source: other, sourceSize: CGSize(width: 1024, height: 768),
                                        operations: [.retouch(strokes)], scale: 1)
            _ = F.pixels(image, bounds: CGRect(x: 300, y: 300, width: 200, height: 100))
        }
    }

    /// The operations with every stroke, circle and operation rendered to a
    /// bitmap before the next: the simplest graphs Core Image can get, and
    /// by definition what the fused graph must produce (each stroke reads
    /// the result of the ones before). Strokes here stay clear of the
    /// image's edges, where the two may differ by design.
    static func staged(_ operations: [EditOperation], source: CIImage) -> F.Pixels {
        var image = source
        var pixels = F.pixels(source)
        for op in operations {
            let steps: [EditOperation] = switch op {
            case .retouch(let strokes): strokes.map { .retouch([$0]) }
            case .redEye(let spots): spots.map { .redEye([$0]) }
            default: [op]
            }
            for step in steps {
                pixels = F.pixels(EditGraph.image(source: image, sourceSize: size, operations: [step], scale: 1))
                image = CIImage(bitmapData: pixels.data.withUnsafeBufferPointer { Data(buffer: $0) },
                                bytesPerRow: pixels.width * 16, size: size, format: .RGBAf, colorSpace: F.space)
            }
        }
        return pixels
    }

    /// The fused graphs render first, in pieces too: which programs Core
    /// Image compiled first, and what the GPU rendered before, decided
    /// whether the old graph went wrong.
    @Test func theFusedGraphMatchesEachStepRenderedOnItsOwn() {
        var scenes: [(name: String, source: CIImage, operations: [EditOperation])] = []
        for pupils in [false, true] {
            for count in [2, 4] {
                scenes.append(("pupils \(pupils), \(count) operations", Self.texture(pupils: pupils),
                               Array(Self.operations.prefix(count))))
            }
        }
        var fused: [[F.Pixels]] = []
        for scene in scenes {
            let image = EditGraph.image(source: scene.source, sourceSize: Self.size, operations: scene.operations, scale: 1)
            Self.dirtyTheGPU()
            var renders = [F.pixels(image), F.pixels(image)]
            renders.append(Self.tiled(image))
            fused.append(renders)
        }
        for (scene, renders) in zip(scenes, fused) {
            let reference = Self.staged(scene.operations, source: scene.source)
            for (index, render) in renders.enumerated() {
                // Half-float intermediates and the blur's GPU path round a
                // little, in tiles a little more: well under one 8-bit step.
                #expect(Self.worst(render.data, reference.data) < 0.01,
                        "\(scene.name), \(["whole", "whole again", "61 px tiles"][index])")
            }
        }
    }

    /// `image` rendered in 61 px tiles, as Core Image divides a large export.
    static func tiled(_ image: CIImage) -> F.Pixels {
        var data = [Float](repeating: 0, count: 700 * 500 * 4)
        let tile = 61
        for y in stride(from: 0, to: 500, by: tile) {
            for x in stride(from: 0, to: 700, by: tile) {
                let w = min(tile, 700 - x), h = min(tile, 500 - y)
                let part = F.pixels(image, bounds: CGRect(x: x, y: 500 - y - h, width: w, height: h))
                for row in 0..<h {
                    let from = row * w * 4, to = ((y + row) * 700 + x) * 4
                    data.replaceSubrange(to..<(to + w * 4), with: part.data[from..<(from + w * 4)])
                }
            }
        }
        return F.Pixels(width: 700, height: 500, data: data)
    }

    /// A straighten after retouching: Core Image may move the rotation
    /// across the retouch kernels and sample them between pixels, which
    /// once left a half-transparent seam around every patch and a red ring
    /// around corrected pupils. The result must match rotating the retouched
    /// pixels.
    @Test func aRotationAfterwardsSamplesTheRetouchedPixels() {
        let operations = Array(Self.operations.prefix(2))
        let rotate = EditOperation.rotate(degrees: 7, autoCrop: false)
        let fused = F.pixels(EditGraph.image(source: Self.texture(), sourceSize: Self.size,
                                             operations: operations + [rotate], scale: 1))
        let retouched = Self.staged(operations, source: Self.texture())
        let bitmap = CIImage(bitmapData: retouched.data.withUnsafeBufferPointer { Data(buffer: $0) },
                             bytesPerRow: 700 * 16, size: Self.size, format: .RGBAf, colorSpace: F.space)
        let reference = F.pixels(EditGraph.image(source: bitmap, sourceSize: Self.size, operations: [rotate], scale: 1))
        #expect(fused.width == reference.width && fused.height == reference.height)
        var worst: Float = 0, differing = 0
        // The rotated image's own edges depend on how each source is sampled; only its inside counts.
        for i in 0..<(fused.width * fused.height) where reference.data[4 * i + 3] > 0.999 {
            let d = (0..<4).map { abs(fused.data[4 * i + $0] - reference.data[4 * i + $0]) }.max()!
            worst = max(worst, d)
            if d > 0.02 { differing += 1 }
        }
        #expect(worst < 0.03 && differing == 0, "worst \(worst), \(differing) px differ by more than 0.02")
    }
}
