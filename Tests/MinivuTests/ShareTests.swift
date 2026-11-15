import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// Records what would be offered to the share services instead of showing
/// the share sheet.
@MainActor final class FakeSharePresenter: SharePresenting {
    private(set) var shared: [(urls: [URL], view: NSView)] = []
    /// The questions asked before sharing, in order.
    var asked: [ExternalEditorOpener.Question] = []

    func share(_ urls: [URL], relativeTo rect: NSRect, of view: NSView) {
        shared.append((urls, view))
    }
}

extension AppWindowTests {
    /// File > Share… and the browser's Share button. No test reaches a real
    /// share service: `FileSharing.shared` gets a fake presenter and its
    /// question is answered by the test.
    @MainActor @Suite(.serialized) struct ShareTests {
        let catalog = Catalog.inMemory()

        init() { _ = NSApplication.shared }

        /// Runs `body` with a fake share sheet and an answer for the
        /// unsaved-edits question, putting the real ones back afterwards.
        func withFakeSharing(answer: Bool = true,
                             _ body: (FakeSharePresenter) async throws -> Void) async rethrows {
            let sharing = FileSharing.shared
            let presenter = sharing.presenter, confirm = sharing.confirm
            defer {
                sharing.presenter = presenter
                sharing.confirm = confirm
            }
            let fake = FakeSharePresenter()
            sharing.presenter = fake
            sharing.confirm = { [fake] question, _, reply in
                fake.asked.append(question)
                reply(answer)
            }
            try await body(fake)
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

        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// One main-queue turn, for work the code puts there.
        func nextTurn() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        // MARK: - Browser

        /// The selected images go to the share sheet, folders left out; with
        /// nothing selected there is nothing to share and the command says so.
        @Test func browserSharesTheSelectedImages() async throws {
            try await withFakeSharing { fake in
                let t = try ScratchFolder()
                try t.file("a.jpg"); try t.file("b.jpg"); try t.folder("Sub")
                let controller = makeController()
                defer { controller.window?.close() }
                controller.open(folder: t.url)
                await settle(controller)

                #expect(controller.canPerformTools(.shareFiles) == false)
                controller.shareFiles(nil)
                #expect(fake.shared.isEmpty)

                controller.model.selectAll()
                #expect(controller.canPerformTools(.shareFiles) == true)
                let item = NSMenuItem(title: "Share…", action: .shareFiles, keyEquivalent: "")
                #expect(controller.validateMenuItem(item), "through the window's own chain")
                controller.shareFiles(item)
                #expect(fake.shared.count == 1)
                #expect(fake.shared.first?.urls.map(\.lastPathComponent).sorted() == ["a.jpg", "b.jpg"])
                #expect(fake.shared.first?.view === controller.grid.collectionView)
                #expect(fake.asked.isEmpty, "the browser has no edits to warn about")
            }
        }

        /// The toolbar's Share button offers the same files as the menu,
        /// asked for when it is clicked.
        @Test func toolbarShareButtonOffersTheSameFiles() async throws {
            let t = try ScratchFolder()
            try t.file("a.jpg"); try t.file("b.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            let toolbar = try #require(controller.window?.toolbar)
            let delegate = controller.toolbarController
            #expect(delegate.toolbarDefaultItemIdentifiers(toolbar).contains(.browserShare))
            let button = try #require(delegate.toolbar(toolbar, itemForItemIdentifier: .browserShare,
                                                       willBeInsertedIntoToolbar: false)
                as? NSSharingServicePickerToolbarItem)
            #expect(!button.label.isEmpty && button.image?.accessibilityDescription == "Share")

            #expect(controller.toolbarController.items(for: button).isEmpty)
            controller.model.selectAll()
            let offered = controller.toolbarController.items(for: button).compactMap { $0 as? URL }
            #expect(offered.map(\.lastPathComponent).sorted() == ["a.jpg", "b.jpg"])
        }

        // MARK: - Viewer

        /// The image shown is shared straight away when it has no edits.
        @Test func viewerSharesTheImageShown() async throws {
            try await withFakeSharing { fake in
                let t = try ScratchFolder()
                let photo = try t.jpeg("a.jpg", width: 60, height: 40)
                ViewerWindowController.show(images: [try #require(FolderEntry(url: photo))], index: 0,
                                            fullScreen: false) { _ in }
                defer { closeViewer() }
                let viewer = try #require(ViewerWindowController.current)
                let item = NSMenuItem(title: "Share…", action: .shareFiles, keyEquivalent: "")
                #expect(viewer.validateMenuItem(item))

                viewer.shareFiles(item)
                #expect(fake.asked.isEmpty)
                #expect(fake.shared.count == 1)
                #expect(fake.shared.first?.urls == [photo])
                #expect(fake.shared.first?.view === viewer.canvasView)
            }
        }

        /// With unsaved edits the file as last saved is what any service
        /// gets, so the user is told first, and No shares nothing.
        @Test(arguments: [false, true])
        func viewerWithUnsavedEditsSaysTheSavedFileIsShared(answer: Bool) async throws {
            try await withFakeSharing(answer: answer) { fake in
                let t = try ScratchFolder()
                let photo = try t.jpeg("a.jpg", width: 60, height: 40)
                ViewerWindowController.show(images: [try #require(FolderEntry(url: photo))], index: 0,
                                            fullScreen: false) { _ in }
                defer { closeViewer() }
                let viewer = try #require(ViewerWindowController.current)
                await TestTiming.waitUntil { viewer.canEditCurrent }
                viewer.rotateRight(nil)
                #expect(viewer.hasUnsavedEdits)

                viewer.shareFiles(nil)
                #expect(fake.asked == [FileSharing.unsavedEditsQuestion(name: "a.jpg")])
                #expect(fake.asked.first?.confirmTitle == "Share Saved File")
                await nextTurn()
                if answer {
                    #expect(fake.shared.map(\.urls) == [[photo]], "the file itself, as saved")
                } else {
                    #expect(fake.shared.isEmpty)
                }
            }
        }
    }
}
