import AppKit
import MinivuCore

/// Tools > Create Web Gallery… in the browser: a gallery of the selected
/// pictures, or of every picture shown when none is selected
/// (`toolStills`: videos are left out), titled after the folder.
extension BrowserWindowController {
    @objc func createWebGallery(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let images = toolStills
        guard !images.isEmpty else { return }
        let controller = WebGalleryController(images: images, title: toolTitle ?? "Gallery", startFolder: toolStartFolder)
        controller.begin(on: window)
    }
}
