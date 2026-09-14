import AppKit
import MinivuCore

/// What the Tools commands (Phase 7) work on in the browser, and when they
/// are available. Every tool picks its images through these, so a slideshow,
/// a batch conversion and a contact sheet of the same selection agree.
extension BrowserWindowController {
    /// The selected images in grid order, or every image shown (filters
    /// applied) when no image is selected. Folders never count.
    var toolImages: [FolderEntry] {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        return selected.isEmpty ? model.entries.filter { !$0.isDirectory } : selected
    }

    /// Two or more selected images play on their own; otherwise every image
    /// shown plays, starting at the selected one (or the first).
    var slideshowImages: (images: [FolderEntry], start: Int) {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        if selected.count >= 2 { return (selected, 0) }
        let all = model.entries.filter { !$0.isDirectory }
        let start = selected.first.flatMap { chosen in all.firstIndex { $0.url == chosen.url } } ?? 0
        return (all, start)
    }

    /// The one image a single-image command (Set as Desktop Picture) works
    /// on: the lead of the selection, unless it is a folder.
    var toolLeadImage: FolderEntry? {
        model.leadEntry.flatMap { $0.isDirectory ? nil : $0 }
    }

    /// Validation for the Tools commands; nil for any other action. Cheap,
    /// because menus validate often: counts, never a walk of the folder.
    func canPerformTools(_ action: Selector) -> Bool? {
        switch action {
        case .startSlideshow, .batchConvert, .batchRename, .printImages, .makeContactSheet, .makeMontage:
            model.imageCount > 0
        case .setAsDesktopPicture, .openInExternalEditor:
            toolLeadImage != nil
        default:
            nil
        }
    }
}
