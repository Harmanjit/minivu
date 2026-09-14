import AppKit
import MinivuCore
import MinivuRender

/// Clone stamp, healing brush and red-eye removal in the viewer (DESIGN.md
/// 4.7): the tools panel's rows and the Image menu send these. Each tool
/// opens once the original is decoded (it needs the image's pixel size),
/// shows its inspector and an overlay for pointer work, and commits one
/// operation on Apply.
extension ViewerWindowController {
    @objc func cloneStamp(_ sender: Any?) { openRetouchBrush(.clone) }
    @objc func healingBrush(_ sender: Any?) { openRetouchBrush(.heal) }
    @objc func removeRedEye(_ sender: Any?) { openRedEye() }

    /// Opens the clone stamp or healing brush; `then` runs with its state and
    /// overlay (the snapshot harness paints through it).
    func openRetouchBrush(_ mode: RetouchStroke.Mode,
                          then: ((RetouchToolState, RetouchBrushOverlayView) -> Void)? = nil) {
        if case .custom(let open)? = activeTool, let state = open as? RetouchToolState, state.mode == mode {
            if let overlay = container.canvasOverlay as? RetouchBrushOverlayView { then?(state, overlay) }
            return
        }
        whenToolCanOpen { [weak self] session, size in
            guard let self else { return }
            let state = RetouchToolState(mode: mode, document: session.document, imageSize: size)
            let overlay = RetouchBrushOverlayView(canvas: self.canvas, state: state)
            self.presentTool(state, inspector: RetouchBrushInspectorView(state: state, actions: self.inspectorActions()),
                             overlay: overlay, onViewChange: { [weak overlay] in overlay?.viewChanged() })
            self.window?.makeFirstResponder(overlay)
            then?(state, overlay)
        }
    }

    /// Opens red-eye removal; `then` runs with its state.
    func openRedEye(then: ((RedEyeToolState) -> Void)? = nil) {
        if case .custom(let open)? = activeTool, let state = open as? RedEyeToolState {
            then?(state)
            return
        }
        whenToolCanOpen { [weak self] session, size in
            guard let self else { return }
            let state = RedEyeToolState(document: session.document, imageSize: size)
            let overlay = RedEyeOverlayView(canvas: self.canvas, state: state)
            let inspector = RedEyeInspectorView(state: state, actions: self.inspectorActions(),
                                                detect: { [weak self, weak state] in
                                                    guard let self, let state else { return }
                                                    self.detectRedEyes(for: state, in: session)
                                                })
            self.presentTool(state, inspector: inspector, overlay: overlay,
                             onViewChange: { [weak overlay] in overlay?.viewChanged() })
            self.window?.makeFirstResponder(overlay)
            then?(state)
        }
    }

    /// Runs `open` with the session and the output size once the original is
    /// decoded: in this event when it already is (the tool replaces the one
    /// open now without the panel sliding), otherwise when the decode
    /// finishes, unless another tool was asked for meanwhile.
    private func whenToolCanOpen(_ open: @escaping (EditSession, CGSize) -> Void) {
        let prepared = editSessionForCurrent()?.document.outputSize != nil
        guard let session = beginOpeningTool(replacing: prepared) else { return }
        let request = toolRequest
        let body: (CGSize) -> Void = { [weak self] size in
            guard let self, self.toolRequest == request, self.editSession === session, self.activeTool == nil else {
                return
            }
            open(session, size)
        }
        if prepared, let size = session.document.outputSize {
            body(size)
        } else {
            session.whenPrepared(body)
        }
    }

    /// The Auto Detect button: faces found by Vision on a 1600 px rendering
    /// of the committed edit, off the main thread; circles added for the eyes
    /// that are red.
    private func detectRedEyes(for state: RedEyeToolState, in session: EditSession) {
        guard state.detection != .running else { return }
        state.detection = .running
        let document = session.document
        Task { [weak self, weak state] in
            do {
                let image = try await EditRenderer.shared.renderForAnalysis(document, maxPixelSize: 1600)
                let spots = await BlockingWork.run { RedEyeDetector.detect(in: image) }
                guard let self, let state, self.editSession === session else { return }
                state.addDetected(spots)
            } catch {
                state?.detection = .failed
            }
        }
    }

