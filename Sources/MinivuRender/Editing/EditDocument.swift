import Foundation
import CoreGraphics
import MinivuCore

/// One image being edited: the file, its operation list and the undo
/// history (DESIGN.md 4.7).
///
/// Non-destructive: nothing here touches pixels. Undo and redo move a cursor
/// through the list, so they cost no memory for pixels and a re-render is
/// all they need. The decoded original and the screen proxy hang off the
/// document (`EditRenderer` puts them there), so they live exactly as long
/// as the document does, or until `EditRenderer.release`.
@MainActor public final class EditDocument {
    public let entry: FolderEntry
    public let page: Int

    /// Undo depth. Older operations stay applied; they just can't be undone
    /// any more. The list itself isn't capped, since operations are a few
    /// bytes each.
    public static let maximumUndoSteps = 50

    /// The committed operations, oldest first: the history up to the cursor.
    public private(set) var operations: [EditOperation] = []

    /// A live, uncommitted operation (an inspector slider being dragged),
    /// rendered after the committed ones. `apply` replaces it.
    public var preview: EditOperation? {
        didSet {
            guard preview != oldValue else { return }
            revision += 1
            onChange?()
        }
    }

    /// Called after any change to the operations, the preview, the undo
    /// state, the saved state or the source size.
    public var onChange: (() -> Void)?

    /// Every operation ever committed and not dropped by a later commit,
    /// including undone ones (which redo brings back).
    private var history: [EditOperation] = []
    /// `operations` is `history[..<cursor]`.
    private var cursor = 0
    /// Undo stops here (see `maximumUndoSteps`).
    private var undoFloor = 0
    private var savedOperations: [EditOperation] = []

    public init(entry: FolderEntry, page: Int = 0) {
        self.entry = entry
        self.page = page
    }

    // MARK: - Editing

    /// Commits `op` after the current operations, dropping anything that
    /// was undone (the usual redo rule), and clears `preview`, which is
    /// normally the same operation still being shown live. Identity
    /// operations are not recorded, but still clear the preview: a dialog
    /// confirmed with every slider at zero leaves nothing behind.
    public func apply(_ op: EditOperation) {
        let hadPreview = preview != nil
        if hadPreview {
            // Set without the observer's notification; one follows below.
            previewWithoutNotifying(nil)
        }
        guard !op.isIdentity else {
            if hadPreview { onChange?() }
            return
        }
        history.removeSubrange(cursor...)
        history.append(op)
        cursor = history.count
        undoFloor = max(undoFloor, cursor - Self.maximumUndoSteps)
        operationsChanged()
    }

    public func undo() {
        guard canUndo else { return }
        cursor -= 1
        operationsChanged()
    }

    public func redo() {
        guard canRedo else { return }
        cursor += 1
        operationsChanged()
    }

    public var canUndo: Bool { cursor > undoFloor }
    public var canRedo: Bool { cursor < history.count }

    /// The operation undo would remove, for "Undo Crop".
    public var undoTitle: String? { canUndo ? history[cursor - 1].title : nil }
    /// The operation redo would bring back.
    public var redoTitle: String? { canRedo ? history[cursor].title : nil }

    // MARK: - Saving

    /// True when the committed operations differ from what was last saved
    /// (or, before any save, from the untouched file). Undoing back to the
    /// saved state makes the document clean again.
    public var isDirty: Bool { operations != savedOperations }

    public func markSaved() {
        guard savedOperations != operations else { return }
        savedOperations = operations
        onChange?()
    }

    // MARK: - Sizes

    /// The oriented full-resolution size of the original, once
    /// `EditRenderer.prepare` has decoded it. (Capped at Metal's 16384 px
    /// texture limit: a larger original is edited at that size.)
    public internal(set) var sourceSize: CGSize? {
        didSet { if sourceSize != oldValue { onChange?() } }
    }

    /// The size after the committed operations and the preview.
    public var outputSize: CGSize? {
        sourceSize.map { EditGraph.outputSize(source: $0, operations: renderedOperations) }
    }

    /// What a preview render shows: the committed operations, then the
    /// live one.
    var renderedOperations: [EditOperation] {
        guard let preview, !preview.isIdentity else { return operations }
        return operations + [preview]
    }

    // MARK: - Renderer state

    /// Increases with every change to what `renderedOperations` would
    /// return, so a finished render can tell whether it still shows the
    /// current state, or at least a newer one than is already on screen.
    private(set) var revision = 0

    /// Set by `EditRenderer`; see there.
    var source: EditSource?
    var proxy: EditProxy?
    var preparation: Task<Void, Error>?
    /// Changes when the renderer releases the document, so a preparation
    /// that finishes afterwards doesn't bring the original back.
    var preparationToken = 0
    let previewLane = RenderLane()
    let fullLane = RenderLane()
    /// The newest render handed to a completion: its revision, and whether
    /// it was full resolution.
    var lastDelivered: (revision: Int, full: Bool)?

    private func operationsChanged() {
        operations = Array(history[..<cursor])
        revision += 1
        onChange?()
    }

    private func previewWithoutNotifying(_ value: EditOperation?) {
        let callback = onChange
        onChange = nil
        preview = value
        onChange = callback
    }
}

extension EditDocument {
    /// Everything `EditRenderer.renderForExport` needs, frozen, so a save can
    /// run in the background while editing goes on.
    public struct Snapshot: Sendable {
        public let url: URL
        public let page: Int
        public let kind: ImageKind?
        /// The committed operations only: a preview is never saved.
        public let operations: [EditOperation]
        public let sourceSize: CGSize?
        /// The decoded original if the document had one, so exporting doesn't
        /// decode the file a second time. Holding it keeps it alive until the
        /// export finishes, even if the document is released meanwhile.
        let source: EditSource?
        /// How to decode the file if `source` is nil (RAW files follow the
        /// viewer's settings, as in `prepare`).
        let settings: DisplaySettings
    }

    public func snapshot() -> Snapshot {
        Snapshot(url: entry.url, page: page, kind: entry.kind, operations: operations, sourceSize: sourceSize,
                 source: source, settings: ImageLoader.shared.settings)
    }
}

/// One kind of render (screen previews, or full resolution) for one
/// document: at most one running, and at most one waiting, the newest.
@MainActor final class RenderLane {
    struct Request {
        /// Long edge wanted; nil for full resolution.
        let pixelSize: Int?
        let completion: (ImageTexture) -> Void
    }

    var isRunning = false
    var pending: Request?
}
