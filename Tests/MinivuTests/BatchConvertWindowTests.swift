import Testing
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// Batch Convert: the job's policies, cancelling and failures on real
    /// files, the sheet's model, and the whole run from the browser window.
    /// Replaced files go to a Trash folder of the test's own.
    @MainActor @Suite(.serialized) struct BatchConvertWindowTests {
        let catalog = Catalog.inMemory()
        let defaults: UserDefaults

        init() {
            let suite = "minivu-batch-convert-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            BatchTools.store = BatchStore(defaults: defaults)
            BatchTools.confirmReplacingOriginals = nil
            BatchTools.trash = nil
            BatchTools.concurrency = nil
            BatchTools.sheets = sheets.presenter
        }

        let sheets = BatchSheetRecorder()

        func trashFolder(_ t: ScratchFolder) throws -> (BatchFileWriter.Trasher, URL) {
            let trash = try t.folder(".FakeTrash")
            return ({ url in
                let place = trash.appendingPathComponent(UUID().uuidString + " " + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: place)
                return place
            }, trash)
        }

        func visibleNames(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        func hiddenNames(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(".") && $0 != ".FakeTrash" }
        }

        func pixelSize(_ url: URL) -> CGSize? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return CGSize(width: image.width, height: image.height)
        }

        func type(_ url: URL) -> String? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
        }

        func plan(_ urls: [URL], _ settings: BatchConvertSettings, into folder: URL? = nil) -> [BatchOutput] {
            BatchOutputPlanner.plan(urls.map { RenameSource(url: $0) }, settings: settings, folder: folder)
        }

        func run(_ urls: [URL], _ settings: BatchConvertSettings, trash: @escaping BatchFileWriter.Trasher,
                 concurrency: Int = 2, onEncoded: ((BatchConvertJob, Int) -> Void)? = nil) async -> BatchConvertJob.Outcome {
            let job = BatchConvertJob(outputs: plan(urls, settings), settings: settings,
                                      converter: BatchConvertJob.makeConverter(), trash: trash, concurrency: concurrency)
            if let onEncoded { job.onEncoded = { [unowned job] index in onEncoded(job, index) } }
            return await job.run()
        }

        /// Each policy for a name already taken; nothing existing is ever lost.
        @Test func existingFilePoliciesNeverLoseAFile() async throws {
            let t = try ScratchFolder()
            let (trash, trashURL) = try trashFolder(t)
            let png = try t.jpeg("photo.png", width: 64, height: 48)   // JPEG data named .png: decoded by content
            let existing = t.url.appendingPathComponent("photo.jpg")
            try Data("someone's photo".utf8).write(to: existing)
            var settings = BatchConvertSettings(options: .defaults(for: .jpeg))

            settings.existingFiles = .skip
            var outcome = await run([png], settings, trash: trash)
            #expect(outcome.written.isEmpty && outcome.skipped.map(\.source) == [png])
            #expect(try Data(contentsOf: existing) == Data("someone's photo".utf8))

            settings.existingFiles = .keepBoth
            outcome = await run([png], settings, trash: trash)
            #expect(outcome.written.map(\.lastPathComponent) == ["photo 2.jpg"])
            #expect(type(t.url.appendingPathComponent("photo 2.jpg")) == UTType.jpeg.identifier)
            #expect(try Data(contentsOf: existing) == Data("someone's photo".utf8))

            settings.existingFiles = .replace
            settings.resize = BatchResize(mode: .width, pixels: 32)
            outcome = await run([png], settings, trash: trash)
            #expect(outcome.written.map(\.lastPathComponent) == ["photo.jpg"])
            #expect(pixelSize(existing) == CGSize(width: 32, height: 24))
            let trashed = try #require(outcome.trashed.first)
            #expect(try Data(contentsOf: trashed) == Data("someone's photo".utf8), "the old file is whole in the Trash")
            #expect(trashed.deletingLastPathComponent().lastPathComponent == trashURL.lastPathComponent)
            #expect(hiddenNames(t.url).isEmpty, "no temporary files")
            #expect(visibleNames(t.url) == ["photo 2.jpg", "photo.jpg", "photo.png"])
        }

        /// Cancel stops the batch between files and nothing partial is left.
        @Test func cancelLeavesNoPartialFiles() async throws {
            let t = try ScratchFolder()
            let (trash, _) = try trashFolder(t)
            let sources = try (1...6).map { try t.jpeg("img\($0).png", width: 300, height: 200) }
            let out = try t.folder("out")
            var settings = BatchConvertSettings(options: .defaults(for: .tiff))
            let bookmark = try out.bookmarkData()
            settings.destination = .chosenFolder(bookmark: bookmark)
            let job = BatchConvertJob(outputs: plan(sources, settings, into: out), settings: settings,
                                      converter: BatchConvertJob.makeConverter(), trash: trash, concurrency: 1)
            job.onEncoded = { [unowned job] index in if index == 1 { job.progress.cancel() } }
            let outcome = await job.run()
            #expect(outcome.wasCancelled)
            #expect(outcome.written.map(\.lastPathComponent) == ["img1.tif"], "the file converted after Cancel is dropped")
            #expect(visibleNames(out) == ["img1.tif"])
            #expect(hiddenNames(out).isEmpty)
            #expect(pixelSize(out.appendingPathComponent("img1.tif")) == CGSize(width: 300, height: 200))
            #expect(BatchConvertJob.summary(for: outcome) == nil, "a cancel with nothing wrong needs no alert")
        }

        /// A file that can't be converted is named with the reason; the rest convert.
        @Test func aFailingFileIsReportedAndTheRestConvert() async throws {
            let t = try ScratchFolder()
            let (trash, _) = try trashFolder(t)
            let good1 = try t.jpeg("one.jpg", width: 40, height: 30)
            let broken = t.url.appendingPathComponent("broken.jpg")
            try Data("not a picture at all".utf8).write(to: broken)
            let good2 = try t.jpeg("two.jpg", width: 40, height: 30)
            let settings = BatchConvertSettings(options: .defaults(for: .png))
            let outcome = await run([good1, broken, good2], settings, trash: trash)
            #expect(outcome.written.map(\.lastPathComponent) == ["one.png", "two.png"])
            #expect(outcome.failed.map(\.source) == [broken])
            #expect(outcome.failed.first?.detail == "broken.jpg could not be opened.")
            #expect(!visibleNames(t.url).contains("broken.png"))
            let summary = try #require(BatchConvertJob.summary(for: outcome))
            #expect(summary.title == "1 file couldn’t be converted.")
            #expect(summary.detail == "2 files converted.\n\nbroken.jpg: broken.jpg could not be opened.")
        }

        @Test func concurrencyFollowsMemory() {
            #expect(BatchConvertJob.defaultConcurrency(physicalMemory: 8 << 30) == 1)
            #expect(BatchConvertJob.defaultConcurrency(physicalMemory: 16 << 30) == 2)
        }

        /// The sheet's model: options per format, the preview name, and what
        /// is remembered for next time.
        @Test func convertSheetModel() async throws {
            let t = try ScratchFolder()
            let first = try #require(FolderEntry(url: try t.jpeg("IMG_1.jpg", width: 20, height: 20)))
            _ = try t.jpeg("IMG_1.png", width: 20, height: 20)
            let model = BatchConvertModel(entries: [first], store: BatchTools.store)
            #expect(model.title == "Convert 1 Image")
            model.format = .png
            await model.previewWork?.value
            #expect(model.previewText == "IMG_1.jpg  →  IMG_1 2.png" && model.previewProblem == nil)

            model.format = .jpeg
            model.qualityPercent = 55
            model.format = .heic
            #expect(model.settings.options == SaveOptionsStore(defaults: defaults).options(for: .heic))
            model.format = .jpeg
            #expect(model.qualityPercent == 55, "switching formats keeps what was chosen for each")

            model.usesPattern = true
            model.pattern = RenamePattern(text: "Web {nmae}")
            #expect(!model.canConvert && model.unknownTokens == ["{nmae}"])
            model.pattern = RenamePattern(text: "Web {##}")
            await model.previewWork?.value
            #expect(model.canConvert && model.previewText == "IMG_1.jpg  →  Web 01.jpg")

            model.setUsesChosenFolder(true)
            #expect(!model.usesChosenFolder, "no folder chosen yet")
            #expect(model.choose(folder: try t.folder("web")))
            #expect(model.usesChosenFolder && model.canConvert)
            let settings = model.commit()
            #expect(settings.naming == .pattern(RenamePattern(text: "Web {##}")))
            let again = BatchConvertModel(entries: [first], store: BatchTools.store)
            #expect(again.settings == settings && again.usesPattern && again.chosenFolder?.lastPathComponent == "web")
            #expect(again.qualityPercent == 55)
        }

        /// From the browser: converting into the folder shown selects the
        /// results, and replacing originals happens only once confirmed.
        @Test func convertsFromTheBrowserAndAsksBeforeReplacingOriginals() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let (trash, _) = try trashFolder(t)
            BatchTools.trash = trash
            let a = try t.jpeg("a.jpg", width: 80, height: 60)
            let b = try t.jpeg("b.jpg", width: 80, height: 60)
            let originalA = try Data(contentsOf: a)
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await controller.model.work?.value
            // The files converted are selected; nobody needs them previewed
            // (decoding them would only compete with the rest of the tests).
            controller.preview.isVisible = false
            #expect(controller.toolImages.map(\.name) == ["a.jpg", "b.jpg"], "nothing selected: every image shown")

            controller.batchConvert(nil)
            let sheet = try #require(sheets.shown.last)
            let host = try #require(sheet.contentView as? NSHostingView<BatchConvertView>)
            #expect(host.rootView.model.entries.count == 2)
            host.rootView.onCancel()
            #expect(sheets.shown.isEmpty)

            // PNG copies beside the originals, selected afterwards.
            controller.runBatchConvert(controller.toolImages, settings: BatchConvertSettings(options: .defaults(for: .png)))
            await controller.batchWork?.value
            await controller.model.work?.value
            #expect(Set(controller.model.selection.map(\.lastPathComponent)) == ["a.png", "b.png"])
            #expect(sheets.everShown.count == 2 && sheets.shown.isEmpty, "the progress sheet came and went")

            // JPEG over the originals: refused, then confirmed.
            var settings = BatchConvertSettings(options: .defaults(for: .jpeg), existingFiles: .replace,
                                                resize: BatchResize(mode: .width, pixels: 40))
            settings.options.keepMetadata = false
            var asked = 0
            BatchTools.confirmReplacingOriginals = { count in
                asked = count
                return false
            }
            controller.runBatchConvert([try #require(FolderEntry(url: a)), try #require(FolderEntry(url: b))],
                                       settings: settings)
            await controller.batchWork?.value
            #expect(asked == 2)
            #expect(try Data(contentsOf: a) == originalA, "not confirmed: the original is untouched")

            BatchTools.confirmReplacingOriginals = { _ in true }
            controller.runBatchConvert([try #require(FolderEntry(url: a))], settings: settings)
            await controller.batchWork?.value
            #expect(pixelSize(a) == CGSize(width: 40, height: 30))
            let trashed = try FileManager.default.contentsOfDirectory(at: t.url.appendingPathComponent(".FakeTrash"),
                                                                      includingPropertiesForKeys: nil)
            #expect(try trashed.map { try Data(contentsOf: $0) } == [originalA], "the original is in the Trash, whole")
            #expect(hiddenNames(t.url).isEmpty)
        }
    }
}
