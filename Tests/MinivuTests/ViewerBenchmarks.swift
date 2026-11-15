import Testing
import AppKit
import CoreImage
import MinivuCore
@testable import MinivuRender
@testable import Minivu

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH_DIR is set; see `Bench`. The windows are real ones,
// made in this process as the other window tests make them.

extension AppWindowTests {
    /// The viewer: opening it, moving between photos, zooming to 100%.
    @MainActor @Suite(.serialized) struct ViewerBenchmark {
        init() {
            _ = NSApplication.shared
            ImageCanvasView.tracksPresentedFrames = true
        }

        func close() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// The photo `entry` is on the canvas and drawn: its own texture,
        /// not a stand-in, in a frame the GPU has finished.
        func shows(_ entry: FolderEntry) -> Bool {
            guard let viewer = ViewerWindowController.current, viewer.displayed?.entry == entry, !viewer.isLoadingPage,
                  viewer.canvasTexture != nil else { return false }
            return Self.drawn(viewer.canvasView)
        }

        /// The canvas's image is in a finished frame. A window on no screen
        /// has no display link, so this draws as its refresh would; on a
        /// screen the link has usually drawn already.
        static func drawn(_ canvas: ImageCanvasView) -> Bool {
            if !canvas.hasPresentedImage { canvas.displayRefreshed() }
            return canvas.hasPresentedImage
        }

        func settle() async {
            await AppServices.images.waitUntilIdle()
            await Bench.mainQueueTurn()
        }

