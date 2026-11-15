import AppKit
import MinivuCore

/// Tools > Export Slideshow Video… in the viewer: a video of the viewer's
/// whole list from the image it shows, as its slideshow plays.
extension ViewerWindowController {
    @objc func exportSlideshowVideo(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, model.count > 0 else { return }
        let controller = SlideshowVideoController(images: model.images, start: model.index,
                                                  screen: SlideshowVideoController.screenPixels(of: window),
                                                  startFolder: model.current?.url.deletingLastPathComponent())
        controller.begin(on: window)
    }
}
