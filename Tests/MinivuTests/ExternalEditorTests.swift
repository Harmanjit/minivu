import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// Records what would be opened instead of launching anything.
final class FakeLauncher: ApplicationLaunching {
    var opened: [(urls: [URL], application: URL)] = []
    var error: Error?

    func open(_ urls: [URL], withApplicationAt application: URL, completion: @escaping @MainActor (Error?) -> Void) {
        opened.append((urls, application))
        let error = self.error
        Task { @MainActor in completion(error) }
    }
}

@MainActor @Suite struct ExternalEditorTests {
    /// A store in a defaults domain of its own; `body` gets the domain's
    /// name to read it back.
    func withStore(_ body: (ExternalEditorsStore, String) async throws -> Void) async rethrows {
        let scratch = ScratchDefaults("minivu-editors-tests")
        defer { scratch.remove() }
        try await body(ExternalEditorsStore(defaults: scratch.defaults), scratch.name)
    }

    func editor(_ name: String, _ identifier: String? = nil, path: String? = nil) -> ExternalEditor {
        ExternalEditor(name: name, bundleIdentifier: identifier, path: path ?? "/Applications/\(name).app")
    }

    @Test func storeRoundTripsItsOrderedList() async {
        await withStore { store, suite in
            let defaults = UserDefaults(suiteName: suite)!
            #expect(store.editors.isEmpty)
            #expect(store.add(editor("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x")))
            #expect(store.add(editor("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app")))
            #expect(store.add(editor("Tool", nil, path: "/Applications/Tool.app")))
            // The same application twice is refused, by identifier or by path.
            #expect(!store.add(editor("Preview copy", "com.apple.Preview", path: "/tmp/Preview.app")))
            #expect(!store.add(editor("Tool again", nil, path: "/Applications/Tool.app")))
            store.move(at: 2, by: -2)
            #expect(store.editors.map(\.name) == ["Tool", "Preview", "Pixelmator Pro"])
            store.move(from: IndexSet(integer: 0), to: 3)
            store.remove(at: 0)
            store.move(at: 0, by: -1)   // already first: nothing happens
            store.remove(at: 7)
            #expect(store.editors.map(\.name) == ["Pixelmator Pro", "Tool"])

            let reloaded = ExternalEditorsStore(defaults: defaults)
            #expect(reloaded.editors == store.editors)
            #expect(defaults.data(forKey: ExternalEditorsStore.defaultsKey) != nil)

            // A list kept in memory only never writes.
            let memory = ExternalEditorsStore(defaults: nil)
            memory.add(editor("Preview", "com.apple.Preview"))
            store.detachFromDefaults()
            store.replaceAll(with: [])
            #expect(ExternalEditorsStore(defaults: defaults).editors.map(\.name) == ["Pixelmator Pro", "Tool"])
        }
    }

    @Test func editorsAreMadeFromApplications() throws {
        let preview = try #require(ExternalEditorsStore.editor(forApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                                               makeBookmark: false))
        #expect(preview.name == "Preview" && preview.bundleIdentifier == "com.apple.Preview")
        #expect(preview.bookmark == nil)
        #expect(ExternalEditorsStore.editor(forApplicationAt: URL(fileURLWithPath: "/tmp/photo.jpg")) == nil)
        #expect(ExternalEditorsStore.applicationURL(for: preview)?.url.path == "/System/Applications/Preview.app")
        // Moved: found again by bundle identifier.
        var moved = preview
        moved.path = "/nowhere/Preview.app"
        #expect(ExternalEditorsStore.applicationURL(for: moved) != nil)
        #expect(ExternalEditorsStore.applicationURL(for: editor("Gone", "com.example.gone", path: "/nowhere/Gone.app")) == nil)
    }

    @Test func suggestionsDeclareTheEditorRole() {
        #expect(ExternalEditorSuggestions.declaresImageEditor(nil) == false)
        #expect(ExternalEditorSuggestions.declaresImageEditor(Bundle(path: "/System/Applications/Calculator.app")) == false)
        let found = ExternalEditorSuggestions.find(excluding: ["com.apple.Preview"])
        #expect(!found.contains { $0.bundleIdentifier == "com.apple.Preview" })
        #expect(!found.contains { ($0.bundleIdentifier ?? "").hasPrefix("com.minivu.") })
        #expect(found.count <= 6)
    }

