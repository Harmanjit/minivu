import AppKit
import MinivuCore

/// Tools > Start Slideshow and the toolbar's Slideshow button in the browser:
/// two or more selected images play on their own; otherwise every image
/// shown plays, from the selected one (`slideshowImages`).
extension BrowserWindowController {
    @objc func startSlideshow(_ sender: Any?) {
        let (images, start) = slideshowImages
        guard !images.isEmpty else { return }
        SlideshowWindowController.start(images: images, startIndex: start, from: window) { [weak self] _ in
            guard let self, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.grid.collectionView)
        }
    }
}
