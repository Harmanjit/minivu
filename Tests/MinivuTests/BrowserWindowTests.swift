import Testing
import AppKit
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// The assembled window, never shown: model changes reach the grid, title
    /// and menus, and the grid's selection reaches the model.
    ///
    /// Serialized: every browser window records its folder in the shared
    /// defaults, which `folderFlowsThroughTheWindow` reads back.
    @MainActor @Suite(.serialized) struct BrowserWindowTests {
        /// Waits for the folder listing and one turn of the main queue.
        func settle(_ controller: BrowserWindowController) async {
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return item
        }

        @Test func folderFlowsThroughTheWindow() async throws {
            _ = NSApplication.shared
            let savedLastFolder = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(savedLastFolder, forKey: AppDelegate.lastFolderKey) }

            // Empty files: listed by extension, and never decoded into any cache.
            let t = try ScratchFolder()
            let sub = try t.folder("Sub")
            try t.file("a.jpg"); let b = try t.file("b.jpg"); try t.file("c.jpg")
            let controller = BrowserWindowController()
            let window = try #require(controller.window)
            let grid = controller.grid
            _ = grid.view

            controller.open(folder: t.url)
            await settle(controller)
            #expect(window.title == t.url.lastPathComponent)
            #expect(window.subtitle == "3 images, 1 folder")
            #expect(grid.collectionView.numberOfItems(inSection: 0) == 4)
            #expect(UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey) == controller.model.folder?.path)

            // Model to view.
            controller.model.select(b)
            #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0)])
            #expect(controller.validateMenuItem(item(.moveToTrash)))
            #expect(!controller.validateMenuItem(item(.goBack)))

            // ⌘A in the grid selects everything and keeps the lead.
            grid.collectionView.selectAll(nil)
            #expect(controller.model.selection.count == 4)
            #expect(controller.model.lead?.lastPathComponent == "b.jpg")
            #expect(grid.collectionView.selectionIndexPaths.count == 4)

            // View to model, as a click reports it.
            let first = IndexPath(item: 1, section: 0)
            grid.collectionView.selectionIndexPaths = [first]
            grid.collectionView(grid.collectionView, didSelectItemsAt: [first])
            #expect(controller.model.lead?.lastPathComponent == "a.jpg")

            // Into the subfolder and back up, which selects it again.
            controller.model.navigate(to: sub)
            await settle(controller)
            #expect(controller.validateMenuItem(item(.goBack)))
            #expect(grid.collectionView.numberOfItems(inSection: 0) == 0)
            controller.goToEnclosingFolder(nil)
            await settle(controller)
            #expect(controller.model.lead?.lastPathComponent == "Sub")
            #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 0, section: 0)])

            // Sort checkmarks follow the preference.
            let byName = item(.sortBy, tag: SortKey.allCases.firstIndex(of: .name)!)
            _ = controller.validateMenuItem(byName)
            #expect(byName.state == (Preferences.shared.sortOrder.key == .name ? .on : .off))
            let preview = item(.togglePreviewPane)
            _ = controller.validateMenuItem(preview)
            #expect(preview.title == (controller.previewItem.isCollapsed ? "Show Preview Pane" : "Hide Preview Pane"))

            // The search field's filter reaches the grid.
            controller.model.filter = "c.j"
            #expect(grid.collectionView.numberOfItems(inSection: 0) == 1)
            window.close()
        }
    }
}

/// Keyboard and wheel paths through the browser, with key events made the
/// way AppKit delivers them. Part of the serialized window suite.
extension AppWindowTests.BrowserWindowTests {
    nonisolated static let testAssets = URL(fileURLWithPath: "/Users/harman/latent/TestAssets", isDirectory: true)

