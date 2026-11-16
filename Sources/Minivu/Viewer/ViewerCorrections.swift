import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender

/// The G11 tools in the viewer and the watermark (DESIGN.md 4.7 and 5):
/// Auto Enhance, one click; Noise Reduction and Vignette, slider inspectors;
/// Perspective, four corners dragged on the canvas; Canvas Size, a sheet
/// like Resize; and Watermark, an inspector of text or a chosen picture.
/// Each is one undo step when applied.
extension ViewerWindowController {
    @objc func reduceNoise(_ sender: Any?) { openAdjustment(.noiseReduction) }
    @objc func addVignette(_ sender: Any?) { openAdjustment(.vignette) }
    @objc func correctPerspective(_ sender: Any?) { openPerspective() }
    @objc func addWatermark(_ sender: Any?) { openEffect(.watermark) }

    // MARK: - Auto Enhance

    /// Measures the edit as it stands (off the main thread, on a small
    /// rendering) and applies what Core Image suggests as one step. The
    /// suggestion is stored in the operation, so it renders the same at
    /// every size and after a reload. Nothing is applied if the document
    /// changed meanwhile, the viewer moved on, or the photo needs nothing
    /// (which beeps, as a command with nothing to do does).
    @objc func autoEnhance(_ sender: Any?) {
        guard autoEnhanceTask == nil else { return }
        guard let session = editSessionForCurrent() else {
            NSSound.beep()
            return
        }
        if let tool = activeTool, tool.state != nil { closeToolKeepingChanges() }
        let document = session.document
        let before = document.operations
        // The session weakly: a viewer closed meanwhile lets it go at once
        // rather than when the analysis finishes.
        autoEnhanceTask = Task { [weak self, weak session] in
            let enhance = try? await EditRenderer.shared.autoEnhancement(for: document)
            guard let self else { return }
            self.autoEnhanceTask = nil
            defer { self.updateChrome() }
            guard let session, self.editSession === session, document.operations == before, !self.isClosing
            else { return }
            guard let enhance, !enhance.isIdentity else {
                NSSound.beep()
                return
            }
            if let tool = self.activeTool, tool.state != nil { self.closeToolKeepingChanges() }
            document.apply(.autoEnhance(enhance))
        }
        updateChrome()
    }

    // MARK: - Perspective

    /// Opens the perspective tool once the size is known, with the corners
    /// at the image's own corners; `then` runs with its state.
    func openPerspective(then: ((PerspectiveToolState) -> Void)? = nil) {
        if case .custom(let open as PerspectiveToolState)? = activeTool {
            then?(open)
            return
        }
        let prepared = editSessionForCurrent()?.document.outputSize != nil
        guard let session = beginOpeningTool(replacing: prepared) else { return }
        let request = toolRequest
        let open: (CGSize) -> Void = { [weak self, weak session] _ in
            guard let self, let session, self.toolRequest == request, self.editSession === session,
                  self.activeTool == nil else { return }
            let state = PerspectiveToolState(document: session.document)
            let overlay = PerspectiveOverlayView(canvas: self.canvas, state: state)
            overlay.onApply = { [weak self] in self?.closeTool(applying: true) }
            let inspector = PerspectiveInspectorView(state: state, actions: self.inspectorActions(),
                                                     detect: { [weak self, weak state, weak session] in
                                                         guard let self, let state, let session else { return }
                                                         self.detectPerspective(for: state, in: session)
                                                     })
            self.presentTool(state, inspector: inspector, overlay: overlay,
                             onViewChange: { [weak overlay] in overlay?.needsDisplay = true })
            then?(state)
        }
        if prepared, let size = session.document.outputSize {
            open(size)
        } else {
            session.whenPrepared(open)
        }
    }

