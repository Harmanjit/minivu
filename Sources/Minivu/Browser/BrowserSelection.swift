import AppKit
import MinivuCore

/// Edit > Select Tagged and Invert Selection, which work on what the grid
/// is showing rather than on the whole folder: a filter is the user saying
/// which images they are working with, so a selection command that reached
/// past it would select images they cannot see.
extension BrowserWindowController {
    /// Edit > Select Tagged: the tagged images the grid is showing, and
    /// nothing else, so the culling marks become the working selection.
    @objc func selectTagged(_ sender: Any?) {
        let tagged = model.entries.filter { isTagged($0) }.map(\.url)
        guard !tagged.isEmpty else { return NSSound.beep() }
        // The lead is where the preview and the viewer are, so it stays put
        // when it is itself tagged. When it isn't, `setSelection` drops it
        // and leads with the first image of the new selection rather than
        // leaving the preview on a photo the user has just deselected.
        model.setSelection(Set(tagged), lead: model.lead)
    }

    /// ⇧⌘I: everything the grid is showing that wasn't selected, and nothing
    /// that was. Folders take part, as they do in Select All: the user asked
    /// for the rest of what they can see, and a subfolder is part of that.
    @objc func invertSelection(_ sender: Any?) {
        guard !model.entries.isEmpty else { return NSSound.beep() }
        let inverted = model.entries.map(\.url).filter { !model.selection.contains($0) }
        // Nothing that was selected still is, the old lead with it, so the
        // lead is given up: `setSelection` leads with the first item of the
        // new selection, or with nothing when the whole grid was selected.
        model.setSelection(Set(inverted), lead: nil)
    }

    /// Whether the grid is showing this entry as tagged. The tag is minivu's
    /// own mark, kept in the catalog against an image; a folder never has one.
    private func isTagged(_ entry: FolderEntry) -> Bool {
        !entry.isDirectory && model.marks(for: entry.url).isTagged
    }

    /// Whether this controller handles `action`, or nil to let the rest of
    /// the chain answer.
    ///
    /// Each is off when it would change nothing: with no tagged image shown
    /// there is nothing to select, and with an empty grid there is nothing
    /// to swap.
    ///
    /// `event` is the key press the menu bar is offering, which only a test
    /// passes: dequeuing one to fill `NSApp.currentEvent` ends the test run,
    /// so the suite hands the press straight over, as `TextKeys` allows.
    func canPerformSelection(_ action: Selector, event: NSEvent? = NSApp.currentEvent) -> Bool? {
        let selecting: [Selector] = [.selectTagged, .invertSelection]
        // ⇧⌘I typed while the search field or the inline rename editor has
        // the keyboard belongs to the text being edited, not to the grid
        // behind it. An item that validates as disabled lets the key press
        // through, and clicking the item still works (see `TextKeys`).
        if selecting.contains(action), TextKeys.belongToText(in: window, event: event) { return false }
        return switch action {
        case .selectTagged:
            model.entries.contains { isTagged($0) }
        case .invertSelection:
            !model.entries.isEmpty
        default:
            nil
        }
    }
}
