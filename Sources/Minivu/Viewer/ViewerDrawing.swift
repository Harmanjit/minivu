import AppKit
import MinivuCore
import MinivuRender

/// The drawing tool in the viewer (DESIGN.md 4.7 and 5): text, lines,
/// arrows, highlights, rectangles, ovals and callouts over the image, kept as
/// vectors in one `.annotations` operation.
///
/// The tool is `AnnotationToolState` (objects, selection, style, undo within
/// the tool), shown by `AnnotationOverlayView` over the canvas and
/// `AnnotationInspectorView` in the tools panel. Apply commits one step;
/// reopening the tool on an image whose last step is a drawing edits that
/// drawing again (see `AnnotationToolState`).
extension ViewerWindowController {
    /// The tools panel's Text and Shapes (and any menu item sending it). The sender's tag picks
    /// the starting tool (`AnnotationToolKind`; 0, as a plain button sends, is
    /// the selection arrow). With the tool already open it only switches tools.
    @objc func drawAnnotations(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 0
        openDrawing(tool: AnnotationToolKind(rawValue: tag) ?? .select)
    }

    /// The open drawing tool's state, if the drawing tool is open.
    var drawingToolState: AnnotationToolState? {
        if case .custom(let state)? = activeTool { return state as? AnnotationToolState }
        return nil
    }

    /// Opens the drawing tool once the output size is known; `then` runs with
    /// its state and overlay (the snapshot harness sets a scene up through it).
    func openDrawing(tool: AnnotationToolKind, then: ((AnnotationToolState, AnnotationOverlayView) -> Void)? = nil) {
        if let state = drawingToolState, let overlay = container.canvasOverlay as? AnnotationOverlayView {
            state.tool = tool
            then?(state, overlay)
            return
        }
        // Once the original is decoded (the usual case after any edit) the
        // tool opens in this event, in place of the one open now.
        let prepared = editSessionForCurrent()?.document.outputSize != nil
        guard let session = beginOpeningTool(replacing: prepared) else { return }
        let request = toolRequest
        let open: (CGSize) -> Void = { [weak self] size in
            guard let self, self.toolRequest == request, self.editSession === session, self.activeTool == nil else { return }
            let state = AnnotationToolState(document: session.document, imageSize: size, tool: tool)
            let overlay = AnnotationOverlayView(canvas: self.canvas, state: state)
            self.presentTool(state, inspector: AnnotationInspectorView(state: state, actions: self.inspectorActions()),
                             overlay: overlay, onViewChange: { [weak overlay] in overlay?.viewChanged() })
            // Delete, the arrow keys and ⌘C/⌘V reach the overlay first.
            self.window?.makeFirstResponder(overlay)
            then?(state, overlay)
        }
        if prepared, let size = session.document.outputSize {
            open(size)
        } else {
            session.whenPrepared(open)
        }
    }

