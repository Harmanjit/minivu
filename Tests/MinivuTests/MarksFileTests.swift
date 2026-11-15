import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
@testable import Minivu

/// Ratings, the tag and colour labels in the files (G2), and colour labels
/// as Finder tags (G4).
@MainActor @Suite(.serialized) struct MarksFileTests {
    /// A real image with marks of its own in its XMP, as Lightroom leaves them.
    static func image(_ name: String, in folder: ScratchFolder, type: UTType = .jpeg, rating: Int? = nil,
                      label: String? = nil) throws -> URL {
        let url = folder.url.appendingPathComponent(name)
        let metadata = CGImageMetadataCreateMutable()
        if let rating { CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(rating)" as CFString) }
        if let label { CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString) }
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try #require(context.makeImage()), metadata, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    static func xmp(_ url: URL, _ path: String) -> String? {
        let metadata = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        return metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, path as CFString) as String? }
    }

    /// A writer of its own, quick, recording what it writes and reports.
    @MainActor final class Harness {
        let writer = MarksFileWriter()
        let catalog = Catalog.inMemory()
        let calls = WriteLog()
        var failures: [MetadataBatch.Failure] = []
        var enabled = true

        init(delay: Duration = .milliseconds(150)) {
            writer.delay = delay
            writer.isEnabled = { [unowned self] in self.enabled }
            let calls = self.calls
            writer.apply = { edit, url in
                calls.record(edit, url)
                return try MetadataWriter.apply(edit, to: url)
            }
            writer.reportFailures = { [unowned self] in self.failures += $0 }
            catalog.mirror = CatalogFileMirror(writer: writer)
        }

        /// The catalog's change notices reach the writer on the main queue.
        func settle() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
    }

    // MARK: - Writing

    @Test func nothingIsWrittenWhileTheSettingIsOff() async throws {
        let t = try ScratchFolder()
        let url = try Self.image("a.jpg", in: t)
        let bytes = try Data(contentsOf: url)
        let harness = Harness()
        harness.enabled = false
        harness.catalog.setRating(4, for: [url])
        harness.catalog.setTagged(true, for: [url])
        harness.writer.labelChanged(.red, of: [url])
        await harness.settle()
        #expect(harness.writer.pendingCount == 0)
        await harness.writer.flushAndWait()
        #expect(harness.calls.edits.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: t.url.appendingPathComponent("a.xmp").path))
        #expect(harness.catalog.marks(for: url) == Catalog.Marks(rating: 4, isTagged: true), "the catalog keeps them")
        // And the preference itself is off unless the user turns it on.
        let defaults = UserDefaults(suiteName: "minivu-marks-\(UUID().uuidString)")!
        #expect(defaults.object(forKey: Preferences.Keys.writeMarksToFiles) == nil)
        #expect(!defaults.bool(forKey: Preferences.Keys.writeMarksToFiles))
    }

    @Test func quickChangesAreWrittenOnce() async throws {
        let t = try ScratchFolder()
        let url = try Self.image("a.jpg", in: t)
        let harness = Harness()
        for stars in 1...5 { harness.catalog.setRating(stars, for: [url]) }
        harness.catalog.setTagged(true, for: [url])
        harness.catalog.setTagged(false, for: [url])
        await harness.settle()
        #expect(harness.writer.pendingCount == 1)
        #expect(harness.calls.edits.isEmpty, "nothing before the quiet period ends")
        await TestTiming.waitUntil { harness.writer.pendingCount == 0 }
        await harness.writer.writing?.value
        #expect(harness.calls.edits.count == 1)
        #expect(harness.calls.edits.first?.rating == 5 && harness.calls.edits.first?.tagged == false)
        #expect(Self.xmp(url, "xmp:Rating") == "5")
        #expect(MarksXMP.readMarks(from: url) == Catalog.Marks(rating: 5))
        #expect(MetadataRevisions.shared.revision(of: url) > 0)
    }

    /// Only the mark changed in minivu is written: tagging a file whose
    /// catalog row has an old rating leaves the rating another application
    /// put in the file since, and rating it leaves the file's tag.
    @Test func onlyTheMarkThatChangedIsWritten() async throws {
        let t = try ScratchFolder()
        let url = try Self.image("a.jpg", in: t)
        let harness = Harness()
        harness.enabled = false
        harness.catalog.setRating(2, for: [url])   // months ago, setting off
        await harness.settle()
        try MetadataWriter.apply(MetadataEdit(rating: 5), to: url)   // since then, in Lightroom
        harness.enabled = true

        harness.catalog.setTagged(true, for: [url])
        await harness.settle()
        await harness.writer.flushAndWait()
        #expect(harness.calls.edits.map(\.rating) == [nil] && harness.calls.edits.map(\.tagged) == [true])
        #expect(MarksXMP.readMarks(from: url) == Catalog.Marks(rating: 5, isTagged: true), "Lightroom's five stars stay")

        harness.catalog.setRating(3, for: [url])
        await harness.settle()
        await harness.writer.flushAndWait()
        #expect(harness.calls.edits.last?.rating == 3 && harness.calls.edits.last?.tagged == nil)
        #expect(MarksXMP.readMarks(from: url) == Catalog.Marks(rating: 3, isTagged: true))
    }

    @Test func writesGoThroughTheWriteQueue() async throws {
        let t = try ScratchFolder()
        let url = try Self.image("a.jpg", in: t)
        let harness = Harness(delay: .seconds(60))
        harness.catalog.setRating(2, for: [url])
        await harness.settle()
        // A slow write already queued for the file runs first.
        let gate = Gate()
        FileWriteQueue.shared.enqueue(touching: [url]) { await gate.wait() }
        harness.writer.flush()
        #expect(FileWriteQueue.shared.pendingCount >= 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.calls.edits.isEmpty, "behind the earlier write")
        await gate.open()
        await harness.writer.writing?.value
        #expect(harness.calls.edits.count == 1 && Self.xmp(url, "xmp:Rating") == "2")
    }

    @Test func rawFilesGetASidecarAndAreNeverModified() async throws {
        let t = try ScratchFolder()
        let raw = try Self.image("camera.dng", in: t, type: .tiff)
        let bytes = try Data(contentsOf: raw)
        let harness = Harness()
        harness.catalog.setRating(3, for: [raw])
        harness.catalog.setTagged(true, for: [raw])
        await harness.settle()
        await harness.writer.flushAndWait()
        #expect(try Data(contentsOf: raw) == bytes)
        let sidecar = t.url.appendingPathComponent("camera.xmp")
        let xmp = try #require(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData))
        #expect(CGImageMetadataCopyStringValueWithPath(xmp, nil, "xmp:Rating" as CFString) as String? == "3")
        #expect(MarksXMP.readMarks(from: raw) == Catalog.Marks(rating: 3, isTagged: true))
    }

    @Test func aFileThatAlreadySaysItIsLeftAloneAndFailuresAreReported() async throws {
        let t = try ScratchFolder()
        let same = try Self.image("same.jpg", in: t, rating: 3)
        let bytes = try Data(contentsOf: same)
        let gone = t.url.appendingPathComponent("gone.jpg")
        let pdf = try t.file("doc.png")
        let harness = Harness()
        harness.writer.marksChanged(.rating, [same: Catalog.Marks(rating: 3)], of: [same])
        harness.writer.marksChanged(.rating, [gone: Catalog.Marks(rating: 2)], of: [gone])
        harness.writer.marksChanged(.rating, [pdf: Catalog.Marks(rating: 1)], of: [pdf])
        await harness.writer.flushAndWait()
        #expect(try Data(contentsOf: same) == bytes)
        #expect(harness.calls.urls.map(\.lastPathComponent) == ["doc.png"], "only the file that needed it was tried")
        // An empty "PNG" can't be rewritten: told once, kept in the catalog.
        #expect(harness.failures.map(\.url.lastPathComponent) == ["doc.png"])
    }

    @Test func labelsGoIntoTheFileAsXMPLabel() async throws {
        let t = try ScratchFolder()
        let url = try Self.image("a.jpg", in: t, label: "Approved")
        try FinderTags.setTags(["Holiday"], for: url)
        let harness = Harness()
        ColorLabelCommand.setLabel(.red, for: [url], writer: harness.writer)
        await ColorLabelCommand.work?.value
        #expect(FinderTags.tags(for: url) == ["Holiday", "Red"])
        #expect(FinderTag.read(from: url).last == FinderTag(name: "Red", colorIndex: 6))
        await harness.writer.flushAndWait()
        #expect(Self.xmp(url, "xmp:Label") == "Red")
        #expect(harness.calls.edits.last?.colorLabel == .red && harness.calls.edits.last?.rating == nil)

        ColorLabelCommand.setLabel(ColorLabel.none, for: [url], writer: harness.writer)
        await ColorLabelCommand.work?.value
        await harness.writer.flushAndWait()
        #expect(FinderTags.tags(for: url) == ["Holiday"])
        #expect(Self.xmp(url, "xmp:Label") == nil)
    }

    // MARK: - Reading in the browser

    func makeModel(_ catalog: Catalog, cache: FileMarksCache, order: FileSortOrder = FileSortOrder()) -> BrowserModel {
        BrowserModel(sortOrder: order, invalidate: { _ in }, watchesFolder: false, catalog: catalog, fileMarksCache: cache)
    }

    func open(_ model: BrowserModel, _ folder: URL) async {
        model.navigate(to: folder)
        await model.work?.value
        await model.finderTagWork?.value
    }

    /// Lets scheduled reads start, then waits for them and any re-sort.
    func settleReads(_ model: BrowserModel) async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        await model.fileMarksWork?.value
        await model.work?.value
    }

    @Test func filesWithoutARowShowTheirOwnMarksOnceShown() async throws {
        let t = try ScratchFolder()
        let a = try Self.image("a.jpg", in: t, rating: 3)
        let b = try Self.image("b.jpg", in: t)
        let c = try Self.image("c.jpg", in: t, rating: 5)
        let catalog = Catalog.inMemory()
        catalog.setRating(1, for: [c])
        let reads = ReadLog()
        let cache = FileMarksCache { url in reads.record(url); return MarksXMP.readMarks(from: url) }
        let model = makeModel(catalog, cache: cache)
        await open(model, t.url)
        #expect(reads.names.isEmpty, "listing a folder reads no file")
        #expect(model.marks(for: a) == .none)

        var changes: [BrowserModel.Changes] = []
        model.onChange = { changes.append($0) }
        model.wantFileMarks(for: [a, b, c])
        await settleReads(model)
        #expect(model.marks(for: a) == Catalog.Marks(rating: 3))
        #expect(model.marks(for: b) == .none)
        #expect(model.marks(for: c) == Catalog.Marks(rating: 1), "the catalog wins")
        #expect(Set(reads.names) == ["a.jpg", "b.jpg"], "a file with a row isn't read")
        #expect(changes.last == .marks && model.changedMarkNames == ["a.jpg"])

        // Asked again, or listed again, nothing is read again.
        model.wantFileMarks(for: [a, b])
        model.reload()
        await model.work?.value
        await settleReads(model)
        #expect(reads.names.count == 2)
        #expect(model.marks(for: a) == Catalog.Marks(rating: 3), "the listing brings what the cache knows")
    }

    @Test func sortingAndFilteringByRatingReadTheWholeFolder() async throws {
        let t = try ScratchFolder()
        _ = try Self.image("a.jpg", in: t)
        _ = try Self.image("b.jpg", in: t, rating: 4)
        _ = try Self.image("c.jpg", in: t, rating: 2)
        let model = makeModel(Catalog.inMemory(), cache: FileMarksCache(),
                              order: FileSortOrder(key: .rating, ascending: false))
        await open(model, t.url)
        await settleReads(model)
        await TestTiming.waitUntil { model.entries.map(\.name) == ["b.jpg", "c.jpg", "a.jpg"] }
        #expect(model.entries.map(\.name) == ["b.jpg", "c.jpg", "a.jpg"])

        let filtered = makeModel(Catalog.inMemory(), cache: FileMarksCache())
        await open(filtered, t.url)
        filtered.marksFilter.minimumRating = 3
        await settleReads(filtered)
        #expect(filtered.entries.map(\.name) == ["b.jpg"])
    }

    @Test func clearingAFilesRatingInMinivuKeepsItCleared() async throws {
        let t = try ScratchFolder()
        let a = try Self.image("a.jpg", in: t, rating: 4)
        let catalog = Catalog.inMemory()
        let cache = FileMarksCache()
        catalog.fileMarksReader = { cache.marks(for: $0) }
        let model = makeModel(catalog, cache: cache)
        await open(model, t.url)
        model.wantFileMarks(for: [a])
        await settleReads(model)
        #expect(model.marks(for: a).rating == 4)

        // Tagging keeps the file's four stars; clearing them sticks.
        model.toggleTag(for: [a])
        await settleCatalog(model)
        #expect(model.marks(for: a) == Catalog.Marks(rating: 4, isTagged: true))
        model.setRating(0, for: [a])
        model.toggleTag(for: [a])
        await settleCatalog(model)
        #expect(model.marks(for: a) == .none)
        model.reload()
        await model.work?.value
        #expect(model.marks(for: a) == .none, "the file's rating doesn't come back")
        #expect(Self.xmp(a, "xmp:Rating") == "4", "the file was left alone")
    }

    // MARK: - Label commands

    @Test func labelsFollowFinderStandardTags() {
        let english = FinderTags.englishColorNames
        #expect(ColorLabelCommand.label(of: [FinderTag(name: "Work", colorIndex: 4)], standardNames: english) == .none,
                "a coloured tag of the user's own isn't a label")
        #expect(ColorLabelCommand.label(of: [FinderTag(name: "Rot", colorIndex: 6)], standardNames: [6: "Rot"]) == .red)
        #expect(ColorLabelCommand.label(of: [FinderTag(name: "Green", colorIndex: 0)], standardNames: english) == .green)
        let red = [FinderTag(name: "Red", colorIndex: 6)]
        #expect(ColorLabelCommand.sharedLabel([red, red], standardNames: english) == .red)
        #expect(ColorLabelCommand.sharedLabel([red, []], standardNames: english) == nil)
        #expect(ColorLabelCommand.sharedLabel([[], []], standardNames: english) == ColorLabel.none)
        let menu = ColorLabelCommand.menu(withShortcuts: true)
        #expect(menu.items.map(\.title) == ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        #expect(menu.items.map(\.keyEquivalent) == (0...7).map(String.init))
        #expect(menu.items.allSatisfy { $0.keyEquivalentModifierMask == [.command, .option] && $0.action == .setColorLabel })
        #expect(menu.items.allSatisfy { $0.image?.accessibilityDescription == $0.title })
        #expect(ColorLabelCommand.menu(withShortcuts: false).items.allSatisfy { $0.keyEquivalent.isEmpty })
    }
}

