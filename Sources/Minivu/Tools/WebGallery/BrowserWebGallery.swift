import AppKit
import MinivuCore

/// Tools > Create Web Gallery… in the browser: a gallery of the selected
/// pictures, or of every picture shown when none is selected
/// (`toolImages`), titled after the folder.
extension BrowserWindowController {
    @objc func createWebGallery(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let images = toolImages
        guard !images.isEmpty else { return }
        let title = model.folder.map { FileManager.default.displayName(atPath: $0.path) } ?? "Gallery"
        let controller = WebGalleryController(images: images, title: title, startFolder: model.folder)
        controller.begin(on: window)
    }
}
