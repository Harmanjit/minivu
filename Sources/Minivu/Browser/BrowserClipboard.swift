import AppKit
import MinivuCore

/// Copy and Paste for images rather than for text. The Edit menu has had
/// both since the beginning, for the text fields; outside one they belong
/// to the files on the grid and to the picture in the viewer.
extension BrowserWindowController {
    /// Whether this controller handles `action`, or nil to let the rest of
    /// the chain answer.
    func canPerformClipboard(_ action: Selector) -> Bool? {
        nil
    }
}
