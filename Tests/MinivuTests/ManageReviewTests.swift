import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// Transfers that must never lose a file: a folder into itself, a file onto
/// itself under another spelling of its path, Replace of an item that holds
/// the source, and Replace itself (which puts the old item in the Trash).
@MainActor @Suite(.serialized) struct ManageTransferSafetyTests {
    let answerReplace: FileTransfer.ConflictResolver = { _, _ in .init(policy: .replace, applyToAll: true) }

    /// Move To or Copy To the folder the files are already in.
    @Test func replaceOntoItselfKeepsTheFile() async throws {
        let t = try ScratchFolder()
        let photo = try t.file("photo.jpg", bytes: 7)
        for isMove in [true, false] {
            var asked = 0
            let outcome = await FileTransfer.run(.init(files: [photo], destination: t.url, isMove: isMove), window: nil) {
                _, _ in
                asked += 1
                return .init(policy: .replace, applyToAll: true)
            }
            #expect(asked == 0, "no clash to ask about: it is the same file")
            #expect(outcome.transfers.isEmpty && outcome.failed.isEmpty)
            let size = try FileManager.default.attributesOfItem(atPath: photo.path)[.size] as? Int
            #expect(size == 7)
        }
    }

    /// The same folder reached through a symbolic link.
    @Test func replaceThroughSymlinkKeepsTheFile() async throws {
        let t = try ScratchFolder()
        let real = try t.folder("Real")
        let photo = try t.file("photo.jpg", bytes: 7, in: real)
        let link = t.url.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let outcome = await FileTransfer.run(.init(files: [photo], destination: link, isMove: true), window: nil,
                                             resolver: answerReplace)
        #expect(outcome.transfers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: photo.path))
    }

    /// A folder into itself or a folder inside it fails and leaves it be.
    @Test func folderIntoItselfFails() async throws {
        let t = try ScratchFolder()
        let trip = try t.folder("Trip")
        let inner = try t.folder("Inner", in: trip)
        try t.file("a.jpg", in: trip)
        for isMove in [true, false] {
            let outcome = await FileTransfer.run(.init(files: [trip], destination: inner, isMove: isMove), window: nil,
                                                 resolver: answerReplace)
            #expect(outcome.transfers.isEmpty)
            #expect(outcome.failed.map(\.url.lastPathComponent) == ["Trip"])
        }
        #expect(FileManager.default.fileExists(atPath: trip.appendingPathComponent("a.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: inner.appendingPathComponent("Trip").path))
    }

    /// Replacing "Picks" with a "Picks" inside it would delete the source.
    @Test func replaceOfAnItemHoldingTheSourceFails() async throws {
        let t = try ScratchFolder()
        let outer = try t.folder("Picks")
        let inner = try t.folder("Picks", in: outer)
        let photo = try t.file("a.jpg", in: inner)
        var asked = 0
        let outcome = await FileTransfer.run(.init(files: [inner], destination: t.url, isMove: true), window: nil) { _, _ in
            asked += 1
            return .init(policy: .replace, applyToAll: true)
        }
        #expect(asked == 0)
        #expect(outcome.transfers.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: photo.path))
    }

    /// Replace puts the old item away (in the Trash; here a stand-in
    /// folder), marks and all, instead of deleting it.
    @Test func replacedItemGoesToTheTrash() async throws {
        let t = try ScratchFolder()
        let source = try t.folder("Source"), destination = try t.folder("Destination"), bin = try t.folder("Bin")
        let incoming = try t.file("p.jpg", bytes: 4, in: source)
        let old = try t.file("p.jpg", bytes: 1, in: destination)
        Catalog.shared.setRating(2, for: [old])
        let outcome = await FileTransfer.run(.init(files: [incoming], destination: destination, isMove: true),
                                             window: nil, resolver: answerReplace,
                                             trash: AppWindowTests.ManageUndoSafetyTests.trash(into: bin))
        #expect(outcome.transfers.map(\.to.lastPathComponent) == ["p.jpg"])
        let trashed = try #require(outcome.trashed.first)
        #expect(trashed.from.lastPathComponent == "p.jpg")
        #expect((try FileManager.default.attributesOfItem(atPath: trashed.to.path)[.size] as? Int) == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: old.path)[.size] as? Int) == 4)
        #expect(Catalog.shared.marks(for: old).rating == 0, "the newcomer doesn't inherit the old file's stars")
        #expect(Catalog.shared.marks(for: trashed.to).rating == 2)
    }
}

