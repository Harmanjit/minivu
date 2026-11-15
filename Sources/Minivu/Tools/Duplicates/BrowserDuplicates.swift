import AppKit
import MinivuCore

/// Tools > Find Duplicates… for the browser window (G5).
extension BrowserWindowController {
    /// Opens the finder pointed at what the window shows: its selected
    /// images, its folder (or the list shown instead of one) and the
    /// folder's tree.
    @objc func findDuplicates(_ sender: Any?) {
        DuplicatesWindowController.show(source: duplicateSource, browser: self)
    }

    var duplicateSource: DuplicateSource {
        DuplicateSource(selection: model.selectedEntries.filter { !$0.isDirectory }, folder: model.folder,
                        listImages: model.folder == nil ? model.entries.filter { !$0.isDirectory } : nil,
                        includeHidden: model.showHiddenFiles)
    }
}
