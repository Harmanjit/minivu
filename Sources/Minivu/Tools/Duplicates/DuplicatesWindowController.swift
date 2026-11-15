import AppKit
import SwiftUI
import MinivuCore

/// The question asked before marked duplicates go to the Trash, replaceable
/// in tests.
@MainActor enum DuplicatePrompts {
    /// Asks on `window` whether to move `count` files to the Trash;
    /// `wholeGroups` is how many groups would keep no copy at all.
    static var confirmTrash: (NSWindow, Int, Int, @escaping (Bool) -> Void) -> Void = { window, count, wholeGroups, answer in
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Move 1 file to the Trash?" : "Move \(count.formatted()) files to the Trash?"
        var detail = "You can put them back from the Trash in Finder."
        if wholeGroups > 0 {
            detail = (wholeGroups == 1 ? "In 1 group every file is marked, so no copy of it will be left here. "
                : "In \(wholeGroups) groups every file is marked, so no copy of them will be left here. ") + detail
            alert.alertStyle = .warning
        }
        alert.informativeText = detail
        let move = alert.addButton(withTitle: "Move to Trash")
        move.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }
}

/// Tools > Find Duplicates… (G5): finds identical files or similar pictures
/// in the browser's selection, its folder or its folder's tree, lists them
/// in groups with a suggested file to keep, and moves the files the user
/// marks to the Trash, only when asked and after a confirmation.
///
/// SwiftUI, as the other tool windows' forms are (DESIGN.md 4.1): the list
/// is a few hundred rows, not the grid's hot path. One window; asking again
/// from the browser points it at what the browser shows now.
final class DuplicatesWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: DuplicatesWindowController?

    let model: DuplicatesModel
    /// Where Show in Browser shows files.
    private(set) weak var browser: BrowserWindowController?
    private(set) var isTrashing = false

    static let defaultSize = NSSize(width: 900, height: 640)
    static let minimumSize = NSSize(width: 720, height: 420)

    /// Opens the window, or brings it forward pointed at `source`.
    @discardableResult
    static func show(source: DuplicateSource, browser: BrowserWindowController?,
                     store: ThumbnailStore? = AppServices.thumbnailStore) -> DuplicatesWindowController {
        if let controller = current {
            controller.browser = browser
            controller.model.retarget(source)
            controller.showWindow(nil)
            return controller
        }
        let controller = DuplicatesWindowController(model: DuplicatesModel(source: source, store: store), browser: browser)
        current = controller
        controller.showWindow(nil)
        return controller
    }

    init(model: DuplicatesModel, browser: BrowserWindowController?) {
        self.model = model
        self.browser = browser
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Find Duplicates"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(rootView: DuplicatesView(model: model, actions: DuplicatesView.Actions(
            trash: { [weak self] in self?.moveMarkedToTrash() },
            showInBrowser: { [weak self] in self?.showInBrowser() },
            compare: { [weak self] in self?.compareSelected() })))
        // The window's size is the user's, not the content's.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: Self.defaultSize)
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName("FindDuplicates")
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    func windowWillClose(_ notification: Notification) {
        model.abandon()
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Commands

    /// Moves the marked files to the Trash once the user confirms, after
    /// the viewer has dealt with unsaved edits of any of them and queued
    /// saves have landed (`FileWriteQueue.trash`).
    func moveMarkedToTrash() {
        let urls = model.markedFiles.map(\.url)
        guard let window, !urls.isEmpty, !isTrashing, !model.isRunning else { return }
        DuplicatePrompts.confirmTrash(window, urls.count, model.wholeGroupsMarked) { [weak self] confirmed in
            guard confirmed, let self else { return }
            if let viewer = ViewerWindowController.current {
                viewer.resolveUnsavedEdits(before: urls) { [weak self] in self?.trash(urls) }
            } else {
                trash(urls)
            }
        }
    }

    private func trash(_ urls: [URL]) {
        isTrashing = true
        Task { [weak self] in
            var gone: Set<URL>
            var failure: Error?
            do {
                gone = Set(try await FileWriteQueue.shared.trash(urls).keys)
            } catch {
                // Some may have gone anyway.
                failure = error
                gone = Set(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
            }
            guard let self else { return }
            self.isTrashing = false
            gone.forEach(BrowserModel.invalidateCaches)
            self.model.didTrash(gone)
            self.browser?.model.removeEntries(gone)
            if let failure, let window = self.window {
                NSAlert(error: failure).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// The selected files, or every file found when none is, as a list in
    /// the browser (Back returns to where it was).
    func showInBrowser() {
        let files = model.selectedFiles.isEmpty ? model.allFiles : model.selectedFiles
        guard !files.isEmpty, let browser else { return }
        let title = model.resultMode == .similar ? "Similar Images" : "Duplicates"
        browser.open(list: VirtualList(kind: .files(files.map(\.url)), title: title))
        browser.showWindow(nil)
    }

    /// Two to four selected files side by side; ← and → step through the
    /// rest of their groups.
    func compareSelected() {
        let files = model.selectedFiles
        guard CompareModel.paneRange.contains(files.count) else { return }
        let groups = model.groups.filter { group in group.files.contains { model.selection.contains($0.url) } }
        CompareWindowController.show(entries: files, allImages: groups.flatMap(\.files))
    }

    var canCompare: Bool { CompareModel.paneRange.contains(model.selection.count) }
}
