import AppKit

/// File > Share… in the viewer: the image shown. With unsaved edits the
/// file as saved is shared, which is said first (see `FileSharing`).
extension ViewerWindowController {
    @objc func shareFiles(_ sender: Any?) {
        guard let entry = model.current else { return }
        FileSharing.shared.share([entry.url], from: canvas, rect: shareAnchorRect,
                                 unsavedEditsIn: hasUnsavedEdits ? entry.name : nil)
    }

    /// A point at the middle of the picture area, where the eye already is:
    /// a menu command has no button to point at.
    var shareAnchorRect: NSRect {
        NSRect(x: canvas.bounds.midX, y: canvas.bounds.midY, width: 1, height: 1)
    }
}