    func settle(_ model: BrowserModel) async {
        await model.work?.value
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    func key(_ characters: String, code: UInt16, at time: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    /// ⌘A keeps the lead, so Return after it opens the photo the user was
    /// on, not the first or last of the folder.
    @Test func selectAllThenReturnOpensTheLead() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        try t.folder("Sub")
        try t.file("a.jpg"); let b = try t.file("b.jpg"); try t.file("c.jpg")
        let controller = BrowserWindowController()
        defer { controller.window?.close() }
        let grid = controller.grid
        _ = grid.view
        var opened: [String] = []
        grid.onOpen = { opened.append($0.name) }

        controller.open(folder: t.url)
        await settle(controller.model)
        controller.model.select(b)
        grid.collectionView.selectAll(nil)
        #expect(controller.model.selection.count == 4)
        #expect(controller.model.statusText.hasPrefix("4 of 4 selected"))
        grid.collectionView.keyDown(with: key("\r", code: 36, at: 1))
        #expect(opened == ["b.jpg"])
        #expect(controller.validateMenuItem(item(.openInViewer)))
        #expect(controller.model.imagesForViewer(startingAt: try #require(controller.model.lead))?.index == 1)

        // With nothing chosen first, the lead is the first item.
        controller.model.setSelection([], lead: nil)
        grid.collectionView.selectAll(nil)
        grid.collectionView.keyDown(with: key("\r", code: 76, at: 2))
        #expect(opened == ["b.jpg", "Sub"])
    }

    /// Typing a name selects the first entry it begins, in the folder's
    /// name order (base name first, then the extension).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: AppWindowTests.BrowserWindowTests.testAssets.path)))
    func typeSelectInTestAssets() async throws {
        _ = NSApplication.shared
        let model = BrowserModel(sortOrder: FileSortOrder(), invalidate: { _ in }, watchesFolder: false)
        let grid = GridViewController(model: model)
        _ = grid.view
        model.onChange = { grid.modelChanged($0) }
        model.navigate(to: Self.testAssets)
        await settle(model)

        let photos = model.entries.map(\.name).filter { $0.hasPrefix("HSB_") }
        #expect(photos == ["HSB_2615.NEF", "HSB_2639.NEF", "HSB_6548.heic", "HSB_6548.jpg", "HSB_6548.NEF",
                           "HSB_6548.tif", "HSB_6548_nosp.jpg", "HSB_6548_P3.jpg", "HSB_6548_SRGB.jpg",
                           "HSB_6664.NEF"])
        var time: TimeInterval = 10
        var leads: [String] = []
        for character in "hsb_66" {
            time += 0.15
            grid.collectionView.keyDown(with: key(String(character), code: 0, at: time))
            leads.append(model.lead?.lastPathComponent ?? "-")
        }
        #expect(leads == ["HSB_2615.NEF", "HSB_2615.NEF", "HSB_2615.NEF", "HSB_2615.NEF", "HSB_6548.heic",
                          "HSB_6664.NEF"])
        #expect(grid.collectionView.selectionIndexPaths.map(\.item) == [model.index(of: try #require(model.lead))])

        // After a pause, typing starts a new name.
        grid.collectionView.keyDown(with: key("n", code: 0, at: time + 2))
        #expect(model.lead?.lastPathComponent == "nikon_d750_sample.nef")
    }

    /// The wheel over the preview, in "navigate" mode, moves the grid's
    /// selection to the next image and scrolls it into view.
    @Test func previewWheelStepsTheGrid() async throws {
        _ = NSApplication.shared
        let savedWheel = Preferences.shared.wheelAction, savedWrap = Preferences.shared.wrapAround
        defer {
            Preferences.shared.wheelAction = savedWheel
            Preferences.shared.wrapAround = savedWrap
        }
        Preferences.shared.wheelAction = .navigate
        Preferences.shared.wrapAround = false

        let t = try ScratchFolder()
        try t.folder("Sub")
        let files = try (0..<300).map { try t.file(String(format: "p%03d.jpg", $0)) }
        let controller = BrowserWindowController()
        defer { controller.window?.close() }
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        let grid = controller.grid
        _ = grid.view
        controller.open(folder: t.url)
        await settle(controller.model)
        controller.model.select(files[0])

        // A mouse wheel notch towards the user: next image.
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        canvas.delegate = controller.preview
        func wheel(_ lines: Int32) throws {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                             wheel1: lines, wheel2: 0, wheel3: 0))
            canvas.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        }
        try wheel(-1)
        #expect(controller.model.lead?.lastPathComponent == "p001.jpg")
        try wheel(1)
        try wheel(1)
        #expect(controller.model.lead?.lastPathComponent == "p000.jpg", "stops at the first image, not the folder")

        // In "zoom" mode the wheel is the canvas's own: the selection stays.
        Preferences.shared.wheelAction = .zoom
        try wheel(-1)
        #expect(controller.model.lead?.lastPathComponent == "p000.jpg")
        Preferences.shared.wheelAction = .navigate

        // Stepping back from the first image with wrap-around reaches the
        // last, far down the grid, which scrolls to show it.
        Preferences.shared.wrapAround = true
        try wheel(1)
        #expect(controller.model.lead?.lastPathComponent == "p299.jpg")
        let last = IndexPath(item: controller.model.entries.count - 1, section: 0)
        #expect(grid.collectionView.selectionIndexPaths == [last])
        let frame = try #require(grid.collectionView.layoutAttributesForItem(at: last)?.frame)
        #expect(grid.collectionView.visibleRect.intersects(frame))
    }

    /// Enclosing Folder is enabled only when the parent can be read.
    @Test func enclosingFolderValidation() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        let locked = try t.folder("Locked")
        let inside = try t.folder("Inside", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let controller = BrowserWindowController()
        defer { controller.window?.close() }
        _ = controller.grid.view

        // The toolbar's up button validates the same way as the menu item.
        let upButton = try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier == .browserEnclosingFolder })

        controller.open(folder: locked)
        await settle(controller.model)
        #expect(controller.validateMenuItem(item(.goToEnclosingFolder)))
        #expect(controller.validateToolbarItem(upButton))
        controller.open(folder: inside)
        await settle(controller.model)
        #expect(!controller.validateMenuItem(item(.goToEnclosingFolder)))
        #expect(!controller.validateToolbarItem(upButton))
    }
}

