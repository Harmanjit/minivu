import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// Editing timings on the 24 MP test JPEG. Runs only when MINIVU_BENCH_DIR
/// points at the test photos:
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test -c release --filter EditBenchmark
///
/// M4, release build (2026-09-14):
///     prepare HSB_6548.jpg 6032x4032 (proxy 3024x2021): first 145.7 ms, again 137.4 ms
///     preview 3024 px lighting median 4.7 ms, colors 4.1, curves 4.1, levels 4.0
///     full-resolution resize lanczos3 75% 30.1 ms, 150% 94.4 ms; lanczos8 50% 41.6 ms
///     export 5 ops -> 5311x3444 8-bit sRGB: first 54.5 ms, median 38.4 ms
/// A debug build is the same except where Swift itself is the work: curves
/// 8.3 ms, because its table is built in Swift for every render.
@MainActor @Suite(.serialized) struct EditBenchmark {
    nonisolated static let photo = DecodeBenchmark.folder?.appendingPathComponent("HSB_6548.jpg")

    func milliseconds(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }

    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func preview(_ renderer: EditRenderer, _ doc: EditDocument, _ pixelSize: Int) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderPreview(doc, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    @Test(.enabled(if: photo != nil))
    func editTimings() async throws {
        let renderer = EditRenderer.shared
        let clock = ContinuousClock()
        let entry = FolderEntry(url: Self.photo!)!
        _ = GPU.shared

        // Prepare: decode, upload, Lanczos proxy at 3024 px.
        var doc = EditDocument(entry: entry)
        let cold = try await clock.measure { try await renderer.prepare(doc, proxyPixelSize: 3024) }
        renderer.release(doc)
        doc = EditDocument(entry: entry)
        let warm = try await clock.measure { try await renderer.prepare(doc, proxyPixelSize: 3024) }
        print(String(format: "prepare %@ %.0fx%.0f (proxy %dx%d): first %.1f ms, again %.1f ms",
                     entry.name as NSString, doc.sourceSize!.width, doc.sourceSize!.height,
                     doc.proxy!.texture.width, doc.proxy!.texture.height, milliseconds(cold), milliseconds(warm)))

        // Slider renders at 3024 px through the public API: request to delivery.
        let sliders: [(String, (Double) -> EditOperation)] = [
            ("lighting", { .lighting(brightness: $0 * 0.3, contrast: $0 * 0.2, gamma: 1 + $0 * 0.3, shadows: $0 * 0.5, highlights: -$0 * 0.4) }),
            ("colors", { .colors(hue: $0 * 20, saturation: $0 * 0.3, lightness: $0 * 0.1, temperature: $0 * 0.4, tint: -$0 * 0.2) }),
            ("curves", { .curves(ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.3 - $0 * 0.1),
                                                     CurvePoint(x: 0.7, y: 0.7 + $0 * 0.1), CurvePoint(x: 1, y: 1)])) }),
            ("levels", { .levels(Levels(master: LevelsChannel(inputBlack: $0 * 0.05, inputWhite: 1 - $0 * 0.05, gamma: 1 + $0 * 0.2,
                                                              outputBlack: 0, outputWhite: 1))) }),
        ]
        for (name, make) in sliders {
            var times: [Double] = []
            for i in 0..<24 {
                doc.preview = make(0.2 + Double(i % 8) / 10)
                let d = await clock.measure { _ = await preview(renderer, doc, 3024) }
                if i >= 4 { times.append(milliseconds(d)) }
            }
            print(String(format: "preview 3024 px %-9@ median %.1f ms  min %.1f ms  max %.1f ms", name as NSString,
                         median(times), times.min()!, times.max()!))
        }
        doc.preview = nil

        // Full-resolution resizes of the 6032x4032 original, rendered into a texture.
        let source = doc.source!
        for (label, op) in [("lanczos3 75%", EditOperation.resize(width: 4524, height: 3024, filter: .lanczos3)),
                            ("lanczos3 150%", .resize(width: 9048, height: 6048, filter: .lanczos3)),
                            ("lanczos8 50%", .resize(width: 3016, height: 2016, filter: .lanczos8))] {
            var times: [Double] = []
            for _ in 0..<5 {
                let d = try clock.measure {
                    let image = EditGraph.image(source: source.image, sourceSize: source.size, operations: [op], scale: 1)
                    _ = try EditRenderer.renderTexture(image, context: renderer.context, gpu: renderer.gpu)
                }
                times.append(milliseconds(d))
            }
            print(String(format: "full-resolution resize %@: first %.1f ms, median %.1f ms", label as NSString, times[0], median(times)))
        }

        // Export of a five-operation stack to an 8-bit sRGB CGImage.
        doc.apply(.crop(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)))
        doc.apply(.rotate(degrees: 2, autoCrop: true))
        doc.apply(.lighting(brightness: 0.05, contrast: 0.1, gamma: 1.1, shadows: 0.3, highlights: -0.2))
        doc.apply(.curves(ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.22), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)])))
        doc.apply(.sharpen(amount: 0.5, radius: 1.5))
        let snapshot = doc.snapshot()
        var exportTimes: [Double] = []
        var size = CGSize.zero
        for _ in 0..<3 {
            let d = try await clock.measure {
                let image = try await renderer.renderForExport(snapshot, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                               bitsPerComponent: 8)
                size = CGSize(width: image.width, height: image.height)
            }
            exportTimes.append(milliseconds(d))
        }
        print(String(format: "export 5 ops -> %.0fx%.0f 8-bit sRGB: first %.1f ms, median %.1f ms", size.width, size.height,
                     exportTimes[0], median(exportTimes)))
        renderer.release(doc)
    }
}
