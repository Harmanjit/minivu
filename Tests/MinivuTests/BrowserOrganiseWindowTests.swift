import Testing
import AppKit
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// Find, smart folders, collections, the flat view and More Filters
    /// through the browser window (G3), never shown, with a catalog of its
    /// own and the sheets and questions recorded instead of shown.
    @MainActor @Suite(.serialized, .batchToolsReset) struct BrowserOrganiseWindowTests {
        let catalog = Catalog.inMemory()
        let sheets = BatchSheetRecorder()

        init() {
            BatchTools.sheets = sheets.presenter
        }

        func makeController() -> BrowserWindowController {
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            _ = controller.sidebar.view
            return controller
        }

        /// Waits for listings (including one a catalog notification starts),
        /// the catalog's write queue and a turn of the main queue.
        func settle(_ controller: BrowserWindowController) async {
            var awaited: Task<Void, Never>?
            repeat {
                awaited = controller.model.work
                await awaited?.value
                await withCheckedContinuation { done in BrowserModel.catalogWrites.async { done.resume() } }
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            } while controller.model.work != awaited
        }

        func item(_ action: Selector, collection: Int64? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.representedObject = collection.map { NSNumber(value: $0) }
            return item
        }

        /// Answers every name prompt with `name`, for the test's length.
        func answeringNames(with name: String?, _ body: () async throws -> Void) async rethrows {
            let saved = OrganisePrompts.askForName
            OrganisePrompts.askForName = { _, _, _, _, answer in answer(name) }
            defer { OrganisePrompts.askForName = saved }
            try await body()
        }

        @Test func findShowsResultsAndSavesThemAsASmartFolder() async throws {
            let t = try ScratchFolder()
            let sub = try t.folder("Sub")
            try t.file("IMG_1.jpg"); try t.file("IMG_2.jpg", in: sub); try t.file("DSC_3.jpg")
            let controller = makeController()
            controller.open(folder: t.url)
            await settle(controller)
            #expect(controller.validateMenuItem(item(.findImages)))
            #expect(!controller.validateMenuItem(item(.saveAsSmartFolder)))

            controller.findImages(nil)
            let sheet = try #require(controller.formSheet)
            #expect(sheets.shown == [sheet.window])
            let form = try #require(sheet.searchForm)
            #expect(BrowserModel.samePath(form.scope, t.url) && form.includeSubfolders)
            // A second Find while one is up does nothing.
            controller.findImages(nil)
            #expect(sheets.shown.count == 1)
            form.name = " img "
            controller.endFormSheet(sheet)
            #expect(sheets.shown.isEmpty && controller.formSheet == nil)
            controller.runSearch(form.query)
            await settle(controller)

            let window = try #require(controller.window)
            #expect(window.title == "“img” in \(t.url.lastPathComponent)")
            #expect(Set(controller.model.entries.map(\.name)) == ["IMG_1.jpg", "IMG_2.jpg"])
            #expect(controller.validateMenuItem(item(.saveAsSmartFolder)))
            #expect(!controller.validateMenuItem(item(.newFolder)), "a list has no folder to make one in")

            await answeringNames(with: "Shots") {
                controller.saveAsSmartFolder(nil)
                await settle(controller)
            }
            let saved = try #require(catalog.smartFolders().first)
            #expect(saved.name == "Shots" && saved.query.name == "img" && saved.query.includeSubfolders)
            #expect(controller.model.list?.kind == .smartFolder(id: saved.id) && window.title == "Shots")
            #expect(controller.sidebar.libraryRows == ["Shots"])
            #expect(controller.sidebar.selectedFolder == nil)

            // Re-run when opened: a file made since is found.
            try t.file("IMG_4.jpg")
            controller.open(list: VirtualList(kind: .smartFolder(id: saved.id), title: "Shots"))
            await settle(controller)
            #expect(controller.model.entries.count == 3)

            // Back to the folder.
            controller.goBack(nil)
            await settle(controller)
            #expect(controller.model.list?.kind == .search(form.query))
        }

        @Test func collectionsTakeTheSelectionAndGiveItBack() async throws {
            let t = try ScratchFolder()
            let a = try t.file("a.jpg"), b = try t.file("b.jpg")
            try t.file("c.jpg")
            let controller = makeController()
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.setSelection([a, b], lead: a)
            #expect(!controller.validateMenuItem(item(.removeFromCollection)), "only while a collection is shown")

            await answeringNames(with: "Trip") {
                controller.newCollection(nil)
                await settle(controller)
            }
            let trip = try #require(catalog.collections().first)
            #expect(trip.name == "Trip" && trip.count == 2)
            #expect(controller.sidebar.libraryRows == ["Trip"])

            // Add to Collection from its menu item, which names the collection.
            controller.model.setSelection([t.url.appendingPathComponent("c.jpg")], lead: nil)
            #expect(controller.validateMenuItem(item(.addToCollection, collection: trip.id)))
            controller.addToCollection(item(.addToCollection, collection: trip.id))
            await settle(controller)
            #expect(catalog.collections().first?.count == 3)

            controller.open(list: VirtualList(kind: .collection(id: trip.id), title: "Trip"))
            await settle(controller)
            #expect(controller.model.entries.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"])
            controller.model.setSelection([controller.model.entries[1].url], lead: nil)
            #expect(controller.validateMenuItem(item(.removeFromCollection)))
            controller.removeFromCollection(nil)
            await settle(controller)
            #expect(controller.model.entries.map(\.name) == ["a.jpg", "c.jpg"])
            #expect(FileManager.default.fileExists(atPath: b.path), "never out of its folder")

            // Deleting the collection shown goes back where the window was.
            let saved = OrganisePrompts.confirmDelete
            OrganisePrompts.confirmDelete = { _, _, _, answer in answer(true) }
            defer { OrganisePrompts.confirmDelete = saved }
            controller.perform(.delete(VirtualList(kind: .collection(id: trip.id), title: "Trip")))
            await settle(controller)
            #expect(catalog.collections().isEmpty && controller.sidebar.libraryRows.isEmpty)
            #expect(controller.model.list == nil && controller.model.folder != nil)
        }

        @Test func imagesDroppedOnACollectionRowJoinIt() async throws {
            let t = try ScratchFolder()
            let a = try t.file("a.jpg")
            let notes = try t.file("notes.txt")
            let controller = makeController()
            let id = try #require(catalog.createCollection(named: "Picks"))
            #expect(SidebarViewController.collectable([a, notes]).map(\.lastPathComponent) == ["a.jpg"])
            controller.perform(.add([a], toCollection: id))
            await settle(controller)
            #expect(catalog.collectionMembers(id).map(\.lastPathComponent) == ["a.jpg"])
        }

        @Test func theFlatViewIsAViewMenuToggle() async throws {
            let t = try ScratchFolder()
            let sub = try t.folder("Sub")
            try t.file("a.jpg"); try t.file("b.jpg", in: sub)
            let controller = makeController()
            controller.open(folder: t.url)
            await settle(controller)
            let toggle = item(.toggleFlatView)
            #expect(controller.validateMenuItem(toggle) && toggle.state == .off)

            controller.toggleFlatView(nil)
            await settle(controller)
            #expect(controller.validateMenuItem(toggle) && toggle.state == .on)
            #expect(controller.model.entries.map(\.name) == ["a.jpg", "b.jpg"])
            #expect(controller.window?.subtitle == "2 images, with subfolders")
            let cell = try #require(controller.grid.collectionView.item(at: IndexPath(item: 1, section: 0)) as? ThumbnailCell)
            #expect(cell.thumbnailView.folderName == "Sub")
            #expect(cell.thumbnailView.accessibilityLabel()?.hasPrefix("b.jpg, in Sub") == true)
            controller.toggleFlatView(nil)
            await settle(controller)
            #expect(controller.model.entries.map(\.name) == ["Sub", "a.jpg"])
        }

        @Test func moreFiltersEditsTheMetadataFilter() async throws {
            let t = try ScratchFolder()
            try t.file("a.jpg"); try t.file("b.nef")
            let controller = makeController()
            controller.open(folder: t.url)
            await settle(controller)
            let more = item(.showMoreFilters)
            #expect(controller.validateMenuItem(more) && more.state == .off)

            controller.showMoreFilters(nil)
            let sheet = try #require(controller.formSheet)
            let form = try #require(sheet.criteriaForm)
            form.fileTypes = [.raw]
            controller.model.metadataFilter = form.criteria
            controller.endFormSheet(sheet)
            #expect(controller.model.entries.map(\.name) == ["b.nef"])
            #expect(controller.validateMenuItem(more) && more.state == .on)

            // Show All clears it with the rating filters.
            controller.filterByRating(item(.filterByRating))
            #expect(controller.model.entries.count == 2 && !controller.model.metadataFilter.isActive)
        }

        @Test func findAndFlatViewShortcutsReachTheirCommands() throws {
            let bar = MainMenu.make()
            final class Recorder: NSObject {
                var calls: [String] = []
                @objc func findImages(_ sender: Any?) { calls.append("findImages:") }
                @objc func toggleFlatView(_ sender: Any?) { calls.append("toggleFlatView:") }
            }
            let recorder = Recorder()
            func walk(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
            for item in walk(bar) where item.action == .findImages || item.action == .toggleFlatView {
                item.target = recorder
            }
            for (flags, expected) in [(CGEventFlags.maskCommand, "findImages:"),
                                      ([.maskCommand, .maskAlternate], "toggleFlatView:")] {
                let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true))
                event.flags = flags
                let key = try #require(NSEvent(cgEvent: event))
                guard key.charactersIgnoringModifiers?.lowercased() == "f" else { continue }
                recorder.calls = []
                #expect(bar.performKeyEquivalent(with: key))
                #expect(recorder.calls == [expected])
            }
        }
    }
}

