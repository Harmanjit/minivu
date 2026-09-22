import AppKit
import MinivuCore

/// Edit > Select Tagged and Invert Selection, which work on what the grid
/// is showing rather than on the whole folder: a filter is the user saying
/// which images they are working with, so a selection command that reached
/// past it would select images they cannot see.
extension BrowserWindowController {
    /// Whether this controller handles `action`, or nil to let the rest of
    /// the chain answer.
    func canPerformSelection(_ action: Selector) -> Bool? {
        nil
    }
}
