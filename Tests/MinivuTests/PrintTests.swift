import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// Printing with a page layout: paper to layout, the print view's pages, the
/// accessory and its store, and how large pictures are decoded.
@MainActor @Suite struct PrintTests {
    /// US Letter with a quarter-inch unprintable edge.
    let letter = PrintPaper(size: CGSize(width: 612, height: 792),
                            imageableBounds: CGRect(x: 18, y: 18, width: 576, height: 756), dotsPerInch: 300)

    /// A solid colour, standing in for the viewer's rendered edit.
    nonisolated static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 300, height: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func fileItems(_ count: Int) -> [LayoutItem] {
        (0..<count).map { index in
            let url = URL(fileURLWithPath: "/tmp/print-tests/\(index).jpg")
            return LayoutItem(entry: FolderEntry(url: url, name: "\(index).jpg", isDirectory: false, kind: .raster,
                                                 fileSize: 1, modified: Date(timeIntervalSince1970: 0),
                                                 created: .distantPast))
        }
    }

    /// A provider that never touches the disk: every file is 6000 × 4000 and
    /// decodes to a flat grey image of the size asked, and the sizes are recorded.
    final class RecordingDecoder: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int] = []
        var requested: [Int] { lock.withLock { sizes } }

        func provider() -> LayoutImageProvider {
            LayoutImageProvider(decode: { [self] _, _, size in
                lock.withLock { sizes.append(size) }
                let long = min(size, 6000)
                return (PrintTests.solid(0.5, 0.5, 0.5, width: long, height: long * 2 / 3), size >= 6000)
            }, describe: { _, _ in LayoutImageInfo(pixelSize: CGSize(width: 6000, height: 4000), dateTaken: nil) })
        }
    }

    @Test func paperBecomesALayout() {
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 4
        settings.margin = 9                                   // less than the printer can reach
        settings.spacing = 12
        settings.caption = .name
        let layout = letter.layout(for: settings, imageCount: 10)
        #expect(layout.pageSize == CGSize(width: 612, height: 792))
        #expect(layout.margins == LayoutInsets(all: 18))
        #expect(layout.columns == 2 && layout.rows == 2)
        #expect(layout.captionHeight == CaptionContent.name.height(fontSize: PrintLayoutSettings.captionFontSize))
        #expect(layout.pageCount(forImageCount: 10) == 3)
        #expect(layout.centersPartialPages)

        settings.margin = 36
        #expect(letter.layout(for: settings, imageCount: 1).margins == LayoutInsets(all: 36))

        // Page Setup at 50% lays out a sheet twice the size, printed at half.
        let half = PrintPaper(size: letter.size, imageableBounds: letter.imageableBounds, scale: 0.5, dotsPerInch: 300)
        #expect(half.pageSize == CGSize(width: 1224, height: 1584))
        #expect(half.unprintableInsets == LayoutInsets(all: 36))
        #expect(half.pixelsPerUnit == 300.0 / 72 * 0.5)
        // Resolutions are capped both ways.
        #expect(PrintPaper(size: letter.size, dotsPerInch: 2880).pixelsPerUnit == 600.0 / 72)
        #expect(PrintPaper(size: letter.size, dotsPerInch: 72).pixelsPerUnit == 150.0 / 72)

        // Landscape paper turns the grid.
        let landscape = PrintPaper(size: CGSize(width: 792, height: 612))
        settings.imagesPerPage = 6
        let turned = landscape.layout(for: settings, imageCount: 6)
        #expect(turned.columns == 3 && turned.rows == 2)
    }

    @Test func printViewPagesFollowTheLayout() {
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 6
        let job = PrintJob(items: fileItems(13), settings: settings, paper: letter, provider: RecordingDecoder().provider())
        let paper = letter
        let view = PrintPageView(job: job, paperSource: { paper }, previewTest: { false })
        var range = NSRange(location: 0, length: 0)
        #expect(view.knowsPageRange(&range))
        #expect(range == NSRange(location: 1, length: 3))
        #expect(view.isFlipped)
        // The printable part of each sheet, in sheet points from its corner.
        #expect(view.rectForPage(1) == NSRect(x: 18, y: 18, width: 576, height: 756))
        #expect(view.rectForPage(3) == NSRect(x: 18, y: 2 * PrintPageView.pagePitch + 18, width: 576, height: 756))
        // Every page lies inside the view and apart from the others.
        #expect(view.bounds.contains(view.rectForPage(3)))
        #expect(!view.rectForPage(1).intersects(view.rectForPage(2)))

        // The panel's paper changes: the pages follow.
        let a5 = PrintPaper(size: CGSize(width: 420, height: 595))
        let smaller = PrintPageView(job: job, paperSource: { a5 }, previewTest: { false })
        #expect(smaller.knowsPageRange(&range))
        #expect(smaller.rectForPage(2) == NSRect(x: 0, y: PrintPageView.pagePitch, width: 420, height: 595))
        // An unprintable edge that isn't the same all round.
        let offset = PrintPaper(size: CGSize(width: 612, height: 792), imageableBounds: CGRect(x: 12, y: 30, width: 590, height: 740))
        #expect(offset.printableSheetRect == CGRect(x: 12, y: 22, width: 590, height: 740))
        #expect(offset.unprintableInsets == LayoutInsets(top: 22, left: 12, bottom: 30, right: 10))

        settings.imagesPerPage = 1
        job.update(settings: settings)
        #expect(smaller.knowsPageRange(&range) && range.length == 13)

        let single = PrintJob(items: fileItems(1), settings: PrintLayoutSettings(), paper: letter)
        #expect(PrintPageView(job: single, paperSource: { nil }, previewTest: { false }).knowsPageRange(&range))
        #expect(range == NSRange(location: 1, length: 1))
    }

    @Test func drawsARenderedImageIntoItsCell() throws {
        let red = LayoutItem(image: Self.solid(1, 0, 0), name: "Edited.jpg", modified: Date())
        let blue = LayoutItem(image: Self.solid(0, 0, 1), name: "Other.jpg", modified: Date())
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 2
        settings.autoRotate = false
        let paper = PrintPaper(size: CGSize(width: 200, height: 300))
        let job = PrintJob(items: [red, blue], settings: settings, paper: paper)
        let context = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        job.drawPage(0, in: context)
        let image = try #require(context.makeImage())
        let cells = job.currentLayout.cells(onPage: 0, imageCount: 2)
        // 1 × 2 on a tall page: red on top, blue below; margins stay paper.
        #expect(cells.count == 2 && cells[0].frame.maxY <= cells[1].frame.minY)
        #expect(ContactSheetTests.pixel(image, at: CGPoint(x: cells[0].imageArea.midX, y: cells[0].imageArea.midY))
            == [255, 0, 0])
        #expect(ContactSheetTests.pixel(image, at: CGPoint(x: cells[1].imageArea.midX, y: cells[1].imageArea.midY))
            == [0, 0, 255])
        #expect(ContactSheetTests.pixel(image, at: CGPoint(x: 5, y: 5)) == [255, 255, 255])
    }

    /// Prints `items` to a PDF the way File > Print does after the panel,
    /// without a printer: the operation asks the view for its pages and
    /// draws each into the printing system's context. Returns the document
    /// and the job.
    func printToPDF(_ items: [LayoutItem], settings: PrintLayoutSettings, in folder: URL,
                    configure: (NSPrintInfo) -> Void = { _ in }) throws -> (CGPDFDocument, PrintJob) {
        let url = folder.appendingPathComponent("Printed \(UUID().uuidString).pdf")
        let scratchDefaults = ScratchDefaults("minivu-print-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        let store = PrintLayoutStore(defaults: defaults)
        store.settings = settings
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.orientation = .portrait
        configure(info)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let session = PrintPresenter.makeSession(items: items, title: "Pictures", store: store, printInfo: info)
        session.operation.showsPrintPanel = false
        session.operation.showsProgressPanel = false
        #expect(session.operation.run())
        return (try #require(CGPDFDocument(url as CFURL)), session.job)
    }

    /// Page `number` (from 1) of `document` as sRGB pixels at 1 px per point.
    func rasterize(_ document: CGPDFDocument, page number: Int) throws -> CGImage {
        let page = try #require(document.page(at: number))
        let box = page.getBoxRect(.mediaBox)
        let context = try #require(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: box.width, height: box.height))
        context.drawPDFPage(page)
        return try #require(context.makeImage())
    }

    @Test func printsEachSheetThroughThePrintingSystem() throws {
        _ = NSApplication.shared
        let scratch = try ScratchFolder()
        let colours = [Self.solid(1, 0, 0), Self.solid(0, 0, 1), Self.solid(0, 1, 0)]
        let items = colours.enumerated().map { LayoutItem(image: $1, name: "\($0).jpg", modified: Date()) }
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 2
        settings.autoRotate = false
        settings.scaling = .fill

        let (document, job) = try printToPDF(items, settings: settings, in: scratch.url)
        #expect(document.numberOfPages == 2)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(abs(box.width - 612) < 0.5 && abs(box.height - 792) < 0.5)
        let first = try rasterize(document, page: 1)
        let cells = job.currentLayout.cells(onPage: 0, imageCount: 3)
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: cells[0].imageArea.midX, y: cells[0].imageArea.midY)) == [255, 0, 0])
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: cells[1].imageArea.midX, y: cells[1].imageArea.midY)) == [0, 0, 255])
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: 306, y: 4)) == [255, 255, 255])
        // No offset: the edges of the first picture are where the layout says.
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: cells[0].imageArea.minX + 2, y: cells[0].imageArea.minY + 2)) == [255, 0, 0])
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: cells[0].imageArea.minX - 3, y: cells[0].imageArea.minY + 20)) == [255, 255, 255])
        #expect(ContactSheetTests.pixel(first, at: CGPoint(x: cells[0].imageArea.minX + 20, y: cells[0].imageArea.minY - 3)) == [255, 255, 255])
        // The last sheet holds one picture, centred.
        let second = try rasterize(document, page: 2)
        #expect(ContactSheetTests.pixel(second, at: CGPoint(x: 306, y: 396)) == [0, 255, 0])
        #expect(ContactSheetTests.pixel(second, at: CGPoint(x: 306, y: 60)) == [255, 255, 255])

        // Page Setup at 50%: the layout is twice the size and prints at half,
        // so the sheet still shows its pictures where the layout puts them.
        let (halved, halvedJob) = try printToPDF(items, settings: settings, in: scratch.url) { $0.scalingFactor = 0.5 }
        #expect(halvedJob.currentLayout.pageSize == CGSize(width: 1224, height: 1584))
        let small = try rasterize(halved, page: 1)
        #expect(small.width == 612 && small.height == 792)
        let halfCells = halvedJob.currentLayout.cells(onPage: 0, imageCount: 3)
        #expect(ContactSheetTests.pixel(small, at: CGPoint(x: halfCells[0].imageArea.midX / 2, y: halfCells[0].imageArea.midY / 2))
            == [255, 0, 0])
        #expect(ContactSheetTests.pixel(small, at: CGPoint(x: halfCells[1].imageArea.midX / 2, y: halfCells[1].imageArea.midY / 2))
            == [0, 0, 255])
        #expect(ContactSheetTests.pixel(small, at: CGPoint(x: halfCells[0].imageArea.minX / 2 + 2, y: halfCells[0].imageArea.minY / 2 + 2))
            == [255, 0, 0])
        #expect(ContactSheetTests.pixel(small, at: CGPoint(x: 306, y: halfCells[1].imageArea.maxY / 2 + 3)) == [255, 255, 255])

        // Landscape paper: two side by side.
        let (turned, turnedJob) = try printToPDF(items, settings: settings, in: scratch.url) { $0.orientation = .landscape }
        let wide = try rasterize(turned, page: 1)
        #expect(wide.width == 792 && wide.height == 612)
        let wideCells = turnedJob.currentLayout.cells(onPage: 0, imageCount: 3)
        #expect(wideCells[0].frame.maxX <= wideCells[1].frame.minX)
        #expect(ContactSheetTests.pixel(wide, at: CGPoint(x: wideCells[1].imageArea.midX, y: wideCells[1].imageArea.midY)) == [0, 0, 255])
    }

    /// A landscape picture turned to fill a tall sheet is turned clockwise:
    /// its top edge faces the right of the sheet.
    @Test func autoRotatedPicturesTurnClockwise() throws {
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))            // bottom half blue
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 100, width: 300, height: 100))          // top half red
        let picture = LayoutItem(image: try #require(context.makeImage()), name: "Wide.jpg", modified: Date())
        var settings = PrintLayoutSettings()
        settings.margin = 0
        settings.autoRotate = true
        let job = PrintJob(items: [picture], settings: settings, paper: PrintPaper(size: CGSize(width: 200, height: 300)))
        let page = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        job.drawPage(0, in: page)
        let image = try #require(page.makeImage())
        #expect(ContactSheetTests.pixel(image, at: CGPoint(x: 150, y: 150)) == [255, 0, 0])
        #expect(ContactSheetTests.pixel(image, at: CGPoint(x: 50, y: 150)) == [0, 0, 255])
    }

    @Test func previewDecodesSmallAndInTheBackground() async throws {
        let decoder = RecordingDecoder()
        let job = PrintJob(items: fileItems(2), settings: PrintLayoutSettings(), paper: letter, provider: decoder.provider())
        let context = try #require(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // One call per batch of decodes asked for: one per page here.
            var batches = 0
            job.onPreviewReady {
                batches += 1
                if batches == 2 { done.resume() }
            }
            // Nothing is decoded yet: the preview draws placeholders and
            // returns at once, asking for the decodes behind it.
            job.drawPreviewPage(0, in: context)
            job.drawPreviewPage(1, in: context)
        }
        #expect(decoder.requested.count == 2)
        #expect(decoder.requested.allSatisfy { $0 <= PrintDecodePolicy.previewMaxPixelSize })
        job.onPreviewReady {}

        // Drawn again, the preview uses what was decoded: no new decodes.
        job.drawPreviewPage(0, in: context)
        #expect(decoder.requested.count == 2)

        // The printer gets pictures at its resolution: a photo filling a
        // letter sheet at 300 dpi, capped.
        job.drawPage(0, in: context)
        let printed = try #require(decoder.requested.last)
        #expect(decoder.requested.count == 3)
        #expect(printed > 2000 && printed <= PrintDecodePolicy.maxPixelSize)
    }

    /// However large or small a decode comes out (a JPEG's cheap 1/8 scale
    /// of a huge photo, a RAW file's small embedded preview), the preview
    /// draws it from then on rather than asking for it again and again.
    @Test(arguments: [4.0, 0.25]) func previewAsksOnceWhateverSizeADecodeGives(factor: Double) async throws {
        let log = SizeLog()
        let provider = LayoutImageProvider(decode: { _, _, size in
            log.append(size)
            let long = max(2, Int(Double(size) * factor))
            return (PrintTests.solid(0.5, 0.5, 0.5, width: long, height: long * 2 / 3), false)
        }, describe: { _, _ in LayoutImageInfo(pixelSize: CGSize(width: 12000, height: 8000), dateTaken: nil) })
        let job = PrintJob(items: fileItems(1), settings: PrintLayoutSettings(), paper: letter, provider: provider)
        let context = try #require(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        job.drawPreviewPage(0, in: context)
        await job.previewDecodesFinished()
        #expect(log.values.count == 1)
        for _ in 0..<3 {
            job.drawPreviewPage(0, in: context)
            await job.previewDecodesFinished()
        }
        #expect(log.values.count == 1)
        // What the preview drew is no larger than twice what it needs.
        let size = try #require(log.values.first)
        let cached = try #require(provider.cachedImage(for: fileItems(1)[0], maxPixelSize: size))
        #expect(max(cached.width, cached.height) <= size * 2)
    }

    /// A small decode is the whole picture only when the file is that small.
    @Test func smallDecodesKnowWhetherTheyAreWhole() throws {
        let scratch = try ScratchFolder()
        let tiny = try scratch.jpeg("tiny.jpg", width: 300, height: 200)
        let large = try scratch.jpeg("large.jpg", width: 2400, height: 1600)
        let whole = try #require(LayoutImageProvider.decodeFile(tiny, 0, 512))
        #expect(whole.isFullResolution && whole.image.width == 300)
        let part = try #require(LayoutImageProvider.decodeFile(large, 0, 256))
        #expect(!part.isFullResolution && max(part.image.width, part.image.height) == 256)
        let print = try #require(LayoutImageProvider.decodeFile(large, 0, 1000))
        #expect(!print.isFullResolution && max(print.image.width, print.image.height) >= 970)
    }

    /// Page Setup keeps the paper and scale of the last print, never its
    /// copies, pages or destination.
    @Test func aPrintHandsOnOnlyItsPaperToPageSetup() {
        let shared = NSPrintInfo()
        shared.topMargin = 40
        let chosen = NSPrintInfo()
        chosen.paperSize = NSSize(width: 842, height: 595)
        chosen.orientation = .landscape
        chosen.scalingFactor = 0.8
        chosen.topMargin = 0
        chosen.jobDisposition = .save
        chosen.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: "/tmp/elsewhere.pdf")
        chosen.dictionary()[NSPrintInfo.AttributeKey.copies] = 3
        chosen.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 2
        chosen.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 2
        let setup = PrintSession.pageSetup(from: chosen, keeping: shared)
        #expect(setup.paperSize == NSSize(width: 842, height: 595))
        #expect(setup.orientation == .landscape)
        #expect(setup.scalingFactor == 0.8)
        #expect(setup.topMargin == 40)
        #expect(setup.jobDisposition == shared.jobDisposition)
        #expect(setup.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] == nil)
        #expect((setup.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int ?? 1) == 1)
        #expect((setup.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int ?? 1) == 1)
    }

    @Test func storeRoundTripsAndRepairs() throws {
        let scratchDefaults = ScratchDefaults("minivu-print-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        let store = PrintLayoutStore(defaults: defaults)
        #expect(store.settings == PrintLayoutSettings())

        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 12
        settings.scaling = .fill
        settings.margin = 30
        settings.spacing = 6
        settings.caption = .nameAndDate
        settings.autoRotate = false
        store.settings = settings
        #expect(PrintLayoutStore(defaults: defaults).settings == settings)

        // An older or hand-edited value: missing fields default, strays are repaired.
        defaults.set(Data(#"{"imagesPerPage":7,"margin":500,"caption":"nameAndDimensions"}"#.utf8),
                     forKey: PrintLayoutStore.key)
        let repaired = store.settings
        #expect(repaired.imagesPerPage == 1 && repaired.margin == 72 && repaired.caption == .name)
        #expect(repaired.scaling == .fit && repaired.autoRotate)
        defaults.set(Data("nonsense".utf8), forKey: PrintLayoutStore.key)
        #expect(store.settings == PrintLayoutSettings())
    }

    @Test func accessoryUpdatesTheJobThePreviewAndTheStore() throws {
        _ = NSApplication.shared
        let scratchDefaults = ScratchDefaults("minivu-print-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        let store = PrintLayoutStore(defaults: defaults)
        let session = PrintPresenter.makeSession(items: fileItems(8), title: "8 Pictures", store: store,
                                                 printInfo: NSPrintInfo())
        let accessory = session.accessory
        #expect(accessory.keyPathsForValuesAffectingPreview() == ["layoutRevision"])
        #expect(session.operation.canSpawnSeparateThread)
        #expect(session.operation.printPanel.accessoryControllers.contains { $0 === accessory })
        #expect(session.operation.printPanel.options.contains(.showsPreview))
        let info = session.operation.printInfo
        #expect(info.leftMargin == 0 && info.topMargin == 0 && info.rightMargin == 0 && info.bottomMargin == 0)

        let revision = accessory.layoutRevision
        accessory.model.settings.imagesPerPage = 4
        #expect(accessory.layoutRevision == revision + 1)
        #expect(session.job.currentSettings.imagesPerPage == 4)
        #expect(session.job.pageCount == 2)
        #expect(store.settings.imagesPerPage == 4)

        let summary = accessory.localizedSummaryItems()
        #expect(summary.first?[.itemName] == "Images per Page" && summary.first?[.itemDescription] == "4")
        #expect(summary.count == 6)
        _ = accessory.view                                     // the form builds
    }

    /// The menu items reach these through the responder chain.
    @Test func browserAndViewerHandleTheCommands() {
        #expect(BrowserWindowController.instancesRespond(to: .printImages))
        #expect(BrowserWindowController.instancesRespond(to: .makeContactSheet))
        #expect(ViewerWindowController.instancesRespond(to: .printImages))
        #expect(!ViewerWindowController.instancesRespond(to: .makeContactSheet))
        #expect(PrintPresenter.jobTitle(for: fileItems(1)) == "0.jpg")
        #expect(PrintPresenter.jobTitle(for: fileItems(3)) == "3 Pictures")
    }

    @Test func lengthsFollowTheLocale() {
        #expect(PrintLength.text(points: 18, locale: Locale(identifier: "en_US")) == "0.25 in")
        #expect(PrintLength.text(points: 72, locale: Locale(identifier: "en_GB")) == "25.4 mm")
        #expect(PrintLength.text(points: 0, locale: Locale(identifier: "fr_FR")) == "0 mm")
    }

    @Test func providerCachesWithinItsBudget() {
        let provider = LayoutImageProvider(byteBudget: 3 * 1600 * 266, decode: { _, _, size in
            (PrintTests.solid(0, 0, 0, width: size, height: size * 2 / 3), false)
        })
        let items = fileItems(5)
        for item in items { _ = provider.image(for: item, maxPixelSize: 400) }
        #expect(provider.cachedCount <= 3)
        #expect(provider.cachedBytes <= provider.byteBudget)
        // The newest is kept; a smaller request is served from it, a much
        // larger one isn't.
        #expect(provider.cachedImage(for: items[4], maxPixelSize: 300) != nil)
        #expect(provider.cachedImage(for: items[4], maxPixelSize: 1000) == nil)
        #expect(provider.cachedImage(for: items[4], maxPixelSize: 100) == nil)
        #expect(provider.cachedImage(for: items[0], maxPixelSize: 400) == nil)
    }
}
