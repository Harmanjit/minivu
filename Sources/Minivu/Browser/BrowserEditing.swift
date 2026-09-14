import AppKit
import MinivuCore

/// The editing commands the browser handles for its selection: lossless
/// rotate and flip, the JPEG comment, and Save As to convert a file. Opening
/// an image for real editing is the viewer's job.
extension BrowserWindowController {
    @objc func rotateLeft(_ sender: Any?) {
        transformSelection(.rotateCounterclockwise)
    }

    @objc func rotateRight(_ sender: Any?) {
        transformSelection(.rotateClockwise)
    }

    @objc func flipHorizontal(_ sender: Any?) {
        transformSelection(.flipHorizontal)
    }

    @objc func flipVertical(_ sender: Any?) {
        transformSelection(.flipVertical)
    }

    @objc func editComment(_ sender: Any?) {
        guard let window, let entry = singleSelectedImage, ExportFormat.format(for: entry.url) == .jpeg else { return }
        CommentEditor.present(for: entry.url, on: window) { [weak self] saved in
            if saved { self?.model.reload() }
        }
    }

    /// Converts the selected file: Save As with the original's pixels.
    @objc func saveImageAs(_ sender: Any?) {
        guard let window, let entry = singleSelectedImage else { return }
        SavePresenter.presentSaveAs(entry: entry, document: nil, on: window) { [weak self] url in
            // The watcher would notice a file written into this folder too;
            // listing now shows it without waiting.
            guard let self, let url, let folder = self.model.folder,
                  BrowserModel.samePath(folder, url.deletingLastPathComponent()) else { return }
            self.model.reload()
        }
    }

    /// Changes the orientation of every selected file that allows it, off
    /// the main thread, then lists the folder again so the grid, the
    /// dimensions and the preview show the files as they now are. Files that
    /// can't be transformed are skipped and reported afterwards in one alert.
    func transformSelection(_ kind: LosslessTransform.Kind) {
        let (applicable, skipped) = LosslessBatch.partition(model.selectedEntries)
        guard !applicable.isEmpty else { return NSSound.beep() }
        LosslessQueue.shared.enqueue(kind, urls: applicable, skipped: skipped) { [weak self] outcome in
            for url in outcome.transformed { BrowserModel.invalidateCaches(url) }
            guard let self else { return }
            if !outcome.transformed.isEmpty { self.model.reload() }
            if let message = LosslessBatch.message(for: outcome, kind: kind), let window = self.window {
                let alert = NSAlert()
                alert.messageText = message.title
                alert.informativeText = message.detail
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// The lead file when it is the only thing selected.
    var singleSelectedImage: FolderEntry? {
        guard model.selection.count == 1, let entry = model.leadEntry, !entry.isDirectory else { return nil }
        return entry
    }

    /// Whether an editing command applies to the selection; nil for other commands.
    func canPerformEditing(_ action: Selector) -> Bool? {
        switch action {
        case .rotateLeft, .rotateRight, .flipHorizontal, .flipVertical:
            model.selectedEntries.contains(where: LosslessBatch.isApplicable)
        case .editComment:
            singleSelectedImage.map { ExportFormat.format(for: $0.url) == .jpeg } ?? false
        case .saveImageAs:
            singleSelectedImage != nil
        default:
            nil
        }
    }
}
