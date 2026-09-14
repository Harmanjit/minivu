import Testing
import Foundation
import MinivuCore
@testable import Minivu

/// A scratch folder of empty "images" and subfolders, removed afterwards.
/// The browser lists by extension, so the files need no pixels.
final class ScratchFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minivu-browser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, bytes: Int = 1, in folder: URL? = nil) throws -> URL {
        let file = (folder ?? url).appendingPathComponent(name)
        try Data(count: bytes).write(to: file)
        return file
    }

    @discardableResult
    func folder(_ name: String, in parent: URL? = nil) throws -> URL {
        let folder = (parent ?? url).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Records what the model asked to invalidate.
final class InvalidationLog {
    var urls: [URL] = []
}

@MainActor @Suite struct BrowserModelTests {
    func makeModel(order: FileSortOrder = FileSortOrder(), lister: BrowserModel.Lister? = nil,
                   log: InvalidationLog = InvalidationLog()) -> BrowserModel {
        if let lister {
            return BrowserModel(sortOrder: order, lister: lister, invalidate: { log.urls.append($0) },
                                watchesFolder: false)
        }
        return BrowserModel(sortOrder: order, invalidate: { log.urls.append($0) }, watchesFolder: false)
    }

    func names(_ model: BrowserModel) -> [String] { model.entries.map(\.name) }

    func open(_ model: BrowserModel, _ folder: URL, selecting item: URL? = nil) async {
        model.navigate(to: folder, selecting: item)
        await model.work?.value
    }

    @Test func listsFoldersFirstThenImagesSorted() async throws {
        let t = try ScratchFolder()
        try t.file("b10.jpg"); try t.file("b2.jpg"); try t.file("A.heic"); try t.file("notes.txt")
        try t.folder("Zed"); try t.folder("alpha")
        let model = makeModel()
        var changes: [BrowserModel.Changes] = []
        model.onChange = { changes.append($0) }

        model.navigate(to: t.url)
        #expect(model.state == .loading)
        #expect(model.entries.isEmpty)
        await model.work?.value

        #expect(model.state == .loaded)
        #expect(names(model) == ["alpha", "Zed", "A.heic", "b2.jpg", "b10.jpg"])
        #expect(model.imageCount == 3 && model.folderCount == 2)
        #expect(model.subtitle == "3 images, 2 folders")
        #expect(changes.first == .all)
        #expect(changes.last?.contains(.entries) == true)
    }

    @Test func sortOrderAndHiddenFilesReload() async throws {
        let t = try ScratchFolder()
        try t.file("small.jpg", bytes: 10); try t.file("big.jpg", bytes: 1000); try t.file(".secret.png")
        let model = makeModel()
        await open(model, t.url)
        #expect(names(model) == ["big.jpg", "small.jpg"])

        model.sortOrder = FileSortOrder(key: .size, ascending: true)
        await model.work?.value
        #expect(names(model) == ["small.jpg", "big.jpg"])

        model.showHiddenFiles = true
        await model.work?.value
        #expect(names(model).contains(".secret.png"))
    }

    @Test func filterIgnoresCaseAndAccentsAndPrunesSelection() async throws {
        let t = try ScratchFolder()
        let cafe = try t.file("Café Night.jpg")
        let beach = try t.file("beach.jpg")
        let model = makeModel()
        await open(model, t.url)
        model.setSelection([cafe, beach], lead: beach)

        model.filter = "CAFE"
        #expect(names(model) == ["Café Night.jpg"])
        #expect(model.selection.map(\.lastPathComponent) == ["Café Night.jpg"])
        #expect(model.lead?.lastPathComponent == "Café Night.jpg")

        model.filter = ""
        #expect(model.entries.count == 2)
    }

    @Test func historyAndEnclosingFolder() async throws {
        let t = try ScratchFolder()
        let a = try t.folder("A")
        let b = try t.folder("B")
        let photo = try t.file("in-b.jpg", in: b)
        let model = makeModel()

        await open(model, a)
        #expect(!model.canGoBack)
        await open(model, b, selecting: photo)
        #expect(model.lead?.lastPathComponent == "in-b.jpg")
        #expect(model.canGoBack && !model.canGoForward)

        model.goBack()
        await model.work?.value
        #expect(model.folder?.lastPathComponent == "A")
        #expect(model.canGoForward)

        // Forward returns to B with the photo selected again.
        model.goForward()
        await model.work?.value
        #expect(model.folder?.lastPathComponent == "B")
        #expect(model.lead?.lastPathComponent == "in-b.jpg")

        // Up selects the folder we came from; a new place clears Forward.
        model.goBack()
        await model.work?.value
        model.goToEnclosingFolder()
        await model.work?.value
        #expect(BrowserModel.samePath(try #require(model.folder), t.url))
        #expect(model.lead?.lastPathComponent == "A")
        #expect(!model.canGoForward)
        #expect(model.backStack.map { $0.folder.lastPathComponent } == ["A"])
    }

    @Test func navigatingToTheSameFolderOnlySelects() async throws {
        let t = try ScratchFolder()
        let one = try t.file("1.jpg")
        let two = try t.file("2.jpg")
        let model = makeModel()
        await open(model, t.url, selecting: one)
        model.navigate(to: t.url, selecting: two)
        #expect(model.lead == model.entry(for: two)?.url)
        #expect(!model.canGoBack)
    }

    /// A slow listing of the first folder must not replace the second.
    @Test func staleListingsAreDropped() async throws {
        let t = try ScratchFolder()
        let slow = try t.folder("slow")
        let fast = try t.folder("fast")
        try t.file("slow.jpg", in: slow)
        try t.file("fast.jpg", in: fast)
        let model = makeModel(lister: { folder, hidden in
            if folder.lastPathComponent == "slow" { Thread.sleep(forTimeInterval: 0.3) }
            return try FolderListing.contents(of: folder, includeHidden: hidden)
        })
        model.navigate(to: slow)
        let slowWork = model.work
        model.navigate(to: fast)
        await model.work?.value
        await slowWork?.value
        #expect(model.folder?.lastPathComponent == "fast")
        #expect(names(model) == ["fast.jpg"])
    }

    @Test func reloadKeepsSelectionAndInvalidatesChangedFiles() async throws {
        let t = try ScratchFolder()
        let keep = try t.file("keep.jpg", bytes: 10)
        let edited = try t.file("edited.jpg", bytes: 10)
        let gone = try t.file("gone.jpg", bytes: 10)
        let log = InvalidationLog()
        let model = makeModel(log: log)
        await open(model, t.url)
        model.setSelection([keep, gone], lead: gone)

        try Data(count: 99).write(to: edited)
        try FileManager.default.removeItem(at: gone)
        try t.file("new.jpg")
        model.reload()
        await model.work?.value

        #expect(Set(log.urls.map(\.lastPathComponent)) == ["edited.jpg", "gone.jpg"])
        #expect(model.selection.map(\.lastPathComponent) == ["keep.jpg"])
        #expect(model.lead?.lastPathComponent == "keep.jpg")
        #expect(names(model) == ["edited.jpg", "keep.jpg", "new.jpg"])
    }

    @Test func changedFilesDiff() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        func entry(_ name: String, size: Int64 = 1, modified: Date = date, folder: Bool = false) -> FolderEntry {
            FolderEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: folder,
                        kind: folder ? nil : .raster, fileSize: size, modified: modified, created: date)
        }
        let old = [entry("sub", folder: true), entry("a.jpg"), entry("b.jpg"), entry("c.jpg"), entry("d.jpg")]
        let new = [entry("a.jpg"), entry("b.jpg", size: 2), entry("c.jpg", modified: date + 1)]
        #expect(BrowserModel.changedFiles(old: old, new: new).map(\.lastPathComponent) == ["b.jpg", "c.jpg", "d.jpg"])
        #expect(BrowserModel.changedFiles(old: [], new: new).isEmpty)
    }

    @Test func unreadableFolderReportsAnError() async throws {
        let t = try ScratchFolder()
        let model = makeModel()
        await open(model, t.url.appendingPathComponent("missing"))
        guard case .failed(let message) = model.state else {
            Issue.record("expected an error, got \(model.state)")
            return
        }
        #expect(message.contains("missing"))
        #expect(model.entries.isEmpty)
        #expect(model.subtitle.isEmpty)
    }

    @Test func viewerImagesSkipFoldersAndFollowTheFilter() async throws {
        let t = try ScratchFolder()
        try t.folder("sub")
        try t.file("a.jpg"); let b = try t.file("b.jpg"); try t.file("c.png")
        let model = makeModel()
        await open(model, t.url)

        let all = try #require(model.imagesForViewer(startingAt: b))
        #expect(all.images.map(\.name) == ["a.jpg", "b.jpg", "c.png"])
        #expect(all.index == 1)
        #expect(model.neighbouringImages(of: b).map(\.name) == ["c.png", "a.jpg"])

        model.filter = "jpg"
        let filtered = try #require(model.imagesForViewer(startingAt: b))
        #expect(filtered.images.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(model.imagesForViewer(startingAt: t.url.appendingPathComponent("c.png")) == nil)
    }

    @Test func selectionAfterTrashMovesOn() async throws {
        let t = try ScratchFolder()
        let urls = try ["1.jpg", "2.jpg", "3.jpg", "4.jpg"].map { try t.file($0) }
        let log = InvalidationLog()
        let model = makeModel(log: log)
        await open(model, t.url)
        func name(_ url: URL?) -> String? { url?.lastPathComponent }

        #expect(name(model.selectionAfterRemoving([urls[1], urls[2]])) == "4.jpg")
        #expect(name(model.selectionAfterRemoving([urls[3]])) == "3.jpg")
        #expect(model.selectionAfterRemoving(Set(urls)) == nil)

        model.setSelection([urls[1]], lead: urls[1])
        model.removeEntries([urls[1]])
        #expect(names(model) == ["1.jpg", "3.jpg", "4.jpg"])
        #expect(model.selection.isEmpty)
        #expect(log.urls.map(\.lastPathComponent) == ["2.jpg"])
    }

    @Test func typeToSelectAndTotals() async throws {
        let t = try ScratchFolder()
        try t.folder("Émile")
        let big = try t.file("beach.jpg", bytes: 2048)
        let small = try t.file("boat.jpg", bytes: 1024)
        let model = makeModel()
        await open(model, t.url)

        #expect(model.firstEntry(withPrefix: "EM")?.lastPathComponent == "Émile")
        #expect(model.firstEntry(withPrefix: "bo")?.lastPathComponent == "boat.jpg")
        #expect(model.firstEntry(withPrefix: "zz") == nil)

        model.selectAll()
        #expect(model.selection.count == 3)
        #expect(model.selectedBytes == 3072)
        #expect(model.selectedEntries.map(\.name) == ["Émile", "beach.jpg", "boat.jpg"])
        model.setSelection([big, small], lead: small)
        #expect(model.statusText.hasPrefix("2 of 3 selected — "))
    }

    @Test func countTexts() {
        #expect(BrowserModel.countText(images: 1, folders: 0) == "1 image")
        #expect(BrowserModel.countText(images: 0, folders: 0) == "0 images")
        #expect(BrowserModel.countText(images: 0, folders: 3) == "3 folders")
        #expect(BrowserModel.countText(images: 1234, folders: 1) == "\(1234.formatted()) images, 1 folder")
        #expect(BrowserModel.selectionText(selected: 0, total: 5, bytes: 0, images: 5, folders: 0) == "5 images")
        #expect(BrowserModel.selectionText(selected: 2, total: 5, bytes: 0, images: 3, folders: 2) == "2 of 5 selected")
    }

    /// The real watcher: a file added in Finder appears without a manual reload.
    @Test func watcherReloadsOnChange() async throws {
        let t = try ScratchFolder()
        try t.file("first.jpg")
        let model = BrowserModel(invalidate: { _ in }, watchesFolder: true)
        await open(model, t.url)
        try await Task.sleep(for: .milliseconds(300))
        try t.file("second.jpg")
        let deadline = ContinuousClock.now + .seconds(5)
        while model.entries.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(names(model) == ["first.jpg", "second.jpg"])
    }
}
