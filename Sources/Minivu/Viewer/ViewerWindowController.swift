import AppKit
import MinivuCore

/// PLACEHOLDER: the full-screen image viewer. Replaced by the viewer work
/// package; only the entry point below is a contract the browser relies on.
final class ViewerWindowController: NSWindowController {
    /// The viewer on screen, if any. minivu shows one viewer at a time.
    private(set) static var current: ViewerWindowController?

    /// Opens (or retargets) the viewer on `images[index]`.
    /// - Parameters:
    ///   - images: the folder's images in the browser's current order and filter.
    ///   - fullScreen: borderless full screen rather than a window.
    ///   - onClose: called with the image showing when the viewer closes, so
    ///     the browser can select it.
    static func show(images: [FolderEntry], index: Int, fullScreen: Bool,
                     onClose: @escaping (FolderEntry?) -> Void) {
        onClose(images.indices.contains(index) ? images[index] : nil)
    }
}
