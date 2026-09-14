import AppKit

/// Tools > Set as Desktop Picture in the viewer: the image shown, with its
/// edits when they aren't saved yet (the file doesn't have them), on the
/// screen the viewer is on.
extension ViewerWindowController {
    @objc func setAsDesktopPicture(_ sender: Any?) {
        guard let entry = model.current, let screen = window?.screen ?? NSScreen.main else { return }
        let edits = editSession.flatMap { $0.document.isDirty ? $0.document.snapshot() : nil }
        DesktopPictureSetter.shared.run(url: entry.url, edits: edits, screen: screen, window: window)
    }
}
