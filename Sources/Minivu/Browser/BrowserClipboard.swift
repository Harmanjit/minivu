import AppKit
import MinivuCore

/// Copy and Paste for images rather than for text. The Edit menu has had
/// both since the beginning, for the text fields; outside one they belong
/// to the files on the grid and to the picture in the viewer.
///
/// Copy and Paste are the two ends of what a drag already does, so they are
/// built from the same pieces: Copy writes the pasteboard object the grid's
/// drag source writes, and Paste hands the files to `transfer(_:to:move:)`,
/// the one path a drop, Copy To and Move To all take. Pasting therefore
/// settles name clashes the way Finder does, waits for queued writes,
/// registers its Undo and keeps the catalog in step, with none of that
/// written a second time here.
extension BrowserWindowController {
    // MARK: - Commands

    @objc func copy(_ sender: Any?) {
        copySelection(to: .general)
    }

    @objc func paste(_ sender: Any?) {
        pasteFiles(from: .general)
    }

    /// Puts the selected files on `pasteboard` as file URLs, so they paste
    /// into Finder and into anything else that takes files.
    ///
    /// The objects are the ones the grid's drag source writes for an item
    /// (`collectionView(_:pasteboardWriterForItemAt:)`), so dragging a
    /// selection out and copying it hand another application the same thing.
    /// The pasteboard is a parameter so that nothing but the command itself
    /// ever writes to the person's own clipboard.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        let urls = model.selectedEntries.map { $0.url as NSURL }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }

    /// Copies the files on `pasteboard` into the folder being shown.
    ///
    /// Always a copy, never a move: the pasteboard says nothing about what
    /// was meant to happen to the originals, and a Paste that emptied the
    /// folder they came from would be a file operation nobody asked for.
    /// With nothing to paste it does nothing at all, since the menu item is
    /// already disabled then and AppKit beeps for the key by itself.
    @discardableResult
    func pasteFiles(from pasteboard: NSPasteboard) -> Bool {
        guard let folder = model.folder else { return false }
        let files = Self.pastableFiles(on: pasteboard, into: folder)
        guard !files.isEmpty else { return false }
        transfer(files, to: folder, move: false)
        return true
    }

    /// The files on `pasteboard` that pasting would actually bring in: the
    /// ones a drag of them onto the grid would bring, by the same rules
    /// (`DropRules.movableItems`), which leave out files already in the
    /// folder and a folder pasted into itself. What survives this still goes
    /// through `TransferChecks.preflight`, which catches by file identity
    /// what paths alone cannot: the same file reached through a symbolic
    /// link or under another letter case.
    nonisolated static func pastableFiles(on pasteboard: NSPasteboard, into folder: URL) -> [URL] {
        DropRules.movableItems(GridViewController.fileURLs(from: pasteboard), into: folder)
    }

    // MARK: - Validation

    /// Whether this controller handles `action`, or nil to let the rest of
    /// the chain answer.
    func canPerformClipboard(_ action: Selector) -> Bool? {
        canPerformClipboard(action, pasteboard: .general)
    }

    /// The same, reading `pasteboard` for what Paste would bring in. Tests
    /// pass a pasteboard of their own, so asking whether Paste applies never
    /// depends on what the person happens to have copied.
    func canPerformClipboard(_ action: Selector, pasteboard: NSPasteboard) -> Bool? {
        // Copy and Paste belong to the search field or the rename editor
        // while one of them has the keyboard, however they were asked for.
        // Unlike ⌘⌫, which means Move to Trash when it comes from the menu
        // and the text only when typed (`TextKeys`), Edit > Copy means the
        // text's Copy whenever text is being edited, so the question is
        // about the first responder and not about the event, exactly as
        // `ViewerWindow.isEditingText` asks it for Undo. The field editor
        // takes these first in the responder chain anyway; this is the same
        // answer from the other end, so neither can reach the files past a
        // field being typed in.
        let toTheText = window?.firstResponder is NSText
        switch action {
        case #selector(NSText.copy(_:)):
            return !toTheText && !model.selection.isEmpty
        case #selector(NSText.paste(_:)):
            // As with Copy To and Move To: one transfer at a time, and none
            // from under a sheet, whose commands the browser would otherwise
            // answer while it stays the main window.
            guard !toTheText, !isTransferring, window?.attachedSheet == nil,
                  let folder = model.folder, model.state == .loaded else { return false }
            // A folder that can't be written to takes nothing, so Paste is
            // not offered rather than failing halfway through. A write
            // refused for a reason `access` cannot see still ends in
            // `reportFailures`.
            guard FileManager.default.isWritableFile(atPath: folder.path) else { return false }
            return !Self.pastableFiles(on: pasteboard, into: folder).isEmpty
        default:
            return nil
        }
    }
}
