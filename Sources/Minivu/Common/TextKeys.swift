import AppKit

/// Keys a text field needs that are also menu shortcuts.
///
/// AppKit offers every key press to the menu bar before the focused view,
/// so while the search field, a rename field, an inspector's number field
/// or a drawn text box has the keyboard, ⌘⌫ (delete to the start of the
/// line), ⌘↑ and ⌘↓ (to the start and end of the text) would reach Move to
/// Trash, Enclosing Folder and Open in Viewer instead. An item that
/// validates as disabled lets the key through to the text; clicking the
/// menu item, the context menu and the toolbar still work, because only a
/// key press is held back.
enum TextKeys {
    /// Whether `event` is a key press meant for text being edited in `window`.
    static func belongToText(in window: NSWindow?, event: NSEvent? = NSApp.currentEvent) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return window?.firstResponder is NSText
    }
}
