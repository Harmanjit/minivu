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
        /// Save (⌘S) of an edited photo through the viewer's own path
        /// (`SavePresenter.save`): the header reads it starts with, then the
        /// write through the write queue (render at full resolution, encode,
        /// fsync and rename), to its completion. "Replace the original?" is
        /// off, as after "Don't ask again". A fresh clone and document each
        /// run, prepared beforehand as the viewer's would be.
        func saveInPlace(_ label: String, _ source: URL, scratch: ScratchFolder, window: NSWindow,
                         store: SaveOptionsStore) async throws {
            var entry: FolderEntry?, doc: EditDocument?
            var round = 0
            let phases = Bench.Phases()
            let runs = Bench.runs(5)
            try await Bench.measure("save", "inPlace_\(label)", runs: runs, extra: String(
                format: "preflight_ms=%.1f render_ms=%.1f encode_prepare_ms=%.1f encode_ms=%.1f fsync_ms=%.1f opens=%.1f",
                phases.perRun("save.preflight", runs), phases.perRun("edit.export.render", runs),
                phases.perRun("encode.prepare", runs), phases.perRun("encode.finalize", runs),
                phases.perRun("write.fsync", runs), phases.countPerRun("file.open", runs)), setup: {
                if let doc { EditRenderer.shared.release(doc) }
                round += 1
                let url = scratch.url.appendingPathComponent("save-\(label)-\(round).\(source.pathExtension)")
                try FileManager.default.copyItem(at: source, to: url)
                let opened = try #require(FolderEntry(url: url))
                let document = EditDocument(entry: opened)
                document.apply(.lighting(brightness: 0.1, contrast: 0.1, gamma: 1, shadows: 0.2, highlights: -0.1))
                try await EditRenderer.shared.prepare(document)
                entry = opened
                doc = document
            }, timing: phases.timing) {
                let (entry, document) = (try #require(entry), try #require(doc))
                let saved = await withCheckedContinuation { done in
                    SavePresenter.save(entry: entry, document: document, on: window, store: store,
                                       preferences: .shared) { done.resume(returning: $0) }
                }
                #expect(saved)
            }
            if let doc { EditRenderer.shared.release(doc) }
        }

        @Test(.enabled(if: Bench.jpeg != nil)) func saveInPlaceAndSaveAs() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let jpeg = try #require(Bench.jpeg)
            let scratchDefaults = ScratchDefaults("minivu-bench")
            defer { scratchDefaults.remove() }
            let store = SaveOptionsStore(defaults: scratchDefaults.defaults)
            let confirms = Preferences.shared.confirmOverwriteOnSave
            defer { Preferences.shared.confirmOverwriteOnSave = confirms }
            Preferences.shared.confirmOverwriteOnSave = false
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            try await saveInPlace("jpeg", jpeg, scratch: scratch, window: window, store: store)
            if let heic = Bench.heic { try await saveInPlace("heic", heic, scratch: scratch, window: window, store: store) }

            // Save As AVIF of the unedited photo: its decode at full size and
            // the encode, as the Save As panel's Save button runs them.
            guard ExportFormat.avif.isWritable else { return }
            let entry = try #require(FolderEntry(url: jpeg))
            var round = 0
            let phases = Bench.Phases()
            try await Bench.measure("save", "saveAsAVIF", runs: Bench.runs(5),
                                    extra: String(format: "encode_ms=%.1f", phases.perRun("save.encode", Bench.runs(5))),
                                    timing: phases.timing) {
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

        /// Batch Convert with Replace: 24 MP photos (named .jpeg) to JPEGs of
        /// 2048 px beside them, where a rated .jpg of each name is already:
        /// each of those goes to a folder standing in for the Trash, its
        /// marks moved with it in the catalog (`catalog.fileMoved` per file).
        /// (Replacing the originals themselves, same name and type, keeps
        /// their marks where they are and moves none.) Fresh clones every run.
        @Test(.enabled(if: Bench.jpeg != nil)) func batchConvertReplacing() async throws {
            let scratch = try ScratchFolder()
            let source = try #require(Bench.jpeg)
            let bin = try scratch.folder("Bin")
            var settings = BatchConvertSettings(options: .defaults(for: .jpeg), destination: .besideOriginals,
                                                naming: .keep, existingFiles: .replace)
            settings.resize = BatchResize(mode: .longSide, pixels: 2048)
            var round = 0
            var job: BatchConvertJob?
            var outcome: BatchConvertJob.Outcome?
            Perf.startRecording()
            try await Bench.measure("batch", "replaceExistingJpeg2048_\(Self.count)", warmups: 0, runs: Bench.runs(5), extra: {
                let recording = Perf.stopRecording()
                let files = Double(Bench.runs(5) * Self.count)
                return String(format: "written=%d trashed=%d trash_ms=%.2f catalogMoved_ms=%.2f commit_ms=%.1f",
                              outcome?.written.count ?? 0, outcome?.trashed.count ?? 0,
                              recording.total("batch.trash") / files, recording.total("batch.catalogMoved") / files,
                              recording.total("batch.commit") / files)
            }(), setup: {
                round += 1
                let folder = try scratch.folder("Replace \(round)")
                let sources = try (0..<Self.count).map { i in
                    let url = folder.appendingPathComponent(String(format: "photo-%04d.jpeg", i))
                    try FileManager.default.copyItem(at: source, to: url)
                    return url
                }
                let existing = try sources.map { url in
                    let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
                    try FileManager.default.copyItem(at: source, to: jpg)
                    return jpg
                }
                let catalog = Catalog.inMemory()
                catalog.setRating(3, for: existing)
                let outputs = BatchOutputPlanner.plan(sources.map { RenameSource(url: $0) }, settings: settings, folder: folder)
                job = BatchConvertJob(outputs: outputs, settings: settings, converter: BatchConvertJob.makeConverter(),
                                      trash: { url in
                                          let place = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                                          try FileManager.default.moveItem(at: url, to: place)
                                          return place
                                      }, catalog: catalog)
            }) {
                outcome = await job?.run()
            }
            #expect(outcome?.trashed.count == Self.count)
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