extension AppWindowTests {
    /// The Label commands in the browser and the viewer (G4). They open the
    /// app's windows, so they run with the other window suites.
    @MainActor @Suite(.serialized) struct LabelWindowTests {
        @Test func theBrowserLabelsItsSelection() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 20, height: 20)
            let b = try t.jpeg("b.jpg", width: 20, height: 20)
            try FinderTags.setTags(["Keep"], for: b)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value
            await controller.model.finderTagWork?.value

            func item(_ label: ColorLabel) -> NSMenuItem {
                let item = NSMenuItem(title: label.name, action: .setColorLabel, keyEquivalent: "")
                item.tag = label.rawValue
                return item
            }
            controller.model.setSelection([t.url.appendingPathComponent("missing")], lead: nil)
            #expect(!controller.validateMenuItem(item(.green)))
            controller.model.setSelection([a, b], lead: a)
            #expect(controller.validateMenuItem(item(.green)))
            controller.setColorLabel(item(.green))
            await ColorLabelCommand.work?.value
            await TestTiming.waitUntil { controller.model.selectedLabel == .green }
            #expect(FinderTags.tags(for: a) == ["Green"] && FinderTags.tags(for: b) == ["Keep", "Green"])
            let green = item(.green), red = item(.red)
            _ = controller.validateMenuItem(green)
            _ = controller.validateMenuItem(red)
            #expect(green.state == .on && red.state == .off)
        }

        @Test func theViewerLabelsItsImage() async throws {
            let folder = try ScratchFolder()
            let url = try folder.jpeg("a.jpg", width: 300, height: 200)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.model.current != nil }

            let blue = NSMenuItem(title: "Blue", action: .setColorLabel, keyEquivalent: "")
            blue.tag = ColorLabel.blue.rawValue
            #expect(viewer.validateMenuItem(blue) && blue.state == .off)
            viewer.setColorLabel(blue)
            await ColorLabelCommand.work?.value
            #expect(FinderTags.tags(for: url) == ["Blue"])
            _ = viewer.validateMenuItem(blue)
            #expect(blue.state == .on)
        }
    }
}

/// What a test writer was asked to write, from the write queue's thread.
final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(edit: MetadataEdit, url: URL)] = []
    var edits: [MetadataEdit] { lock.withLock { entries.map(\.edit) } }
    var urls: [URL] { lock.withLock { entries.map(\.url) } }
    func record(_ edit: MetadataEdit, _ url: URL) { lock.withLock { entries.append((edit, url)) } }
}

/// The files a test cache read.
final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [String] = []
    var names: [String] { lock.withLock { read } }
    func record(_ url: URL) { lock.withLock { read.append(url.lastPathComponent) } }
}
