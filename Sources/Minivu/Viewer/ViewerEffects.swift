import AppKit
import SwiftUI
import MinivuRender

/// The special effects in the viewer (DESIGN.md 5): Drop Shadow, Frame,
/// Bump Map, Sketch, Oil Painting and Lens, each a slider inspector in the
/// tools panel with a live preview, and for Lens a circle on the canvas.
///
/// Every effect opens once the original is decoded (usually at once, since
/// any earlier edit decoded it), because the brush and line sizes default
/// to the photo's size; like every tool, it is one undo step when applied.
extension ViewerWindowController {
    @objc func addDropShadow(_ sender: Any?) { openEffect(.dropShadow) }
    @objc func addFrame(_ sender: Any?) { openEffect(.frame) }
    @objc func applyBumpMap(_ sender: Any?) { openEffect(.bumpMap) }
    @objc func applySketch(_ sender: Any?) { openEffect(.sketch) }
    @objc func applyOilPaint(_ sender: Any?) { openEffect(.oilPaint) }
    @objc func applyLens(_ sender: Any?) { openEffect(.lens) }

    /// The open effect tool, if one is.
    var activeEffect: (any EffectTool)? {
        if case .custom(let state)? = activeTool { return state as? any EffectTool }
        return nil
    }

    /// Opens `kind` in place of any open tool; `then` runs with its state
    /// (the snapshot harness and tests set values through it). An effect
    /// already open stays as it is.
    func openEffect(_ kind: EffectKind, then: ((any EffectTool) -> Void)? = nil) {
        if let open = activeEffect, open.kind == kind {
            then?(open)
            return
        }
        let prepared = editSessionForCurrent()?.document.outputSize != nil
        guard let session = beginOpeningTool(replacing: prepared) else { return }
        let request = toolRequest
        let open: (CGSize) -> Void = { [weak self] size in
            guard let self, self.toolRequest == request, self.editSession === session, self.activeTool == nil else { return }
            let state = self.presentEffect(kind, document: session.document, size: size)
            then?(state)
        }
        if prepared, let size = session.document.outputSize {
            open(size)
        } else {
            session.whenPrepared(open)
        }
    }

    /// Makes the tool's state (which previews its defaults at once) and shows
    /// its inspector, and for Lens its overlay.
    private func presentEffect(_ kind: EffectKind, document: EditDocument, size: CGSize) -> any EffectTool {
        let actions = inspectorActions()
        let width = Int(size.width), height = Int(size.height)
        switch kind {
        case .dropShadow:
            let state = EffectToolState(kind: kind, document: document, initial: DropShadow()) { .dropShadow($0) }
            presentTool(state, inspector: DropShadowInspectorView(state: state, actions: actions))
            return state
        case .frame:
            let state = EffectToolState(kind: kind, document: document, initial: FrameStyle()) { .frame($0) }
            presentTool(state, inspector: FrameInspectorView(state: state, actions: actions))
            return state
        case .bumpMap:
            let state = EffectToolState(kind: kind, document: document, initial: BumpMap()) { .bumpMap($0) }
            presentTool(state, inspector: BumpMapInspectorView(state: state, actions: actions))
            return state
        case .sketch:
            var initial = Sketch()
            initial.radius = Sketch.defaultRadius(width: width, height: height)
            let state = EffectToolState(kind: kind, document: document, initial: initial) { .sketch($0) }
            presentTool(state, inspector: SketchInspectorView(state: state, actions: actions))
            return state
        case .oilPaint:
            var initial = OilPaint()
            initial.radius = OilPaint.defaultRadius(width: width, height: height)
            let state = EffectToolState(kind: kind, document: document, initial: initial) { .oilPaint($0) }
            presentTool(state, inspector: OilPaintInspectorView(state: state, actions: actions))
            return state
        case .lens:
            let state = EffectToolState(kind: kind, document: document, initial: LensEffect()) { .lens($0) }
            let overlay = LensOverlayView(canvas: canvas, state: state)
            overlay.onApply = { [weak self] in self?.closeTool(applying: true) }
            presentTool(state, inspector: LensInspectorView(state: state, actions: actions), overlay: overlay,
                        onViewChange: { [weak overlay] in overlay?.viewChanged() })
            return state
        }
    }

    // MARK: - Snapshot harness (debug only)

    /// Debug only, for the snapshot harness
    /// (`MINIVU_ACTIONS=debugEffectFrameAndShadow:`): commits a matte frame,
    /// then opens Drop Shadow over it with rounded corners, so both grow the
    /// canvas. No menu item or key sends it.
    @objc func debugEffectFrameAndShadow(_ sender: Any?) {
        openEffect(.frame) { [weak self] tool in
            guard let self, let frame = tool as? EffectToolState<FrameStyle> else { return }
            frame.update { $0.kind = .matte; $0.width = 0.08 }
            self.closeTool(applying: true, replacing: true)
            self.openEffect(.dropShadow) { tool in
                (tool as? EffectToolState<DropShadow>)?.update { $0.offsetX = 0.03; $0.offsetY = 0.03; $0.blur = 0.025 }
            }
        }
    }

    /// Debug only: Sketch in colored pencil.
    @objc func debugEffectSketch(_ sender: Any?) {
        openEffect(.sketch) { tool in
            (tool as? EffectToolState<Sketch>)?.update { $0.style = .coloredPencil; $0.strength = 0.6 }
        }
    }

    /// Debug only: Oil Painting with its defaults (add `actualSize:` to the
    /// actions to see the strokes at 100%).
    @objc func debugEffectOilPaint(_ sender: Any?) {
        openEffect(.oilPaint)
    }

    /// Debug only: Bump Map at a strong setting.
    @objc func debugEffectBumpMap(_ sender: Any?) {
        openEffect(.bumpMap) { tool in
            (tool as? EffectToolState<BumpMap>)?.update { $0.strength = 2; $0.blend = 0.6 }
        }
    }

    /// Debug only: Lens off-centre with its rim.
    @objc func debugEffectLens(_ sender: Any?) {
        openEffect(.lens) { tool in
            (tool as? EffectToolState<LensEffect>)?.update {
                $0.centerX = 0.45; $0.centerY = 0.62; $0.radius = 0.22; $0.magnification = 2.2; $0.ring = true
            }
        }
    }
}