/// Edit > Select Tagged and Invert Selection on the grid, each with a
/// catalog of its own. Part of the serialized window suite.
extension AppWindowTests.BrowserWindowTests {
    /// A browser window with a catalog of its own, so a test's tags never
    /// reach the one the person running it has.
    func makeController() -> BrowserWindowController {
        let controller = BrowserWindowController(catalog: .inMemory())
        _ = controller.grid.view
        return controller
    }

    /// Tags the named images through the model, so the marks land under the
    /// URLs the listing made rather than the test's own spelling of them.
    func tag(_ names: [String], in controller: BrowserWindowController) async {
        let urls = controller.model.entries.filter { names.contains($0.name) }.map(\.url)
        controller.model.toggleTag(for: urls)
        await settleCatalog(controller.model)
        await TestTiming.waitUntil { urls.allSatisfy { controller.model.marks(for: $0).isTagged } }
    }

    /// Select Tagged takes exactly the tagged images and leaves the folder
    /// and the untagged image alone. The lead moves only when it has to.
    @Test func selectTaggedTakesTheTaggedImagesAndNothingElse() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        try t.folder("Sub")
        try t.file("a.jpg"); let b = try t.file("b.jpg"); try t.file("c.jpg")
        let controller = makeController()
        defer { controller.window?.close() }
        controller.open(folder: t.url)
        await settle(controller.model)

        // Nothing is tagged yet, so there is nothing to select.
        #expect(!controller.validateMenuItem(item(.selectTagged)))
        await tag(["a.jpg", "c.jpg"], in: controller)
        #expect(controller.validateMenuItem(item(.selectTagged)))

        controller.model.select(b)
        controller.selectTagged(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["a.jpg", "c.jpg"])
        #expect(controller.model.lead?.lastPathComponent == "a.jpg", "the lead was untagged, so it moved")
        #expect(controller.grid.collectionView.selectionIndexPaths.map(\.item).sorted() == [1, 3])

        // A lead that is itself tagged stays where it is, so the preview
        // doesn't jump to another photo.
        controller.model.select(try #require(controller.model.entries.last).url)
        controller.selectTagged(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["a.jpg", "c.jpg"])
        #expect(controller.model.lead?.lastPathComponent == "c.jpg")
    }

    /// A filter is the user saying which images they are working with, so a
    /// tagged image the grid isn't showing is not selected.
    @Test func selectTaggedStopsAtWhatTheFilterShows() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        try t.file("a.jpg"); try t.file("b.jpg"); try t.file("c.jpg")
        let controller = makeController()
        defer { controller.window?.close() }
        controller.open(folder: t.url)
        await settle(controller.model)
        await tag(["a.jpg", "c.jpg"], in: controller)

        controller.model.filter = "c"
        #expect(controller.model.entries.map(\.name) == ["c.jpg"])
        controller.selectTagged(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["c.jpg"])
        #expect(controller.model.selection.count == 1, "a.jpg is tagged, but the grid isn't showing it")