    /// The Auto button: Vision looks for the most prominent four-sided
    /// shape in a small rendering of the edit as it stands.
    func detectPerspective(for state: PerspectiveToolState, in session: EditSession) {
        guard state.detection != .running else { return }
        state.detection = .running
        let document = session.document
        Task { [weak self, weak state, weak session] in
            let image = try? await EditRenderer.shared.renderForAnalysis(document,
                                                                         maxPixelSize: EditRenderer.analysisPixelSize)
            let quad = await BlockingWork.run { image.flatMap { PerspectiveDetector.detect(in: $0) } }
            guard let self, let state, let session, self.editSession === session else { return }
            state.useDetected(quad)
        }
    }

    // MARK: - Canvas Size

    @objc func changeCanvasSize(_ sender: Any?) {
        guard let session = beginOpeningTool(), let window else { return }
        let request = toolRequest
        // The session weakly, down to the sheet's completion: a sheet ended
        // from outside (the viewer closing under it) never calls it, and the
        // sheet's views can outlive it for a while, which must not keep the
        // session and its textures.
        session.whenPrepared { [weak self, weak session] size in
            guard let self, let session, self.toolRequest == request, self.editSession === session,
                  window.attachedSheet == nil else { return }
            CanvasSizeSheet.present(size: size, on: window) { [weak self, weak session] operation in
                guard let self, let session, self.editSession === session, let operation else { return }
                session.document.apply(operation)
            }
        }
    }

    // MARK: - Watermark

    /// The watermark tool's state and inspector (from `presentEffect`).
    func presentWatermark(document: EditDocument) -> any EffectTool {
        let state = EffectToolState(kind: .watermark, document: document, initial: Watermark.starting()) { .watermark($0) }
        let inspector = WatermarkInspectorView(state: state, actions: inspectorActions(),
                                               chooseImage: { [weak self, weak state] in
                                                   guard let self, let state else { return }
                                                   self.chooseWatermarkImage(for: state)
                                               })
        presentTool(state, inspector: inspector)
        return state
    }

    /// Asks for the watermark's picture with an open panel, as a sheet. A
    /// hook so tests can hand over a file instead.
    static var askForWatermarkImage: (_ window: NSWindow, _ completion: @escaping (URL?) -> Void) -> Void = { window, completion in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = localized("Choose a picture to use as the watermark.")
        panel.prompt = localized(.init("Choose", comment: "Open panel button: use the selected picture"))
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Puts the chosen picture in the watermark, as a read-only bookmark so
    /// a saved document or preset can still render it later. Files on
    /// removable or network volumes are refused, as everywhere in minivu.
    func chooseWatermarkImage(for state: EffectToolState<Watermark>) {
        guard let window, window.attachedSheet == nil else { return }
        Self.askForWatermarkImage(window) { [weak state] url in
            guard let state, let url else { return }
            guard VolumePolicy.isAllowed(url), let bookmark = Watermark.bookmark(for: url) else {
                NSSound.beep()
                return
            }
            state.update {
                $0.kind = .image
                $0.imageBookmark = bookmark
                $0.imageName = url.lastPathComponent
            }
        }
    }

    // MARK: - Snapshot harness (debug only)

    #if DEBUG
    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugEditPerspective:`):
    /// the perspective tool with its corners pulled in as a converging
    /// facade would need. No menu item or key sends it.
    @objc func debugEditPerspective(_ sender: Any?) {
        openPerspective { state in
            state.update {
                $0.topLeft = CGPoint(x: 0.12, y: 0.08)
                $0.topRight = CGPoint(x: 0.86, y: 0.12)
                $0.bottomRight = CGPoint(x: 0.95, y: 0.92)
                $0.bottomLeft = CGPoint(x: 0.04, y: 0.95)
            }
        }
    }

    /// Debug only: a tiled text watermark.
    @objc func debugEditWatermark(_ sender: Any?) {
        openEffect(.watermark) { tool in
            (tool as? EffectToolState<Watermark>)?.update { $0.tiled = true; $0.opacity = 0.35 }
        }
    }
    #endif
}
