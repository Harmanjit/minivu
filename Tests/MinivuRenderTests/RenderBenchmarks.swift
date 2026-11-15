import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

/// Editing as the viewer's tools drive it: preparing a document, and a
/// slider's preview from the request to the frame delivered.
@MainActor @Suite(.serialized) struct EditLatencyBenchmark {
    /// The proxy's long edge: a 16-inch MacBook Pro's screen.
    static let screenEdge = 3456

    func preview(_ doc: EditDocument, _ pixelSize: Int = screenEdge) async {
        await withCheckedContinuation { done in
            EditRenderer.shared.renderPreview(doc, pixelSize: pixelSize) { _ in done.resume() }
        }
    }

    func fullResolution(_ doc: EditDocument) async -> ImageTexture {
        await withCheckedContinuation { done in
            EditRenderer.shared.renderFullResolution(doc) { done.resume(returning: $0) }
        }
    }

    /// Prepare (decode, upload and proxy) of each photo, a fresh document
    /// every run so nothing is reused but Core Image's own setup.
    @Test(.enabled(if: Bench.folder != nil)) func prepare() async throws {
        _ = GPU.shared
        for (label, url) in [("jpeg", Bench.jpeg), ("heic", Bench.heic), ("nef", Bench.nef)] {
            guard let url, let entry = FolderEntry(url: url) else { continue }
            var doc = EditDocument(entry: entry)
            Perf.startRecording()
            try await Bench.measure("edit", "prepare_\(label)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                return String(format: "load_ms=%.1f proxy_ms=%.1f size=%.0fx%.0f",
                              recording.total("edit.prepare.load") / Double(max(recording.durations["edit.prepare.load"]?.count ?? 1, 1)),
                              recording.total("edit.prepare.proxy") / Double(max(recording.durations["edit.prepare.proxy"]?.count ?? 1, 1)),
                              doc.sourceSize?.width ?? 0, doc.sourceSize?.height ?? 0)
            }(), setup: {
                EditRenderer.shared.release(doc)
                doc = EditDocument(entry: entry)
            }) {
                try await EditRenderer.shared.prepare(doc, proxyPixelSize: Self.screenEdge)
            }
            EditRenderer.shared.release(doc)
        }
    }

    /// Slider frames: each a new value, rendered and delivered before the
    /// next is asked for, as a drag that waits for the screen would.
    func slider(_ name: String, entry: FolderEntry, frames: Int,
                _ make: (Double) -> EditOperation) async throws {
        let doc = EditDocument(entry: entry)
        try await EditRenderer.shared.prepare(doc, proxyPixelSize: Self.screenEdge)
        defer { EditRenderer.shared.release(doc) }
        var samples: [Double] = []
        for i in 0..<(frames + 4) {
            doc.preview = make(0.1 + Double(i % 9) / 10)
            let start = ContinuousClock.now
            await preview(doc)
            if i >= 4 { samples.append(Bench.milliseconds(ContinuousClock.now - start)) }
        }
        Bench.report("edit", "slider_\(name)", samples, "pixels=\(Self.screenEdge)")
        // The full-resolution render a zoom to 100% asks for, a new value each run.
        var full: ImageTexture?
        var step = 0
        try await Bench.measure("edit", "fullRender_\(name)", runs: Bench.runs(5),
                                extra: "size=\(full?.texture.width ?? 0)x\(full?.texture.height ?? 0)") {
            step += 1
            doc.preview = make(0.2 + Double(step % 7) / 10)
            full = await fullResolution(doc)
        }
    }

    @Test(.enabled(if: Bench.folder != nil)) func sliderLatency() async throws {
        _ = GPU.shared
        let frames = Bench.size(30, quick: 3)
        if let entry = Bench.jpeg.flatMap(FolderEntry.init(url:)) {
            try await slider("lighting", entry: entry, frames: frames) {
                .lighting(brightness: $0 * 0.3, contrast: $0 * 0.2, gamma: 1 + $0 * 0.3, shadows: $0 * 0.5,
                          highlights: -$0 * 0.4)
            }
        }
        if let entry = Bench.nef.flatMap(FolderEntry.init(url:)) {
            try await slider("rawExposure", entry: entry, frames: Bench.size(12, quick: 2)) {
                .rawDevelop(RawDevelop(exposure: $0 * 2 - 1))
            }
        }
    }
}

/// Slideshow video export: ten 24 MP slides at 1080p, 30 frames a second,
/// three seconds each with one-second dissolves and captions on.
@Suite(.serialized) struct SlideshowVideoBenchmark {
    @Test(.enabled(if: Bench.jpeg != nil)) func tenSlidesAt1080p() async throws {
        let scratch = Fixtures.directory.appendingPathComponent("bench-slideshow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let count = Bench.size(10, quick: 2)
        let photos = try Bench.clones(of: try #require(Bench.jpeg), count: count, in: scratch)
        let plan = SlideshowVideoPlan(slides: photos.map {
            SlideshowVideoPlan.Slide(url: $0, transition: .crossFade, caption: $0.lastPathComponent)
        }, interval: 3, transitionDuration: 1)
        let format = SlideshowVideoFormat(width: 1920, height: 1080, frameRate: 30)
        _ = GPU.shared
        var index = 0
        let peak = Bench.FootprintPeak()
        try await Bench.measure("slideshowVideo", "export\(count)", warmups: 0, runs: Bench.runs(5), extra: {
            let memory = peak.stop()
            return String(format: "slides=%d peak_mb=%.0f", count, memory.peak)
        }()) {
            index += 1
            let url = scratch.appendingPathComponent("show-\(index).mp4")
            try await SlideshowVideoWriter.write(plan, format: format, to: url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
