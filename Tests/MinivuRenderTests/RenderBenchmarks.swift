import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH or MINIVU_BENCH_DIR is set; see `Bench`.

extension Benchmarks {
    /// Editing as the viewer's tools drive it: preparing a document, and a
    /// slider's preview from the request to the frame delivered.
    @MainActor @Suite(.serialized) struct EditLatencyBenchmark {
        /// The proxy's long edge: a 16-inch MacBook Pro's screen.
        nonisolated static let screenEdge = 3456

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
                let phases = Bench.Phases()
                try await Bench.measure("edit", "prepare_\(label)", runs: Bench.runs(5), extra: String(
                    format: "load_ms=%.1f proxy_ms=%.1f size=%.0fx%.0f", phases.median("edit.prepare.load"),
                    phases.median("edit.prepare.proxy"), doc.sourceSize?.width ?? 0, doc.sourceSize?.height ?? 0), setup: {
                    EditRenderer.shared.release(doc)
                    doc = EditDocument(entry: entry)
                }, timing: phases.timing) {
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

        /// A crop dragged smaller over 24 frames, from the whole photo to a
        /// third of it: each frame's preview needs more of the original's
        /// pixels, and every quarter of growth the proxy is rebuilt from the
        /// full-resolution image with Lanczos, mid-drag. The frames, and the
        /// rebuilds among them.
        @Test(.enabled(if: Bench.jpeg != nil)) func cropDragRebuildsTheProxy() async throws {
            _ = GPU.shared
            let entry = try #require(Bench.jpeg.flatMap(FolderEntry.init(url:)))
            let frames = Bench.size(24, quick: 6)
            var samples: [Double] = [], rebuilds: [Double] = []
            for _ in 0..<Bench.runs(3) {
                let doc = EditDocument(entry: entry)
                try await EditRenderer.shared.prepare(doc, proxyPixelSize: Self.screenEdge)
                await preview(doc)
                Perf.startRecording()
                for i in 0..<frames {
                    let side = 1 - 0.67 * Double(i + 1) / Double(frames)
                    doc.preview = .crop(CGRect(x: (1 - side) / 2, y: (1 - side) / 2, width: side, height: side))
                    let start = ContinuousClock.now
                    await preview(doc)
                    samples.append(Bench.milliseconds(ContinuousClock.now - start))
                }
                rebuilds += Perf.stopRecording().durations["edit.render.proxyRebuild"] ?? []
                EditRenderer.shared.release(doc)
            }
            Bench.report("edit", "cropDragFrame", samples,
                         String(format: "rebuilds_per_drag=%.1f rebuild_ms=%.1f frames=%d pixels=%d",
                                Double(rebuilds.count) / Double(Bench.runs(3)), Bench.median(rebuilds), frames, Self.screenEdge))
            #expect(!rebuilds.isEmpty)
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

        /// A RAW tool preview at screen size from the document's engine
        /// filter, alone and started 5 ms after a full-resolution render of
        /// the same filter (the full lane's developed original), which it
        /// waits for (`RawDevelopFilter.withImage`); and beside a full render
        /// from a second filter of the same file, which it needn't wait for.
        @Test(.enabled(if: Bench.nef != nil)) nonisolated func rawPreviewBesideFullRender() throws {
            let filter = try #require(RawDevelopFilter(url: Bench.nef!))
            let settings = DisplaySettings(), size = filter.orientedSize
            let scale = Double(Self.screenEdge) / Double(max(size.width, size.height))
            var step = 0
            func preview() throws {
                step += 1
                _ = try EditRenderer.renderDeveloped(filter, develop: RawDevelop(exposure: Double(step % 9) / 10),
                                                     fullSize: size, scale: scale, settings: settings, gpu: .shared)
            }
            let other = try #require(RawDevelopFilter(url: Bench.nef!))
            @Sendable func full(_ filter: RawDevelopFilter) throws {
                _ = try EditRenderer.developedSource(filter, develop: RawDevelop(exposure: 0.5), settings: settings,
                                                     gpu: .shared)
            }
            try Bench.measure("edit", "rawPreview_alone", extra: "pixels=\(Self.screenEdge)") { try preview() }
            try Bench.measure("edit", "rawFull_alone") { try full(filter) }
            try full(other)
            for (metric, fullFilter) in [("rawPreview_besideFull", filter), ("rawPreview_besideOtherFilterFull", other)] {
                let done = DispatchSemaphore(value: 0)
                try Bench.measure("edit", metric, warmups: 0, runs: Bench.runs(9), extra: "pixels=\(Self.screenEdge)",
                                  setup: {
                    DispatchQueue.global(qos: .utility).async { try? full(fullFilter); done.signal() }
                    Thread.sleep(forTimeInterval: 0.005)
                }, timing: { if !$0 { done.wait() } }) { try preview() }
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
            var url: URL?
            let peak = Bench.FootprintPeak()
            Perf.startRecording()
            try await Bench.measure("slideshowVideo", "export\(count)", warmups: 0, runs: Bench.runs(5), extra: {
                let memory = peak.stop()
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5))
                return String(format: "slides=%d peak_mb=%.0f decode_ms=%.1f slide_wait_ms=%.1f frame_draw_ms=%.2f "
                                  + "frames_drawn=%.0f caption_ms=%.2f append_ms=%.1f",
                              count, memory.peak, recording.total("video.slideDecode") / runs,
                              recording.total("video.slideWait") / runs,
                              Bench.median(recording.durations["video.frameDraw"] ?? []),
                              Double(recording.durations["video.frameDraw"]?.count ?? 0) / runs,
                              recording.total("video.caption") / runs, recording.total("video.append") / runs)
            }(), setup: {
                // The last run's video goes before this run, untimed.
                if let url { try? FileManager.default.removeItem(at: url) }
                index += 1
                url = scratch.appendingPathComponent("show-\(index).mp4")
            }) {
                try await SlideshowVideoWriter.write(plan, format: format, to: try #require(url))
            }
        }
    }

    /// The GPU's part of a launch, as `AppDelegate.warmUpGPU` runs it on a
    /// background thread: the Metal device and command queue, the shader
    /// library, and the canvas's render pipeline. A new `GPU` each run, so
    /// the library is loaded and the pipeline built again, but Metal's own
    /// shader cache on disk is warm after the first: `first_ms` is that
    /// first of the process, nearest a launch after a restart.
    @Suite(.serialized) struct GPULaunchBenchmark {
        @Test(.enabled(if: Bench.enabled)) func gpuWarmUp() throws {
            var samples: [Double] = []
            for _ in 0...Bench.runs(7) {
                let start = ContinuousClock.now
                let gpu = try GPU()
                _ = try CanvasRenderer(gpu: gpu)
                samples.append(Bench.milliseconds(ContinuousClock.now - start))
            }
            Bench.report("launch", "gpuWarmUp", Array(samples.dropFirst()), String(format: "first_ms=%.1f", samples[0]))
        }
    }
}