    // MARK: Menu

    @Test func menuItemsHaveTagsTheShortcutAndEditLast() async throws {
        await withStore { store, _ in
            let empty = ExternalEditorsMenu.make(store: store)
            #expect(empty.items.map(\.title) == ["Edit Editor List…"])
            #expect(empty.items.last?.action == .manageExternalEditors)

            store.add(editor("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app"))
            store.add(editor("TextEdit", "com.apple.TextEdit", path: "/System/Applications/TextEdit.app"))
            // Rebuilt as the list changes, without the menu being opened.
            let items = empty.items
            #expect(items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Preview", "TextEdit", "-", "Edit Editor List…"])
            #expect(items[0].action == .openInExternalEditor && items[1].action == .openInExternalEditor)
            #expect(items.prefix(2).map(\.tag) == [0, 1])
            #expect(items[0].keyEquivalent == "e" && items[0].keyEquivalentModifierMask == .command)
            #expect(items[1].keyEquivalent.isEmpty)
            #expect(items[0].image?.size == NSSize(width: 16, height: 16))
            #expect(items.allSatisfy { $0.target == nil })

            store.move(at: 1, by: -1)
            #expect(empty.items[0].title == "TextEdit" && empty.items[0].keyEquivalent == "e" && empty.items[0].tag == 0)
            #expect(empty.items[1].keyEquivalent.isEmpty)
        }
    }

    /// ⌘E is free across the whole menu bar (display-only shortcuts shown
    /// too), and pressed as a key it reaches the first editor.
    @Test func commandEBelongsToTheFirstEditor() async throws {
        try await withStore { store, _ in
            _ = NSApplication.shared
            store.add(editor("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app"))
            store.add(editor("TextEdit", "com.apple.TextEdit", path: "/System/Applications/TextEdit.app"))
            let bar = MainMenu.make()
            let tools = try #require(bar.items.first { $0.title == "Tools" }?.submenu)
            let holder = try #require(tools.items.first { $0.title == ExternalEditorsMenu.title })
            holder.submenu = ExternalEditorsMenu.make(store: store)

            func walk(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
            let displayOnly = bar.items.compactMap { $0.submenu?.delegate as? DisplayOnlyShortcuts }
            displayOnly.forEach { $0.showShortcuts(true) }
            var holders: [String: [String]] = [:]
            for item in walk(bar) where !item.keyEquivalent.isEmpty {
                var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                holders["\(modifiers.rawValue)-\(item.keyEquivalent.lowercased())", default: []].append(item.title)
            }
            displayOnly.forEach { $0.showShortcuts(false) }
            #expect(holders["\(NSEvent.ModifierFlags.command.rawValue)-e"] == ["Preview"])
            #expect(holders.values.allSatisfy { $0.count == 1 }, "\(holders.filter { $0.value.count > 1 })")

            let recorder = EditorRecorder()
            for item in walk(bar) where item.action == .openInExternalEditor { item.target = recorder }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 14, keyDown: true)!   // E
            event.flags = .maskCommand
            let press = try #require(NSEvent(cgEvent: event))
            guard press.charactersIgnoringModifiers?.lowercased() == "e" else { return }
            #expect(bar.performKeyEquivalent(with: press))
            #expect(recorder.tags == [0])
        }
    }

    final class EditorRecorder: NSObject {
        var tags: [Int] = []
        @objc func openInExternalEditor(_ sender: Any?) { tags.append((sender as? NSMenuItem)?.tag ?? -1) }
    }

    // MARK: Opening

    final class Answers {
        var questions: [ExternalEditorOpener.Question] = []
        var reply = true
        var settingsShown = 0
    }

    func opener(store: ExternalEditorsStore, launcher: FakeLauncher, answers: Answers) -> ExternalEditorOpener {
        let opener = ExternalEditorOpener()
        opener.store = { store }
        opener.launcher = launcher
        opener.watcher = nil
        opener.confirm = { question, _, answer in
            answers.questions.append(question)
            answer(answers.reply)
        }
        opener.showEditorSettings = { answers.settingsShown += 1 }
        return opener
    }