    // MARK: - Snapshot harness (debug only)

    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugDrawingSample:`):
    /// opens the drawing tool with an arrow, a highlight over a rectangle, a
    /// callout with text, an oval and a line of text, the callout selected
    /// so its handles show. No menu item or key sends it.
    @objc func debugDrawingSample(_ sender: Any?) {
        openDrawing(tool: .select) { state, _ in
            Self.addDebugScene(to: state)
        }
    }

    /// Debug only: the sample at 100% around the callout, to check that text
    /// renders crisply from the full-resolution drawing.
    @objc func debugDrawingActualSize(_ sender: Any?) {
        openDrawing(tool: .select) { [weak self] state, overlay in
            Self.addDebugScene(to: state)
            guard let self, let callout = state.objects.first(where: { $0.kind == .callout }) else { return }
            let center = CGPoint(x: callout.pixelRect(in: state.imageSize).midX, y: callout.pixelRect(in: state.imageSize).midY)
            self.canvas.actualSize(at: nil)
            // Centre the callout: pan by the distance from its point to the view centre.
            let viewCenter = CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY)
            let at = center.applying(overlay.imageToView)
            self.canvas.pan(byPoints: CGSize(width: viewCenter.x - at.x, height: viewCenter.y - at.y))
        }
    }

    /// Debug only: the sample with the callout's text being typed.
    @objc func debugDrawingEditText(_ sender: Any?) {
        openDrawing(tool: .select) { state, _ in
            Self.addDebugScene(to: state)
            if let callout = state.objects.first(where: { $0.kind == .callout }) { state.beginTextEditing(callout.id) }
        }
    }

    /// Debug only: the sample with the arrow mid-drag and the text turned
    /// mid-drag, both drawn by the overlay rather than the render.
    @objc func debugDrawingLiveDrag(_ sender: Any?) {
        openDrawing(tool: .select) { state, _ in
            Self.addDebugScene(to: state)
            guard var arrow = state.objects.first(where: { $0.kind == .arrow }),
                  var text = state.objects.first(where: { $0.kind == .text }) else { return }
            state.select(arrow.id)
            state.beginLive(arrow.id)
            arrow = AnnotationGeometry.moved(arrow, by: CGSize(width: state.imageSize.width * 0.05, height: 0),
                                             in: state.imageSize)
            state.replace(arrow)
            state.beginLive(text.id)
            text.rotation = -8
            state.replace(text)
        }
    }

    /// Debug only: applies the sample and saves it through `renderForExport`
    /// to /tmp/minivu-drawing-export.png (8-bit sRGB), for checking the saved
    /// pixels against the preview.
    @objc func debugDrawingExport(_ sender: Any?) {
        openDrawing(tool: .select) { [weak self] state, _ in
            Self.addDebugScene(to: state)
            guard let self, let document = self.editSession?.document else { return }
            self.closeTool(applying: true)
            let snapshot = document.snapshot()
            Task {
                do {
                    let image = try await EditRenderer.shared.renderForExport(
                        snapshot, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8)
                    let url = URL(fileURLWithPath: "/tmp/minivu-drawing-export.png")
                    _ = SnapshotHarness.write(image, to: url)
                    FileHandle.standardError.write(Data("drawing export: \(url.path) \(image.width)x\(image.height)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("drawing export failed: \(error)\n".utf8))
                }
            }
        }
    }

    private static func addDebugScene(to state: AnnotationToolState) {
        guard state.objects.isEmpty else { return }
        var rectangle = state.newObject(.rectangle)
        rectangle.frame = CGRect(x: 0.04, y: 0.43, width: 0.36, height: 0.2)
        rectangle.strokeColor = EditColor(red: 1, green: 0.8, blue: 0)
        rectangle.dash = .dashed
        var highlight = state.newObject(.highlight)
        highlight.frame = CGRect(x: 0.07, y: 0.49, width: 0.3, height: 0.06)
        var arrow = state.newObject(.arrow)
        arrow.start = CGPoint(x: 0.5, y: 0.2)
        arrow.end = CGPoint(x: 0.36, y: 0.42)
        arrow.strokeWidth = 0.008
        arrow.shadow = true
        var callout = state.newObject(.callout)
        callout.frame = CGRect(x: 0.56, y: 0.1, width: 0.3, height: 0.12)
        callout.tailPoint = CGPoint(x: 0.66, y: 0.45)
        callout.text = "Sharp at every size"
        callout.fontSize = 0.035
        callout.shadow = true
        var oval = state.newObject(.oval)
        oval.frame = CGRect(x: 0.6, y: 0.55, width: 0.25, height: 0.3)
        oval.strokeColor = EditColor(red: 0.2, green: 0.8, blue: 1)
        oval.strokeWidth = 0.005
        var text = state.newObject(.text)
        text.frame = CGRect(x: 0.06, y: 0.8, width: 0.45, height: 0.1)
        text.text = "minivu drawing layer"
        text.fontSize = 0.045
        text.fontWeight = .bold
        text.textOutlineColor = EditColor(red: 0, green: 0, blue: 0, alpha: 0.8)
        for var object in [rectangle, highlight, arrow, callout, oval, text] {
            if object.kind.hasText { state.fitHeight(&object) }
            state.add(object)
        }
        if let calloutID = state.objects.first(where: { $0.kind == .callout })?.id { state.select(calloutID) }
    }
}
