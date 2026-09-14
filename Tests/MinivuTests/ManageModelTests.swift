import Testing
import Synchronization
import AppKit
import MinivuCore
@testable import Minivu

/// Waits for the catalog writes queued so far, the change notifications
/// they post, and any re-sort they start.
@MainActor func settleCatalog(_ model: BrowserModel) async {
    await withCheckedContinuation { done in BrowserModel.catalogWrites.async { done.resume() } }
    for _ in 0..<2 {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }
    await model.work?.value
}

/// The browser model with ratings, tags, Finder tags, filters and orders,
/// against a catalog of its own.
@MainActor @Suite struct ManageModelTests {
    let catalog = Catalog.inMemory()

    func makeModel(order: FileSortOrder = FileSortOrder()) -> BrowserModel {
        BrowserModel(sortOrder: order, invalidate: { _ in }, watchesFolder: false, catalog: catalog)
    }

    func names(_ model: BrowserModel) -> [String] { model.entries.map(\.name) }

    func open(_ model: BrowserModel, _ folder: URL) async {
        model.navigate(to: folder)
        await model.work?.value
        await model.finderTagWork?.value
    }

    @Test func listingReadsMarksAndSortsByRating() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg"), c = try t.file("c.jpg")
        try t.folder("Zed"); try t.folder("Alpha")
        catalog.setRating(2, for: [a])
        catalog.setRating(5, for: [c])
        catalog.setTagged(true, for: [b])