    func files(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/editor/\($0).jpg") }
    }

    @Test func opensInTheChosenEditor() async {
        await withStore { store, _ in
            store.add(editor("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app"))
            store.add(editor("TextEdit", "com.apple.TextEdit", path: "/System/Applications/TextEdit.app"))
            let launcher = FakeLauncher(), answers = Answers()
            let opener = opener(store: store, launcher: launcher, answers: answers)
            opener.open(files(3), editorIndex: 1, window: nil)
            #expect(answers.questions.isEmpty)
            #expect(launcher.opened.count == 1)
            #expect(launcher.opened.first?.urls == files(3))
            #expect(launcher.opened.first?.application.path == "/System/Applications/TextEdit.app")
            // A stale tag or nothing to open does nothing.
            opener.open(files(1), editorIndex: 5, window: nil)
            opener.open([], editorIndex: 0, window: nil)
            #expect(launcher.opened.count == 1)
        }
    }

    @Test func manyFilesAndUnsavedEditsAreAskedAbout() async {
        await withStore { store, _ in
            store.add(editor("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app"))
            let launcher = FakeLauncher(), answers = Answers()
            let opener = opener(store: store, launcher: launcher, answers: answers)

            opener.open(files(20), editorIndex: 0, window: nil)
            #expect(answers.questions.isEmpty && launcher.opened.count == 1)

            answers.reply = false
            opener.open(files(21), editorIndex: 0, window: nil)
            #expect(answers.questions.map(\.message) == ["Open 21 images in Preview?"])
            #expect(launcher.opened.count == 1)

            answers.questions = []
            opener.open(files(1), editorIndex: 0, window: nil, unsavedEditsIn: "a.jpg")
            #expect(answers.questions.map(\.confirmTitle) == ["Open Saved File"])
            #expect(answers.questions.first?.detail
                == "Preview opens the file as it was last saved, without the edits made here.")
            #expect(launcher.opened.count == 1)

            answers.reply = true
            answers.questions = []
            opener.open(files(25), editorIndex: 0, window: nil, unsavedEditsIn: "a.jpg")
            #expect(answers.questions.count == 2)
            #expect(launcher.opened.count == 2)
        }
    }

    @Test func aMissingApplicationOffersTheEditorList() async {
        await withStore { store, _ in
            store.add(editor("Gone", "com.example.gone", path: "/nowhere/Gone.app"))
            let launcher = FakeLauncher(), answers = Answers()
            let opener = opener(store: store, launcher: launcher, answers: answers)
            opener.open(files(1), editorIndex: 0, window: nil)
            #expect(launcher.opened.isEmpty)
            #expect(answers.questions.map(\.confirmTitle) == ["Edit Editor List…"])
            #expect(answers.settingsShown == 1)
        }
    }

    @Test func menuSenderTagsPickTheEditor() {
        let item = NSMenuItem(title: "", action: .openInExternalEditor, keyEquivalent: "")
        item.tag = 3
        #expect(ExternalEditorOpener.editorIndex(item) == 3)
        #expect(ExternalEditorOpener.editorIndex(nil) == 0)
        #expect(BrowserWindowController.instancesRespond(to: .openInExternalEditor))
        #expect(ViewerWindowController.instancesRespond(to: .openInExternalEditor))
    }

    // MARK: Watching

    /// A file an editor saves is reported once per change, by its own
    /// folder's FSEvents stream.
    @Test func watcherReportsFilesSavedElsewhere() async throws {
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("a.jpg", width: 40, height: 30)
        let other = try scratch.jpeg("b.jpg", width: 40, height: 30)
        let watcher = ExternalEditWatcher()
        var reports: [[URL]] = []
        watcher.onChange = { reports.append($0) }
        watcher.watch([photo])
        await watcher.work?.value
        #expect(watcher.watchedFolders == [scratch.url.standardizedFileURL])

        try await Task.sleep(for: .milliseconds(300))   // FSEvents reports changes after its stream starts
        try scratch.jpeg("a.jpg", width: 50, height: 30)
        try scratch.jpeg("b.jpg", width: 60, height: 30)   // not watched
        let deadline = Date().addingTimeInterval(10)
        while reports.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            await watcher.work?.value
        }
        #expect(reports == [[photo.standardizedFileURL]])
        _ = other

        // Unchanged since: a folder event alone reports nothing.
        watcher.folderChanged(scratch.url.standardizedFileURL)
        await watcher.work?.value
        #expect(reports.count == 1)
    }

    /// A watched file that disappears (renamed in the browser, moved, or
    /// mid-save) isn't reported, so the viewer never shows "can't display"
    /// for it; once back with new contents it is.
    @Test func watcherIgnoresFilesThatAreGone() async throws {
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("a.jpg", width: 40, height: 30)
        let watcher = ExternalEditWatcher()
        var reports: [[URL]] = []
        watcher.onChange = { reports.append($0) }
        watcher.watch([photo])
        await watcher.work?.value
        let folder = scratch.url.standardizedFileURL

        try FileManager.default.moveItem(at: photo, to: scratch.url.appendingPathComponent("renamed.jpg"))
        watcher.folderChanged(folder)
        await watcher.work?.value
        #expect(reports.isEmpty)

        try scratch.jpeg("a.jpg", width: 70, height: 30)
        watcher.folderChanged(folder)
        await watcher.work?.value
        #expect(reports == [[photo.standardizedFileURL]])
    }

    /// minivu's own save of a watched file isn't reported as another
    /// application's: no second reload, and no question about edits.
    @Test func watcherIgnoresMinivusOwnWrites() async throws {
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("a.jpg", width: 40, height: 30)
        let watcher = ExternalEditWatcher()
        var reports: [[URL]] = []
        watcher.onChange = { reports.append($0) }
        watcher.watch([photo])
        await watcher.work?.value
        let folder = scratch.url.standardizedFileURL

        try scratch.jpeg("a.jpg", width: 80, height: 30)   // as Save writes it
        watcher.noteOwnWrite(photo)
        watcher.folderChanged(folder)                       // the write's own FSEvents report
        await watcher.work?.value
        #expect(reports.isEmpty)

        // A file that isn't watched is ignored; an editor's save still counts.
        watcher.noteOwnWrite(scratch.url.appendingPathComponent("other.jpg"))
        try scratch.jpeg("a.jpg", width: 90, height: 30)
        watcher.folderChanged(folder)
        await watcher.work?.value
        #expect(reports == [[photo.standardizedFileURL]])
    }

    @Test func watcherKeepsTheMostRecentFolders() async throws {
        let scratch = try ScratchFolder()
        let watcher = ExternalEditWatcher()
        watcher.onChange = { _ in }
        var folders: [URL] = []
        for index in 0..<(ExternalEditWatcher.folderLimit + 2) {
            let folder = try scratch.folder("f\(index)")
            folders.append(folder.standardizedFileURL)
            watcher.watch([folder.appendingPathComponent("x.jpg")])
        }
        await watcher.work?.value
        #expect(watcher.watchedFolders == Array(folders.suffix(ExternalEditWatcher.folderLimit)))
    }
}

