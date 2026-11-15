import AppKit
import MinivuCore

/// Image > Edit Metadata… (⌘I) for the browser's selection (G1): title,
/// caption, keywords, creator, copyright, date taken and location, written
/// into the files without re-encoding, or into XMP sidecars for camera raw
/// files and formats ImageIO can't rewrite.
extension BrowserWindowController {
    @objc func editMetadata(_ sender: Any?) {
        guard canEditMetadata, let window else { return NSSound.beep() }
        let urls = model.selectedEntries.filter { !$0.isDirectory }.map(\.url)
        let edit: () -> Void = { [weak self] in self?.presentMetadataEditor(for: urls, on: window) }
        // Unsaved edits of one of these images in the viewer are asked about
        // first, as Move to Trash asks: saving them writes the file too.
        guard let viewer = ViewerWindowController.current else { return edit() }
        viewer.resolveUnsavedEdits(before: urls, then: edit)
    }

    private func presentMetadataEditor(for urls: [URL], on window: NSWindow) {
        guard !BatchTools.hasSheet(on: window) else { return NSSound.beep() }
        MetadataEditor.present(for: urls, on: window) { [weak self] outcome in
            guard let outcome else { return }
            for url in outcome.rewritten { BrowserModel.invalidateCaches(url) }
            // The new dates and sizes, and with them the preview pane.
            if !outcome.rewritten.isEmpty { self?.model.reload() }
            ViewerWindowController.current?.metadataDidChange(outcome.rewritten)
        }
    }

    /// The preview pane's keyword tokens and field (G4): a quick Edit
    /// Metadata of one file's keywords, written the same way and refreshed
    /// the same way. Unsaved edits of it in the viewer are asked about first.
    func writeKeywords(_ edit: MetadataEdit, to url: URL) {
        guard let window else { return }
        let write = { [weak self] in
            MetadataEditor.write(edit, to: [url], skipped: [], on: window) { [weak self] outcome in
                guard let outcome else { return }
                for url in outcome.rewritten { BrowserModel.invalidateCaches(url) }
                if !outcome.rewritten.isEmpty { self?.model.reload() }
                ViewerWindowController.current?.metadataDidChange(outcome.rewritten)
            }
        }
        guard let viewer = ViewerWindowController.current else { return write() }
        viewer.resolveUnsavedEdits(before: [url], then: write)
    }

    /// Whether the selection has an image whose metadata can be written
    /// (in the file or in a sidecar), with no sheet up. By extension only,
    /// so it is cheap for a large selection.
    var canEditMetadata: Bool {
        guard let window, !BatchTools.hasSheet(on: window) else { return false }
        return model.selectedEntries.contains { !$0.isDirectory && MetadataWriter.method(for: $0.url) != .unsupported }
    }
}
