import AppKit
import MinivuCore
import MinivuRender

/// What an edit session shows its renders on: the viewer's canvas, behind a
/// protocol so tests can stand in for it.
protocol EditCanvas: AnyObject {
    /// Long edge of the canvas's drawable in pixels, the size previews
    /// render at.
    var editPreviewPixelSize: Int { get }
    /// `imageSize` of the texture on screen, whichever path put it there.
    var editDisplayedImageSize: CGSize? { get }
    func showEditedImage(_ texture: ImageTexture, preserveView: Bool)
    /// Puts the viewer's own texture of the page back, in place of an edit
    /// render: the edits on screen were all taken back.
    func showUneditedImage(preserveView: Bool)
}

/// The edit of one page of one image: the glue between an `EditDocument`,
/// `EditRenderer` and the canvas (DESIGN.md 4.7).
///
/// Made lazily, the first time the user edits the image on screen, so
/// viewing costs nothing. It starts decoding the original at once (a tool
/// opening is a strong hint a slider move follows), but the unedited
/// texture the viewer already shows stays up until there is an edit to
/// show, so nothing flashes while that decode runs.
///
/// Every document change with something to show asks for a preview at the
/// canvas's size. Renders coalesce in the renderer, so a slider dragged
/// faster than the GPU skips states rather than queueing them.
///
/// Nothing is rendered in place of the viewer's texture for a document with
/// nothing to show (a tool opened, or its change cancelled or undone): the
/// render would be the same picture, and an HDR photo keeps the texture the
/// viewer shows it with. Not for RAW files, whose viewer texture can be the
/// camera's preview rather than the render edits start from, nor when the
/// viewer's texture isn't the size the original decodes at (a vector), since
/// tools lay their overlays over the canvas in the document's pixels.
final class EditSession {
    let document: EditDocument
    private weak var canvas: EditCanvas?
    private let renderer: EditRenderer

    /// After every change to the document: operations, preview, saved state.
    var onChange: (() -> Void)?

    /// Another application changed the file while this session had unsaved
    /// edits (see `ViewerWindowController.reloadAfterExternalEdit`).
    enum ExternalChange {
        case none
        /// The question is up, or waits for another sheet to end.
        case asking
        /// The user kept the edits.
        case kept
    }

    /// Anything but `.none` means Save becomes Save As: writing over the
    /// file would silently replace the other application's version.
    var externalChange = ExternalChange.none

    /// The geometry-changing operations behind the texture on the canvas, or
    /// nil while the canvas still shows the viewer's unedited texture.
    private(set) var displayedGeometry: [EditOperation]?
    private var preparation: Task<Void, Error>?
    private(set) var isEnded = false
    /// The size of the viewer's texture when the session began.
    private let uneditedSize: CGSize?

    /// True while an edited render is on screen. Meanwhile the viewer's own
    /// loads (a sharper decode, a settings reload) must not replace it.
    var hasDisplayedEdit: Bool { displayedGeometry != nil }

    init(entry: FolderEntry, page: Int, canvas: EditCanvas, renderer: EditRenderer = .shared) {
        document = EditDocument(entry: entry, page: page)
        self.canvas = canvas
        self.renderer = renderer
        uneditedSize = canvas.editDisplayedImageSize
        document.onChange = { [weak self] in self?.documentChanged() }
    }

    /// Begins decoding the original in the background.
    func start() {
        guard preparation == nil, !isEnded else { return }
        let renderer = self.renderer, document = self.document
        preparation = Task { try await renderer.prepare(document) }
    }

    /// Runs `body` with the current output size once the original is
    /// decoded; never if the session ends first, or if the file can't be
    /// decoded (which beeps, since a tool was asked for). Tools that work in
    /// pixels (crop, resize) open through this.
    func whenPrepared(_ body: @escaping (CGSize) -> Void) {
        start()
        let preparation = self.preparation
        Task { [weak self] in
            _ = try? await preparation?.value
            guard let self, !self.isEnded else { return }
            guard let size = self.document.outputSize else {
                NSSound.beep()
                return
            }
            body(size)
        }
    }

