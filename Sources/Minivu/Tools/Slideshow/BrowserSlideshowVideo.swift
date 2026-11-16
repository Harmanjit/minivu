import AppKit
import MinivuCore

/// Tools > Export Slideshow Video… in the browser: a video of the pictures
/// a slideshow would play (`slideshowImages`), in its order, with Settings >
/// Slideshow.
extension BrowserWindowController {
    @objc func exportSlideshowVideo(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let (images, start) = slideshowImages
        guard !images.isEmpty else { return }
        let controller = SlideshowVideoController(images: images, start: start,
                                                  screen: SlideshowVideoController.screenPixels(of: window),
                                                  startFolder: toolStartFolder)
        controller.begin(on: window)
    }
}
