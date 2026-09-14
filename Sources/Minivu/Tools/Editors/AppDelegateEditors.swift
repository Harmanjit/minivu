import AppKit

/// Edit Editor List… opens Settings on the Editors pane.
extension AppDelegate {
    @objc func manageExternalEditors(_ sender: Any?) {
        showSettings(pane: .editors)
    }

    #if DEBUG
    /// Debug only, for the snapshot harness: shows Settings > Editors with
    /// Preview and TextEdit in the list. The list stops being saved first,
    /// so the sample never reaches the user's settings.
    @objc func debugSampleEditors(_ sender: Any?) {
        showSampleEditors(["/System/Applications/Preview.app", "/System/Applications/TextEdit.app"])
    }

    /// Debug only, for the snapshot harness: TextEdit alone, so Preview shows
    /// among the suggestions.
    @objc func debugSampleEditorsWithSuggestions(_ sender: Any?) {
        showSampleEditors(["/System/Applications/TextEdit.app"])
    }

    private func showSampleEditors(_ paths: [String]) {
        let store = ExternalEditorsStore.shared
        store.detachFromDefaults()
        store.replaceAll(with: paths.compactMap {
            ExternalEditorsStore.editor(forApplicationAt: URL(fileURLWithPath: $0), makeBookmark: false)
        })
        showSettings(pane: .editors)
    }
    #endif
}
