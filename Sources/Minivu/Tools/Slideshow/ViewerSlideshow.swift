import AppKit
import MinivuCore

/// Tools > Start Slideshow in the viewer: the viewer's whole list, from the
/// image it shows. When the show ends the viewer shows the last slide.
extension ViewerWindowController {
    @objc func startSlideshow(_ sender: Any?) {
        guard model.count > 0 else { return }
        SlideshowWindowController.start(images: model.images, startIndex: model.index, from: window) {
            [weak self] entry in self?.slideshowEnded(lastShown: entry)
        }
    }

    /// Moves to the slide the show ended on, through the viewer's own
    /// navigation, so unsaved edits are asked about first.
    private func slideshowEnded(lastShown entry: FolderEntry?) {
        guard !isClosing, let window else { return }
        window.makeKeyAndOrderFront(nil)
        guard let entry, let index = model.images.firstIndex(where: { $0.url == entry.url }), index != model.index
        else { return }
        showImage(at: index)
    }
}