/// The form's fields as criteria (G3).
@MainActor @Suite struct CriteriaFormTests {
    @Test func numbersReadAsPhotographersTypeThem() {
        #expect(CriteriaFormModel.number("2.8") == 2.8)
        #expect(CriteriaFormModel.number("f/2,8") == 2.8)
        #expect(CriteriaFormModel.number(" 400 ") == 400)
        #expect(CriteriaFormModel.number("") == nil && CriteriaFormModel.number("abc") == nil)
        #expect(CriteriaFormModel.number("-3") == nil)
    }

    @Test func fieldsRoundTripThroughCriteria() {
        var criteria = MetadataCriteria()
        criteria.fileTypes = [.raw, .heif]
        criteria.takenFrom = 2023_02_28
        criteria.takenTo = 2024_12_31
        criteria.camera = "X-T5"
        criteria.iso = NumberRange(minimum: 100, maximum: 6400)
        criteria.aperture = NumberRange(maximum: 2.8)
        criteria.focalLength = NumberRange(minimum: 23)
        criteria.keywords = ["Paris", "night"]
        criteria.colorLabel = ColorLabel.none
        criteria.hasLocation = false
        criteria.shape = .square
        criteria.minimumWidth = 3000
        let form = CriteriaFormModel(criteria)
        #expect(form.keywords == "Paris, night" && form.apertureMaximum == "2.8" && form.isoMinimum == "100")
        #expect(form.criteria == criteria)

        form.clear()
        #expect(form.criteria == MetadataCriteria())
    }

    @Test func aSearchFormKeepsItsScopeAmongTheChoices() {
        let elsewhere = URL(fileURLWithPath: "/Users/Shared/Elsewhere", isDirectory: true)
        let form = SearchFormModel(query: SearchQuery(scope: elsewhere, name: "x", minimumRating: 2),
                                   scopes: [URL(fileURLWithPath: "/Users/Shared/Pictures", isDirectory: true)])
        #expect(form.scopes.count == 2 && BrowserModel.samePath(form.scope, elsewhere))
        #expect(form.query == SearchQuery(scope: elsewhere, name: "x", minimumRating: 2))
    }
}
