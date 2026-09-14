import Testing
import AppKit
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// Sending a file away loses no work: the viewer asks about unsaved edits
    /// before trashing them, and a save still in the write queue lands
    /// before the file goes to the Trash, is renamed or is moved (else its
    /// atomic replace would put the file back at the old path).
    @MainActor @Suite(.serialized) struct TrashSafetyTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Closes whatever viewer is open without asking about edits.
        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// Takes the place of the user's Trash: a folder in the scratch folder.
        @MainActor final class Bin {
            let folder: URL
            private(set) var names: [String] = []
            private let saved = FileWriteQueue.shared.putInTrash

            init(in scratch: ScratchFolder) throws {
                folder = try scratch.folder("Trash")
                FileWriteQueue.shared.putInTrash = { [unowned self] urls in
                    var moved: [URL: URL] = [:]
                    for url in urls {
                        let place = folder.appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.moveItem(at: url, to: place)
                        moved[url] = place
                        names.append(url.lastPathComponent)
                    }
                    return moved
                }
            }

            func restore() { FileWriteQueue.shared.putInTrash = saved }
            func contents(_ name: String) -> String? {
                (try? Data(contentsOf: folder.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
            }
        }

        /// A save that takes a while, replacing the file atomically as Save does.
        func slowSave(_ url: URL, _ text: String) -> Task<FileWriteQueue.Outcome<Void>, Error> {
            FileWriteQueue.shared.enqueue(replacing: [url]) {
                try await Task.sleep(for: .milliseconds(300))
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        }

        func contents(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        @Test func viewerTrashAsksAboutUnsavedEdits() async throws {
            let scratch = try ScratchFolder()
            let bin = try Bin(in: scratch)
            defer { bin.restore() }
            let list = try [scratch.jpeg("a.jpg", width: 600, height: 400), scratch.jpeg("b.jpg", width: 600, height: 400)]
                .map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }

            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            var asked: [String] = []
            var answer = UnsavedEditsChoice.cancel
            ViewerWindowController.askAboutUnsavedEdits = { name, _, reply in
                asked.append(name)
                reply(answer)
            }

            // Committed edits: Cancel keeps the image and its edits.
            viewer.rotateRight(nil)
            let session = try #require(viewer.editSession)
            viewer.moveToTrash(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(asked == ["a.jpg"])
            #expect(bin.names.isEmpty && exists(list[0].url))
            #expect(viewer.editSession === session && session.document.isDirty)

            // A tool's unapplied changes count too.
            viewer.undoEdit()
            viewer.adjustLighting(nil)
            guard case .adjustment(let lighting)? = viewer.activeTool else {
                Issue.record("Lighting didn't open")
                return
            }
            lighting.setValue(0.4, section: 0, slider: 0)
            #expect(viewer.hasUnsavedEdits)
            viewer.moveToTrash(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(asked == ["a.jpg", "a.jpg"])
            #expect(bin.names.isEmpty && viewer.activeTool != nil)

            // Don't Save trashes it and moves on.
            answer = .discard
            viewer.moveToTrash(nil)
            await waitUntil { viewer.window?.title == "b.jpg" }
            #expect(asked.count == 3 && bin.names == ["a.jpg"])
            #expect(viewer.editSession == nil && !exists(list[0].url))
        }

        /// Only the viewer's edited image is asked about when the browser
        /// trashes a selection.
        @Test func browserTrashAsksAboutTheViewersEditedImage() async throws {
            let scratch = try ScratchFolder()
            let bin = try Bin(in: scratch)
            defer { bin.restore() }
            let a = try scratch.jpeg("a.jpg", width: 600, height: 400)
            try scratch.file("b.jpg"); try scratch.file("c.jpg")
            let entry = try #require(FolderEntry(url: a))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)

            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            var asked: [String] = []
            var answer = UnsavedEditsChoice.cancel
            ViewerWindowController.askAboutUnsavedEdits = { name, _, reply in
                asked.append(name)
                reply(answer)
            }

            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: scratch.url)
            await controller.model.work?.value
            let entries = controller.model.entries.filter { !$0.isDirectory }.map(\.url)
            #expect(entries.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "c.jpg"])

            controller.model.setSelection([entries[1]], lead: entries[1])
            controller.moveToTrash(nil)
            await waitUntil { bin.names == ["b.jpg"] }
            #expect(asked.isEmpty && bin.names == ["b.jpg"])

            controller.model.setSelection([entries[0], entries[2]], lead: entries[0])
            controller.moveToTrash(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(asked == ["a.jpg"] && bin.names == ["b.jpg"])
            #expect(viewer.editSession?.document.isDirty == true)

            answer = .discard
            controller.model.setSelection([entries[0], entries[2]], lead: entries[0])
            controller.moveToTrash(nil)
            await waitUntil { bin.names.count == 3 }
            #expect(asked == ["a.jpg", "a.jpg"] && Set(bin.names) == ["a.jpg", "b.jpg", "c.jpg"])
            #expect(viewer.editSession == nil)
        }

        /// ⌘S then at once ⌘⌫ (or a rename, or a move): the save lands, then
        /// the file goes, and nothing comes back at the old path.
        @Test func queuedSavesLandBeforeTheFileMoves() async throws {
            let scratch = try ScratchFolder()
            let bin = try Bin(in: scratch)
            defer { bin.restore() }
            let sub = try scratch.folder("Sub")
            let a = try scratch.jpeg("a.jpg", width: 60, height: 40)
            let b = try scratch.jpeg("b.jpg", width: 60, height: 40)
            let c = try scratch.file("c.jpg"), d = try scratch.file("d.jpg"), f = try scratch.file("f.jpg")

            // The viewer's Move to Trash.
            let list = try [a, b].map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            let viewerSave = slowSave(a, "viewer save")
            viewer.moveToTrash(nil)
            _ = try await viewerSave.value
            await waitUntil { bin.names == ["a.jpg"] }
            #expect(!exists(a) && bin.contents("a.jpg") == "viewer save")
            closeViewer()

            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: scratch.url)
            await controller.model.work?.value

            // The browser's Move to Trash.
            controller.model.select(c)
            let browserSave = slowSave(c, "browser save")
            controller.moveToTrash(nil)
            _ = try await browserSave.value
            await waitUntil { bin.names.contains("c.jpg") }
            #expect(!exists(c) && bin.contents("c.jpg") == "browser save")

            // Rename.
            let e = scratch.url.appendingPathComponent("e.jpg")
            let renameSave = slowSave(d, "before rename")
            controller.performRename(d, to: "e.jpg")
            _ = try await renameSave.value
            await waitUntil { exists(e) }
            #expect(!exists(d) && contents(e) == "before rename")

            // Move.
            let moveSave = slowSave(f, "before move")
            controller.transfer([f], to: sub, move: true)
            await controller.transferWork?.value
            _ = try await moveSave.value
            #expect(!exists(f) && contents(sub.appendingPathComponent("f.jpg")) == "before move")
            await FileWriteQueue.shared.waitUntilIdle()
        }

        /// A write that names its file only as touched (a comment, a
        /// lossless rotate) is waited for too, and so are writes inside a
        /// folder; writes to other files aren't.
        @Test func waitingCoversTouchedFilesAndFolders() async throws {
            let queue = FileWriteQueue()
            let folder = URL(fileURLWithPath: "/tmp/minivu-wait/Sub")
            let finished = Flag()
            queue.enqueue(touching: [folder.appendingPathComponent("x.jpg")]) {
                try await Task.sleep(for: .milliseconds(150))
                await finished.set()
            }
            await queue.waitForWrites(to: [URL(fileURLWithPath: "/tmp/minivu-wait/Subway.jpg")])
            #expect(await !finished.value)
            await queue.waitForWrites(to: [folder])
            #expect(await finished.value)
            #expect(FileWriteQueue.path("/a/b/c.jpg", isIn: [URL(fileURLWithPath: "/a")]))
            #expect(!FileWriteQueue.path("/a/bc.jpg", isIn: [URL(fileURLWithPath: "/a/b")]))
        }

        actor Flag {
            var value = false
            func set() { value = true }
        }
    }
}