extension AppWindowTests {
    /// The viewer shows what an editor saved, unless it has unsaved edits of
    /// its own; the browser opens its selection in the editor.
    @MainActor @Suite(.serialized) struct ExternalEditorWindowTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        }

        @Test func viewerReloadsAFileAnEditorSaved() async throws {
            let folder = try ScratchFolder()
            let a = try folder.jpeg("a.jpg", width: 600, height: 400)
            let list = try [a, folder.jpeg("b.jpg", width: 600, height: 400)].map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 400))

            // Another file changing leaves the image alone.
            try folder.jpeg("b.jpg", width: 300, height: 500)
            ExternalEditWatcher.filesChanged([list[1].url])
            try await Task.sleep(for: .milliseconds(100))
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 400))

            viewer.histogramPanel.model.onCountColors?()
            await waitUntil { viewer.histogramPanel.model.colorCount != .counting }
            #expect(viewer.histogramPanel.model.colorCount != .idle)
            try folder.jpeg("a.jpg", width: 300, height: 500)
            ExternalEditWatcher.filesChanged([a])
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 300, height: 500) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 300, height: 500))
            // The entry takes the saved file's date and size at once, so the
            // info panel and colour count describe it without moving away.
            let saved = try #require(FolderEntry(url: a))
            #expect(saved.fileSize != list[0].fileSize)
            #expect(viewer.model.current?.fileSize == saved.fileSize)
            #expect(viewer.model.current?.modified == saved.modified)
            #expect(viewer.model.index == 0 && viewer.model.images[1] == list[1])
            #expect(viewer.displayed?.entry == viewer.model.current)
            #expect(viewer.histogramPanel.model.colorCount == .idle, "the old file's count is gone")
            await waitUntil { viewer.canEditCurrent }
            #expect(viewer.canEditCurrent, "the saved file can be edited")

            // With unsaved edits the user is asked. Keep My Edits: the edited
            // image stays, and Save becomes Save As, leaving the file alone.
            let savedQuestion = ViewerWindowController.askAboutExternalChange
            let savedSaveAs = ViewerWindowController.presentSaveAs
            defer {
                ViewerWindowController.askAboutExternalChange = savedQuestion
                ViewerWindowController.presentSaveAs = savedSaveAs
            }
            var asked: [String] = []
            var answer = ExternalChangeChoice.keepEdits
            ViewerWindowController.askAboutExternalChange = { name, _, reply in
                asked.append(name)
                reply(answer)
            }
            var savesAs: [URL] = []
            ViewerWindowController.presentSaveAs = { entry, _, _, completion in
                savesAs.append(entry.url)
                completion(nil)
            }
            await waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 500, height: 300) }
            try folder.jpeg("a.jpg", width: 200, height: 200)
            let editorsVersion = try Data(contentsOf: a)
            ExternalEditWatcher.filesChanged([a])
            #expect(asked == ["a.jpg"])
            try await Task.sleep(for: .milliseconds(200))
            #expect(viewer.hasUnsavedEdits)
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 500, height: 300))
            viewer.saveImage(nil)
            #expect(savesAs == [a], "Save asks for a name instead of replacing the other version")
            #expect(try Data(contentsOf: a) == editorsVersion)
            // A later save in the editor isn't asked about again.
            ExternalEditWatcher.filesChanged([a])
            #expect(asked.count == 1 && viewer.hasUnsavedEdits)
            viewer.endEditSession()

            // Reload: the edits go and the file as it is now shows.
            await waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            await waitUntil { viewer.hasUnsavedEdits }
            try folder.jpeg("a.jpg", width: 120, height: 90)
            answer = .reload
            ExternalEditWatcher.filesChanged([a])
            #expect(asked.count == 2 && !viewer.hasUnsavedEdits && viewer.editSession == nil)
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 120, height: 90) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 120, height: 90))
        }

        /// A file saved over by an application minivu didn't open it in: no
        /// watcher saw it, so Save itself notices, before "Replace the
        /// original?", and asks as the watcher would. Nothing is written.
        @Test func saveNoticesAChangeNoWatcherSaw() async throws {
            let folder = try ScratchFolder()
            let a = try folder.jpeg("a.jpg", width: 600, height: 400)
            let entry = try #require(FolderEntry(url: a))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            let savedQuestion = ViewerWindowController.askAboutExternalChange
            let savedSaveAs = ViewerWindowController.presentSaveAs
            defer {
                ViewerWindowController.askAboutExternalChange = savedQuestion
                ViewerWindowController.presentSaveAs = savedSaveAs
            }
            var asked: [String] = []
            ViewerWindowController.askAboutExternalChange = { name, _, reply in
                asked.append(name)
                reply(.keepEdits)
            }
            var savesAs: [URL] = []
            ViewerWindowController.presentSaveAs = { entry, _, _, completion in
                savesAs.append(entry.url)
                completion(nil)
            }
            await waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600) }
            try folder.jpeg("a.jpg", width: 200, height: 200)
            let theirs = try Data(contentsOf: a)

            viewer.saveImage(nil)
            await waitUntil { !asked.isEmpty }
            #expect(asked == ["a.jpg"])
            #expect(viewer.hasUnsavedEdits && viewer.window?.attachedSheet == nil)
            #expect(try Data(contentsOf: a) == theirs)
            viewer.saveImage(nil)
            #expect(savesAs == [a], "once the edits are kept, Save asks for a name")
            #expect(try Data(contentsOf: a) == theirs)
            viewer.endEditSession()
        }

        /// Every edit undone shows the image the edits were made on, which
        /// tools, Redo and Save As go on working with, never the file as
        /// another application left it: whether the edits were kept when the
        /// change was seen, or nobody noticed it and the viewer's own copy of
        /// the page is gone from its cache.
        @Test func undoingEveryEditShowsTheImageTheEditsWereMadeOn() async throws {
            let folder = try ScratchFolder()
            let a = try folder.jpeg("a.jpg", width: 600, height: 400)
            let b = try folder.jpeg("b.jpg", width: 600, height: 400)
            let list = try [a, b].map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            let savedQuestion = ViewerWindowController.askAboutExternalChange
            defer { ViewerWindowController.askAboutExternalChange = savedQuestion }
            ViewerWindowController.askAboutExternalChange = { _, _, reply in reply(.keepEdits) }
            let original = CGSize(width: 600, height: 400), rotated = CGSize(width: 400, height: 600)

            // Kept when the change was seen.
            await waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            await waitUntil { viewer.canvasTexture?.imageSize == rotated }
            let session = try #require(viewer.editSession)
            try folder.jpeg("a.jpg", width: 200, height: 200)
            ExternalEditWatcher.filesChanged([a])
            #expect(session.externalChange == .kept)
            viewer.undoEdit()
            try await Task.sleep(for: .milliseconds(500))
            #expect(viewer.canvasTexture?.imageSize == original, "undone, kept edits")
            #expect(viewer.editSession === session)
            viewer.openCrop()
            await waitUntil { viewer.activeTool != nil }
            if case .crop(let crop)? = viewer.activeTool {
                #expect(crop.selection.bounds.size == viewer.canvasTexture?.imageSize, "the crop is over what shows")
            } else {
                Issue.record("Crop didn't open")
            }
            viewer.closeTool()
            viewer.redoEdit()
            await waitUntil { viewer.canvasTexture?.imageSize == rotated }
            #expect(viewer.canvasTexture?.imageSize == rotated)
            viewer.endEditSession()

            // Nobody noticed, and the cache let the viewer's copy go.
            viewer.nextImage(nil)
            await waitUntil { viewer.displayed?.entry == list[1] && viewer.canEditCurrent }
            viewer.rotateRight(nil)
            await waitUntil { viewer.canvasTexture?.imageSize == rotated }
            try folder.jpeg("b.jpg", width: 200, height: 200)
            AppServices.images.cache.removeAll()
            viewer.undoEdit()
            try await Task.sleep(for: .milliseconds(500))
            #expect(viewer.canvasTexture?.imageSize == original, "undone, change unnoticed")
            viewer.endEditSession()
        }

        @Test func browserOpensTheSelectionNotTheFolder() async throws {
            let t = try ScratchFolder()
            let first = try t.jpeg("a.jpg", width: 40, height: 20)
            let second = try t.jpeg("b.jpg", width: 40, height: 20)
            try t.jpeg("c.jpg", width: 40, height: 20)
            let sub = try t.folder("Sub")
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value

            let scratchDefaults = ScratchDefaults("minivu-editors-window")
            defer { scratchDefaults.remove() }
            let defaults = scratchDefaults.defaults
            let store = ExternalEditorsStore(defaults: defaults)
            store.add(ExternalEditor(name: "Preview", bundleIdentifier: "com.apple.Preview",
                                     path: "/System/Applications/Preview.app"))
            let opener = ExternalEditorOpener.shared
            let saved = (opener.store, opener.launcher, opener.watcher)
            defer { (opener.store, opener.launcher, opener.watcher) = saved }
            let launcher = FakeLauncher()
            opener.store = { store }
            opener.launcher = launcher
            opener.watcher = nil

            let item = NSMenuItem(title: "Preview", action: .openInExternalEditor, keyEquivalent: "")
            controller.model.setSelection([first, second, sub], lead: second)
            #expect(controller.validateMenuItem(item))
            controller.openInExternalEditor(item)
            #expect(launcher.opened.first?.urls.map(\.lastPathComponent) == ["a.jpg", "b.jpg"])

            controller.model.setSelection([], lead: nil)
            #expect(!controller.validateMenuItem(item))
        }
    }
}
