import AppKit
import MinivuCore

/// What the Tools commands (Phase 7) work on in the browser, and when they
/// are available. Every tool picks its images through these, so a slideshow,
/// a batch conversion and a contact sheet of the same selection agree.
extension BrowserWindowController {
    /// The selected images in grid order, or every image shown (filters
    /// applied) when no image is selected. Folders never count.
    /// Videos count: Batch Rename renames them like any file (G18).
    var toolImages: [FolderEntry] {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        return selected.isEmpty ? model.entries.filter { !$0.isDirectory } : selected
    }

    /// `toolImages` without videos, for the tools that make or show
    /// pictures (Batch Convert, Print, Contact Sheet, Montage): a video
    /// is not a picture to convert or lay out, and its first frame alone
    /// would misrepresent it (G18).
    var toolStills: [FolderEntry] {
        toolImages.filter { $0.kind != .video }
    }

    /// Two or more selected images play on their own; otherwise every image
    /// shown plays, starting at the selected one (or the first). Videos are
    /// left out (G18): a slideshow shows pictures for an interval, and
    /// playing a clip inside one is the viewer's job. A video chosen as the
    /// start starts the show at the next picture.
    var slideshowImages: (images: [FolderEntry], start: Int) {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        let selectedStills = selected.filter { $0.kind != .video }
        if selectedStills.count >= 2 { return (selectedStills, 0) }
        let all = model.entries.filter { !$0.isDirectory }
        let start = selected.first.flatMap { chosen in all.firstIndex { $0.url == chosen.url } } ?? 0
        return SlideshowSequence.withoutVideos(all, start: start)
    }

    /// Whether `toolStills` would hold anything, from the counts and the
    /// selection rather than a walk of the folder: menus and the toolbar
    /// validate on every event, and a folder can hold 20,000 files.
    var toolsHaveStills: Bool {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        return selected.isEmpty ? model.imageCount > model.videoCount : selected.contains { $0.kind != .video }
    }

    /// Whether `slideshowImages` would hold anything, as cheaply: two
    /// selected pictures play on their own, otherwise the folder's pictures
    /// do, wherever the show starts.
    var slideshowHasStills: Bool {
        let selectedStills = model.selectedEntries.lazy.filter { !$0.isDirectory && $0.kind != .video }
        return selectedStills.prefix(2).count >= 2 || model.imageCount > model.videoCount
    }

    /// The one image a single-image command (Set as Desktop Picture) works
    /// on: the lead of the selection, unless it is a folder. Videos count
    /// (they can be shared or opened in an editor); Set as Desktop Picture
    /// checks for them itself.
    var toolLeadImage: FolderEntry? {
        model.leadEntry.flatMap { $0.isDirectory ? nil : $0 }
    }

    /// Validation for the Tools commands; nil for any other action. Cheap,
    /// because menus validate often: counts, never a walk of the folder.
    ///
    /// The commands that open a sheet are off while one is up (a batch
    /// sheet, its progress, the print panel, an alert): the sheet is key, but
    /// the browser stays the main window, so the menu bar would still reach
    /// it and the command could only beep or queue a second sheet. Batch
    /// Rename and Convert also stay off while a batch or a copy is still
    /// running without its sheet.
    func canPerformTools(_ action: Selector) -> Bool? {
        let opensSheet: [Selector] = [.batchConvert, .batchRename, .extractPages, .createMultiPageFile, .makeImageStrip,
                                      .printImages, .makeContactSheet, .makeMontage, .exportSlideshowVideo,
                                      .createWebGallery]
        if opensSheet.contains(action), let window, BatchTools.hasSheet(on: window) { return false }
        let batches: [Selector] = [.batchConvert, .batchRename, .extractPages, .createMultiPageFile, .makeImageStrip]
        if batches.contains(action), isRunningBatch || isTransferring { return false }
        return switch action {
        case .batchRename:
            model.imageCount > 0
        // Tools of pictures: a selection of videos only leaves nothing for
        // them, as does a folder of nothing but videos (G18).
        case .startSlideshow, .exportSlideshowVideo:
            slideshowHasStills
        case .batchConvert, .extractPages, .createMultiPageFile, .makeImageStrip, .printImages, .makeContactSheet,
             .makeMontage, .createWebGallery:
            toolsHaveStills
        case .setAsDesktopPicture:
            toolLeadImage.map { $0.kind != .video } ?? false
        case .openInExternalEditor:
            toolLeadImage != nil
        case .shareFiles:
            !shareURLs.isEmpty
        case .findDuplicates:
            model.folder != nil || model.list != nil || model.hasSelectedImages
        default:
            nil
        }
    }
}
