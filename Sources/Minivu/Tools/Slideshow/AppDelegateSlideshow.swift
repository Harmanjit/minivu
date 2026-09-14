import AppKit

extension AppDelegate {
    #if DEBUG
    /// Debug only, for the snapshot harness: opens Settings on the Slideshow
    /// pane (`MINIVU_SNAPSHOT_WINDOW=settings MINIVU_ACTIONS=debugShowSlideshowSettings:`).
    /// The slideshow's gear button does the same through `showSettings(pane:)`.
    /// No menu item or key sends it.
    @objc func debugShowSlideshowSettings(_ sender: Any?) {
        showSettings(pane: .slideshow)
    }
    #endif
}