        let model = makeModel(order: FileSortOrder(key: .rating, ascending: false))
        await open(model, t.url)
        #expect(names(model) == ["Alpha", "Zed", "c.jpg", "a.jpg", "b.jpg"], "folders by name, then most stars first")
        #expect(model.marks(for: c).rating == 5)
        #expect(model.marks(for: b) == Catalog.Marks(rating: 0, isTagged: true))
    }

    @Test func ratingChangesReachOnlyTheirCells() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        let model = makeModel()
        await open(model, t.url)
        var changes: [BrowserModel.Changes] = []
        model.onChange = { changes.append($0) }

        model.select(b)
        model.setRating(4, for: model.selectedImageURLs)
        await settleCatalog(model)
        #expect(catalog.marks(for: b).rating == 4)
        #expect(model.marks(for: b).rating == 4)
        #expect(changes.last == .marks)
        #expect(model.changedMarkNames == ["b.jpg"])
        #expect(names(model) == ["a.jpg", "b.jpg"], "name order doesn't move")

        // Another folder's file changes nothing here.
        changes = []
        catalog.setRating(3, for: [URL(fileURLWithPath: "/elsewhere/a.jpg")])
        await settleCatalog(model)
        #expect(changes.isEmpty)

        // Tagging a mixed selection tags all; tagging an all-tagged one untags.
        catalog.setTagged(true, for: [a])
        await settleCatalog(model)
        model.toggleTag(for: [a, b])
        await settleCatalog(model)
        #expect(model.marks(for: a).isTagged && model.marks(for: b).isTagged)
        model.toggleTag(for: [a, b])
        await settleCatalog(model)
        #expect(!model.marks(for: a).isTagged && !model.marks(for: b).isTagged)
    }

    @Test func ratingSortFollowsNewRatings() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"); try t.file("b.jpg"); let c = try t.file("c.jpg")
        let model = makeModel(order: FileSortOrder(key: .rating, ascending: false))
        await open(model, t.url)
        #expect(names(model) == ["a.jpg", "b.jpg", "c.jpg"])
        model.setRating(1, for: [c])
        await settleCatalog(model)
        #expect(names(model) == ["c.jpg", "a.jpg", "b.jpg"])
        model.setRating(3, for: [a])
        await settleCatalog(model)
        #expect(names(model) == ["a.jpg", "c.jpg", "b.jpg"])
    }

    @Test func filtersHideAndMoveTheSelectionOn() async throws {
        let t = try ScratchFolder()
        try t.folder("Sub")
        let a = try t.file("a.jpg"), b = try t.file("b.jpg"), c = try t.file("c.jpg"), d = try t.file("d.jpg")
        catalog.setRating(3, for: [a, b, c])
        catalog.setRating(1, for: [d])
        catalog.setTagged(true, for: [c])
        let model = makeModel()
        await open(model, t.url)
        #expect(model.statusText == "4 images, 1 folder")

        model.marksFilter.minimumRating = 3
        #expect(names(model) == ["Sub", "a.jpg", "b.jpg", "c.jpg"], "folders stay")
        #expect(model.statusText == "4 of 5 shown")
        model.marksFilter.taggedOnly = true
        #expect(names(model) == ["Sub", "c.jpg"])
        model.marksFilter = MarksFilter(minimumRating: 3)

        // Rating the selected photo below the filter hides it and selects the next.
        model.select(a)
        model.setRating(2, for: [a])
        await settleCatalog(model)
        #expect(names(model) == ["Sub", "b.jpg", "c.jpg"])
        #expect(model.lead?.lastPathComponent == "b.jpg")
        #expect(model.statusText.hasPrefix("1 of 3 selected"))

        model.marksFilter = MarksFilter()
        #expect(names(model).count == 5)
        #expect(model.statusText.hasPrefix("1 of 5 selected"))
    }

    @Test func customOrderAndReordering() async throws {
        let t = try ScratchFolder()
        for name in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] { try t.file(name) }
        catalog.setCustomOrder(["c.jpg", "a.jpg"], in: t.url)
        let model = makeModel(order: FileSortOrder(key: .custom, ascending: true))
        await open(model, t.url)
        #expect(names(model) == ["c.jpg", "a.jpg", "b.jpg", "d.jpg"])

        model.moveImages([t.url.appendingPathComponent("d.jpg"), t.url.appendingPathComponent("b.jpg")],
                         before: t.url.appendingPathComponent("c.jpg"))
        await settleCatalog(model)
        #expect(names(model) == ["b.jpg", "d.jpg", "c.jpg", "a.jpg"])
        #expect(catalog.customOrder(in: t.url) == ["b.jpg", "d.jpg", "c.jpg", "a.jpg"])

        // Descending shows it back to front, and a move there is stored the right way round.
        model.sortOrder = FileSortOrder(key: .custom, ascending: false)
        await model.work?.value
        #expect(names(model) == ["a.jpg", "c.jpg", "d.jpg", "b.jpg"])
        model.moveImages([t.url.appendingPathComponent("b.jpg")], before: nil)
        await settleCatalog(model)
        #expect(names(model) == ["a.jpg", "c.jpg", "d.jpg", "b.jpg"], "already last: nothing to store")
        model.moveImages([t.url.appendingPathComponent("a.jpg")], before: nil)
        await settleCatalog(model)
        #expect(names(model) == ["c.jpg", "d.jpg", "b.jpg", "a.jpg"])
        #expect(catalog.customOrder(in: t.url) == ["a.jpg", "b.jpg", "d.jpg", "c.jpg"])

        // Other sorts don't reorder.
        model.sortOrder = FileSortOrder()
        await model.work?.value
        model.moveImages([t.url.appendingPathComponent("d.jpg")], before: nil)
        await settleCatalog(model)
        #expect(names(model) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    @Test func finderTagsAreReadAndFiltered() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"); try t.file("b.jpg")
        let trip = try t.folder("Trip")
        try FinderTags.setTags(["Red", "Work"], for: a)
        try FinderTags.setTags(["Blue"], for: trip)
        let model = makeModel()
        var changes: [BrowserModel.Changes] = []
        model.onChange = { changes.append($0) }
        await open(model, t.url)
        #expect(model.finderTags(for: a).map(\.name) == ["Red", "Work"])
        #expect(model.finderTags(for: trip).map(\.name) == ["Blue"])
        #expect(model.finderTagsInFolder.map(\.name) == ["Blue", "Red", "Work"])
        #expect(changes.last == .marks)

        model.marksFilter.finderTag = "Red"
        #expect(names(model) == ["Trip", "a.jpg"])
        // A listing again (the watcher) reads them again.
        try FinderTags.setTags([], for: a)
        model.reload()
        await model.work?.value
        await model.finderTagWork?.value
        #expect(names(model) == ["Trip"])
        #expect(model.finderTagsInFolder.map(\.name) == ["Blue"])
    }

    @Test func selectedMarksAreSharedValuesKeptUntilAChange() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        let trip = try t.folder("Trip")
        catalog.setRating(3, for: [a, b])
        catalog.setTagged(true, for: [a])
        let model = makeModel()
        await open(model, t.url)
        #expect(model.selectedMarks == .init(sharedRating: nil, allTagged: false), "nothing selected")

        model.setSelection([a, b, trip], lead: a)
        #expect(model.selectedMarks == .init(sharedRating: 3, allTagged: false), "folders don't count")
        model.setSelection([a], lead: a)
        #expect(model.selectedMarks == .init(sharedRating: 3, allTagged: true))

        // A mark written while selected is seen, not the kept answer.
        model.setRating(5, for: [a])
        await settleCatalog(model)
        #expect(model.selectedMarks == .init(sharedRating: 5, allTagged: true))
        model.setSelection([a, b], lead: a)
        #expect(model.selectedMarks == .init(sharedRating: nil, allTagged: false))
    }

    /// Tagging in Finder changes only an extended attribute, which the
    /// watcher doesn't see: a refresh (window key, a mark written) reads the
    /// named files again and leaves the others alone.
    @Test func finderTagsRefreshForNamedFiles() async throws {
        let t = try ScratchFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        try FinderTags.setTags(["Red"], for: b)
        let model = makeModel()
        await open(model, t.url)
        #expect(model.finderTags(for: b).map(\.name) == ["Red"])

        try FinderTags.setTags(["Blue"], for: a)
        try FinderTags.setTags([], for: b)
        var changes: [BrowserModel.Changes] = []
        model.onChange = { changes.append($0) }
        model.refreshFinderTags(of: [a, URL(fileURLWithPath: "/elsewhere/b.jpg")])
        await model.finderTagWork?.value
        #expect(model.finderTags(for: a).map(\.name) == ["Blue"])
        #expect(model.finderTags(for: b).map(\.name) == ["Red"], "not named: not read")
        #expect(changes == [.marks])

        // Rating a file reads its Finder tags again too.
        model.setRating(2, for: [b])
        await settleCatalog(model)
        await model.finderTagWork?.value
        #expect(model.finderTags(for: b).isEmpty)
        #expect(model.finderTagsInFolder.map(\.name) == ["Blue"])
    }

    @Test func reloadSelectsArrivals() async throws {
        let t = try ScratchFolder()
        try t.file("a.jpg")
        let model = makeModel()
        await open(model, t.url)
        let b = try t.file("b.jpg"), c = try t.file("c.jpg")
        model.reload(thenSelect: [b, c, URL(fileURLWithPath: "/elsewhere/a.jpg")])
        await model.work?.value
        #expect(Set(model.selection.map(\.lastPathComponent)) == ["b.jpg", "c.jpg"])
        #expect(model.lead?.lastPathComponent == "b.jpg")
    }
}

