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
}

/// The edit of one page of one image: the glue between an `EditDocument`,
/// `EditRenderer` and the canvas (DESIGN.md 4.7).
///
/// Made lazily, the first time the user edits the image on screen, so
/// viewing costs nothing. It starts decoding the original at once (a tool
/// opening is a strong hint a slider move follows), but the unedited
/// texture the viewer already shows stays up until the first edited render
/// arrives, so nothing flashes while that decode runs.
///
/// Every document change asks for a preview at the canvas's size. Renders
/// coalesce in the renderer, so a slider dragged faster than the GPU skips
/// states rather than queueing them.
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

    /// True once an edited render is on screen. From then on the viewer's
    /// own loads (a sharper decode, a settings reload) must not replace it.
    var hasDisplayedEdit: Bool { displayedGeometry != nil }

    init(entry: FolderEntry, page: Int, canvas: EditCanvas, renderer: EditRenderer = .shared) {
        document = EditDocument(entry: entry, page: page)
        self.canvas = canvas
        self.renderer = renderer
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
        requestPreview()
        onChange?()
    }

    /// A screen-sized render of the current state.
    func requestPreview() {
        guard !isEnded else { return }
        let geometry = Self.geometry(of: document)
        let size = max(canvas?.editPreviewPixelSize ?? 0, 256)
        renderer.renderPreview(document, pixelSize: size) { [weak self] texture in
            self?.deliver(texture, geometry: geometry)
        }
    }

    /// A full-resolution render, for zooming past the preview.
    func requestFullResolution() {
        guard !isEnded else { return }
        let geometry = Self.geometry(of: document)
        renderer.renderFullResolution(document) { [weak self] texture in
            self?.deliver(texture, geometry: geometry)
        }
    }

    /// Display settings changed (RAW decoding, HDR): the original is decoded
    /// again under the new ones, and the current state rendered from it.
    func reload() {
        guard !isEnded else { return }
        renderer.release(document)
        preparation = nil
        start()
        if hasDisplayedEdit { requestPreview() }
    }

    /// Zoom and pan survive a render only when the picture's geometry is the
    /// same as the one on screen: a tone change keeps the user's view, a crop
    /// or rotation fits the new picture. The size check also covers the very
    /// first render, which replaces the viewer's texture (a RAW file's
    /// embedded preview can differ in size from the render).
    private func deliver(_ texture: ImageTexture, geometry: [EditOperation]) {
        guard !isEnded, let canvas else { return }
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
