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
    /// change. Caches of the files were already dropped. An edit session
    /// without changes is ended first, since it holds the pixels decoded
    /// before the editor's save.
    ///
    /// With unsaved edits here, reloading would throw them away and saving
    /// over the file would throw the editor's work away, so the user is
    /// asked: Reload (discarding the edits) or Keep My Edits. From the moment
    /// the change is seen, Save becomes Save As for this session, so neither
    /// version is lost while the question waits for another sheet. Once the
    /// edits are kept, later saves by the editor aren't asked about again.
    func reloadAfterExternalEdit(of urls: [URL]) {
        guard !isClosing, let shown = current,
              urls.contains(where: { SavePresenter.sameFile($0, shown.entry.url) }) else { return }
        guard hasUnsavedEdits, let session = editSession else {
            if editSession != nil { endEditSession() }
            showSavedFile()
            return
        }
        guard session.externalChange == .none else { return }
        session.externalChange = .asking
        askAboutExternalChange(session)
    }

    /// Asks as a sheet, once the window has no other sheet up.
    private func askAboutExternalChange(_ session: EditSession) {
        guard let window, !isClosing, editSession === session, session.externalChange == .asking else { return }
        guard hasUnsavedEdits else {
            // The edits went (undone, or saved as a new file) while waiting:
            // nothing to lose, so show what the other application saved.
            endEditSession()
            showSavedFile()
            return
        }
        guard window.attachedSheet == nil else {
            // Once, however many times this waits: asked when that sheet ends.
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(sheetEndedBeforeExternalChangeQuestion(_:)),
                                                   name: NSWindow.didEndSheetNotification, object: window)
            return
        }
        Self.askAboutExternalChange(session.document.entry.name, window) { [weak self] choice in
            guard let self, self.editSession === session else { return }
            switch choice {
            case .reload:
                self.endEditSession()
                self.showSavedFile()
            case .keepEdits:
                session.externalChange = .kept
                self.updateChrome()
            }
        }
    }

    /// Decodes the image shown again, from the file the editor saved. Its
    /// entry takes the file's new date and size first (the viewer keeps the
    /// listing it was opened with), and everything that describes the image
    /// is brought up to date as for a new one: the info panel, the colour
    /// count, the filmstrip's thumbnail, the pages and frames read. Zoom and
    /// pan are kept when the size didn't change. Only with no edit session,
    /// which belongs to the entry it began with.
    private func showSavedFile() {
        if let shown = current, editSession == nil {
            var entry = shown.entry
            let stamp = ExternalEditWatcher.stamp(of: entry.url)
            entry.modified = stamp.modified ?? entry.modified
            entry.fileSize = stamp.size.map(Int64.init) ?? entry.fileSize
            refreshEntry(entry)
        }
        loadCurrentPage(reloading: true)
    }

    @objc private func sheetEndedBeforeExternalChangeQuestion(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: window)
        // After AppKit has finished detaching the sheet (and after whatever
        // its handler starts, such as a save's next sheet).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.editSession else { return }
                self.askAboutExternalChange(session)
            }
        }
    }

    /// Asks what to do about a file changed elsewhere, as a sheet on
    /// `window`. A static hook so tests can answer without an alert.
    static var askAboutExternalChange: (_ name: String, _ window: NSWindow,
                                        _ answer: @escaping (ExternalChangeChoice) -> Void) -> Void = { name, window, answer in
        let alert = NSAlert()
        alert.messageText = "“\(name)” was changed by another application."
        alert.informativeText = "Reload shows the version saved there and discards your edits. "
            + "If you keep your edits, saving them asks for a name, so the other version isn’t replaced."
        // The default keeps what is on screen; nothing is lost either way
        // until the user chooses Reload.
        alert.addButton(withTitle: "Keep My Edits")
        let reload = alert.addButton(withTitle: "Reload")
        reload.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            answer(response == .alertSecondButtonReturn ? .reload : .keepEdits)
        }
    }
}

/// What the user chose when the image being edited changed on disk.
enum ExternalChangeChoice {
    /// Show the file as it is now; the edits here are discarded.
    case reload
    /// Carry on editing; Save becomes Save As.
    case keepEdits
}
