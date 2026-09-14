import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// Effect timings on the 24 MP test JPEG. Runs only when MINIVU_BENCH_DIR
/// points at the test photos:
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter EffectsBenchmark
///
/// M4, debug build (2026-09-14; the work is on the GPU, and the package's
/// release build currently stops in the compiler on `BrowserModel`), preview
/// at 3024 px, request to delivery with the mip chain, warm medians:
///     drop shadow 8.6 ms, frame (matte) 5.0, bump map 7.7, sketch 9.9,
///     oil paint 20.1 (radius 4 at full size, 2 on the proxy), lens 4.3
///     full resolution 6032 x 4032, oil paint radius 4 (four tiles): 149 ms
/// The oil paint kernel first measured 135 ms and 1650 ms, gathering its
/// eight sectors one at a time; gathering them as two four-wide vectors,
/// with one summed square per sample, made it seven to eleven times faster.
@MainActor @Suite(.serialized) struct EffectsBenchmark {
    func milliseconds(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }

    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func preview(_ renderer: EditRenderer, _ doc: EditDocument, _ pixelSize: Int) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderPreview(doc, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    @Test(.enabled(if: EditBenchmark.photo != nil))
    func effectTimings() async throws {
        let renderer = EditRenderer.shared
        let clock = ContinuousClock()
        let entry = FolderEntry(url: EditBenchmark.photo!)!
        let doc = EditDocument(entry: entry)
        try await renderer.prepare(doc, proxyPixelSize: 3024)

        var frame = FrameStyle()
        frame.kind = .matte
        let effects: [(String, (Double) -> EditOperation)] = [
            ("drop shadow", { var s = DropShadow(); s.blur = 0.01 + $0 * 0.02; return .dropShadow(s) }),
            ("frame", { var f = frame; f.width = 0.02 + $0 * 0.05; return .frame(f) }),
            ("bump map", { var b = BumpMap(); b.strength = 0.5 + $0; return .bumpMap(b) }),
            ("sketch", { var s = Sketch(); s.strength = $0; return .sketch(s) }),
            ("oil paint", { var o = OilPaint(); o.levels = 20 + Int($0 * 30); return .oilPaint(o) }),
            ("lens", { var l = LensEffect(); l.magnification = 1.5 + $0; return .lens(l) }),
        ]
        for (name, make) in effects {
            var times: [Double] = []
            for i in 0..<16 {
                doc.preview = make(0.1 + Double(i % 8) / 10)
                let d = await clock.measure { _ = await preview(renderer, doc, 3024) }
                if i >= 4 { times.append(milliseconds(d)) }
            }
            print(String(format: "preview 3024 px %-12@ median %.1f ms  min %.1f ms  max %.1f ms", name as NSString,
                         median(times), times.min()!, times.max()!))
        }
        doc.preview = nil

        let source = doc.source!
        var times: [Double] = []
        for _ in 0..<4 {
            let d = try clock.measure {
                let image = EditGraph.image(source: source.image, sourceSize: source.size, operations: [.oilPaint(OilPaint())],
                                            scale: 1)
                _ = try EditRenderer.renderTexture(image, context: renderer.context, gpu: renderer.gpu)
            }
            times.append(milliseconds(d))
        }
        print(String(format: "full resolution oil paint: first %.1f ms, median %.1f ms", times[0], median(times)))
        renderer.release(doc)
    }
}
