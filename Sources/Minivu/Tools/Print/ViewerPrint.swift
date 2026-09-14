import AppKit
import MinivuCore
import MinivuRender

/// File > Print… in the viewer: the image on screen, on its page. With
/// unsaved edits it prints what the viewer shows, the edited render, not
/// the file on disk.
extension ViewerWindowController {
    @objc func printImages(_ sender: Any?) {
        guard validateToolAction(.printImages) == true, let shown = current, let window, window.attachedSheet == nil else { return }
        // As with other commands: a tool of settings is left, a drawing or
        // brush strokes are kept.
        closeToolKeepingChanges()
        let entry = shown.entry
        guard let document = editSession?.document, document.isDirty,
              document.entry == entry, document.page == shown.page else {
            let item = LayoutItem(entry: entry, page: shown.page)
            PrintPresenter.present(items: [item], title: entry.name, on: window)
            return
        }
        let snapshot = document.snapshot()
        let progress = SaveProgress(on: window, title: "Preparing “\(entry.name)” for printing…")
        Task { [weak window] in
            do {
                // Display P3 keeps the gamut the edit was made in; the
                // printing system converts to the printer's profile.
                let space = CGColorSpace(name: CGColorSpace.displayP3)!
                let image = try await EditRenderer.shared.renderForExport(snapshot, colorSpace: space, bitsPerComponent: 8)
                let url = entry.url
                let taken = await BlockingWork.run { MetadataReader.summary(for: url).dateTaken }
                progress.finish()
                guard let window, window.attachedSheet == nil else { return }
                let item = LayoutItem(image: image, name: entry.name, modified: taken ?? entry.modified)
                PrintPresenter.present(items: [item], title: entry.name, on: window)
            } catch {
                progress.finish()
                SaveAlert.show(error, title: "“\(entry.name)” couldn’t be prepared for printing.", on: window)
            }
        }
    }
}
