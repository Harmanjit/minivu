import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

// Benchmarks for the performance study (docs/feature-notes/perf.md). Off
// unless MINIVU_BENCH_DIR is set; see `Bench`. Everything is written into
// clones in a scratch folder, never beside the test photos.

extension AppWindowTests {
    /// Save in place and Save As, as the viewer's commands run them.
    @MainActor @Suite(.serialized) struct SaveBenchmark {
        /// Save (⌘S) of an edited photo: the header reads Save starts with,
        /// then the write through the write queue (render at full
        /// resolution, encode, fsync and rename). A fresh clone and document
        /// each run, prepared beforehand as the viewer's would be.
        func saveInPlace(_ label: String, _ source: URL, scratch: ScratchFolder) async throws {
            var url = source, doc: EditDocument?
            var round = 0
            Perf.startRecording()
            try await Bench.measure("save", "inPlace_\(label)", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "render_ms=%.1f encode_prepare_ms=%.1f encode_ms=%.1f fsync_ms=%.1f opens=%.1f",
                              recording.total("edit.export.render") / runs, recording.total("encode.prepare") / runs,
                              recording.total("encode.finalize") / runs, recording.total("write.fsync") / runs,
                              Double(recording.counts["file.open"] ?? 0) / runs)
            }(), setup: {
                if let doc { EditRenderer.shared.release(doc) }
                round += 1
                url = scratch.url.appendingPathComponent("save-\(label)-\(round).\(source.pathExtension)")
                try FileManager.default.copyItem(at: source, to: url)
                let document = EditDocument(entry: try #require(FolderEntry(url: url)))
                document.apply(.lighting(brightness: 0.1, contrast: 0.1, gamma: 1, shadows: 0.2, highlights: -0.1))
                try await EditRenderer.shared.prepare(document)
                doc = document
            }) {
                let target = url
                let snapshot = try #require(doc).snapshot()
                let (info, sourceSpace) = await BlockingWork.run {
                    (ImageDecoder.info(for: target), SavePolicy.sourceColorSpace(of: target))
                }
                let format = try #require(SavePolicy.inPlaceFormat(for: target, info: info))
                let options = SavePolicy.inPlaceOptions(remembered: .defaults(for: format), sourceBitDepth: info?.bitDepth ?? 8)
                let space = SavePolicy.renderColorSpace(source: sourceSpace, isHDR: info?.isHDR ?? false, preferWideGamut: false)
                _ = try await FileWriteQueue.shared.enqueue(replacing: [target]) {
                    try await SavePresenter.writeInPlace(snapshot, colorSpace: space, options: options, to: target,
                                                         renderer: .shared)
                }.value
            }
            if let doc { EditRenderer.shared.release(doc) }
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func saveInPlaceAndSaveAs() async throws {
            let scratch = try ScratchFolder()
            let jpeg = try #require(Bench.jpeg)
            try await saveInPlace("jpeg", jpeg, scratch: scratch)
            if let heic = Bench.heic { try await saveInPlace("heic", heic, scratch: scratch) }

            // Save As AVIF of the unedited photo: its decode at full size and
            // the encode, as the Save As panel's Save button runs them.
            guard ExportFormat.avif.isWritable else { return }
            let entry = try #require(FolderEntry(url: jpeg))
            var round = 0
            Perf.startRecording()
            try await Bench.measure("save", "saveAsAVIF", runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let runs = Double(Bench.runs(5) + 1)
                return String(format: "encode_ms=%.1f", recording.total("save.encode") / runs)
            }()) {
                round += 1
                let out = scratch.url.appendingPathComponent("saved-\(round).avif")
                try await SavePresenter.write(SaveImageSource(entry: entry, document: nil), options: .defaults(for: .avif),
                                              to: out, metadataSource: jpeg)
            }
        }
    }

    /// Batch Convert of 20 photos with the app's job at its default
    /// concurrency, and a web gallery of 20.
    @MainActor @Suite(.serialized, .batchToolsReset) struct BatchOutputBenchmark {
        static let count = Bench.size(20, quick: 2)

        func convert(_ label: String, _ sources: [URL], scratch: ScratchFolder,
                     _ configure: (inout BatchConvertSettings) -> Void) async throws {
            var settings = BatchConvertSettings(options: .defaults(for: .jpeg))
            configure(&settings)
            var round = 0
            var outcome: BatchConvertJob.Outcome?
            let peak = Bench.FootprintPeak()
            Perf.startRecording()
            try await Bench.measure("batch", "\(label)_\(sources.count)", warmups: 0, runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let memory = peak.stop()
                let files = Double(Bench.runs(5) * sources.count)
                return String(format: "concurrency=%d written=%d prepare_ms=%.1f render_ms=%.1f encode_ms=%.1f commit_ms=%.1f peak_mb=%.0f",
                              BatchConvertJob.defaultConcurrency(), outcome?.written.count ?? 0,
                              recording.total("batch.prepare") / files, recording.total("batch.render") / files,
                              recording.total("batch.encode") / files, recording.total("batch.commit") / files, memory.peak)
            }()) {
                round += 1
                let out = try scratch.folder("\(label) \(round)")
                var runSettings = settings
                runSettings.destination = .chosenFolder(bookmark: try out.bookmarkData())
                let outputs = BatchOutputPlanner.plan(sources.map { RenameSource(url: $0) }, settings: runSettings, folder: out)
                let job = BatchConvertJob(outputs: outputs, settings: runSettings, converter: BatchConvertJob.makeConverter(),
                                          trash: { url in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) })
                outcome = await job.run()
            }
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func batchConvert() async throws {
            let scratch = try ScratchFolder()
            let sources = try Bench.clones(of: try #require(Bench.jpeg), count: Self.count, in: try scratch.folder("Sources"))
            try await convert("jpeg2048", sources, scratch: scratch) {
                $0.resize = BatchResize(mode: .longSide, pixels: 2048)
            }
            try await convert("heicFull", sources, scratch: scratch) { $0.options = .defaults(for: .heic) }
            if ExportFormat.avif.isWritable {
                try await convert("avifFull", sources, scratch: scratch) { $0.options = .defaults(for: .avif) }
            }
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func webGallery() async throws {
            let scratch = try ScratchFolder()
            let sources = try Bench.clones(of: try #require(Bench.jpeg), count: Self.count, in: try scratch.folder("Sources"))
            let entries = sources.compactMap(FolderEntry.init(url:))
            var round = 0
            try await Bench.measure("webGallery", "export\(entries.count)", warmups: 0, runs: Bench.runs(5),
                                    extra: "pictures=\(entries.count)") {
                round += 1
                let out = try scratch.folder("Gallery \(round)")
                _ = try await WebGalleryExport.export(images: entries, title: "Trip", settings: WebGallerySettings(),
                                                      into: out, cancel: CancellationFlag())
            }
        }
    }
}
