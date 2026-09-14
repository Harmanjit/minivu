import Testing
import AppKit
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// Ratings, renaming, new folders and transfers through the assembled
    /// browser window (never shown), with a catalog of its own.
    @MainActor @Suite(.serialized) struct ManageWindowTests {
        let catalog = Catalog.inMemory()

        func makeController() -> BrowserWindowController {
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            return controller
        }

        func settle(_ controller: BrowserWindowController) async {
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func key(_ characters: String, code: UInt16, at time: TimeInterval) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return item
        }

        func cell(_ controller: BrowserWindowController, _ name: String) -> ThumbnailCell? {
            let grid = controller.grid
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            grid.collectionView.layoutSubtreeIfNeeded()
            guard let index = controller.model.entries.firstIndex(where: { $0.name == name }) else { return nil }
            return grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? ThumbnailCell
        }

        /// 3 and ` in the grid rate and tag the selection; the cell, the menu
        /// checkmarks and the preview's bar follow.
        @Test func gridKeysRateAndTag() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            try t.file("a.jpg"); let b = try t.file("b.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.select(b)

            let grid = controller.grid.collectionView
            grid.keyDown(with: key("3", code: 20, at: 10))
            await settleCatalog(controller.model)
            #expect(catalog.marks(for: b).rating == 3)
            let bCell = try #require(cell(controller, "b.jpg"))
            #expect(bCell.thumbnailView.stars.rating == 3 && !bCell.thumbnailView.stars.isHidden)
            #expect(bCell.thumbnailView.tagBadge.isHidden)
            let three = item(.setRating, tag: 3)
            #expect(controller.validateMenuItem(three) && three.state == .on)
            #expect(controller.preview.marksStars.rating == 3 && !controller.preview.marksBar.isHidden)

            grid.keyDown(with: key("`", code: 50, at: 12))
            await settleCatalog(controller.model)
            #expect(catalog.marks(for: b).isTagged)
            #expect(!bCell.thumbnailView.tagBadge.isHidden)
            let tag = item(.toggleTag)
            #expect(controller.validateMenuItem(tag) && tag.state == .on)

            // Clicking the fourth star rates just that cell.
            bCell.onRate?(b, 4)
            await settleCatalog(controller.model)
            #expect(bCell.thumbnailView.stars.rating == 4)

            // A letter still types a name; a digit right after continues it.
            grid.keyDown(with: key("a", code: 0, at: 20))
            grid.keyDown(with: key("1", code: 18, at: 20.2))
            await settleCatalog(controller.model)
            #expect(controller.model.lead?.lastPathComponent == "a.jpg", "typed a; no file starts with a1")
            #expect(catalog.marks(for: t.url.appendingPathComponent("a.jpg")).rating == 0)
        }

        /// F2's editor selects the name without its extension; Return renames
        /// the file off the main thread and selects it; Undo puts it back.
        @Test func renameInPlaceWithUndo() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let photo = try t.file("photo.jpg"); try t.file("other.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.select(photo)
            #expect(controller.validateMenuItem(item(.renameItem)))

            controller.renameItem(nil)
            let editor = try #require(controller.grid.renameEditor)
            #expect(editor.field.superview === controller.grid.collectionView)
            #expect(editor.field.currentEditor()?.selectedRange == NSRange(location: 0, length: 5))
            #expect(!controller.validateMenuItem(item(.renameItem)), "one editor at a time")

            // A name that's taken is refused before anything happens.
            editor.field.stringValue = "other.jpg"
            editor.commit()
            #expect(controller.grid.renameEditor == nil)
            #expect(FileManager.default.fileExists(atPath: photo.path))
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            await waitUntil { controller.grid.renameEditor != nil }
            #expect(controller.grid.renameEditor?.field.stringValue == "other.jpg", "back to correct")

            let again = try #require(controller.grid.renameEditor)
            again.field.stringValue = "beach.jpg"
            again.commit()
            let beach = t.url.appendingPathComponent("beach.jpg")
            await waitUntil { controller.model.lead?.lastPathComponent == "beach.jpg" }
            #expect(FileManager.default.fileExists(atPath: beach.path))
            #expect(!FileManager.default.fileExists(atPath: photo.path))

            let undo = try #require(controller.window?.undoManager)
            #expect(undo.undoActionName == "Rename")
            undo.undo()
            await waitUntil { FileManager.default.fileExists(atPath: photo.path) }
            #expect(FileManager.default.fileExists(atPath: photo.path))
            #expect(undo.canRedo)
            undo.redo()
            await waitUntil { FileManager.default.fileExists(atPath: beach.path) }
            #expect(FileManager.default.fileExists(atPath: beach.path))
        }

        @Test func escapeCancelsRename() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let photo = try t.file("photo.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.select(photo)
            controller.renameItem(nil)
            let editor = try #require(controller.grid.renameEditor)
            editor.field.stringValue = "changed.jpg"
            let textView = try #require(editor.field.currentEditor() as? NSTextView)
            #expect(editor.control(editor.field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(controller.grid.renameEditor == nil && editor.field.superview == nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(FileManager.default.fileExists(atPath: photo.path))
        }

        /// ⇧⌘N makes "untitled folder" and starts editing its whole name.
        @Test func newFolderStartsRename() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            try t.file("a.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            #expect(controller.validateMenuItem(item(.newFolder)))

            controller.newFolder(nil)
            await waitUntil { controller.grid.renameEditor != nil }
            let editor = try #require(controller.grid.renameEditor)
            #expect(editor.url.lastPathComponent == "untitled folder")
            #expect(editor.field.currentEditor()?.selectedRange == NSRange(location: 0, length: 15))
            #expect(controller.model.lead?.lastPathComponent == "untitled folder")
            editor.cancel()
        }

        /// A move out of the folder selects the next photo; Undo brings it
        /// back, Redo moves it again. The undo title counts the items.
        @Test func moveWithUndoAndRedo() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let sub = try t.folder("Sub")
            let a = try t.file("a.jpg"); try t.file("b.jpg")
            catalog.setRating(4, for: [a])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.select(a)

            controller.transfer([a], to: sub, move: true)
            await controller.transferWork?.value
            await settle(controller)
            let moved = sub.appendingPathComponent("a.jpg")
            #expect(FileManager.default.fileExists(atPath: moved.path))
            #expect(controller.model.entries.map(\.name) == ["Sub", "b.jpg"])
            #expect(controller.model.lead?.lastPathComponent == "b.jpg")

            let undo = try #require(controller.window?.undoManager)
            #expect(undo.undoActionName == "Move 1 Item")
            undo.undo()
            await waitUntil { controller.model.entries.contains { $0.name == "a.jpg" } }
            #expect(FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: moved.path))
            #expect(controller.model.lead?.lastPathComponent == "a.jpg", "put back and selected")
            undo.redo()
            await waitUntil { FileManager.default.fileExists(atPath: moved.path) }
            #expect(!FileManager.default.fileExists(atPath: a.path))
        }

        /// Copies from elsewhere arrive selected; Undo sends them to the Trash.
        @Test func copyInSelectsArrivals() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let shown = try t.folder("Shown"), other = try t.folder("Other")
            try t.file("a.jpg", in: shown)
            let incoming = try ["x.jpg", "y.jpg"].map { try t.file($0, in: other) }
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: shown)
            await settle(controller)

            controller.transfer(incoming, to: shown, move: false)
            await controller.transferWork?.value
            await settle(controller)
            #expect(Set(controller.model.selection.map(\.lastPathComponent)) == ["x.jpg", "y.jpg"])
            #expect(controller.window?.undoManager?.undoActionName == "Copy 2 Items")
            #expect(incoming.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

        /// The filter commands check themselves and fill the toolbar symbol;
        /// the toolbar menu lists the folder's Finder tags.
        @Test func filterCommandsAndToolbar() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try t.file("a.jpg"); try t.file("b.jpg")
            try FinderTags.setTags(["Green"], for: a)
            catalog.setTagged(true, for: [a])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            await controller.model.finderTagWork?.value

            let showAll = item(.filterByRating, tag: 0), three = item(.filterByRating, tag: 3)
            let tagged = item(.toggleTaggedFilter)
            _ = controller.validateMenuItem(showAll)
            #expect(showAll.state == .on)

            controller.toggleTaggedFilter(nil)
            #expect(controller.model.entries.map(\.name) == ["a.jpg"])
            let statusTexts: [String] = controller.grid.statusBar.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(statusTexts.contains("1 of 2 shown"))
            _ = controller.validateMenuItem(tagged)
            _ = controller.validateMenuItem(showAll)
            #expect(tagged.state == .on && showAll.state == .off)

            controller.filterByRating(three)
            _ = controller.validateMenuItem(three)
            #expect(three.state == .on)
            #expect(controller.model.entries.isEmpty)

            let toolbarItem = try #require(controller.window?.toolbar?.items
                .first { $0.itemIdentifier == .browserFilter } as? NSMenuToolbarItem)
            let titles = toolbarItem.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            #expect(titles.contains("Tagged Only") && titles.last == "Green")
            controller.filterByRating(showAll)
            #expect(!controller.model.marksFilter.isActive)
            #expect(controller.model.entries.count == 2)
        }
    }
}

