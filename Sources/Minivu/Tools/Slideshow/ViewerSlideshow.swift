import AppKit
import MinivuCore

/// Tools > Start Slideshow in the viewer: the viewer's whole list, from the
/// image it shows. When the show ends the viewer shows the last slide.
extension ViewerWindowController {
    @objc func startSlideshow(_ sender: Any?) {
        guard model.count > 0 else { return }
        SlideshowWindowController.start(images: model.images, startIndex: model.index, screen: window?.screen) {
            [weak self] entry in self?.slideshowEnded(lastShown: entry)
        }
    }

    /// Moves to the slide the show ended on, as a click on it in the
    /// filmstrip would: through the viewer's own navigation, so unsaved edits
    /// are asked about first and neighbours prefetch as usual.
    private func slideshowEnded(lastShown entry: FolderEntry?) {
        guard !isClosing, let window else { return }
        window.makeKeyAndOrderFront(nil)
        guard let entry, let index = model.images.firstIndex(where: { $0.url == entry.url }), index != model.index
        else { return }
        // The filmstrip's selection handler is the viewer's one way to jump
        // to an index from outside its file; the filmstrip needn't be showing.
        filmstripView(in: container)?.onSelect?(index)
    }

    private func filmstripView(in view: NSView) -> FilmstripView? {
        for subview in view.subviews {
            if let filmstrip = subview as? FilmstripView { return filmstrip }
            if let found = filmstripView(in: subview) { return found }
        }
        return nil
    }
}
