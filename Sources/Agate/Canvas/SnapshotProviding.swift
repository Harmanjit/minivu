import AppKit

/// A view whose pixels layer rendering can't capture (such as Metal content) draws itself for SnapshotHarness.
protocol SnapshotProviding: NSView { func snapshotImage() -> CGImage? }
