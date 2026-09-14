import AppKit

/// A view that can render what it currently shows into an image.
///
/// Metal-backed views can't be captured with `cacheDisplay(in:to:)` (their
/// pixels never pass through AppKit's drawing), so views that draw with
/// Metal render an offscreen copy instead. Used for snapshot tests and
/// anything else that needs a picture of the view.
protocol SnapshotProviding: NSView {
    func snapshotImage() -> CGImage?
}
