import AppKit
import MinivuCore

/// Opens files in another application. `NSWorkspace` in the app; tests pass
/// a fake, so no application is ever launched by a test.
protocol ApplicationLaunching: AnyObject {
    func open(_ urls: [URL], withApplicationAt application: URL, completion: @escaping @MainActor (Error?) -> Void)
}

final class WorkspaceLauncher: ApplicationLaunching {
    func open(_ urls: [URL], withApplicationAt application: URL, completion: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { _, error in
            let message = error.map { $0.localizedDescription }
            Task { @MainActor in
                completion(message.map { NSError(domain: "minivu.editors", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: $0]) })
            }
        }
    }
}

/// Open in External Editor, for the browser's selection and the viewer's
/// image: the questions to ask first, finding the application, and
/// watching the files so the viewer shows what the editor saves.
@MainActor final class ExternalEditorOpener {
    static let shared = ExternalEditorOpener()

    /// Opening more files than this at once is confirmed first: every one
    /// becomes a window or a tab in the editor.
    static let confirmationThreshold = 20

    var store: () -> ExternalEditorsStore = { .shared }
    var launcher: ApplicationLaunching = WorkspaceLauncher()
    var watcher: ExternalEditWatcher? = .shared
    /// Asks a yes-or-no question as a sheet on `window` (or an alert when
    /// there is none). A hook so tests can answer without an alert.
    var confirm: (_ question: Question, _ window: NSWindow?, _ answer: @escaping (Bool) -> Void) -> Void = { question, window, answer in
        ExternalEditorOpener.ask(question, on: window, answer: answer)
    }
    var showEditorSettings: () -> Void = { (NSApp.delegate as? AppDelegate)?.showSettings(pane: .editors) }

    struct Question: Equatable {
        var message: String
        var detail: String
        var confirmTitle: String
    }

    /// Opens `urls` in the editor at `index`. `unsavedEditsIn` names the
    /// image when the viewer has edits the file doesn't.
    func open(_ urls: [URL], editorIndex index: Int, window: NSWindow?, unsavedEditsIn name: String? = nil) {
        let editors = store().editors
        guard !urls.isEmpty, editors.indices.contains(index) else { return }
        let editor = editors[index]

        var questions: [Question] = []
        if urls.count > Self.confirmationThreshold {
            questions.append(Question(message: "Open \(urls.count.formatted()) images in \(editor.name)?",
                                      detail: "Each image opens in \(editor.name) on its own.",
                                      confirmTitle: "Open"))
        }
        if let name {
            questions.append(Question(message: "“\(name)” has edits that aren’t saved.",
                                      detail: "\(editor.name) opens the file as it was last saved, without the edits made here.",
                                      confirmTitle: "Open Saved File"))
        }
        ask(questions, window: window) { [weak self] in
            self?.launch(urls, in: editor, window: window)
        }
    }

    private func ask(_ questions: [Question], window: NSWindow?, then proceed: @escaping () -> Void) {
        guard let question = questions.first else { return proceed() }
        confirm(question, window) { [weak self] yes in
            guard yes else { return }
            self?.ask(Array(questions.dropFirst()), window: window, then: proceed)
        }
    }

    private func launch(_ urls: [URL], in editor: ExternalEditor, window: NSWindow?) {
        guard let (application, isScoped) = ExternalEditorsStore.applicationURL(for: editor) else {
            let question = Question(message: "“\(editor.name)” can’t be found.",
                                    detail: "It may have been moved or deleted. Add it again in Settings > Editors.",
                                    confirmTitle: "Edit Editor List…")
            confirm(question, window) { [weak self] yes in if yes { self?.showEditorSettings() } }
            return
        }
        watcher?.watch(urls)
        let scoped = isScoped && application.startAccessingSecurityScopedResource()
        launcher.open(urls, withApplicationAt: application) { [weak self] error in
            if scoped { application.stopAccessingSecurityScopedResource() }
            guard let error, let self else { return }
            self.confirm(Question(message: "\(editor.name) couldn’t open the images.",
                                  detail: error.localizedDescription, confirmTitle: "OK"), window) { _ in }
        }
    }