/// A drag as AppKit describes it to a drop target, for driving the grid's
/// and sidebar's drop methods without a real mouse.
@MainActor final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(files: [URL], mask: NSDragOperation = [.copy, .move, .generic], sequence: Int = Int.random(in: 1...1_000_000)) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("minivu-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = mask
        draggingSequenceNumber = sequence
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

extension AppWindowTests.ManageWindowTests {
    /// The grid's drop methods: into a folder cell, into the grid's folder
    /// from elsewhere (Option copies), nothing for files already here, and a
    /// reorder with a gap in Custom Order.
    @Test func gridDrops() async throws {
        _ = NSApplication.shared
        let savedOrder = Preferences.shared.sortOrder
        defer { Preferences.shared.sortOrder = savedOrder }
        Preferences.shared.sortOrder = FileSortOrder()
        let t = try ScratchFolder()
        let shown = try t.folder("Shown"), elsewhere = try t.folder("Elsewhere")
        let sub = try t.folder("Sub", in: shown)
        let a = try t.file("a.jpg", in: shown), b = try t.file("b.jpg", in: shown)
        let outside = try t.file("x.jpg", in: elsewhere)
        let controller = makeController()
        defer { controller.window?.close() }
        controller.open(folder: shown)
        await settle(controller)
        let grid = controller.grid
        let view = grid.collectionView
        var dropped: [([String], String, Bool)] = []
        grid.onDropFiles = { files, destination, move in
            dropped.append((files.map(\.lastPathComponent), destination.lastPathComponent, move))
        }

        func validate(_ drag: FakeDrag, item: Int, _ operation: NSCollectionView.DropOperation)
            -> (NSDragOperation, Int, NSCollectionView.DropOperation) {
            var path = IndexPath(item: item, section: 0) as NSIndexPath
            var op = operation
            let result = grid.collectionView(view, validateDrop: drag, proposedIndexPath: &path, dropOperation: &op)
            return (result, path.item, op)
        }

        // Onto the Sub cell: same volume, so a move.
        let intoSub = FakeDrag(files: [a])
        #expect(validate(intoSub, item: 0, .on).0 == .move)
        #expect(grid.dropHighlight.isHidden, "a folder cell lights up, not the grid")
        #expect(grid.collectionView(view, acceptDrop: intoSub, indexPath: IndexPath(item: 0, section: 0), dropOperation: .on))
        #expect(dropped.last! == (["a.jpg"], "Sub", true))

        // From elsewhere with Option held: a copy into the grid's folder,
        // retargeted onto an image so no gap promises a place.
        let copyIn = FakeDrag(files: [outside], mask: .copy)
        let (operation, item, dropOperation) = validate(copyIn, item: 0, .before)
        #expect(operation == .copy && item == 1 && dropOperation == .on)
        #expect(!grid.dropHighlight.isHidden)
        #expect(grid.collectionView(view, acceptDrop: copyIn, indexPath: IndexPath(item: item, section: 0),
                                    dropOperation: dropOperation))
        #expect(dropped.last! == (["x.jpg"], "Shown", false))
        #expect(grid.dropHighlight.isHidden)

        // Files already here, sorted by name: nothing.
        #expect(validate(FakeDrag(files: [b]), item: 1, .before).0 == [])

        // In Custom Order the same drop reorders, before the first image at the earliest.
        Preferences.shared.sortOrder = FileSortOrder(key: .custom, ascending: true)
        await settle(controller)
        let reorder = FakeDrag(files: [b])
        let (reorderOperation, reorderItem, reorderDrop) = validate(reorder, item: 0, .before)
        #expect(reorderOperation == .move && reorderItem == 1 && reorderDrop == .before)
        #expect(grid.collectionView(view, acceptDrop: reorder, indexPath: IndexPath(item: 1, section: 0), dropOperation: .before))
        await settleCatalog(controller.model)
        #expect(controller.model.entries.map(\.name) == ["Sub", "b.jpg", "a.jpg"])
        #expect(catalog.customOrder(in: shown) == ["b.jpg", "a.jpg"])
        _ = sub
    }
}

