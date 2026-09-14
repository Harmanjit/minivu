import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// Plain rules behind ratings, tags, filters, orders and drops.
@Suite struct ManageLogicTests {
    func entry(_ name: String, folder: Bool = false) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/Photos").appendingPathComponent(name), name: name, isDirectory: folder,
                    kind: folder ? nil : .raster, fileSize: 1, modified: .distantPast, created: .distantPast)
    }

    @Test func ratingOrderKeepsNameOrderForTies() {
        let images = ["c.jpg", "a.jpg", "b.jpg", "d.jpg"].map { entry($0) }
        let marks: [String: Catalog.Marks] = ["b.jpg": .init(rating: 5), "d.jpg": .init(rating: 3),
                                               "c.jpg": .init(rating: 3)]
        #expect(MarksOrdering.byRating(images, marks: marks, ascending: false).map(\.name)
            == ["b.jpg", "c.jpg", "d.jpg", "a.jpg"])
        // Ties stay A to Z whichever way the stars run.
        #expect(MarksOrdering.byRating(images, marks: marks, ascending: true).map(\.name)
            == ["a.jpg", "c.jpg", "d.jpg", "b.jpg"])
    }

    @Test func customOrderPlacesUnlistedFilesAfterByName() {
        let images = ["img10.jpg", "img2.jpg", "new.jpg", "img1.jpg"].map { entry($0) }
        let order = ["img10.jpg", "gone.jpg", "img1.jpg"]
        #expect(MarksOrdering.custom(images, order: order, ascending: true).map(\.name)
            == ["img10.jpg", "img1.jpg", "img2.jpg", "new.jpg"])
        #expect(MarksOrdering.custom(images, order: order, ascending: false).map(\.name)
            == ["new.jpg", "img2.jpg", "img1.jpg", "img10.jpg"])
    }

    @Test func reorderingMovesAGroupBeforeATarget() {
        let names = ["a", "b", "c", "d", "e"]
        #expect(MarksOrdering.reordered(names, moving: ["d", "b"], before: "a") == ["b", "d", "a", "c", "e"])
        #expect(MarksOrdering.reordered(names, moving: ["a"], before: nil) == ["b", "c", "d", "e", "a"])
        // A target that is itself moving stands for the next one that stays.
        #expect(MarksOrdering.reordered(names, moving: ["b", "c"], before: "c") == ["a", "b", "c", "d", "e"])
        #expect(MarksOrdering.reordered(names, moving: ["d", "e"], before: "e") == ["a", "b", "c", "d", "e"])
        #expect(MarksOrdering.reordered(names, moving: ["a", "e"], before: "c") == ["b", "a", "e", "c", "d"])
    }

    @Test func filterPassesFoldersAndChecksImages() {
        let photo = entry("p.jpg"), folder = entry("Trip", folder: true)
        var filter = MarksFilter()
        #expect(!filter.isActive)
        filter.minimumRating = 3
        #expect(filter.passes(folder, marks: .none, finderTags: []))
        #expect(!filter.passes(photo, marks: .init(rating: 2), finderTags: []))
        #expect(filter.passes(photo, marks: .init(rating: 3), finderTags: []))
        filter.taggedOnly = true
        #expect(!filter.passes(photo, marks: .init(rating: 4), finderTags: []))
        #expect(filter.passes(photo, marks: .init(rating: 4, isTagged: true), finderTags: []))
        filter = MarksFilter(finderTag: "Red")
        #expect(filter.isActive)
        #expect(!filter.passes(photo, marks: .none, finderTags: [FinderTag(name: "Blue", colorIndex: 4)]))
        #expect(filter.passes(photo, marks: .none, finderTags: [FinderTag(name: "Red", colorIndex: 6)]))
    }

    /// Finder's rules: same volume moves, another copies, Option copies and
    /// Command moves (AppKit narrows the mask to say which is held).
    @Test func dropOperations() {
        let all: NSDragOperation = [.copy, .move, .generic, .link]
        #expect(DropRules.operation(sourceMask: all, sameVolume: true) == .move)
        #expect(DropRules.operation(sourceMask: all, sameVolume: false) == .copy)
        #expect(DropRules.operation(sourceMask: .copy, sameVolume: true) == .copy)            // ⌥
        #expect(DropRules.operation(sourceMask: .generic, sameVolume: false) == .move)        // ⌘
        #expect(DropRules.operation(sourceMask: [.generic, .move], sameVolume: false) == .move)
        #expect(DropRules.operation(sourceMask: .link, sameVolume: true) == [])
    }

    @Test func movableItemsLeaveOutNoOps() {
        let folder = URL(fileURLWithPath: "/Photos/Trip")
        let files = [URL(fileURLWithPath: "/Photos/Trip/a.jpg"), URL(fileURLWithPath: "/Photos/b.jpg"),
                     URL(fileURLWithPath: "/Photos/Trip"), URL(fileURLWithPath: "/Photos"),
                     URL(fileURLWithPath: "/Photos/Trip/Day 1/c.jpg"), URL(fileURLWithPath: "/Photos/TripOld")]
        #expect(DropRules.movableItems(files, into: folder).map(\.path)
            == ["/Photos/b.jpg", "/Photos/Trip/Day 1/c.jpg", "/Photos/TripOld"])
    }

    @Test func sameVolumeForTheTemporaryFolder() throws {
        let t = try ScratchFolder()
        let file = try t.file("a.jpg")
        #expect(DropRules.sameVolume(file, t.url))
        #expect(!DropRules.sameVolume(file, URL(fileURLWithPath: "/nonexistent/folder")))
    }

    @Test func finderTagsParseAndRead() throws {
        #expect(FinderTag.parse(["Red\n6", "Work\n4", "Green", "Custom", "Bad\n9", ""])
            == [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "Work", colorIndex: 4),
                FinderTag(name: "Green", colorIndex: 2), FinderTag(name: "Custom", colorIndex: 0),
                FinderTag(name: "Bad", colorIndex: 0)])
        #expect(FinderTag(name: "Red", colorIndex: 6).color == .systemRed)
        #expect(FinderTag(name: "x", colorIndex: 0).color == nil)

        let t = try ScratchFolder()
        let file = try t.file("tagged.jpg")
        #expect(FinderTag.read(from: file).isEmpty)
        try FinderTags.setTags(["Red", "Blue"], for: file)
        #expect(FinderTag.read(from: file).map(\.name) == ["Red", "Blue"])
        #expect(FinderTag.read(from: file).map(\.colorIndex) == [6, 4])
    }

    @Test func debugMarksParse() {
        #expect(DebugMarks.parse("a.jpg=3, b.NEF=5T,c.png=T,bad=9,=2,d.jpg=t")
            == [.init(name: "a.jpg", rating: 3, tagged: false), .init(name: "b.NEF", rating: 5, tagged: true),
                .init(name: "c.png", rating: 0, tagged: true), .init(name: "d.jpg", rating: 0, tagged: true)])
    }

    @Test func ratingTexts() {
        #expect(RatingText.stars(3) == "★★★☆☆")
        #expect(RatingText.stars(9) == "★★★★★")
        #expect(RatingText.filterTitle(minimum: 0) == "Show All")
        #expect(RatingText.filterTitle(minimum: 2) == "★★ or More")
        #expect(RatingText.filterTitle(minimum: 5) == "★★★★★")
        #expect(BrowserModel.shownText(shown: 12, total: 340) == "12 of 340 shown")
        #expect(BrowserWindowController.transferActionName(count: 3, isMove: true) == "Move 3 Items")
        #expect(BrowserWindowController.transferActionName(count: 1, isMove: false) == "Copy 1 Item")
        #expect(FileTransfer.progressTitle(count: 120, isMove: true, destination: URL(fileURLWithPath: "/P/Trip"))
            == "Moving 120 items to “Trip”")
    }

    @Test func sortKeysRememberTheirDirection() throws {
        let scratchDefaults = ScratchDefaults("minivu-sort-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults

        let name = FileSortOrder(key: .name, ascending: true)
        let rating = SortDirectionMemory.switching(from: name, to: .rating, defaults: defaults)
        #expect(rating == FileSortOrder(key: .rating, ascending: false), "most stars first to begin with")
        let dateDown = SortDirectionMemory.switching(from: FileSortOrder(key: .rating, ascending: true), to: .modified,
                                                     defaults: defaults)
        #expect(dateDown == FileSortOrder(key: .modified, ascending: true))
        let backToName = SortDirectionMemory.switching(from: FileSortOrder(key: .modified, ascending: false), to: .name,
                                                       defaults: defaults)
        #expect(backToName == name)
        #expect(SortDirectionMemory.switching(from: backToName, to: .rating, defaults: defaults).ascending == true)
        #expect(SortDirectionMemory.switching(from: name, to: .modified, defaults: defaults).ascending == false)
        #expect(SortDirectionMemory.switching(from: name, to: .name, defaults: defaults) == name)
    }

    /// Digits and backquote are marks unless they continue a typed name;
    /// letters (T included) always type a name in the grid.
    @Test func gridMarkKeys() {
        #expect(GridCollectionView.markKey("3", continuingName: false) == .rate(3))
        #expect(GridCollectionView.markKey("0", continuingName: false) == .rate(0))
        #expect(GridCollectionView.markKey("`", continuingName: false) == .toggleTag)
        #expect(GridCollectionView.markKey("3", continuingName: true) == nil)
        #expect(GridCollectionView.markKey("6", continuingName: false) == nil)
        #expect(GridCollectionView.markKey("t", continuingName: false) == nil)
    }

    @Test func viewerMarkKeys() {
        func command(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> ViewerKeyCommand? {
            ViewerKeyCommand.command(characters: characters, modifiers: modifiers, zoomedIn: false)
        }
        #expect(command("4") == .rating(4))
        #expect(command("t") == .toggleTag)
        #expect(command("T") == .toggleTag)
        #expect(command("`") == .toggleTag)
        #expect(command("t", .command) == nil, "⌘T is the menu's")
    }

    @Test func dropPlans() {
        let folder = URL(fileURLWithPath: "/Photos")
        let entries = [entry("Trip", folder: true), entry("a.jpg"), entry("b.jpg"), entry("c.jpg")]
        let images: Set<String> = ["a.jpg", "b.jpg", "c.jpg", "hidden.jpg"]
        func decide(_ files: [String], index: Int, on: Bool, custom: Bool) -> GridDropPlan? {
            GridDropPlan.decide(files: files.map { URL(fileURLWithPath: $0) }, folder: folder, entries: entries,
                                index: index, on: on, customOrder: custom, isImageInFolder: images.contains)
        }
        let trip = URL(fileURLWithPath: "/Photos/Trip")
        // Onto a folder cell: into it.
        #expect(decide(["/Photos/a.jpg"], index: 0, on: true, custom: false)
            == .transfer(files: [URL(fileURLWithPath: "/Photos/a.jpg")], destination: trip))
        // From elsewhere, anywhere else: into the grid's folder.
        #expect(decide(["/Other/x.jpg"], index: 2, on: false, custom: false)
            == .transfer(files: [URL(fileURLWithPath: "/Other/x.jpg")], destination: folder))
        // Already here: nothing, unless in Custom Order.
        #expect(decide(["/Photos/c.jpg"], index: 1, on: false, custom: false) == nil)
        #expect(decide(["/Photos/c.jpg"], index: 1, on: false, custom: true)
            == .reorder(files: [URL(fileURLWithPath: "/Photos/c.jpg")], before: URL(fileURLWithPath: "/Photos/a.jpg")))
        // A gap among the folders means the first image; past the end, the end.
        #expect(decide(["/Photos/c.jpg"], index: 0, on: false, custom: true)
            == .reorder(files: [URL(fileURLWithPath: "/Photos/c.jpg")], before: URL(fileURLWithPath: "/Photos/a.jpg")))
        #expect(decide(["/Photos/a.jpg"], index: 4, on: false, custom: true)
            == .reorder(files: [URL(fileURLWithPath: "/Photos/a.jpg")], before: nil))
        // A folder of this folder can't be reordered, and dropping it on itself does nothing.
        #expect(decide(["/Photos/Trip"], index: 0, on: true, custom: true) == nil)
    }
}
