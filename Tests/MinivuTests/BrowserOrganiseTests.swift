import Testing
import Foundation
import ImageIO
import MinivuCore
@testable import Minivu

/// A tree walk the test holds open until the model cancels it.
final class HeldTreeWalk: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: CancellationFlag?
    private var started = false

    var hasStarted: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { flag?.isCancelled ?? false } }

    func walk(_ root: URL, _ hidden: Bool, _ cancel: CancellationFlag,
              _ batch: ([FolderEntry]) -> Void) throws -> TreeEnumerator.Result {
        lock.withLock { flag = cancel; started = true }
        let deadline = Date().addingTimeInterval(10)
        while !cancel.isCancelled, Date() < deadline { usleep(2_000) }
        return TreeEnumerator.Result(images: [], foldersListed: 1, isTruncated: false, isCancelled: cancel.isCancelled)
    }
}

/// The flat view, lists that aren't folders and the metadata filter in the
/// browser's model (G3).
@MainActor @Suite struct BrowserOrganiseTests {
    func makeModel(catalog: Catalog = .inMemory(), treeLister: BrowserModel.TreeLister? = nil,
                   listLoader: BrowserModel.ListLoader? = nil) -> BrowserModel {
        BrowserModel(treeLister: treeLister ?? BrowserModel.listTree,
                     listLoader: listLoader ?? { try VirtualList.load($0, context: $1, cancel: $2, batch: $3) },
                     invalidate: { _ in }, watchesFolder: false, catalog: catalog, fileMarksCache: nil)
    }

    /// Waits until no listing is left in flight, including one that a
    /// catalog notification started meanwhile.
    func settle(_ model: BrowserModel) async {
        var awaited: Task<Void, Never>?
        repeat {
            awaited = model.work
            await awaited?.value
            try? await Task.sleep(for: .milliseconds(20))
        } while model.work != awaited
    }