    // MARK: - Snapshot harness (debug only)

    #if DEBUG
    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugRetouchClone:`):
    /// opens the clone stamp and paints the strokes in `MINIVU_DEBUG_STROKES`
    /// (see `debugPaint`). No menu item or key sends it.
    @objc func debugRetouchClone(_ sender: Any?) { debugPaint(.clone) }

    /// Debug only: the same with the healing brush.
    @objc func debugRetouchHeal(_ sender: Any?) { debugPaint(.heal) }

    /// Debug only: opens red-eye removal with the circles in
    /// `MINIVU_DEBUG_SPOTS` ("x,y,radius;..." normalised, radius a fraction
    /// of the short side), or runs Auto Detect when it is unset. With
    /// `MINIVU_DEBUG_APPLY=1` the circles are applied and the tool closes.
    @objc func debugRedEye(_ sender: Any?) {
        let environment = ProcessInfo.processInfo.environment
        openRedEye { [weak self] state in
            guard let text = environment["MINIVU_DEBUG_SPOTS"] else {
                if let session = self?.editSession { self?.detectRedEyes(for: state, in: session) }
                return
            }
            for item in text.split(separator: ";") {
                let v = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard v.count == 3 else { continue }
                state.addSpot(center: CGPoint(x: v[0], y: v[1]), radius: v[2])
            }
            state.selection = nil
            if environment["MINIVU_DEBUG_APPLY"] == "1" { self?.closeTool(applying: true) }
        }
    }

    /// Debug only. Environment:
    ///     MINIVU_DEBUG_STROKES="sx,sy>x1,y1 x2,y2 ...|..."  per stroke, normalised:
    ///                                                      an Option-click, then a drag
    ///     MINIVU_DEBUG_BRUSH=120                           brush size in pixels
    ///     MINIVU_DEBUG_POINTER=x,y                         where the brush is drawn
    ///     MINIVU_DEBUG_ZOOM=x,y                            zoom to 100% centred here
    ///     MINIVU_DEBUG_LIVE=1                              leave the last stroke mid-drag
    ///     MINIVU_DEBUG_APPLY=1                             apply the strokes and close the tool
    private func debugPaint(_ mode: RetouchStroke.Mode) {
        let environment = ProcessInfo.processInfo.environment
        func point(_ text: Substring) -> CGPoint? {
            let v = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
        }
        openRetouchBrush(mode) { [weak self] state, overlay in
            guard let self else { return }
            if let size = environment["MINIVU_DEBUG_BRUSH"].flatMap(Double.init) { state.setBrushSize(size) }
            if let zoom = environment["MINIVU_DEBUG_ZOOM"].flatMap({ point(Substring($0)) }),
               let shown = self.canvas.image?.imageSize {
                let centre = CGPoint(x: zoom.x * shown.width, y: zoom.y * shown.height)
                self.canvas.applyView(ViewportTransform(zoom: 1, center: centre), mode: .actualSize)
            }
            let strokes = (environment["MINIVU_DEBUG_STROKES"] ?? "").split(separator: "|")
            let live = environment["MINIVU_DEBUG_LIVE"] == "1"
            for (index, stroke) in strokes.enumerated() {
                let parts = stroke.split(separator: ">")
                if parts.count == 2, let source = point(parts[0]) { state.setSource(source) }
                let path = (parts.last ?? "").split(separator: " ").compactMap(point)
                guard let first = path.first, state.beginStroke(at: first) else { continue }
                path.dropFirst().forEach { state.continueStroke(to: $0) }
                if !(live && index == strokes.count - 1) { state.endStroke() }
            }
            if let pointer = environment["MINIVU_DEBUG_POINTER"].flatMap({ point(Substring($0)) }) {
                overlay.movePointer(to: overlay.viewPoint(pointer))
            }
            overlay.needsDisplay = true
            if environment["MINIVU_DEBUG_APPLY"] == "1" { self.closeTool(applying: true) }
        }
    }
    #endif
}
