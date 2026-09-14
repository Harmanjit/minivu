import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// Retouch preview timings on the 24 MP test JPEG. Runs only when
/// MINIVU_BENCH_DIR points at the test photos:
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter RetouchBenchmark
///
/// M4, debug build (2026-09-14; the release build of the test targets
/// currently stops at BrowserModel's isolated deinit), request to delivery
/// with the mip chain, while painting (each render one stroke more or less):
///     heal 20 strokes spread, 3024 px proxy     median 24.1 ms, max 32.1 ms (first 50.9)
///     heal 20 strokes on one spot               median 26.1 ms, max 35.1 ms
///     clone 20 strokes spread                   median 9.5 ms
///     graph for 20 new heal strokes (CPU masks) 7.5 ms (cached masks: under 1 ms)
///     red-eye, 2 spots                          median 5.4 ms
///     export of 20 heal strokes, 6032x4032      94 ms
@MainActor @Suite(.serialized) struct RetouchBenchmark {
    nonisolated static let photo = DecodeBenchmark.folder?.appendingPathComponent("HSB_6548.jpg")

    func milliseconds(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func preview(_ renderer: EditRenderer, _ doc: EditDocument, _ pixelSize: Int) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderPreview(doc, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    /// Twenty strokes of 60 to 120 full-resolution pixels across, each a
    /// short drag, spread over the image (or all on one spot).
    nonisolated static func strokes(_ mode: RetouchStroke.Mode, count: Int, overlapping: Bool) -> [RetouchStroke] {
        (0..<count).map { i in
            let cx = overlapping ? 0.5 : 0.1 + 0.8 * Double(i % 5) / 4
            let cy = overlapping ? 0.5 : 0.15 + 0.7 * Double(i / 5 % 4) / 3
            let radius = (30.0 + Double(i % 4) * 10) / 4032
            let points = (0..<12).map { k in
                CGPoint(x: cx + Double(k) * radius * 0.25 * 0.6667, y: cy + 0.01 * sin(Double(k) / 3))
            }
            return RetouchStroke(mode: mode, points: points, radius: radius, hardness: 0.5,
                                 sourceOffset: CGVector(dx: 0.04, dy: -0.03))
        }
    }

    @Test(.enabled(if: photo != nil))
    func retouchTimings() async throws {
        let renderer = EditRenderer.shared
        let clock = ContinuousClock()
        let doc = EditDocument(entry: FolderEntry(url: Self.photo!)!)
        try await renderer.prepare(doc, proxyPixelSize: 3024)
        _ = await preview(renderer, doc, 3024)

        let cases: [(String, RetouchStroke.Mode, Bool)] = [
            ("heal 20 spread", .heal, false), ("heal 20 on one spot", .heal, true),
            ("clone 20 spread", .clone, false),
        ]
        for (name, mode, overlapping) in cases {
            let all = Self.strokes(mode, count: 21, overlapping: overlapping)
            // As while painting: each render has one stroke more or less.
            var times: [Double] = []
            var first = 0.0
            for i in 0..<16 {
                doc.preview = .retouch(Array(all.prefix(i % 2 == 0 ? 20 : 21)))
                let d = milliseconds(await clock.measure { _ = await preview(renderer, doc, 3024) })
                if i == 0 { first = d } else { times.append(d) }
            }
            print(String(format: "retouch preview 3024 px %@: first %.1f ms, median %.1f ms, max %.1f ms",
                         name as NSString, first, median(times), times.max()!))
        }

        // The graph alone, CPU side: masks and nodes for 20 heal strokes.
        let source = doc.proxy!.image
        var build: [Double] = []
        for i in 0..<5 {
            // Uncached: every stroke slightly different each time.
            let strokes = Self.strokes(.heal, count: 20, overlapping: false).map {
                var stroke = $0
                stroke.hardness = 0.4 + Double(i) * 0.01
                return stroke
            }
            build.append(milliseconds(clock.measure {
                _ = EditGraph.image(source: source, sourceSize: doc.sourceSize!, operations: [.retouch(strokes)],
                                    scale: doc.proxy!.scale)
            }))
        }
        print(String(format: "retouch graph build, 20 new heal strokes at 3024 px: median %.2f ms", median(build)))

        var eyes: [Double] = []
        for i in 0..<8 {
            doc.preview = .redEye([RedEyeSpot(center: CGPoint(x: 0.4, y: 0.5), radius: 0.02, strength: i % 2 == 0 ? 1 : 0.9),
                                   RedEyeSpot(center: CGPoint(x: 0.6, y: 0.5), radius: 0.02)])
            let d = milliseconds(await clock.measure { _ = await preview(renderer, doc, 3024) })
            if i > 0 { eyes.append(d) }
        }
        print(String(format: "red-eye preview 3024 px, 2 spots: median %.1f ms", median(eyes)))

        doc.preview = nil
        doc.apply(.retouch(Self.strokes(.heal, count: 20, overlapping: false)))
        let export = try await clock.measure {
            _ = try await renderer.renderForExport(doc.snapshot(), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitsPerComponent: 8)
        }
        print(String(format: "export 20 heal strokes, 6032x4032 8-bit: %.0f ms", milliseconds(export)))
    }
}