    /// Stops rendering and frees the original and proxy. The document stays
    /// readable (a save may still be holding its snapshot).
    func end() {
        guard !isEnded else { return }
        isEnded = true
        document.onChange = nil
        onChange = nil
        preparation?.cancel()
        renderer.release(document)
    }

    // MARK: - Rendering

    private func documentChanged() {
        guard !isEnded else { return }
        showCurrentState()
        onChange?()
    }

    /// Puts the document as it now is on the canvas: a preview of its edits,
    /// or with none the viewer's own texture, back if an edit render replaced
    /// it.
    private func showCurrentState() {
        guard showsViewersTexture else { return requestPreview() }
        guard let geometry = displayedGeometry else { return }
        displayedGeometry = nil
        canvas?.showUneditedImage(preserveView: geometry.isEmpty)
    }

    /// Whether the viewer's own texture shows the document as it is: no
    /// operation to render (committed or live), and a file the viewer decodes
    /// as the editor does, at the size it does (see the type's documentation).
    /// Before the original is decoded its size isn't known yet; the decode's
    /// arrival asks again.
    private var showsViewersTexture: Bool {
        document.operations.isEmpty && (document.preview?.isIdentity ?? true) && document.entry.kind != .raw
            && (document.sourceSize == nil || document.sourceSize == uneditedSize)
    }

    /// A screen-sized render of the current state. `sharpening` when the
    /// canvas asked for more pixels (see `deliver`).
    func requestPreview(sharpening: Bool = false) {
        guard !isEnded else { return }
        let geometry = Self.geometry(of: document)
        let size = max(canvas?.editPreviewPixelSize ?? 0, 256)
        renderer.renderPreview(document, pixelSize: size) { [weak self] texture in
            self?.deliver(texture, geometry: geometry, sharpening: sharpening)
        }
    }

    /// A full-resolution render, for zooming past the texture on screen.
    func requestFullResolution() {
        guard !isEnded else { return }
        let geometry = Self.geometry(of: document)
        renderer.renderFullResolution(document) { [weak self] texture in
            self?.deliver(texture, geometry: geometry, sharpening: true)
        }
    }

    /// Display settings changed (RAW decoding, HDR): the original is decoded
    /// again under the new ones, and an edit render on screen rendered again
    /// from it. With no edits the viewer's own reload replaces that render.
    func reload() {
        guard !isEnded else { return }
        renderer.release(document)
        preparation = nil
        start()
        guard hasDisplayedEdit else { return }
        if showsViewersTexture { displayedGeometry = nil } else { requestPreview() }
    }

    /// Zoom and pan survive a render only when the picture's geometry is the
    /// same as the one on screen: a tone change keeps the user's view, a crop
    /// or rotation fits the new picture. The size check also covers the very
    /// first render, which replaces the viewer's texture (a RAW file's
    /// embedded preview can differ in size from the render).
    ///
    /// While the viewer's texture shows the document, a render arriving is
    /// dropped unless the canvas asked for it and it shows no edits: one of
    /// edits since taken back, or the same picture again (a render takes the
    /// document as it is when it starts, which can be after an Undo).
    private func deliver(_ texture: ImageTexture, geometry: [EditOperation], sharpening: Bool) {
        guard !isEnded, let canvas else { return }
        if showsViewersTexture, !sharpening || document.deliveredOperations?.isEmpty == false { return }
        let preserve = Self.preservesView(displayedGeometry: displayedGeometry ?? [], newGeometry: geometry,
                                          displayedSize: canvas.editDisplayedImageSize, newSize: texture.imageSize)
        displayedGeometry = geometry
        canvas.showEditedImage(texture, preserveView: preserve)
    }

    nonisolated static func preservesView(displayedGeometry: [EditOperation], newGeometry: [EditOperation],
                                          displayedSize: CGSize?, newSize: CGSize) -> Bool {
        displayedGeometry == newGeometry && displayedSize == newSize
    }

    /// The operations a render would apply that move pixels or change the
    /// size, in order: committed ones, then a live preview.
    static func geometry(of document: EditDocument) -> [EditOperation] {
        var operations = document.operations
        if let preview = document.preview, !preview.isIdentity { operations.append(preview) }
        return operations.filter { $0.changesGeometry && !$0.isIdentity }
    }
}