extension AppWindowTests.ManageWindowTests {
    /// A sidebar row takes files dropped on it, never a gap between rows, and
    /// refuses files already in that folder.
    @Test func sidebarDrops() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        let pictures = try t.folder("Pictures"), trip = try t.folder("Trip")
        let photo = try t.file("p.jpg", in: pictures)
        let sidebar = SidebarViewController(picturesFolder: pictures, favoriteFolders: { [trip] })
        _ = sidebar.view
        var dropped: [(String, Bool)] = []
        sidebar.onDropFiles = { files, folder, move in dropped.append((folder.lastPathComponent, move)) }
        let outline = sidebar.outlineView
        let rows = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }
        let tripRow = try #require(rows.first { $0.title == "Trip" })
        let picturesRow = try #require(rows.first { $0.title == "Pictures" })

        let drag = FakeDrag(files: [photo])
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: tripRow, proposedChildIndex: 0) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: tripRow, childIndex: NSOutlineViewDropOnItemIndex))
        #expect(dropped.count == 1 && dropped[0] == ("Trip", true))
        #expect(sidebar.outlineView(outline, validateDrop: FakeDrag(files: [photo], mask: .copy), proposedItem: tripRow,
                                    proposedChildIndex: NSOutlineViewDropOnItemIndex) == .copy)
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: picturesRow,
                                    proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
    }
}