    func paths(_ model: BrowserModel, relativeTo root: URL) -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return model.entries.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }
    }

    // MARK: - Flat view

    @Test func theFlatViewShowsEveryImageBelowTheFolderWithoutItsFolders() async throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        let deeper = try t.folder("Deeper", in: sub)
        try t.file("b.jpg"); try t.file("a.jpg", in: sub); try t.file("c.jpg", in: deeper)
        try t.file("a.jpg")
        let model = makeModel()
        model.navigate(to: t.url)
        await model.work?.value
        #expect(model.entries.map(\.name) == ["Sub", "a.jpg", "b.jpg"])

        model.flatView = true
        await model.work?.value
        #expect(model.showsManyFolders && model.folderCount == 0)
        #expect(paths(model, relativeTo: t.url) == ["a.jpg", "Sub/a.jpg", "b.jpg", "Sub/Deeper/c.jpg"])
        #expect(model.folder?.lastPathComponent == t.url.lastPathComponent)
        #expect(!model.canGoBack)                    // a view of the folder, not a place

        model.flatView = false
        await model.work?.value
        #expect(model.entries.map(\.name) == ["Sub", "a.jpg", "b.jpg"])
    }

    /// Two images with one name in different folders are two entries, each
    /// with its own marks and selection.
    @Test func namesakesInTheFlatViewKeepTheirOwnMarks() async throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        let top = try t.file("a.jpg"), inside = try t.file("a.jpg", in: sub)
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [inside])
        let model = makeModel(catalog: catalog)
        model.flatView = true
        model.navigate(to: t.url)
        await model.work?.value
        #expect(model.entries.count == 2)
        let shownInside = try #require(model.entries.first { $0.url.deletingLastPathComponent().lastPathComponent == "Sub" })
        let shownTop = try #require(model.entries.first { $0 != shownInside })
        #expect(model.marks(for: shownInside.url).rating == 4 && model.marks(for: shownTop.url).rating == 0)

        model.setSelection([shownTop.url], lead: shownTop.url)
        #expect(model.selectedEntries.map(\.url) == [shownTop.url])

        // A change to one file redraws that one only.
        catalog.setTagged(true, for: [top])
        await Task.yield()
        model.catalogChanged([shownTop.url])
        #expect(model.marks(for: shownTop.url).isTagged && !model.marks(for: shownInside.url).isTagged)
        #expect(model.changedMarkNames == [model.key(shownTop.url)])

        model.marksFilter.minimumRating = 4
        #expect(model.entries.map(\.url) == [shownInside.url])
    }

    @Test func movingOnCancelsAFlatViewStillBeingRead() async throws {
        let t = try ScratchFolder()
        let other = try t.folder("Other")
        let held = HeldTreeWalk()
        let model = makeModel(treeLister: held.walk)
        model.flatView = true
        model.navigate(to: t.url)
        let walking = model.work
        while !held.hasStarted { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.statusText == "" || model.state == .loading)

        model.flatView = false
        model.navigate(to: other)
        #expect(held.wasCancelled)
        await walking?.value
        await model.work?.value
        #expect(model.folder?.lastPathComponent == "Other" && model.state == .loaded && !model.showsManyFolders)
    }

    @Test func aTruncatedWalkSaysSo() async throws {
        let t = try ScratchFolder()
        try t.file("a.jpg")
        let model = makeModel(treeLister: { root, hidden, cancel, batch in
            var result = try TreeEnumerator.images(under: root, includeHidden: hidden, batch: batch)
            result.isTruncated = true
            return result
        })
        model.flatView = true
        model.navigate(to: t.url)
        await model.work?.value
        #expect(model.isTruncated)
        #expect(model.statusText.hasSuffix(BrowserModel.truncatedNote))
    }

    /// The grid fills in while a long walk goes on.
    @Test func aLongWalkShowsWhatItHasFoundSoFar() async throws {
        let t = try ScratchFolder()
        let first = try t.file("first.jpg"), second = try t.file("second.jpg")
        let release = CancellationFlag()
        // The walk holds until the test lets it go (the deadline only keeps
        // a failing run from hanging), so a loaded Mac can't finish it
        // before the partial list has been looked at.
        let deadline = TestTiming.patience(seconds: 60)
        let model = makeModel(treeLister: { _, _, cancel, batch in
            func entry(_ url: URL) -> FolderEntry { FolderEntry(url: url)! }
            batch([entry(first)])
            usleep(UInt32(BrowserModel.partialInterval.components.attoseconds / 1_000_000_000_000) + 50_000)
            batch([entry(second)])
            while !release.isCancelled, !cancel.isCancelled, Date() < deadline { usleep(2_000) }
            return TreeEnumerator.Result(images: [entry(first), entry(second)], foldersListed: 1, isTruncated: false,
                                         isCancelled: false)
        })
        model.flatView = true
        model.navigate(to: t.url)
        await TestTiming.waitUntil(seconds: 30) { model.entries.count == 2 && model.state == .loaded }
        #expect(model.entries.count == 2 && model.state == .loaded)
        #expect(model.statusText.hasSuffix("searching…"))
        release.cancel()
        await model.work?.value
        #expect(model.statusText == "2 images")
    }

    /// A folder's entries are found by name: taking out a namesake from a
    /// subfolder (trashed from Find Duplicates) leaves the shown file.
    @Test func removingANamesakeFromASubfolderKeepsTheShownFile() async throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        let shown = try t.file("a.jpg"), namesake = try t.file("a.jpg", in: sub)
        let model = makeModel()
        model.navigate(to: t.url)
        await model.work?.value
        #expect(model.entries.filter { !$0.isDirectory }.map(\.name) == ["a.jpg"])
        model.removeEntries([namesake])
        #expect(model.entries.filter { !$0.isDirectory }.map(\.name) == ["a.jpg"])
        model.removeEntries([shown])
        #expect(model.entries.filter { !$0.isDirectory }.isEmpty)
    }

    // MARK: - Lists

    @Test func aListIsAPlaceInTheHistory() async throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        try t.file("IMG_1.jpg"); try t.file("IMG_2.jpg", in: sub); try t.file("DSC_3.jpg")
        let model = makeModel()
        model.navigate(to: t.url)
        await model.work?.value

        let list = VirtualList(kind: .search(SearchQuery(scope: t.url, name: "img")), title: "Search")
        model.show(list: list)
        #expect(model.folder == nil && model.list == list)
        await model.work?.value
        #expect(Set(model.entries.map(\.name)) == ["IMG_1.jpg", "IMG_2.jpg"])
        #expect(model.showsManyFolders && model.canGoBack && model.enclosingFolder == nil)

        model.goBack()
        await model.work?.value
        #expect(model.list == nil && model.folder?.lastPathComponent == t.url.lastPathComponent)
        model.goForward()
        await model.work?.value
        #expect(model.list == list && model.entries.count == 2)
    }

    @Test func aCollectionFollowsAFileMinivuRenames() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let model = makeModel(catalog: catalog)
        model.show(list: VirtualList(kind: .collection(id: id), title: "Keep"))
        await model.work?.value
        #expect(model.entries.map(\.name) == ["a.jpg"])

        let renamed = try FileOperations.rename(model.entries[0].url, to: "b.jpg", catalog: catalog)
        model.reload(thenSelect: [renamed])
        await settle(model)
        #expect(model.entries.map(\.name) == ["b.jpg"])
        #expect(model.selection.map(\.lastPathComponent) == ["b.jpg"])
    }

    @Test func aDeletedSmartFolderSaysSo() async throws {
        let catalog = Catalog.inMemory()
        let model = makeModel(catalog: catalog)
        model.show(list: VirtualList(kind: .smartFolder(id: 99), title: "Gone"))
        await model.work?.value
        #expect(model.state == .failed(VirtualList.LoadError.smartFolderGone.localizedDescription))
    }

    // MARK: - Metadata filter

    @Test func theMetadataFilterShowsImagesOnceTheirHeadersAreRead() async throws {
        let t = try ScratchFolder()
        let exif: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "X-T5"],
                                     kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [3200]]]
        try t.jpeg("fuji.jpg", width: 40, height: 60, properties: exif)
        try t.jpeg("plain.jpg", width: 60, height: 40)
        try t.file("raw.nef")
        try t.folder("Folder")
        let catalog = Catalog.inMemory()
        let model = makeModel(catalog: catalog)
        model.navigate(to: t.url)
        await model.work?.value

        // Type needs nothing read.
        model.metadataFilter.fileTypes = [.raw]
        #expect(model.entries.map(\.name) == ["Folder", "raw.nef"])
        #expect(model.isFiltering)

        model.metadataFilter = MetadataCriteria()
        model.metadataFilter.camera = "x-t5"
        await model.filterMetadataWork?.value
        #expect(model.entries.map(\.name) == ["Folder", "fuji.jpg"])

        model.metadataFilter.camera = ""
        model.metadataFilter.shape = .landscape
        await model.filterMetadataWork?.value
        #expect(model.entries.map(\.name) == ["Folder", "plain.jpg"])

        // Read once: the headers are in the catalog for the next time.
        let entries = try [t.url.appendingPathComponent("fuji.jpg"), t.url.appendingPathComponent("plain.jpg")]
            .map { try #require(FolderEntry(url: $0)) }
        #expect(catalog.filterMetadata(for: entries).count == 2)

        // Show All clears it with the other filters.
        model.metadataFilter = MetadataCriteria()
        #expect(model.entries.count == 4 && !model.isFiltering)
    }

    @Test func theColourLabelFilterUsesFinderTags() async throws {
        let t = try ScratchFolder()
        let red = try t.file("red.jpg")
        try t.file("none.jpg")
        try FinderTags.setColorLabel(.red, for: red)
        let model = makeModel()
        model.navigate(to: t.url)
        await model.work?.value
        await model.finderTagWork?.value
        model.metadataFilter.colorLabel = .red
        await model.finderTagWork?.value
        #expect(model.entries.map(\.name) == ["red.jpg"])
    }
}