        /// An HDR JPEG with a gain map, made from the 24 MP photo: the photo
        /// as its SDR base, a stop brighter as its HDR rendition.
        func gainMapJPEG(from photo: URL, in scratch: ScratchFolder) throws -> URL {
            let sdr = try #require(CIImage(contentsOf: photo, options: [.applyOrientationProperty: true]))
            let hdr = sdr.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1])
            let data = try #require(CIContext().jpegRepresentation(of: sdr, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                                   options: [.hdrImage: hdr]))
            let url = scratch.url.appendingPathComponent("hdr-gainmap.jpg")
            try data.write(to: url)
            return url
        }

        /// Opening the viewer on a photo it has never decoded: from the
        /// call to the photo drawn on the canvas, and how long the main
        /// thread was busy meanwhile. A clone of the photo each run, so no texture
        /// is cached.
        func open(_ label: String, _ source: URL, scratch: ScratchFolder) async throws {
            let photos = try Bench.clones(of: source, count: Bench.runs(5) + 1, in: scratch.url, prefix: label)
            let entries = photos.compactMap(FolderEntry.init(url:))
            var index = -1
            var showCall: [Double] = []
            Perf.startRecording()
            let monitor = Bench.MainThreadMonitor()
            try await Bench.measure("viewer", "open_\(label)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let shown = ViewerWindowController.current?.canvasTexture
                return String(format: "show_call_ms=%.1f opens=%.1f %@ texture=%dx%d hdr=%@",
                              Bench.median(showCall),
                              Double(recording.counts["file.open"] ?? 0) / Double(entries.count),
                              monitor.stopText(runs: Bench.runs(5)), shown?.texture.width ?? 0, shown?.texture.height ?? 0,
                              (shown?.isHDR ?? false) ? "yes" : "no")
            }(), setup: {
                close()
                await settle()
                index += 1
            }, timing: monitor.counting) {
                let start = ContinuousClock.now
                ViewerWindowController.show(images: [entries[index]], index: 0, fullScreen: false) { _ in }
                showCall.append(Bench.milliseconds(ContinuousClock.now - start))
                #expect(await Bench.waitUntil { shows(entries[index]) })
            }
            close()
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func openPerFormat() async throws {
            let scratch = try ScratchFolder()
            defer { close() }
            let jpeg = try #require(Bench.jpeg)
            try await open("jpeg", jpeg, scratch: scratch)
            if let heic = Bench.heic { try await open("heic", heic, scratch: scratch) }
            if let nef = Bench.nef {
                try await open("nefPreview", nef, scratch: scratch)
                // The RAW setting at Render RAW data: the sensor data, not the preview.
                let saved = AppServices.images.settings
                defer { AppServices.images.settings = saved }
                AppServices.images.settings.rawDecoding = .fullRaw
                try await open("nefRaw", nef, scratch: scratch)
            }
            try await open("hdrGainMap", try gainMapJPEG(from: jpeg, in: scratch), scratch: scratch)
        }

        /// Next and previous through 24 MP photos: with the neighbour already
        /// prefetched (warm), and with it thrown away just before (cold).
        /// `opens` counts header opens per move, the neighbour's prefetch and
        /// the side reads (exposure line, file marks) included.
        @Test(.enabled(if: Bench.jpeg != nil)) func nextAndPrevious() async throws {
            let scratch = try ScratchFolder()
            defer { close() }
            let count = Bench.runs(7) * 3 + 6
            let entries = try Bench.clones(of: try #require(Bench.jpeg), count: count, in: scratch.url)
                .compactMap(FolderEntry.init(url:))
            ViewerWindowController.show(images: entries, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            #expect(await Bench.waitUntil { shows(entries[0]) })
            var position = 0

            for (label, isWarm) in [("next_warm", true), ("next_cold", false)] {
                Perf.startRecording()
                let monitor = Bench.MainThreadMonitor()
                try await Bench.measure("viewer", label, runs: Bench.runs(7), extra: {
                    let recording = Perf.stopRecording()
                    let flips = recording.durations["viewer.flip"] ?? []
                    let runs = Double(Bench.runs(7) + 1)
                    return String(format: "flip_signpost_ms=%.1f opens_per_flip=%.1f decode_ms=%.1f upload_ms=%.1f "
                                      + "escalation_wait_ms=%.1f %@",
                                  Bench.median(flips), Double(recording.counts["file.open"] ?? 0) / runs,
                                  recording.total("decode") / runs, recording.total("upload") / runs,
                                  recording.total("loader.escalationWait") / runs, monitor.stopText(runs: Bench.runs(7)))
                }(), setup: {
                    await settle()
                    // The side reads of the photo shown land before the move.
                    try? await Task.sleep(for: .milliseconds(200))
                    if !isWarm { AppServices.images.invalidate(entries[position + 1].url) }
                }, timing: monitor.counting) {
                    position += 1
                    viewer.nextImage(nil)
                    #expect(await Bench.waitUntil { shows(entries[position]) })
                }
            }
            try await Bench.measure("viewer", "previous", runs: Bench.runs(7), setup: { await settle() }) {
                position -= 1
                viewer.previousImage(nil)
                #expect(await Bench.waitUntil { shows(entries[position]) })
            }
        }

        /// Zoom to 100% (⌘0's neighbour, Actual Size): from the command to the
        /// full-resolution texture drawn on the canvas.
        @Test(.enabled(if: Bench.jpeg != nil)) func zoomToActualSize() async throws {
            let scratch = try ScratchFolder()
            defer { close() }
            var sources = [("jpeg", try #require(Bench.jpeg))]
            if let heic = Bench.heic { sources.append(("heic", heic)) }
            if let nef = Bench.nef { sources.append(("nef", nef)) }
            for (label, source) in sources {
                let entries = try Bench.clones(of: source, count: Bench.runs(5) + 1, in: scratch.url, prefix: "zoom-\(label)")
                    .compactMap(FolderEntry.init(url:))
                var index = -1
                Perf.startRecording()
                try await Bench.measure("viewer", "actualSize_\(label)", runs: Bench.runs(5), extra: {
                    let recording = Perf.stopRecording()
                    let full = recording.durations["loader.fullResolution"] ?? []
                    let texture = ViewerWindowController.current?.canvasTexture
                    return String(format: "loader_ms=%.1f texture=%dx%d", Bench.median(full),
                                  texture?.texture.width ?? 0, texture?.texture.height ?? 0)
                }(), setup: {
                    index += 1
                    ViewerWindowController.show(images: [entries[index]], index: 0, fullScreen: false) { _ in }
                    #expect(await Bench.waitUntil { shows(entries[index]) })
                    await settle()
                }) {
                    let viewer = try #require(ViewerWindowController.current)
                    viewer.actualSize(nil)
                    #expect(await Bench.waitUntil {
                        viewer.canvasTexture?.isFullResolution == true && Self.drawn(viewer.canvasView)
                    })
                }
            }
        }

        /// The process's footprint while the viewer moves through 20 photos,
        /// as fast as they arrive.
        @Test(.enabled(if: Bench.jpeg != nil)) func memoryFlippingThroughTwenty() async throws {
            let scratch = try ScratchFolder()
            defer { close() }
            let count = Bench.size(20, quick: 4)
            var sources = [try #require(Bench.jpeg)]
            if let heic = Bench.heic { sources.append(heic) }
            let photos = try (0..<count).map { i -> URL in
                let source = sources[i % sources.count]
                let url = scratch.url.appendingPathComponent(String(format: "flip-%02d.%@", i, source.pathExtension))
                try FileManager.default.copyItem(at: source, to: url)
                return url
            }
            let entries = photos.compactMap(FolderEntry.init(url:))
            await settle()
            let peak = Bench.FootprintPeak()
            let start = ContinuousClock.now
            ViewerWindowController.show(images: entries, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            var flips: [Double] = []
            #expect(await Bench.waitUntil { shows(entries[0]) })
            for i in 1..<count {
                let flip = ContinuousClock.now
                viewer.nextImage(nil)
                #expect(await Bench.waitUntil { shows(entries[i]) })
                flips.append(Bench.milliseconds(ContinuousClock.now - flip))
            }
            let total = Bench.milliseconds(ContinuousClock.now - start)
            close()
            await settle()
            let memory = peak.stop()
            Bench.report("memory", "viewerFlip\(count)", flips,
                         String(format: "total_ms=%.0f start_mb=%.0f peak_mb=%.0f end_mb=%.0f", total, memory.start,
                                memory.peak, memory.end))
        }
    }

    /// The browser's grid scrolled through thousands of thumbnails, a screen
    /// at a time, each waiting for its thumbnails: footprint, time, and the
    /// main thread's busy spells (where scrolling stutters).
    @MainActor @Suite(.serialized) struct GridScrollBenchmark {
        @Test(.enabled(if: Bench.enabled)) func scrollThroughFiveThousand() async throws {
            _ = NSApplication.shared
            let saved = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(saved, forKey: AppDelegate.lastFolderKey) }
            let scratch = try ScratchFolder()
            let count = Bench.size(5_000, quick: 300)
            let folder = try scratch.folder("Photos")
            // The 24 MP photo when there is one, else a flat 1800 x 1200 picture.
            let one = try Bench.jpeg ?? scratch.jpeg("one.jpg", width: 1800, height: 1200)
            _ = try Bench.clones(of: one, count: count, in: folder)

            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            controller.showWindow(nil)
            let grid = controller.grid
            let peak = Bench.FootprintPeak()
            controller.open(folder: folder)
            await controller.model.work?.value
            Bench.display(controller.window)
            func settled() -> Bool {
                let visible = grid.collectionView.visibleItems()
                return !visible.isEmpty && visible.allSatisfy { ($0 as? ThumbnailCell)?.isThumbnailSettled ?? true }
            }
            let clip = grid.scrollView.contentView
            var screens: [Double] = []
            #expect(await Bench.waitUntil { settled() })
            let step = max(clip.bounds.height, 100)
            var y = clip.bounds.origin.y
            let monitor = Bench.MainThreadMonitor()
            let start = ContinuousClock.now
            while y + clip.bounds.height < grid.collectionView.frame.height {
                y += step
                monitor.counting(true)
                let screen = ContinuousClock.now
                clip.scroll(to: NSPoint(x: 0, y: y))
                grid.scrollView.reflectScrolledClipView(clip)
                // The cells for the new rows exist once the grid has laid out.
                grid.collectionView.layoutSubtreeIfNeeded()
                await Bench.mainQueueTurn()
                #expect(await Bench.waitUntil(seconds: 10) { settled() })
                Bench.display(controller.window)
                screens.append(Bench.milliseconds(ContinuousClock.now - screen))
                monitor.counting(false)
            }
            let total = Bench.milliseconds(ContinuousClock.now - start)
            let memory = peak.stop()
            Bench.report("memory", "gridScroll\(count)", screens,
                         String(format: "screens=%d total_ms=%.0f start_mb=%.0f peak_mb=%.0f end_mb=%.0f %@", screens.count,
                                total, memory.start, memory.peak, memory.end, monitor.stopText(runs: screens.count)))
        }
    }

    /// Compare (two or four photos side by side): from the command to every
    /// pane's photo drawn, photos never decoded before (fresh clones each
    /// run), and the main thread's busy time meanwhile.
    @MainActor @Suite(.serialized) struct CompareBenchmark {
        init() {
            _ = NSApplication.shared
            ImageCanvasView.tracksPresentedFrames = true
        }

        func close() { CompareWindowController.current?.window?.close() }

        /// Every pane shows its entry, drawn.
        func shown(_ entries: [FolderEntry]) -> Bool {
            guard let controller = CompareWindowController.current, controller.paneViews.count == entries.count
            else { return false }
            return zip(controller.paneViews, entries).allSatisfy { pane, entry in
                pane.entry == entry && pane.hasLoadedImage && pane.canvas.image != nil
                    && ViewerBenchmark.drawn(pane.canvas)
            }
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func openTwoAndFour() async throws {
            let saved = CompareWindowController.catalog
            CompareWindowController.catalog = .inMemory()
            defer { CompareWindowController.catalog = saved }
            let scratch = try ScratchFolder()
            defer { close() }
            for panes in [2, 4] {
                let runs = Bench.runs(5)
                let entries = try Bench.clones(of: try #require(Bench.jpeg), count: panes * (runs + 1), in: scratch.url,
                                               prefix: "compare\(panes)").compactMap(FolderEntry.init(url:))
                var round = -1
                var opens: [Double] = [], loads: [Double] = []
                let monitor = Bench.MainThreadMonitor()
                try await Bench.measure("compare", "open\(panes)", runs: runs, extra: {
                    String(format: "open_signpost_ms=%.1f pane_load_ms=%.1f %@", Bench.median(opens), Bench.median(loads),
                           monitor.stopText(runs: runs))
                }(), setup: {
                    close()
                    await AppServices.images.waitUntilIdle()
                    await Bench.mainQueueTurn()
                    round += 1
                    Perf.startRecording()
                }, timing: monitor.counting) {
                    let chosen = Array(entries[round * panes..<(round + 1) * panes])
                    CompareWindowController.show(entries: chosen, allImages: entries)
                    #expect(await Bench.waitUntil { shown(chosen) })
                    let recording = Perf.stopRecording()
                    opens += recording.durations["compare.open"] ?? []
                    loads += recording.durations["compare.paneLoad"] ?? []
                }
            }
        }
    }
}
