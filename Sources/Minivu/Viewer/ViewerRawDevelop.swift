import AppKit
import MinivuCore
import MinivuRender

/// The RAW tool in the viewer (G10): Apple's RAW engine's own settings for
/// a camera RAW file, as an inspector in the tools panel. Offered only for
/// RAW files whose camera the engine knows; one undo step when applied.
extension ViewerWindowController {
    @objc func adjustRaw(_ sender: Any?) { openRawDevelop() }

    /// Opens the RAW tool once the file is open in the RAW engine (the
    /// camera's settings are the sliders' starting point; a few hundred
    /// milliseconds the first time, nothing after); `then` runs with its
    /// state. A file the engine can't develop beeps instead.
    func openRawDevelop(then: ((RawDevelopToolState) -> Void)? = nil) {
        if case .custom(let open as RawDevelopToolState)? = activeTool {
            then?(open)
            return
        }
        guard current?.entry.kind == .raw else {
            NSSound.beep()
            return
        }
        guard let session = beginOpeningTool() else { return }
        let request = toolRequest
        let document = session.document
        // The session weakly, as the other tools that wait hold it.
        Task { [weak self, weak session] in
            let defaults = await EditRenderer.shared.rawDefaults(for: document)
            guard let self, let session, self.toolRequest == request, self.editSession === session,
                  self.activeTool == nil, !self.isClosing else { return }
            guard let defaults else {
                NSSound.beep()
                return
            }
            let state = RawDevelopToolState(document: session.document, defaults: defaults)
            self.presentTool(state, inspector: RawDevelopInspectorView(state: state, actions: self.inspectorActions()))
            then?(state)
        }
    }

    // MARK: - Snapshot harness (debug only)

    #if DEBUG
    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugEditRaw:`):
    /// the RAW tool with the exposure raised and the picture warmed. No menu
    /// item or key sends it.
    @objc func debugEditRaw(_ sender: Any?) {
        openRawDevelop { state in
            state.update {
                $0.exposure = 0.7
                $0.temperature = ($0.temperature ?? 5500) * 1.15
            }
        }
    }
    #endif
}