    static func ask(_ question: Question, on window: NSWindow?, answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        alert.addButton(withTitle: question.confirmTitle)
        if question.confirmTitle != "OK" { alert.addButton(withTitle: "Cancel") }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// The editor index a menu item (or any control) carries.
    static func editorIndex(_ sender: Any?) -> Int {
        (sender as? NSValidatedUserInterfaceItem)?.tag ?? 0
    }
}

/// Watches the files sent to an editor, so a save there shows up here: the
/// browser's thumbnails and the viewer's textures of the file are dropped,
/// and the viewer reloads the image it shows.
///
/// The browser already lists its folder again when anything in it changes
/// (its own `FolderWatcher`) and drops what changed, but the viewer keeps
/// the folder listing it was opened with, so without this it would go on
/// showing the picture from before the edit.
///
/// One FSEvents stream per folder (idle until something changes, no
/// polling), for the eight folders most recently sent to an editor.
@MainActor final class ExternalEditWatcher {
    static let shared = ExternalEditWatcher()
    static let folderLimit = 8

    nonisolated struct Stamp: Equatable, Sendable {
        var modified: Date?
        var size: Int?
    }

    private final class Watch {
        let folder: URL
        var watcher: FolderWatcher?
        var files: [URL: Stamp] = [:]
        init(folder: URL) { self.folder = folder }
    }

    private var watches: [Watch] = []
    /// What to do with files that changed; tests record instead.
    var onChange: ([URL]) -> Void = { ExternalEditWatcher.filesChanged($0) }
    /// The latest stamp reading, for tests to await.
    private(set) var work: Task<Void, Never>?

    var watchedFolders: [URL] { watches.map(\.folder) }

    func watch(_ urls: [URL]) {
        let previous = work
        work = Task {
            await previous?.value
            let stamps = await BlockingWork.run(qos: .utility) { urls.map { ($0, Self.stamp(of: $0)) } }
            for (url, stamp) in stamps { register(url, stamp: stamp) }
        }
    }

    private func register(_ url: URL, stamp: Stamp) {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        let watch: Watch
        if let index = watches.firstIndex(where: { $0.folder == folder }) {
            watch = watches.remove(at: index)
        } else {
            watch = Watch(folder: folder)
            watch.watcher = FolderWatcher(folder: folder) { [weak self] in
                Task { @MainActor in self?.folderChanged(folder) }
            }
        }
        watch.files[url.standardizedFileURL] = stamp
        watches.append(watch)
        while watches.count > Self.folderLimit {
            watches.removeFirst().watcher?.stop()
        }
    }

    /// Compares each watched file of `folder` with its stamp, off the main
    /// thread, and reports the ones that changed.
    func folderChanged(_ folder: URL) {
        guard let watch = watches.first(where: { $0.folder == folder }) else { return }
        let previous = work
        work = Task {
            await previous?.value
            // Read after the previous comparison has recorded its stamps, so
            // two events close together report one save once.
            let files = watch.files
            let now = await BlockingWork.run(qos: .utility) { files.keys.map { ($0, Self.stamp(of: $0)) } }
            var changed: [URL] = []
            // A file that is gone (moved, renamed, deleted, or between an
            // editor's delete and its rename into place) isn't reported:
            // the viewer would put up "can't display" for a file that an
            // editor is still saving, or that the browser has renamed. Its
            // stamp stays, so it is reported if it comes back changed.
            for (url, stamp) in now where stamp.modified != nil && files[url] != stamp {
                watch.files[url] = stamp
                changed.append(url)
            }
            if !changed.isEmpty { onChange(changed.sorted { $0.path < $1.path }) }
        }
    }

    nonisolated static func stamp(of url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    static func filesChanged(_ urls: [URL]) {
        urls.forEach(SavePresenter.didWrite)
        ViewerWindowController.current?.reloadAfterExternalEdit(of: urls)
    }
}
