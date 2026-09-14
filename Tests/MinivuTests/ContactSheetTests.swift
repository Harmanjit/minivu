import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
@testable import Minivu

/// Contact sheets: settings, page files and PDFs, naming, the preview's
/// cost, and that cancelled or clashing saves never lose a file.
@MainActor @Suite struct ContactSheetTests {
    /// The RGB of `image` at `point`, measured from the top-left corner.
    nonisolated static func pixel(_ image: CGImage, at point: CGPoint) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
        let offset = (y * width + x) * 4
        return Array(data[offset..<offset + 3])
    }

    /// A PNG of one sRGB colour.
    func png(_ name: String, in folder: URL, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
             width: Int = 120, height: Int = 80) throws -> FolderEntry {
        try Self.png(name, in: folder, red, green, blue, width: width, height: height)
    }

    static func png(_ name: String, in folder: URL, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                    width: Int = 120, height: Int = 80) throws -> FolderEntry {
        let url = folder.appendingPathComponent(name)
        let image = PrintTests.solid(red, green, blue, width: width, height: height)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return try #require(FolderEntry(url: url))
    }

    func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// A plain grid: no margins, captions, header or footer, as PNG.
    var bareSettings: ContactSheetSettings {
        var settings = ContactSheetSettings()
        settings.pageSize = .custom
        settings.customWidth = 400
        settings.customHeight = 300
        settings.orientation = .landscape
        settings.columns = 2
        settings.rows = 1
        settings.spacing = 0
        settings.margin = 0
        settings.caption = .none
        settings.showsHeader = false
        settings.showsPageNumbers = false
        settings.scaling = .fill
        settings.format = .png
        return settings
    }

    @Test func settingsMakeTheLayout() {
        var settings = ContactSheetSettings()
        #expect(settings.pagePixelSize == CGSize(width: 2480, height: 3508))
        settings.orientation = .landscape
        #expect(settings.pagePixelSize == CGSize(width: 3508, height: 2480))
        settings.pageSize = .uhd4K
        #expect(settings.pagePixelSize == CGSize(width: 3840, height: 2160))
        settings.orientation = .portrait
        #expect(settings.pagePixelSize == CGSize(width: 2160, height: 3840))
        settings.pageSize = .letter
        #expect(settings.pagePixelSize == CGSize(width: 2550, height: 3300))

        settings.columns = 4
        settings.rows = 5
        settings.caption = .nameAndDimensions
        let layout = settings.layout(imageCount: 45, header: "Trip")
        #expect(layout.pageCount(forImageCount: 45) == 3)
        #expect(layout.headerHeight == settings.headerFontSize * 2)
        #expect(layout.footerHeight > 0)
        #expect(layout.captionHeight == CaptionContent.nameAndDimensions.height(fontSize: 36))
        #expect(settings.layout(imageCount: 45, header: "").headerHeight == 0)
        settings.showsHeader = false
        #expect(settings.layout(imageCount: 45, header: "Trip").headerHeight == 0)

        settings.rows = 0                                     // auto
        #expect(settings.pageCount(imageCount: 45) == 1)
        #expect(settings.layout(imageCount: 45, header: nil).rowCount(forImageCount: 45) == 12)

        let style = settings.style(header: "Trip")
        #expect(style.header == nil && style.showsPageNumbers && style.background == .white)
        #expect(CaptionContent.nameAndDimensions.lines(name: "a.jpg", pixelSize: CGSize(width: 6000, height: 4000),
                                                       date: nil) == ["a.jpg", "6000 × 4000"])
    }

    /// A custom page is the width and height typed, whatever orientation a
    /// preset last had; and a PDF page never passes 200 inches.
    @Test func customPagesAreAsTyped() {
        var settings = ContactSheetSettings()
        settings.pageSize = .custom
        settings.customWidth = 3000
        settings.customHeight = 2000
        settings.orientation = .portrait
        #expect(settings.pagePixelSize == CGSize(width: 3000, height: 2000))
        settings.customWidth = 99_999                         // typed past the limit
        #expect(settings.pagePixelSize == CGSize(width: 16384, height: 2000))
        #expect(abs(settings.pdfPointsPerPixel * 16384 - 14_400) < 0.001)
        settings.customWidth = 3000
        #expect(settings.pdfPointsPerPixel == 1)
        settings.pageSize = .a4
        #expect(settings.pdfPointsPerPixel == 72.0 / 300)
    }

    /// Numbers typed out of range come back as the values used.
    @Test func theDialogShowsTheValuesUsed() {
        let model = ContactSheetModel(items: [], header: "Trip", store: nil)
        model.settings.margin = 5000
        model.settings.columns = 0
        model.settings.captionSize = 1
        #expect(model.settings.margin == 800 && model.settings.columns == 1 && model.settings.captionSize == 8)
        model.stopPreview()
    }

    /// Pages placed before one that can't be are taken away again.
    @Test func aFailedPlacementLeavesNoPages() throws {
        let scratch = try ScratchFolder()
        let output = try scratch.folder("Out")
        let first = try scratch.file("page 1.png", bytes: 10)
        let missing = scratch.url.appendingPathComponent("page 2.png")
        let finals = [output.appendingPathComponent("Sheet 1.png"), output.appendingPathComponent("Sheet 2.png")]
        #expect(throws: (any Error).self) {
            _ = try ContactSheetExport.placeAll([(first, finals[0]), (missing, finals[1])], replacing: false,
                                                trash: { _ in Issue.record("nothing may be trashed") })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func storeRoundTripsAndRepairs() throws {
        let suite = "minivu-contact-sheet-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContactSheetStore(defaults: defaults)
        #expect(store.settings == ContactSheetSettings())
        var settings = bareSettings
        settings.background = ExportColor(red: 0.1, green: 0.2, blue: 0.3)
        settings.caption = .nameAndDate
        settings.colorSpace = .displayP3
        store.settings = settings
        #expect(ContactSheetStore(defaults: defaults).settings == settings)

        defaults.set(Data(#"{"columns":500,"rows":-3,"pageSize":"poster","captionSize":2}"#.utf8),
                     forKey: ContactSheetStore.key)
        let repaired = store.settings
        #expect(repaired.columns == 20 && repaired.rows == 0 && repaired.captionSize == 8)
        #expect(repaired.pageSize == .a4 && repaired.format == .jpeg)
    }

    @Test func pageNamesNeverClash() {
        let taken: Set<String> = ["Trip 2.jpg", "Trip 2 1.jpg"]
        #expect(ContactSheetNaming.pageNames(base: "Trip", count: 3, fileExtension: "jpg") { taken.contains($0) }
            == ["Trip 3 1.jpg", "Trip 3 2.jpg", "Trip 3 3.jpg"])
        #expect(ContactSheetNaming.pageNames(base: "Trip", count: 2, fileExtension: "png") { _ in false }
            == ["Trip 1.png", "Trip 2.png"])
        #expect(ContactSheetNaming.pageNames(base: "Trip", count: 0, fileExtension: "png") { _ in false }.isEmpty)
        #expect(ContactSheetNaming.baseName(folderName: "Trip") == "Trip Contact Sheet")
        #expect(ContactSheetNaming.baseName(folderName: nil) == "Contact Sheet")
        // A header is free text; the pages' names stay in the folder chosen.
        #expect(ContactSheetNaming.baseName(folderName: "2024/09: Trip") == "2024-09- Trip Contact Sheet")
        #expect(ContactSheetNaming.baseName(folderName: "../Trip") == "-Trip Contact Sheet")
        #expect(ContactSheetNaming.baseName(folderName: " .. ") == "Contact Sheet")
        #expect(ContactSheetNaming.baseName(folderName: String(repeating: "é", count: 300)).utf8.count <= 214)
        #expect(!ContactSheetNaming.baseName(folderName: "a\u{0}b\nc").contains("\n"))
        #expect(ContactSheetNaming.singleName(base: "Trip Contact Sheet", format: .pdf) == "Trip Contact Sheet.pdf")
    }

    @Test func writesRasterPagesWithEachPictureInItsCell() async throws {
        let scratch = try ScratchFolder()
        let red = try png("a.png", in: scratch.url, 1, 0, 0)
        let blue = try png("b.png", in: scratch.url, 0, 0, 1)
        let green = try png("c.png", in: scratch.url, 0, 1, 0)
        let output = try scratch.folder("Out")
        let names = ContactSheetNaming.pageNames(base: "Sheet", count: 2, fileExtension: "png") { _ in false }
        var reported: [(Int, Int)] = []
        let urls = try await ContactSheetExport.export(
            items: [red, blue, green].map { LayoutItem(entry: $0) }, settings: bareSettings, header: nil,
            destination: .folder(output, names: names), cancel: CancellationFlag(), didWrite: { _ in },
            progress: { reported.append(($0, $1)) })
        #expect(urls.map(\.lastPathComponent) == ["Sheet 1.png", "Sheet 2.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["Sheet 1.png", "Sheet 2.png"])

        let first = try image(at: urls[0]), second = try image(at: urls[1])
        #expect(first.width == 400 && first.height == 300 && second.width == 400)
        #expect(Self.pixel(first, at: CGPoint(x: 100, y: 150)) == [255, 0, 0])
        #expect(Self.pixel(first, at: CGPoint(x: 300, y: 150)) == [0, 0, 255])
        #expect(Self.pixel(second, at: CGPoint(x: 100, y: 150)) == [0, 255, 0])
        #expect(Self.pixel(second, at: CGPoint(x: 300, y: 150)) == [255, 255, 255])  // the background
        await Task.yield()
        #expect(reported.last.map { $0 == (2, 2) } ?? true)
    }

    @Test func captionsAndHeaderLeaveTheirBandsAndBackground() throws {
        let scratch = try ScratchFolder()
        let red = try png("a.png", in: scratch.url, 1, 0, 0)
        var settings = bareSettings
        settings.caption = .name
        settings.captionSize = 20
        settings.showsHeader = true
        settings.showsPageNumbers = true
        settings.margin = 10
        settings.scaling = .fit
        settings.background = ExportColor(red: 0, green: 0, blue: 0)
        settings.columns = 1
        let page = try #require(try ContactSheetRenderer.renderPage(0, items: [LayoutItem(entry: red)], settings: settings,
                                                                     header: "Trip", provider: LayoutImageProvider()))
        let layout = settings.layout(imageCount: 1, header: "Trip")
        let cell = try #require(layout.cells(onPage: 0, imageCount: 1).first)
        #expect(Self.pixel(page, at: CGPoint(x: cell.imageArea.midX, y: cell.imageArea.midY)) == [255, 0, 0])
        #expect(Self.pixel(page, at: CGPoint(x: 2, y: 2)) == [0, 0, 0])
        // Text on a black page is light: something in the header band is.
        let header = try #require(layout.headerRect)
        let brightest = stride(from: header.minX, to: header.maxX, by: 2).map {
            Int(Self.pixel(page, at: CGPoint(x: $0, y: header.midY))[0])
        }.max() ?? 0
        #expect(brightest > 128)
    }

    @Test func writesOnePDFWithAPagePerSheet() async throws {
        let scratch = try ScratchFolder()
        let entries = try (0..<3).map { try png("\($0).png", in: scratch.url, 0.2, 0.4, 0.6) }
        var settings = ContactSheetSettings()
        settings.format = .pdf
        settings.columns = 1
        settings.rows = 2
        let url = scratch.url.appendingPathComponent("Sheet.pdf")
        let urls = try await ContactSheetExport.export(items: entries.map { LayoutItem(entry: $0) }, settings: settings,
                                                       header: "Trip", destination: .file(url),
                                                       cancel: CancellationFlag(), didWrite: { _ in })
        #expect(urls == [url])
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(document.numberOfPages == 2)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(abs(box.width - 595.2) < 0.01 && abs(box.height - 841.92) < 0.01)   // A4 paper

        settings.pageSize = .uhd4K
        settings.orientation = .landscape
        let screen = scratch.url.appendingPathComponent("Screen.pdf")
        _ = try await ContactSheetExport.export(items: entries.map { LayoutItem(entry: $0) }, settings: settings,
                                                header: nil, destination: .file(screen),
                                                cancel: CancellationFlag(), didWrite: { _ in })
        let screenBox = try #require(CGPDFDocument(screen as CFURL)?.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(screenBox.size == CGSize(width: 3840, height: 2160))
    }

    @Test func replacingTheChosenFileTrashesTheOldOne() async throws {
        let scratch = try ScratchFolder()
        let red = try png("a.png", in: scratch.url, 1, 0, 0)
        let trash = try scratch.folder("Trash")
        let target = scratch.url.appendingPathComponent("Sheet.png")
        try Data("old sheet".utf8).write(to: target)
        var settings = bareSettings
        settings.columns = 1
        let urls = try await ContactSheetExport.export(
            items: [LayoutItem(entry: red)], settings: settings, header: nil, destination: .file(target),
            cancel: CancellationFlag(),
            trash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) },
            didWrite: { _ in })
        #expect(urls == [target])
        #expect(try Data(contentsOf: trash.appendingPathComponent("Sheet.png")) == Data("old sheet".utf8))
        #expect(try image(at: target).width == 400)
    }

    @Test func aFileThatAppearsInTheFolderKeepsItsName() throws {
        let scratch = try ScratchFolder()
        let temp = try scratch.file("page.png", bytes: 10)
        let existing = try scratch.file("Sheet 1.png", bytes: 3)
        let placed = try ContactSheetExport.place(temp, at: existing, replacing: false, trash: { _ in
            Issue.record("nothing may be trashed in a folder save")
        })
        #expect(placed.lastPathComponent == "Sheet 1 2.png")
        #expect(try Data(contentsOf: existing).count == 3)
        #expect(try Data(contentsOf: placed).count == 10)
    }

    @Test func cancellingLeavesNoFiles() async throws {
        let scratch = try ScratchFolder()
        let entries = try (0..<6).map { try png("\($0).png", in: scratch.url, 1, 1, 0) }
        let output = try scratch.folder("Out")
        let cancel = CancellationFlag()
        // The first decode cancels the job, as the Cancel button would mid-way.
        let provider = LayoutImageProvider(decode: { url, page, size in
            cancel.cancel()
            return LayoutImageProvider.decodeFile(url, page, size)
        })
        let names = ContactSheetNaming.pageNames(base: "Sheet", count: 3, fileExtension: "png") { _ in false }
        var settings = bareSettings
        settings.columns = 1
        settings.rows = 2
        await #expect(throws: ContactSheetRenderer.Failure.self) {
            _ = try await ContactSheetExport.export(items: entries.map { LayoutItem(entry: $0) }, settings: settings,
                                                    header: nil, destination: .folder(output, names: names),
                                                    cancel: cancel, provider: provider, didWrite: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)

        settings.format = .pdf
        let pdf = output.appendingPathComponent("Sheet.pdf")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        await #expect(throws: ContactSheetRenderer.Failure.self) {
            _ = try await ContactSheetExport.export(items: entries.map { LayoutItem(entry: $0) }, settings: settings,
                                                    header: nil, destination: .file(pdf), cancel: cancelled,
                                                    didWrite: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test func previewDecodesSmallAndCoalesces() async throws {
        let scratch = try ScratchFolder()
        let entries = try (0..<8).map { try png("\($0).png", in: scratch.url, 0.5, 0.5, 0.5, width: 3000, height: 2000) }
        let sizes = SizeLog()
        let provider = LayoutImageProvider(decode: { url, page, size in
            sizes.append(size)
            return LayoutImageProvider.decodeFile(url, page, size)
        })
        let model = ContactSheetModel(items: entries.map { LayoutItem(entry: $0) }, header: "Trip", store: nil,
                                      previewProvider: provider)
        model.settings.columns = 2
        model.settings.rows = 2
        model.settings.caption = .nameAndDate
        model.settings.spacing = 20                           // several changes in a row: one preview
        await model.waitForPreview()
        #expect(model.previewRenders == 1)
        let preview = try #require(model.preview)
        #expect(max(preview.width, preview.height) == Int(ContactSheetModel.previewLongEdge))
        #expect(sizes.values.count == 4)                     // page 1's four cells
        let cell = model.settings.layout(imageCount: 8, header: "Trip").cellSize(forImageCount: 8)
        // Each decode is the cell at the preview's scale: a few hundred
        // pixels, not the cell's full ~1000.
        #expect(sizes.values.allSatisfy { Double($0) <= max(cell.width, cell.height) * model.previewScale + 1 })
        #expect(sizes.values.allSatisfy { $0 < 400 })

        // Only the background changed: the pictures come from the cache.
        model.settings.background = .black
        await model.waitForPreview()
        #expect(model.previewRenders == 2 && sizes.values.count == 4)
    }
}

/// The dialog itself, which opens a window: part of the serialized window suite.
extension AppWindowTests {
    @MainActor @Suite(.serialized) struct ContactSheetDialogTests {
        @Test func dialogOpensAsASheetOnTheBrowser() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entry = try ContactSheetTests.png("a.png", in: scratch.url, 1, 0, 0)
            let suite = "minivu-contact-sheet-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let controller = ContactSheetController(items: [LayoutItem(entry: entry)], folderName: "Trip",
                                                    startFolder: scratch.url, store: ContactSheetStore(defaults: defaults))
            controller.begin(on: window)
            #expect(window.attachedSheet === controller.sheet)
            #expect(ContactSheetController.controller(for: window) === controller)
            #expect(controller.model.header == "Trip")
            #expect(controller.model.summary == "1 image · 1 page · 2480 × 3508 px")
            controller.model.settings.columns = 3
            #expect(ContactSheetStore(defaults: defaults).settings.columns == 3)
            controller.close()
            #expect(ContactSheetController.controller(for: window) == nil)
        }
    }
}

/// Decode sizes recorded from any thread.
final class SizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    func append(_ size: Int) { lock.withLock { sizes.append(size) } }
    var values: [Int] { lock.withLock { sizes } }
}
