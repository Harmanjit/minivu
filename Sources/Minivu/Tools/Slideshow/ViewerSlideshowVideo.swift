import AppKit
import MinivuCore

/// Tools > Export Slideshow Video… in the viewer: a video of the viewer's
/// whole list from the image it shows, as its slideshow plays. Videos are
/// left out, as Start Slideshow and the browser's export leave them (G18).
extension ViewerWindowController {
    @objc func exportSlideshowVideo(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let (images, start) = SlideshowSequence.withoutVideos(model.images, start: model.index)
        guard !images.isEmpty else { return }
        let controller = SlideshowVideoController(images: images, start: start,
                                                  screen: SlideshowVideoController.screenPixels(of: window),
                                                  startFolder: model.current?.url.deletingLastPathComponent())
        controller.begin(on: window)
    }
}
