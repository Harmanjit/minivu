import AppKit

/// Open in External Editor in the viewer, and showing what the editor saved.
extension ViewerWindowController {
    /// The image shown. With unsaved edits the editor gets the file as
    /// saved, which is said first.
    @objc func openInExternalEditor(_ sender: Any?) {
        guard let entry = model.current else { return }
        ExternalEditorOpener.shared.open([entry.url], editorIndex: ExternalEditorOpener.editorIndex(sender),
                                         window: window, unsavedEditsIn: hasUnsavedEdits ? entry.name : nil)
    }

    /// One of `urls` changed on disk (an editor saved it). If it is the image
    /// shown, it is decoded again, keeping zoom and pan when its size didn't
    /// change. Caches of the files were already dropped.
    ///
    /// Unsaved edits made here stay on screen: reloading would throw them
    /// away. An edit session without changes is ended first, since it holds
    /// the pixels decoded before the editor's save.
    func reloadAfterExternalEdit(of urls: [URL]) {
        guard !isClosing, let shown = current,
              urls.contains(where: { SavePresenter.sameFile($0, shown.entry.url) }) else { return }
        guard !hasUnsavedEdits else { return }
        if editSession != nil { endEditSession() }
        loadCurrentPage(reloading: true)
    }
}