/// Copying and moving with name clashes, off the main thread.
@MainActor @Suite struct ManageTransferTests {
    @Test func copyWithClashesAskedOnce() async throws {
        let t = try ScratchFolder()
        let source = try t.folder("Source"), destination = try t.folder("Destination")
        let files = try ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { try t.file($0, bytes: 4, in: source) }
        try t.file("b.jpg", bytes: 1, in: destination)
        try t.file("c.jpg", bytes: 1, in: destination)
        try t.file("d.jpg", bytes: 1, in: destination)

        var asked: [(String, Int)] = []
        let answers = [FileTransfer.Resolution(policy: .replace, applyToAll: false),
                       FileTransfer.Resolution(policy: .keepBoth, applyToAll: true)]
        let outcome = await FileTransfer.run(.init(files: files, destination: destination, isMove: false), window: nil) {
            file, remaining in
            asked.append((file.lastPathComponent, remaining))
            return answers[asked.count - 1]
        }
        #expect(asked.map(\.0) == ["b.jpg", "c.jpg"], "Apply to All answered d.jpg")
        #expect(asked.map(\.1) == [3, 2])
        #expect(outcome.transfers.map(\.to.lastPathComponent) == ["a.jpg", "b.jpg", "c 2.jpg", "d 2.jpg"])
        #expect(outcome.replaced.map(\.lastPathComponent) == ["b.jpg"])
        #expect(outcome.failed.isEmpty && !outcome.wasCancelled)
        let size = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("b.jpg").path)[.size]
        #expect(size as? Int == 4)
        #expect(FileManager.default.fileExists(atPath: files[0].path), "a copy leaves the original")
    }

    /// Quitting stops a transfer after the item under way: every file is
    /// either copied whole or not at all, and no hidden temporary copy stays.
    @Test func cancellingActiveTransfersStopsBetweenItems() async throws {
        let t = try ScratchFolder()
        let source = try t.folder("Source"), destination = try t.folder("Destination"), bin = try t.folder("Bin")
        let names = (0..<30).map { "p\($0).jpg" }
        let files = try names.map { try t.file($0, bytes: 8, in: source) }
        for name in names { try t.file(name, bytes: 1, in: destination) }
        // The fourth replacement waits until the test has cancelled.
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let count = Mutex(0)
        let trash: FileTransfer.Trasher = { url in
            if count.withLock({ $0 += 1; return $0 }) == 4 {
                reached.signal()
                release.wait()
            }
            let place = bin.appendingPathComponent(UUID().uuidString)
            return Result { try FileManager.default.moveItem(at: url, to: place); return place }
        }
        let job = Task {
            await FileTransfer.run(.init(files: files, destination: destination, isMove: false), window: nil,
                                   resolver: { _, _ in .init(policy: .replace, applyToAll: true) }, trash: trash)
        }
        await BlockingWork.run { reached.wait() }
        // This test's own transfer (others may run alongside): the one of 30.
        let mine = try #require(FileTransfer.active.first { $0.total == names.count })
        mine.cancel()
        release.signal()
        let outcome = await job.value
        #expect(!FileTransfer.active.contains { $0 === mine })
        #expect(outcome.wasCancelled)
        #expect(outcome.transfers.count == 4, "the item under way finishes; none starts after")
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(left.allSatisfy { !$0.hasPrefix(".") }, "no temporary copies")
        #expect(Set(left) == Set(names), "each name holds the old file or its whole replacement")
    }

    @Test func moveSkipsWhatTheUserSkips() async throws {
        let t = try ScratchFolder()
        let source = try t.folder("Source"), destination = try t.folder("Destination")
        let files = try ["a.jpg", "b.jpg"].map { try t.file($0, in: source) }
        try t.file("b.jpg", in: destination)
        let outcome = await FileTransfer.run(.init(files: files, destination: destination, isMove: true), window: nil) { _, _ in
            FileTransfer.Resolution(policy: .skip, applyToAll: false)
        }
        #expect(outcome.transfers.map(\.to.lastPathComponent) == ["a.jpg"])
        #expect(outcome.skipped.map(\.lastPathComponent) == ["b.jpg"])
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        #expect(FileManager.default.fileExists(atPath: files[1].path))
    }

    @Test func exactMovesAndCopiesPutNamesBack() throws {
        let t = try ScratchFolder()
        let destination = try t.folder("Destination")
        let copy = try t.file("photo 2.jpg", in: destination)
        let back = t.url.appendingPathComponent("photo.jpg")
        #expect(BrowserWindowController.moveFile(copy, exactlyTo: back))
        #expect(FileManager.default.fileExists(atPath: back.path))
        #expect(!BrowserWindowController.moveFile(back, exactlyTo: back), "never over a file")
        let again = destination.appendingPathComponent("photo 2.jpg")
        #expect(BrowserWindowController.copyFile(back, exactlyTo: again))
        #expect(FileManager.default.fileExists(atPath: again.path) && FileManager.default.fileExists(atPath: back.path))
    }

    @Test func recentDestinationsKeepFiveNewestFirst() throws {
        let scratchDefaults = ScratchDefaults("minivu-recent-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        let t = try ScratchFolder()
        let folders = try (1...6).map { try t.folder("F\($0)") }
        let store = RecentDestinations(defaults: defaults)
        folders.forEach(store.add)
        store.add(folders[2])
        #expect(store.folders.map(\.lastPathComponent) == ["F3", "F6", "F5", "F4", "F2"])
        let reloaded = RecentDestinations(defaults: defaults)
        #expect(reloaded.folders.map(\.lastPathComponent) == ["F3", "F6", "F5", "F4", "F2"])

        let menu = RecentDestinationsMenu.make(title: "Copy To", action: .copyToFolder, store: reloaded)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["F3", "F6", "F5", "F4", "F2", "-", "Choose Folder…"])
        #expect((menu.items.first?.representedObject as? URL)?.lastPathComponent == "F3")
        #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.action == .copyToFolder })
    }
}