extension AppWindowTests {
    /// Undo and Redo of transfers that replaced something, through the window.
    @MainActor @Suite(.serialized) struct ManageUndoSafetyTests {
        let catalog = Catalog.inMemory()

        func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func size(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        }

        /// Undo puts the moved file back and the replaced one where it was;
        /// Redo replaces it again.
        @Test func undoOfReplacingMoveRestoresTheOldFile() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let shown = try t.folder("Shown"), other = try t.folder("Other")
            let incoming = try t.file("p.jpg", bytes: 4, in: shown)
            let old = try t.file("p.jpg", bytes: 1, in: other)
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            controller.open(folder: shown)
            await controller.model.work?.value
            controller.transferConflictResolver = { _, _ in .init(policy: .replace, applyToAll: true) }
            controller.transferTrash = Self.trash(into: try t.folder("Bin"))

            controller.transfer([incoming], to: other, move: true)
            await controller.transferWork?.value
            #expect(size(old) == 4 && !FileManager.default.fileExists(atPath: incoming.path))

            let undo = try #require(controller.window?.undoManager)
            undo.undo()
            await waitUntil { self.size(old) == 1 && FileManager.default.fileExists(atPath: incoming.path) }
            #expect(size(incoming) == 4, "moved back")
            #expect(size(old) == 1, "the replaced file is back from the Trash")

            #expect(undo.canRedo)
            undo.redo()
            await waitUntil { self.size(old) == 4 }
            #expect(size(old) == 4 && !FileManager.default.fileExists(atPath: incoming.path))
        }

        /// Undo of a copy that replaced a file: the copy goes to the Trash and
        /// the old file returns; Redo trashes it again and copies once more.
        @Test func undoOfReplacingCopyRestoresTheOldFile() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let shown = try t.folder("Shown"), other = try t.folder("Other"), bin = try t.folder("Bin")
            let incoming = try t.file("p.jpg", bytes: 4, in: other)
            let old = try t.file("p.jpg", bytes: 1, in: shown)
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            controller.open(folder: shown)
            await controller.model.work?.value
            controller.transferConflictResolver = { _, _ in .init(policy: .replace, applyToAll: true) }
            controller.transferTrash = Self.trash(into: bin)

            controller.transfer([incoming], to: shown, move: false)
            await controller.transferWork?.value
            #expect(size(old) == 4)
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1, "the old file, trashed")

            let undo = try #require(controller.window?.undoManager)
            #expect(undo.undoActionName == "Copy 1 Item")
            undo.undo()
            await waitUntil { self.size(old) == 1 }
            #expect(size(old) == 1 && size(incoming) == 4)
            let binned = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
            #expect(binned.map { size($0) } == [4], "only the copy is left in the Trash")

            undo.redo()
            await waitUntil { self.size(old) == 4 }
            #expect(size(old) == 4)
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 2)
        }

        /// A stand-in Trash: a folder, each item under a fresh name, marks
        /// carried as the real one carries them.
        nonisolated static func trash(into bin: URL) -> FileTransfer.Trasher {
            { url in
                TransferChecks.trash(url) { item in
                    let place = bin.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
                    try FileManager.default.moveItem(at: item, to: place)
                    return place
                }
            }
        }

        /// Move To the folder the selection is already in does nothing.
        @Test func moveToOwnFolderDoesNothing() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let photo = try t.file("photo.jpg", bytes: 3)
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await controller.model.work?.value
            var asked = false
            controller.transferConflictResolver = { _, _ in
                asked = true
                return .init(policy: .replace, applyToAll: true)
            }
            controller.transfer([photo], to: t.url, move: true)
            await controller.transferWork?.value
            #expect(!asked && size(photo) == 3)
            #expect(controller.window?.undoManager?.canUndo != true)
        }
    }
}

