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
        #expect(view.rectForPage(1) == NSRect(x: 0, y: 0, width: 612, height: 792))
        #expect(view.rectForPage(3) == NSRect(x: 0, y: 2 * PrintPageView.pagePitch, width: 612, height: 792))
        // Every page lies inside the view and apart from the others.
        #expect(view.bounds.contains(view.rectForPage(3)))
        #expect(!view.rectForPage(1).intersects(view.rectForPage(2)))

        // The panel's paper changes: the pages follow.
        let a5 = PrintPaper(size: CGSize(width: 420, height: 595))
        let smaller = PrintPageView(job: job, paperSource: { a5 }, previewTest: { false })
        #expect(smaller.knowsPageRange(&range))
        #expect(smaller.rectForPage(2).size == CGSize(width: 420, height: 595))

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

    @Test func storeRoundTripsAndRepairs() throws {
        let suite = "minivu-print-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let suite = "minivu-print-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