        // With every tagged image filtered out there is nothing to select.
        controller.model.filter = "b"
        #expect(!controller.validateMenuItem(item(.selectTagged)))
    }

    /// Invert Selection swaps exactly the entries the grid is showing,
    /// folders included, and leaves the ones it isn't showing alone.
    @Test func invertSelectionSwapsWhatTheGridIsShowing() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        try t.folder("Sub")
        try t.file("p1.jpg"); let p2 = try t.file("p2.jpg"); try t.file("p3.jpg")
        let controller = makeController()
        defer { controller.window?.close() }
        controller.open(folder: t.url)
        await settle(controller.model)
        controller.model.select(p2)

        controller.invertSelection(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["Sub", "p1.jpg", "p3.jpg"],
                "a folder the grid shows is part of the rest of it, as it is for Select All")
        #expect(controller.model.lead?.lastPathComponent == "Sub", "the old lead is never in the new selection")

        controller.invertSelection(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["p2.jpg"])
        #expect(controller.model.lead?.lastPathComponent == "p2.jpg")

        // The filter hides the folder, so inverting doesn't reach it.
        controller.model.filter = "p"
        #expect(controller.model.entries.map(\.name) == ["p1.jpg", "p2.jpg", "p3.jpg"])
        controller.model.select(p2)
        controller.invertSelection(nil)
        #expect(controller.model.selectedEntries.map(\.name) == ["p1.jpg", "p3.jpg"])
        #expect(controller.model.selection.count == 2, "Sub is hidden, so it stays out of the selection")

        // Everything shown selected inverts to nothing selected.
        controller.model.selectAll()
        controller.invertSelection(nil)
        #expect(controller.model.selection.isEmpty && controller.model.lead == nil)
    }

    /// Neither command is offered when it would change nothing.
    @Test func selectionCommandsAreOffWhenTheyWouldDoNothing() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        let empty = try t.folder("Empty")
        try t.file("a.jpg")
        let controller = makeController()
        defer { controller.window?.close() }
        controller.open(folder: t.url)
        await settle(controller.model)

        // An untagged image is nothing to select, but still something to swap.
        #expect(!controller.validateMenuItem(item(.selectTagged)))
        #expect(controller.validateMenuItem(item(.invertSelection)))

        controller.model.navigate(to: empty)
        await settle(controller.model)
        #expect(controller.model.entries.isEmpty)
        #expect(!controller.validateMenuItem(item(.selectTagged)))
        #expect(!controller.validateMenuItem(item(.invertSelection)))
    }

    /// AppKit offers ⇧⌘I to the menu bar before the search field and the
    /// inline rename editor, so `canPerformSelection` turns both commands
    /// off while either has the keyboard and the key press reaches the text.
    ///
    /// The press is handed to `canPerformSelection` rather than left for it
    /// to find: the only way to fill `NSApp.currentEvent` is to dequeue a
    /// posted event, and doing that in this process ends the test run. With
    /// no press to answer for, which is how a click on the item arrives, the
    /// same call says yes, so the menu item is still there to be clicked.
    @Test func theSearchFieldAndTheRenameEditorKeepTheirKeys() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        try t.file("a.jpg"); try t.file("b.jpg")
        let controller = makeController()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        controller.open(folder: t.url)
        await settle(controller.model)
        await tag(["a.jpg"], in: controller)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "i", charactersIgnoringModifiers: "i",
                                                isARepeat: false, keyCode: 34))

        // With the grid on the keyboard, ⇧⌘I is the command's.
        window.makeFirstResponder(controller.grid.collectionView)
        #expect(controller.canPerformSelection(.selectTagged, event: key) == true)
        #expect(controller.canPerformSelection(.invertSelection, event: key) == true)

        // The toolbar's search field has it while a filter is being typed.
        let search = try #require(window.toolbar?.items
            .first { $0.itemIdentifier == .browserSearch } as? NSSearchToolbarItem)
        #expect(window.makeFirstResponder(search.searchField))
        #expect(window.firstResponder is NSText)
        #expect(controller.canPerformSelection(.selectTagged, event: key) == false)
        #expect(controller.canPerformSelection(.invertSelection, event: key) == false)
        // The same items, chosen with the mouse, still work: no key press is
        // in flight then, which is what a nil event stands for.
        #expect(controller.validateMenuItem(item(.selectTagged)))
        #expect(controller.validateMenuItem(item(.invertSelection)))

        // The inline rename editor has the keyboard the same way.
        window.makeFirstResponder(controller.grid.collectionView)
        controller.model.select(try #require(controller.model.entries.first).url)
        controller.renameItem(nil)
        let editor = try #require(controller.grid.renameEditor)
        #expect(window.firstResponder is NSText)
        #expect(controller.canPerformSelection(.selectTagged, event: key) == false)
        #expect(controller.canPerformSelection(.invertSelection, event: key) == false)

        // The editor gone, the grid has the key back and so do the commands.
        editor.cancel()
        window.makeFirstResponder(controller.grid.collectionView)
        #expect(controller.canPerformSelection(.selectTagged, event: key) == true)
        #expect(controller.canPerformSelection(.invertSelection, event: key) == true)
        #expect(controller.validateMenuItem(item(.invertSelection)))
    }
}