@Suite struct ManageRenameOrderTests {
    @Test func renamedNameTakesThePlace() {
        #expect(MarksOrdering.renamed(["c", "a", "b"], from: "a", to: "z") == ["c", "z", "b"])
        #expect(MarksOrdering.renamed(["c", "a", "z"], from: "a", to: "z") == ["c", "z"], "a stale z goes")
        #expect(MarksOrdering.renamed(["c", "b"], from: "a", to: "z") == nil)
        #expect(MarksOrdering.renamed(["a"], from: "a", to: "a") == nil)
    }
}

extension AppWindowTests {
    @MainActor @Suite(.serialized) struct ManageReviewWindowTests {
        let catalog = Catalog.inMemory()

        func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        }

        /// A file renamed in Custom Order stays where the user put it.
        @Test func renameKeepsCustomOrderPlace() async throws {
            _ = NSApplication.shared
            let savedOrder = Preferences.shared.sortOrder
            defer { Preferences.shared.sortOrder = savedOrder }
            Preferences.shared.sortOrder = FileSortOrder(key: .custom, ascending: true)
            let t = try ScratchFolder()
            let a = try t.file("a.jpg"); try t.file("b.jpg"); try t.file("c.jpg")
            catalog.setCustomOrder(["c.jpg", "a.jpg", "b.jpg"], in: t.url)
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await controller.model.work?.value
            #expect(controller.model.entries.map(\.name) == ["c.jpg", "a.jpg", "b.jpg"])

            controller.performRename(a, to: "z.jpg")
            await waitUntil { controller.model.entries.map(\.name) == ["c.jpg", "z.jpg", "b.jpg"] }
            #expect(controller.model.entries.map(\.name) == ["c.jpg", "z.jpg", "b.jpg"])
            #expect(catalog.customOrder(in: t.url) == ["c.jpg", "z.jpg", "b.jpg"])
        }

        /// The label under the rename field steps aside (a Dark Mode field is
        /// translucent) and comes back when editing ends.
        @Test func renameHidesTheLabelBeneath() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try t.file("a.jpg"); try t.file("b.jpg")
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await controller.model.work?.value
            controller.model.select(a)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let view = controller.grid.collectionView
            view.layoutSubtreeIfNeeded()
            func cell(_ item: Int) throws -> ThumbnailCellView {
                try #require(view.item(at: IndexPath(item: item, section: 0)) as? ThumbnailCell).thumbnailView
            }
            controller.renameItem(nil)
            let editor = try #require(controller.grid.renameEditor)
            #expect(try cell(0).nameField.isHidden && !cell(1).nameField.isHidden)
            // A reload while editing (the folder changed on disk) keeps it so.
            view.reloadData()
            view.layoutSubtreeIfNeeded()
            #expect(try cell(0).nameField.isHidden && !cell(1).nameField.isHidden)
            editor.cancel()
            #expect(try !cell(0).nameField.isHidden)
        }

        func press(_ characters: String, in viewer: ViewerWindowController) throws {
            let window = try #require(viewer.window)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            window.contentView?.keyDown(with: event)
        }

        /// 3 rates and T T tags then untags; the HUD never reads back a
        /// half-written state, and ends with what the keys set.
        @Test func viewerKeysRateAndTag() async throws {
            _ = NSApplication.shared
            let folder = try ScratchFolder()
            let url = try folder.jpeg("a.jpg", width: 60, height: 40)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)

            try press("3", in: viewer)
            #expect(viewer.hud.stars.rating == 3, "shown at once")
            try press("t", in: viewer)
            #expect(!viewer.hud.tagBadge.isHidden)
            try press("t", in: viewer)
            #expect(viewer.hud.tagBadge.isHidden)
            // Let every write land and its notice arrive.
            for _ in 0..<3 {
                await withCheckedContinuation { done in BrowserModel.catalogWrites.async { done.resume() } }
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            }
            #expect(Catalog.shared.marks(for: url) == Catalog.Marks(rating: 3, isTagged: false))
            #expect(viewer.hud.stars.rating == 3 && viewer.hud.tagBadge.isHidden)

            // A change made elsewhere (the browser) still shows.
            Catalog.shared.setTagged(true, for: [url])
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            #expect(!viewer.hud.tagBadge.isHidden)
        }
    }
}
