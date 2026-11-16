import Testing
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// G17 from the browser: Extract Pages (the Batch Convert sheet's other
    /// mode), Batch Convert's every-page option, Create Multi-Page File and
    /// Image Strip, with their sheets' models and the files they write.
    /// Destinations are injected; results never open a viewer.
    @MainActor @Suite(.serialized, .batchToolsReset) struct MultiPageWindowTests {
        let catalog = Catalog.inMemory()
        let scratchDefaults = ScratchDefaults("minivu-multipage-tests")
        let sheets = BatchSheetRecorder()

        init() {
            BatchTools.store = BatchStore(defaults: scratchDefaults.defaults)
            BatchTools.trash = { url in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            BatchTools.sheets = sheets.presenter
            MultiPageTools.showResult = { _ in }
        }

        static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ width: Int = 40, _ height: Int = 30) -> CGImage {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()!
        }

        /// A three-page TIFF: red, green, blue.
        func document(_ t: ScratchFolder, _ name: String = "doc.tif") throws -> URL {
            let url = t.url.appendingPathComponent(name)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                                           3, nil))
            for image in [solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1, 20, 50)] {
                CGImageDestinationAddImage(destination, image, nil)
            }
            try #require(CGImageDestinationFinalize(destination))
            return url
        }

        func centre(_ image: CGImage) -> [Int] {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let i = ((h / 2) * w + w / 2) * 4
            return bytes[i..<i + 3].map(Int.init)
        }

        func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 12 } }

        func pages(_ url: URL) -> [CGImage] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            return (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        }

        func visibleNames(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        func browser(_ t: ScratchFolder) async -> BrowserWindowController {
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value
            controller.preview.isVisible = false
            return controller
        }

        // MARK: - Extract Pages and every page

        /// Extract Pages opens the convert sheet in its own mode: PNG, every
        /// page, names numbered by `{page}`, remembered apart from Batch
        /// Convert's settings. A range writes those pages only.
        @Test func extractPagesFromTheBrowser() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let doc = try document(t)
            let controller = await browser(t)
            defer { controller.window?.close() }
            controller.model.setSelection([doc], lead: doc)

            controller.extractPages(nil)
            let sheet = try #require(sheets.shown.last)
            let host = try #require(sheet.contentView as? NSHostingView<BatchConvertView>)
            let model = host.rootView.model
            #expect(model.mode == .extractPages && model.title == "Extract Pages from 1 File")
            #expect(model.format == .png && model.settings.pages == .separate(.all))
            #expect(model.usesPattern && model.pattern.text == "{name}-{page}")
            await model.previewWork?.value
            #expect(model.previewText.hasSuffix("doc-1.png"))
            model.usesPageRange = true
            model.pageRange = PageRange(first: 2, last: 3)
            model.pageRange.last = 1
            #expect(!model.canConvert && model.pageRangeProblem != nil, "a range ending before it starts")
            model.pageRange.last = 3
            #expect(model.canConvert)
            let settings = model.commit()
            #expect(BatchTools.store.extractSettings?.pages == .separate(PageRange(first: 2, last: 3)))
            #expect(BatchTools.store.convertSettings == nil, "Batch Convert's settings are left alone")
            host.rootView.onCancel()

            controller.runBatchConvert([try #require(FolderEntry(url: doc))], settings: settings)
            await controller.batchWork?.value
            await TestTiming.waitUntil { Set(controller.model.selection.map(\.lastPathComponent)) == ["doc-2.png", "doc-3.png"] }
            #expect(visibleNames(t.url) == ["doc-2.png", "doc-3.png", "doc.tif"])
            let third = try #require(pages(t.url.appendingPathComponent("doc-3.png")).first)
            #expect(third.width == 20 && third.height == 50 && near(centre(third), [0, 0, 255]))
            #expect(Set(controller.model.selection.map(\.lastPathComponent)) == ["doc-2.png", "doc-3.png"])
        }

        /// The tools of pictures leave a video out of their sheets even when
        /// it is chosen with the pictures (G18): only the menu check did.
        @Test func pictureToolsLeaveTheVideoOut() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            _ = try document(t, "a.tif")
            try t.jpeg("b.jpg", width: 60, height: 40)
            try t.file("c.mov")
            let controller = await browser(t)
            defer { controller.window?.close() }
            controller.model.selectAll()
            let window = try #require(controller.window)

            controller.extractPages(nil)
            let extract = try #require(sheets.shown.last?.contentView as? NSHostingView<BatchConvertView>)
            #expect(extract.rootView.model.title == "Extract Pages from 2 Files")
            #expect(controller.canPerformTools(.startSlideshow) == false, "no full-screen show over a sheet")
            extract.rootView.onCancel()

            controller.createMultiPageFile(nil)
            let multi = try #require(sheets.shown.last?.contentView as? NSHostingView<MultiPageView>)
            #expect(multi.rootView.model.order.urls.map(\.lastPathComponent) == ["a.tif", "b.jpg"])
            multi.rootView.onCancel()

            controller.makeImageStrip(nil)
            let strip = try #require(sheets.shown.last?.contentView as? NSHostingView<ImageStripView>)
            #expect(strip.rootView.model.order.urls.map(\.lastPathComponent) == ["a.tif", "b.jpg"])
            strip.rootView.onCancel()

            #expect(sheets.shown.isEmpty)
            controller.createWebGallery(nil)
            let gallery = try #require(WebGalleryController.controller(for: window))
            defer { gallery.close() }
            #expect(gallery.model.images.map(\.url.lastPathComponent) == ["a.tif", "b.jpg"])
        }

        /// Batch Convert's every-page option: one file per page for JPEG,
        /// one multi-page file for TIFF; the sheet starts at the first page.
        @Test func batchConvertWritesEveryPage() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let doc = try document(t)
            let controller = await browser(t)
            defer { controller.window?.close() }
            // A remembered Extract Pages choice never reaches Batch Convert.
            BatchTools.store.convertSettings = BatchConvertSettings(pages: .separate(.all))
            let model = BatchConvertModel(entries: [try #require(FolderEntry(url: doc))], store: BatchTools.store)
            #expect(model.settings.pages == .first && !model.convertsEveryPage)
            model.convertsEveryPage = true
            #expect(model.settings.pages == .all)

            var settings = BatchConvertSettings(options: .defaults(for: .jpeg), pages: .all)
            controller.runBatchConvert([try #require(FolderEntry(url: doc))], settings: settings)
            await controller.batchWork?.value
            #expect(visibleNames(t.url) == ["doc-1.jpg", "doc-2.jpg", "doc-3.jpg", "doc.tif"])
            #expect(near(centre(try #require(pages(t.url.appendingPathComponent("doc-2.jpg")).first)), [0, 255, 0]))

            settings.options = .defaults(for: .tiff)
            settings.resize = BatchResize(mode: .percent, percent: 50)
            controller.runBatchConvert([try #require(FolderEntry(url: doc))], settings: settings)
            await controller.batchWork?.value
            let copy = t.url.appendingPathComponent("doc 2.tif")
            let written = pages(copy)
            #expect(written.map { [$0.width, $0.height] } == [[20, 15], [20, 15], [10, 25]])
            #expect(pages(doc).count == 3, "the original is untouched")
        }

        /// Cancel during a batch of every-page files leaves whole files only:
        /// the file written has all its pages, the one made when Cancel came
        /// is dropped, and no temporary file is left.
        @Test func cancellingEveryPageFilesLeavesWholeFiles() async throws {
            let t = try ScratchFolder()
            let first = try document(t, "a.tif"), second = try document(t, "b.tif")
            let settings = BatchConvertSettings(options: .defaults(for: .tiff), naming: .pattern(RenamePattern(text: "{name} all")),
                                                pages: .all)
            let outputs = BatchOutputPlanner.plan([RenameSource(url: first), RenameSource(url: second)], settings: settings,
                                                  folder: nil)
            #expect(outputs.map(\.pages) == [.all(count: 3), .all(count: 3)])
            let job = BatchConvertJob(outputs: outputs, settings: settings, converter: BatchConvertJob.makeConverter(),
                                      trash: BatchTools.trash, catalog: catalog, concurrency: 1)
            // The second file is finished but not yet written when Cancel
            // comes: it is dropped, its temporary file deleted.
            job.onEncoded = { [unowned job] index in if index == 1 { job.progress.cancel() } }
            let outcome = await job.run()
            #expect(outcome.wasCancelled && outcome.written.map(\.lastPathComponent) == ["a all.tif"])
            #expect(pages(t.url.appendingPathComponent("a all.tif")).count == 3)
            let everything = try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted()
            #expect(everything == ["a all.tif", "a.tif", "b.tif"], "no second file and no temporary file")
        }

        // MARK: - Create Multi-Page File

        /// The sheet lists the images in the browser's order with their page
        /// counts, reorders them, and Save writes the file in that order
        /// where the save panel says, then selects it.
        @Test func createsAMultiPageFileInTheChosenOrder() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            _ = try document(t, "a.tif")
            try t.jpeg("b.jpg", width: 60, height: 40)
            let controller = await browser(t)
            defer { controller.window?.close() }

            controller.createMultiPageFile(nil)
            let sheet = try #require(sheets.shown.last)
            let host = try #require(sheet.contentView as? NSHostingView<MultiPageView>)
            let model = host.rootView.model
            await model.headerWork?.value
            func names() -> [String] { model.order.urls.map(\.lastPathComponent) }
            #expect(names() == ["a.tif", "b.jpg"] && model.title == "Create Multi-Page File from 2 Images")
            #expect(model.pageCount == 4 && model.detail(for: model.order.entries[0]) == "3 pages")
            model.settings.includesEveryPage = false
            #expect(model.pageCount == 2)
            model.settings.includesEveryPage = true
            model.order.moveDown([try #require(model.order.urls.first)])
            #expect(names() == ["b.jpg", "a.tif"] && model.suggestedName == "b.tif")
            model.settings.format = .tiff

            let destination = t.url.appendingPathComponent("Joined.tif")
            var asked: (String, UTType)?
            MultiPageTools.chooseDestination = { name, type, _ in
                asked = (name, type)
                return destination
            }
            host.rootView.onSave()
            #expect(sheets.shown.isEmpty)
            await TestTiming.waitUntil { controller.batchWork != nil }
            await controller.batchWork?.value
            // The reload that selects the new file starts after the write and
            // may not be under way yet: wait for the selection itself.
            await TestTiming.waitUntil { controller.model.selection.map(\.lastPathComponent) == ["Joined.tif"] }
            #expect(asked?.0 == "b.tif" && asked?.1 == .tiff)
            let written = pages(destination)
            #expect(written.count == 4)
            #expect(written.map { [$0.width, $0.height] } == [[60, 40], [40, 30], [40, 30], [20, 50]], "in the chosen order")
            #expect(near(centre(written[2]), [0, 255, 0]))
            #expect(controller.model.selection.map(\.lastPathComponent) == ["Joined.tif"])
            #expect(BatchTools.store.multiPageSettings.format == .tiff, "remembered")
            #expect(sheets.everShown.count == 2 && sheets.shown.isEmpty, "the progress sheet came and went")
        }

        /// A picture that can't be read is left out and named; the file is
        /// still made from the rest. GIF frames share the first one's size.
        @Test func unreadablePicturesAreLeftOutAndNamed() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 80, height: 40)
            let broken = try t.file("b.jpg", bytes: 50)
            let controller = await browser(t)
            defer { controller.window?.close() }
            var reports: [(String, String)] = []
            MultiPageTools.report = { reports.append(($0, $1)) }
            let destination = t.url.appendingPathComponent("anim.gif")
            controller.runMultiPage([photo, broken, photo],
                                    settings: MultiPageSettings(format: .gif, frameSize: 40), to: destination)
            await controller.batchWork?.value
            #expect(reports.map(\.0) == ["1 page was left out."])
            #expect(reports.first?.1.hasPrefix("b.jpg:") == true)
            let frames = try #require(AnimationFrames(url: destination))
            #expect(frames.frameCount == 2 && frames.pixelSize == CGSize(width: 40, height: 20))
            #expect(visibleNames(t.url) == ["a.jpg", "anim.gif", "b.jpg"], "no temporary files")
        }

        /// The sheet's checks: an animation that wouldn't fit in memory, and
        /// a setting out of range, disable Save.
        @Test func multiPageSheetChecks() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 4000, height: 3000)
            let model = MultiPageModel(entries: Array(repeating: try #require(FolderEntry(url: photo)), count: 3),
                                       store: BatchTools.store, byteLimit: 3 * 800 * 600 * 4 * 3 - 1)
            await model.headerWork?.value
            model.settings.format = .gif
            model.settings.frameSize = 800
            #expect(model.problem?.contains("frames: 3, frame size: 800 × 600") == true && !model.canSave)
            model.settings.frameSize = 400
            #expect(model.problem == nil && model.canSave)
            model.settings.frameDelay = 0
            #expect(model.problem != nil)
            model.settings.frameDelay = 0.1
            model.settings.format = .pdf
            model.settings.pdfPageSize = .a4
            model.settings.pdfMargin = -1
            #expect(model.problem != nil)
        }

        @Test func orderMoves() throws {
            let urls = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/p/\($0).jpg") }
            var order = ImageOrder(urls.map { FolderEntry(url: $0, name: $0.lastPathComponent, isDirectory: false, kind: .raster, fileSize: 1,
                                                    modified: .distantPast, created: .distantPast) })
            func names() -> String { order.entries.map { RenameNamer.split($0.name).base }.joined() }
            #expect(!order.canMoveUp([urls[0]]) && order.canMoveDown([urls[0]]))
            order.moveUp([urls[2], urls[3]])
            #expect(names() == "acdb")
            order.moveDown([urls[0]])
            #expect(names() == "cadb")
            order.moveUp([urls[2]])
            #expect(names() == "cadb", "already first")
            order.move(from: [3], to: 0)
            #expect(names() == "bcad")
            order.reverse()
            #expect(names() == "dacb")
        }

        // MARK: - Image Strip

        /// The sheet works out the strip's size as it changes; Save writes it
        /// where the save panel says and opens it in the viewer.
        @Test func makesAnImageStripAndOpensIt() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            try t.jpeg("a.jpg", width: 200, height: 100)
            try t.jpeg("b.jpg", width: 100, height: 100)
            let controller = await browser(t)
            defer { controller.window?.close() }

            controller.makeImageStrip(nil)
            let sheet = try #require(sheets.shown.last)
            let host = try #require(sheet.contentView as? NSHostingView<ImageStripView>)
            let model = host.rootView.model
            await model.headerWork?.value
            model.settings = ImageStripSettings(arrangement: .horizontal, size: 50, spacing: 10, margin: 0,
                                                background: .black, options: .defaults(for: .png))
            #expect(model.sizeText == "160 × 50 pixels" && model.canSave)
            #expect(model.suggestedName == "a Strip.png")
            model.settings.size = 30000
            #expect(model.problem?.contains("32,768") == true && !model.canSave)
            model.settings.size = 50
            model.settings.arrangement = .vertical
            #expect(model.sizeText == "50 × 85 pixels")

            let destination = t.url.appendingPathComponent("Strip.png")
            MultiPageTools.chooseDestination = { _, _, _ in destination }
            var shown: [URL] = []
            MultiPageTools.showResult = { shown.append($0) }
            host.rootView.onSave()
            await TestTiming.waitUntil { controller.batchWork != nil }
            await controller.batchWork?.value
            let strip = try #require(pages(destination).first)
            #expect(strip.width == 50 && strip.height == 85)
            #expect(shown == [destination], "opened in the viewer")
            #expect(BatchTools.store.imageStripSettings.arrangement == .vertical, "remembered")
            #expect(visibleNames(t.url) == ["Strip.png", "a.jpg", "b.jpg"])
        }
    }
}
