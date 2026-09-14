import AppKit

/// Validation for the Tools commands (Phase 7) in the viewer, which works on
/// the image it shows; the slideshow plays its whole list from that image.
extension ViewerWindowController {
    /// nil for any action that isn't a Tools command.
    func validateToolAction(_ action: Selector?) -> Bool? {
        switch action {
        case .startSlideshow: model.count > 0
        case .printImages, .setAsDesktopPicture, .openInExternalEditor: model.current != nil
        default: nil
        }
    }
}
