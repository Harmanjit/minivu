import AppKit

/// Tools > Set as Desktop Picture in the browser: the lead image of the
/// selection, on the screen the browser window is on.
extension BrowserWindowController {
    @objc func setAsDesktopPicture(_ sender: Any?) {
        guard let entry = toolLeadImage, let screen = window?.screen ?? NSScreen.main else { return }
        DesktopPictureSetter.shared.run(url: entry.url, edits: nil, screen: screen, window: window)
    }
}
