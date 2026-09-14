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
        /// Removed when the test's suite instance goes.
        let scratchDefaults = ScratchDefaults("minivu-batch-convert-tests")
        var defaults: UserDefaults { scratchDefaults.defaults }

        init() {
            BatchTools.store = BatchStore(defaults: defaults)
            BatchTools.confirmReplacing = nil
            // Never the user's Trash: a test that replaces sets its own folder.
            BatchTools.trash = { url in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
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

            // A file that takes an output's name after planning was never
            // named in the question: even with Replace it is kept.
            let late = try t.jpeg("late.png", width: 20, height: 10)
            let outputs = plan([late], settings)
            #expect(outputs.map(\.action) == [.write])
            try Data("arrived meanwhile".utf8).write(to: t.url.appendingPathComponent("late.jpg"))
            let job = BatchConvertJob(outputs: outputs, settings: settings, converter: BatchConvertJob.makeConverter(),
                                      trash: trash, concurrency: 1)
            outcome = await job.run()
            #expect(outcome.written.map(\.lastPathComponent) == ["late 2.jpg"] && outcome.trashed.isEmpty)
            #expect(try Data(contentsOf: t.url.appendingPathComponent("late.jpg")) == Data("arrived meanwhile".utf8))
        }

        /// With Replace, a file outside the batch that only shares an
        /// output's name (the camera's JPEG beside a converted RAW) is named
        /// in the question, and nothing goes to the Trash unless the user
        /// chooses Replace: Keep Both numbers the output, Cancel writes nothing.
        @Test func filesOutsideTheBatchAreNamedBeforeTheyAreReplaced() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let (trash, trashURL) = try trashFolder(t)
            BatchTools.trash = trash
            let sources = try ["DSC_1.png", "DSC_2.png"].map { try t.jpeg($0, width: 40, height: 30) }
            let cameraJPEGs = t.url.appendingPathComponent("DSC_1.jpg")
            try Data("the camera's JPEG".utf8).write(to: cameraJPEGs)
            try Data("another".utf8).write(to: t.url.appendingPathComponent("DSC_2.jpg"))
            let controller = BrowserWindowController(catalog: catalog)
            _ = controller.grid.view
            defer { controller.window?.close() }
            controller.preview.isVisible = false
            let entries = try sources.map { try #require(FolderEntry(url: $0)) }
            let settings = BatchConvertSettings(options: .defaults(for: .jpeg), existingFiles: .replace)

            var asked: [BatchReplacements] = []
            BatchTools.confirmReplacing = { asked.append($0); return .cancel }
            controller.runBatchConvert(entries, settings: settings)
            await controller.batchWork?.value
            #expect(asked.last?.originals == [])
            #expect(asked.last?.others.map(\.lastPathComponent) == ["DSC_1.jpg", "DSC_2.jpg"])
            #expect(visibleNames(t.url) == ["DSC_1.jpg", "DSC_1.png", "DSC_2.jpg", "DSC_2.png"], "Cancel writes nothing")

            BatchTools.confirmReplacing = { asked.append($0); return .keepBoth }
            controller.runBatchConvert(entries, settings: settings)
            await controller.batchWork?.value
            #expect(try Data(contentsOf: cameraJPEGs) == Data("the camera's JPEG".utf8))
            #expect(visibleNames(t.url) == ["DSC_1 2.jpg", "DSC_1.jpg", "DSC_1.png", "DSC_2 2.jpg", "DSC_2.jpg", "DSC_2.png"])
            #expect(visibleNames(trashURL).isEmpty)

            BatchTools.confirmReplacing = { asked.append($0); return .replace }
            controller.runBatchConvert([entries[0]], settings: settings)
            await controller.batchWork?.value
            #expect(type(cameraJPEGs) == UTType.jpeg.identifier, "replaced once confirmed")
            let trashed = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
            #expect(try trashed.map { try Data(contentsOf: $0) } == [Data("the camera's JPEG".utf8)])
            #expect(asked.count == 3)
        }

        /// The question names what it would replace.
        @Test func replaceQuestionNamesTheFiles() {
            let folder = URL(fileURLWithPath: "/Photos")
            func urls(_ names: [String]) -> [URL] { names.map { folder.appendingPathComponent($0) } }
            var replacements = BatchReplacements([])
            #expect(replacements.isEmpty)
            replacements.originals = urls(["a.jpg"])
            var question = BrowserWindowController.replaceQuestion(replacements)
            #expect(question.message == "Replace the original with the converted file?")
            replacements.originals = []
            replacements.others = urls(["DSC_1.JPG"])
            question = BrowserWindowController.replaceQuestion(replacements)
            #expect(question.message == "Replace “DSC_1.JPG”?")
            #expect(question.detail.hasPrefix("“DSC_1.JPG” isn’t one of the images being converted"))
            replacements.originals = urls(["x.jpg", "y.jpg"])
            replacements.others = urls(["DSC_1.JPG", "DSC_2.JPG", "DSC_3.JPG", "DSC_4.JPG", "DSC_5.JPG"])
            question = BrowserWindowController.replaceQuestion(replacements)
            #expect(question.message == "Replace 2 originals and 5 files?")
            #expect(question.detail == "The converted files take the originals’ names. "
                + "“DSC_1.JPG”, “DSC_2.JPG”, “DSC_3.JPG” and 2 more aren’t among the images being converted, "
                + "but converted files would take their names. "
                + "Replaced files go to the Trash. Keep Both gives the converted files numbered names instead.")
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

            model.settings.resize = BatchResize(mode: .width, pixels: 0)
            #expect(!model.canConvert && model.resizeProblem != nil, "a 0 px width is refused, not made 1 px")
            model.settings.resize = BatchResize(mode: .percent, percent: 0)
            #expect(!model.canConvert)
            model.settings.resize = BatchResize(mode: .percent, percent: 50)
            #expect(model.canConvert && model.resizeProblem == nil)
            model.settings.resize = BatchResize()

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
            // Back and forth in the popup reuses the folder's bookmark.
            let chosen = model.settings.destination
            model.setUsesChosenFolder(false)
            model.setUsesChosenFolder(true)
            #expect(model.settings.destination == chosen)
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
            var asked: BatchReplacements?
            BatchTools.confirmReplacing = { replacements in
                asked = replacements
                return .cancel
            }
            controller.runBatchConvert([try #require(FolderEntry(url: a)), try #require(FolderEntry(url: b))],
                                       settings: settings)
            await controller.batchWork?.value
            #expect(asked?.originals == [a, b] && asked?.others == [])
            #expect(try Data(contentsOf: a) == originalA, "not confirmed: the original is untouched")

            BatchTools.confirmReplacing = { _ in .replace }
            catalog.setRating(4, for: [a])
            catalog.setCustomOrder(["b.jpg", "a.jpg"], in: t.url)
            controller.runBatchConvert([try #require(FolderEntry(url: a))], settings: settings)
            await controller.batchWork?.value
            #expect(pixelSize(a) == CGSize(width: 40, height: 30))
            #expect(catalog.marks(for: a).rating == 4, "the converted photo keeps the original's stars, as Save does")
            #expect(catalog.customOrder(in: t.url).suffix(2) == ["b.jpg", "a.jpg"], "and its place")
            let trashed = try FileManager.default.contentsOfDirectory(at: t.url.appendingPathComponent(".FakeTrash"),
                                                                      includingPropertiesForKeys: nil)
            #expect(try trashed.map { try Data(contentsOf: $0) } == [originalA], "the original is in the Trash, whole")
            #expect(hiddenNames(t.url).isEmpty)
        }
    }
}
