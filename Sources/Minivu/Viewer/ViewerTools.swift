import AppKit

/// Validation for the Tools commands (Phase 7) in the viewer, which works on
/// the image it shows; the slideshow plays its whole list from that image.
extension ViewerWindowController {
    /// nil for any action that isn't a Tools command. Print is off while a
    /// sheet is up, as in the browser: its panel would be a second sheet.
    /// Print and Set as Desktop Picture are for pictures, and the slideshow
    /// leaves videos out, so a list of nothing else has none to play (G18).
    func validateToolAction(_ action: Selector?) -> Bool? {
        switch action {
        case .startSlideshow: model.images.contains { $0.kind != .video } && window?.attachedSheet == nil
        case .exportSlideshowVideo: model.images.contains { $0.kind != .video } && window?.attachedSheet == nil
        case .printImages: model.current.map { $0.kind != .video } ?? false && window?.attachedSheet == nil
        case .setAsDesktopPicture: model.current.map { $0.kind != .video } ?? false
        case .openInExternalEditor: model.current != nil
        default: nil
        }
    }
}
