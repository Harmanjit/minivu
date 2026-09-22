import Testing
import AppKit
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// Copy and Paste outside a text field: the selected files in the
    /// browser, the picture on screen in the viewer.
    ///
    /// Every test here uses a pasteboard of its own, made with
    /// `NSPasteboard(name:)`. `NSPasteboard.general` is the person's own
    /// clipboard, and a test that wrote to it would destroy whatever they
    /// had copied, so nothing in this file so much as names it.
    @MainActor @Suite(.serialized) struct ClipboardTests {
        let catalog = Catalog.inMemory()
        let copyAction = #selector(NSText.copy(_:))
        let pasteAction = #selector(NSText.paste(_:))

        init() { _ = NSApplication.shared }

        /// A pasteboard of this test's own, under a name nothing else uses.
        func scratchboard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("minivu-clipboard-tests-\(UUID().uuidString)"))
        }

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

        func item(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        func size(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        }

        func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(forClasses: [NSURL.self],
                                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        /// Closes whatever viewer is open without asking about edits.
        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        // MARK: - Browser

        @Test func copyingInTheBrowserPutsTheSelectedFilesOnThePasteboardAsFileURLs() async throws {
            let t = try ScratchFolder()
            try t.file("a.jpg"); try t.file("b.jpg")
            let board = scratchboard()
            defer { board.releaseGlobally() }
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)

            // Nothing selected: nothing to copy, and the menu item says so.
            #expect(controller.canPerformClipboard(copyAction, pasteboard: board) == false)
            #expect(!controller.validateMenuItem(item(copyAction)), "through the window's own chain")
            #expect(!controller.copySelection(to: board))
            #expect(fileURLs(on: board).isEmpty)

            controller.model.selectAll()
            #expect(controller.canPerformClipboard(copyAction, pasteboard: board) == true)
            #expect(controller.validateMenuItem(item(copyAction)))
            #expect(controller.copySelection(to: board))
            #expect(fileURLs(on: board).map(\.lastPathComponent).sorted() == ["a.jpg", "b.jpg"])

            // The same kind of object the grid's drag source writes, so a
            // drag out and a copy hand another application the same thing.
            let grid = controller.grid
            let dragged = grid.collectionView(grid.collectionView,
                                              pasteboardWriterForItemAt: IndexPath(item: 0, section: 0))
            #expect(dragged is NSURL)
        }

        /// Pasting a file whose name is taken keeps both, as a drop does:
        /// nothing that was in the folder is touched, and the paste is one
        /// Undo away.
        @Test func pastingBringsAFileInWithoutOverwritingOneOfTheSameName() async throws {
            let t = try ScratchFolder()
            let shown = try t.folder("Shown"), other = try t.folder("Other")
            let here = try t.file("p.jpg", bytes: 1, in: shown)
            let incoming = try t.file("p.jpg", bytes: 4, in: other)
            let board = scratchboard()
            defer { board.releaseGlobally() }
            board.writeObjects([incoming as NSURL])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: shown)
            await settle(controller)
            controller.transferConflictResolver = { _, _ in .init(policy: .keepBoth, applyToAll: true) }

            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == true)
            #expect(controller.pasteFiles(from: board))
            await controller.transferWork?.value

            #expect(size(here) == 1, "the file that was already here is untouched")
            #expect(size(shown.appendingPathComponent("p 2.jpg")) == 4, "the pasted one, under a free name")
            #expect(size(incoming) == 4, "a paste copies: the original stays where it was")
            #expect(controller.window?.undoManager?.undoActionName == "Copy 1 Item")
        }

        /// Nothing worth pasting, so the command is not offered and does
        /// nothing if it is asked for anyway: an empty pasteboard, text, and
        /// a file that is already in this very folder.
        @Test func pastingNothingDoesNothing() async throws {
            let t = try ScratchFolder()
            let here = try t.file("a.jpg", bytes: 3)
            let board = scratchboard()
            defer { board.releaseGlobally() }
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)

            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == false, "empty")
            #expect(!controller.pasteFiles(from: board))

            board.clearContents()
            board.setString("IMG_0001.jpg", forType: .string)
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == false, "a name is not a file")
            #expect(!controller.pasteFiles(from: board))

            board.clearContents()
            board.writeObjects([here as NSURL])
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == false, "already in this folder")
            #expect(!controller.pasteFiles(from: board))

            #expect(controller.transferWork == nil, "nothing was ever handed to a transfer")
            #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["a.jpg"])
            #expect(controller.window?.undoManager?.canUndo != true)
        }

        /// A folder that cannot be written to takes nothing, so Paste is not
        /// offered for it rather than failing halfway through.
        @Test func pasteIsNotOfferedIntoAFolderThatCannotBeWrittenTo() async throws {
            let t = try ScratchFolder()
            let locked = try t.folder("Locked")
            let incoming = try t.file("q.jpg", bytes: 2)
            let board = scratchboard()
            defer { board.releaseGlobally() }
            board.writeObjects([incoming as NSURL])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: locked)
            await settle(controller)
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == true)

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            // Put the permissions back whatever happens, or the scratch
            // folder can't be deleted.
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == false)
        }

        /// ⌘C and ⌘V while the rename editor (or the search field) has the
        /// keyboard belong to the text, not to the files.
        @Test func copyAndPasteBelongToTheTextWhileAFieldHasTheKeyboard() async throws {
            let t = try ScratchFolder()
            let shown = try t.folder("Shown"), other = try t.folder("Other")
            try t.file("p.jpg", in: shown)
            let incoming = try t.file("q.jpg", in: other)
            let board = scratchboard()
            defer { board.releaseGlobally() }
            board.writeObjects([incoming as NSURL])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: shown)
            await settle(controller)
            controller.model.selectAll()
            #expect(controller.canPerformClipboard(copyAction, pasteboard: board) == true)
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == true)

            controller.renameItem(nil)
            let editor = try #require(controller.grid.renameEditor)
            #expect(controller.window?.firstResponder is NSText)
            #expect(controller.canPerformClipboard(copyAction, pasteboard: board) == false)
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == false)

            editor.cancel()
            #expect(controller.canPerformClipboard(copyAction, pasteboard: board) == true)
            #expect(controller.canPerformClipboard(pasteAction, pasteboard: board) == true)
        }

        // MARK: - Viewer

        /// The viewer copies the picture on screen, and once it has been
        /// edited that is the edited picture rather than the file.
        @Test func copyingInTheViewerPutsTheImageOnThePasteboard() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 120, height: 80)
            let list = [try #require(FolderEntry(url: photo))]
            let board = scratchboard()
            defer { board.releaseGlobally() }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)

            // Nothing is decoded yet, so there is no picture to copy.
            #expect(viewer.validateClipboardAction(copyAction) == false)
            #expect(viewer.copyImage(to: board) == nil)
            // The viewer never claims Paste: there is nothing for it to do.
            #expect(viewer.validateClipboardAction(pasteAction) == nil)

            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateClipboardAction(copyAction) == true)
            #expect(viewer.validateMenuItem(item(copyAction)), "through the viewer's own chain")

            try await #require(viewer.copyImage(to: board)).value
            let image = try #require(board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)
            let rep = try #require(image.representations.first)
            #expect(rep.pixelsWide == 120 && rep.pixelsHigh == 80)
            // The picture and nothing else: no file URL goes with it, so
            // there is no second answer to disagree with the image once
            // there are edits the file does not have.
            #expect(fileURLs(on: board).isEmpty)

            // A committed edit the file knows nothing about: the copy
            // follows the screen, so the turned picture is what is copied.
            viewer.rotateRight(nil)
            #expect(viewer.editSession?.document.isDirty == true)
            try await #require(viewer.copyImage(to: board)).value
            let turned = try #require(board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)
            let turnedRep = try #require(turned.representations.first)
            #expect(turnedRep.pixelsWide == 80 && turnedRep.pixelsHigh == 120)
        }

        /// An open tool's unapplied change is on screen and is what Save
        /// would write, so it is what Copy gives: copying the picture from
        /// before the slider moved would be a different picture from the one
        /// the user is looking at, and nothing would say so.
        @Test func copyingInTheViewerFollowsAToolThatIsStillOpen() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 60, height: 40)
            let list = [try #require(FolderEntry(url: photo))]
            let board = scratchboard()
            defer { board.releaseGlobally() }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }

            try await #require(viewer.copyImage(to: board)).value
            let plain = try #require(colour(on: board))

            // What a tool does while its inspector is open: the change is
            // previewed on the document and the canvas draws it.
            viewer.adjustLighting(nil)
            let document = try #require(viewer.editSession?.document)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            document.preview = .grayscale
            try await #require(viewer.copyImage(to: board)).value
            let previewed = try #require(colour(on: board))
            #expect(previewed != plain, "the copy still shows the photo from before the tool was touched")
            #expect(abs(previewed.0 - previewed.1) < 3 && abs(previewed.1 - previewed.2) < 3,
                    "grey, as the canvas is drawing it: \(previewed)")
        }

        /// The first pixel of the image on `board`, as red, green and blue.
        private func colour(on board: NSPasteboard) -> (Int, Int, Int)? {
            guard let image = board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let rep = image.representations.first as? NSBitmapImageRep,
                  let pixel = rep.colorAt(x: 0, y: 0) else { return nil }
            return (Int(pixel.redComponent * 255), Int(pixel.greenComponent * 255), Int(pixel.blueComponent * 255))
        }
    }
}
