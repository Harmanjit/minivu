import AppKit
import MinivuCore

/// Image > Edit Metadata… (⌘I) for the image the viewer shows (G1). The
/// browser's command does the same for its selection.
extension ViewerWindowController {
    @objc func editMetadata(_ sender: Any?) {
        guard canEditMetadata, let url = model.current?.url else { return NSSound.beep() }
        // Unsaved edits of this image are asked about first, as moving on
        // asks: Save writes the file, and the editor should read what's there.
        resolveUnsavedEdits(before: [url]) { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil, !self.isClosing else { return }
            MetadataEditor.present(for: [url], on: window) { [weak self] outcome in
                guard let self, let outcome else { return }
                for url in outcome.rewritten { BrowserModel.invalidateCaches(url) }
                self.metadataDidChange(outcome.rewritten)
            }
        }
    }

    /// The info panel's keyword tokens and field (G4): a quick Edit
    /// Metadata of the image's keywords. Unsaved edits are asked about
    /// first, as for Edit Metadata.
    func writeKeywords(_ edit: MetadataEdit, to url: URL) {
        resolveUnsavedEdits(before: [url]) { [weak self] in
            guard let self, let window = self.window, !self.isClosing else { return }
            MetadataEditor.write(edit, to: [url], skipped: [], on: window) { [weak self] outcome in
                guard let self, let outcome else { return }
                for url in outcome.rewritten { BrowserModel.invalidateCaches(url) }
                self.metadataDidChange(outcome.rewritten)
            }
        }
    }

    /// The info panel for `entry`, its keywords editable where the file's
    /// metadata can be written.
    func infoPanel(for entry: FolderEntry?) -> InfoPanelView {
        guard let entry else { return InfoPanelView(url: nil) }
        let editable = MetadataWriter.method(for: entry.url) != .unsupported
        return InfoPanelView(url: entry.url, modified: entry.modified, editKeywords: editable ? { [weak self] edit in
            self?.writeKeywords(edit, to: entry.url)
        } : nil)
    }

    var canEditMetadata: Bool {
        guard !isClosing, window?.attachedSheet == nil, let entry = model.current else { return false }
        return MetadataWriter.method(for: entry.url) != .unsupported
    }

    /// Edit Metadata rewrote these files in place (from here or from the
    /// browser): the image shown takes its file's new date and size, as after
    /// a Save, so the info panel and filmstrip describe what is now on disk.
    /// The pixels didn't change, so nothing is decoded again. As with Save,
    /// not under an edit session of the same file, which tells its own entry
    /// apart from the one on screen; the info panel follows anyway, through
    /// `MetadataRevisions`.
    func metadataDidChange(_ urls: [URL]) {
        guard let entry = model.current,
              urls.contains(where: { FileWriteQueue.key($0) == FileWriteQueue.key(entry.url) }) else { return }
        Task { [weak self] in
            let stamp = await BlockingWork.run { ExternalEditWatcher.stamp(of: entry.url) }
            guard let self, !self.isClosing, self.model.current?.url == entry.url,
                  self.editSession?.document.entry.url != entry.url else { return }
            var written = entry
            written.modified = stamp.modified ?? entry.modified
            written.fileSize = stamp.size.map(Int64.init) ?? entry.fileSize
            self.refreshEntry(written)
        }
    }
}
