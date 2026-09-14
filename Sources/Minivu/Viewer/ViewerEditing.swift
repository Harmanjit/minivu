import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// The tool open in the tools panel.
enum OpenEditTool {
    case adjustment(AdjustmentToolState)
    case curves(CurvesToolState)
    case levels(LevelsToolState)
    case crop(CropToolState)
    /// Rotate & Flip or Color Effects: buttons that apply at once, no state.
    case immediate(title: String)
    /// A tool added in its own file (Phase 6 effects, drawing, retouching):
    /// any state, shown through `presentTool(_:inspector:overlay:)`.
    case custom(any EditToolState)

    var state: EditToolState? {
        switch self {
        case .adjustment(let s): s
        case .curves(let s): s
        case .levels(let s): s
        case .crop(let s): s
        case .custom(let s): s
        case .immediate: nil
        }
    }

    var title: String { state?.title ?? { if case .immediate(let title) = self { title } else { "" } }() }
    var hasPendingChanges: Bool { state?.hasPendingChanges ?? false }
}

/// What the user chose in the unsaved-changes alert.
enum UnsavedEditsChoice {
    case save, discard, cancel
}

/// Editing in the viewer (DESIGN.md 4.7 and 5): the responder-chain edit
/// commands, the tools panel's inspectors, the crop and straighten
/// overlays, undo, and what happens to unsaved edits when the user moves on.
///
/// The image on screen gets an `EditSession` the first time it is edited;
/// until then viewing costs nothing extra. One tool is open at a time. Any
/// other command (a rotate, undo, moving to another image) closes it the way
/// Cancel does, so a tool never outlives the state it was opened on.
extension ViewerWindowController: EditCanvas, ViewerEditUndoTarget {
    // MARK: - Session

    /// Whether the image on screen can be edited now: a still page that is
    /// decoded and showing. Animated files can't be (only one frame would be
    /// saved), nor can a file whose pages or frames haven't been read yet,
    /// since it might turn out to be animated.
    var canEditCurrent: Bool {
        guard !isClosing, let shown = current, displayed == shown, canvas.image != nil, errorLabel.isHidden,
              player == nil, structureRead == shown.entry else { return false }
        return true
    }

    /// The session for the image and page on screen, made on first use; nil
    /// when it can't be edited.
    func editSessionForCurrent() -> EditSession? {
        guard canEditCurrent, let shown = current else { return nil }
        if let session = editSession {
            if session.document.entry == shown.entry, session.document.page == shown.page { return session }
            endEditSession()
        }
        let session = EditSession(entry: shown.entry, page: shown.page, canvas: self)
        session.onChange = { [weak self] in self?.editDocumentChanged() }
        session.start()
        editSession = session
        return session
    }

    /// Ends the session, dropping any edits. `reloading` puts the unedited
    /// page back on the canvas (Revert); navigation doesn't need it, since
    /// the next image replaces the edited one.
    func endEditSession(reloading: Bool = false) {
        closeTool()
        guard let session = editSession else { return }
        let showedEdit = session.hasDisplayedEdit
        session.end()
        editSession = nil
        editChromeSignature = nil
        if reloading, showedEdit, !isClosing { loadCurrentPage(reloading: true) }
        updateChrome()
    }

    /// A save wrote the session's edits into the image's own file (Save, or
    /// Save As over the same file). That file is now the original, but the
    /// session still renders from the pixels decoded before the save, and
    /// anything that decodes the file again (new display settings, an
    /// original too large for one texture being exported) would apply every
    /// edit a second time, on screen and in the next save. So the session
    /// ends and the page reloads from the saved file, keeping zoom and pan:
    /// undo starts over from the saved image.
    ///
    /// Only when the document is clean with edits, the one state in which
    /// the file is known to hold exactly its operations. A save to another
    /// file leaves the document dirty, and a session with no operations wrote
    /// nothing.
    func editsWereSaved(_ session: EditSession) {
        guard editSession === session, !isClosing, !session.document.isDirty,
              !session.document.operations.isEmpty else { return }
        endEditSession()
        loadCurrentPage(reloading: true)
    }

    /// Committed edits changed (or only a preview): update the chrome, and
    /// flash the HUD when what it says about the edit changed.
    private func editDocumentChanged() {
        guard let document = editSession?.document else { return }
        let signature = "\(document.isDirty)|\(document.undoTitle ?? "")|\(document.operations.count)"
        updateChrome()
        if signature != editChromeSignature {
            let first = editChromeSignature == nil
            editChromeSignature = signature
            if !(first && !document.isDirty) { hud.flash() }
        }
    }

    // MARK: - EditCanvas

    var editPreviewPixelSize: Int { canvasPixelSize }
    var editDisplayedImageSize: CGSize? { canvas.image?.imageSize }

    func showEditedImage(_ texture: ImageTexture, preserveView: Bool) {
        guard !isClosing, let session = editSession, let shown = current,
              session.document.entry == shown.entry, session.document.page == shown.page else { return }
        // A viewer load still on its way would put the unedited page back.
        cancelLoads()
        errorLabel.isHidden = true
        displayed = shown
        canvas.setImage(texture, preserveView: preserveView)
        container.canvasOverlay?.needsDisplay = true
        updateChrome()
    }

    /// The canvas wants more pixels of an edited image: a larger preview when
    /// a fitted window outgrew it, full resolution otherwise.
    func sharpenEditedImage() {
        guard let session = editSession else { return }
        let image = canvas.image
        let textureEdge = image.map { max($0.textureSize.width, $0.textureSize.height) } ?? 0
        if canvas.zoomMode == .fit, textureEdge < CGFloat(canvasPixelSize) * 0.97 {
            session.requestPreview()
        } else {
            session.requestFullResolution()
        }
    }

    // MARK: - Undo

    var undoEditTitle: String? {
        if let steps = activeTool?.state as? EditToolSteps, let title = steps.undoStepTitle { return title }
        if let tool = activeTool, tool.hasPendingChanges { return tool.title }
        return editSession?.document.undoTitle
    }

    var redoEditTitle: String? {
        if let steps = activeTool?.state as? EditToolSteps, let title = steps.redoStepTitle { return title }
        if let tool = activeTool, tool.hasPendingChanges { return nil }
        return editSession?.document.redoTitle
    }

    /// ⌘Z with a tool showing unapplied changes takes those back (the tool
    /// closes), or only its last step for a tool that has steps of its own
    /// (`EditToolSteps`: a brush stroke); otherwise it undoes the last
    /// committed step.
    func undoEdit() {
        if let steps = activeTool?.state as? EditToolSteps, steps.undoStep() { return }
        if let tool = activeTool, tool.hasPendingChanges {
            closeTool()
            return
        }
        guard let document = editSession?.document, document.canUndo else { return }
        closeTool()
        document.undo()
    }

    func redoEdit() {
        if let steps = activeTool?.state as? EditToolSteps, steps.redoStep() { return }
        guard let document = editSession?.document, document.canRedo else { return }
        closeTool()
        document.redo()
    }

    // MARK: - Unsaved edits

    /// Asks what to do with unsaved edits, as a sheet on `window`. A static
    /// hook so tests can answer without an alert.
    static var askAboutUnsavedEdits: (_ name: String, _ window: NSWindow,
                                      _ answer: @escaping (UnsavedEditsChoice) -> Void) -> Void = { name, window, answer in
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        dontSave.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.save)
            case .alertThirdButtonReturn: answer(.discard)
            default: answer(.cancel)
            }
        }
    }

    /// Runs `proceed` once the edits of the image on screen are dealt with:
    /// at once when nothing would be lost, after Save or Don't Save when
    /// something would, and never after Cancel (or a save that didn't
    /// happen). Unapplied tool changes count, since they are on screen.
    /// `cancelled` runs instead of `proceed` when the user stays.
    func resolveUnsavedEdits(then proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard let session = editSession else {
            proceed()
            return
        }
        guard hasUnsavedEdits, let window, !isClosing else {
            endEditSession()
            proceed()
            return
        }
        // An alert or the resize sheet is already up; the user answers that first.
        guard window.attachedSheet == nil else {
            cancelled?()
            return
        }
        Self.askAboutUnsavedEdits(session.document.entry.name, window) { [weak self] choice in
            guard let self, self.editSession === session else {
                cancelled?()
                return
            }
            switch choice {
            case .cancel:
                cancelled?()
            case .discard:
                self.endEditSession()
                proceed()
            case .save:
                self.closeTool(applying: true)
                self.save(session, on: window) { [weak self] saved in
                    guard saved, let self, self.editSession === session else {
                        cancelled?()
                        return
                    }
                    self.endEditSession()
                    proceed()
                }
            }
        }
    }

    /// Edits on screen that no file has: committed ones not saved, or a
    /// tool's unapplied changes.
    var hasUnsavedEdits: Bool {
        guard let session = editSession else { return false }
        return session.document.isDirty || activeTool?.hasPendingChanges == true
    }

    /// For the app delegate's `applicationShouldTerminate`: asks about unsaved
    /// edits as navigation does, then replies whether quitting may go on
    /// (pass the answer to `NSApp.reply(toApplicationShouldTerminate:)`).
    /// Replies at once when nothing would be lost.
    func reviewUnsavedEditsBeforeQuitting(_ reply: @escaping (Bool) -> Void) {
        resolveUnsavedEdits(then: { reply(true) }, cancelled: { reply(false) })
    }

    // MARK: - Validation

    /// Whether an edit command can run now; nil for commands that aren't
    /// about editing.
    func validateEditAction(_ action: Selector?) -> Bool? {
        switch action {
        case .saveImage:
            return hasUnsavedEdits
        case .revertToSaved:
            return editSession?.document.isDirty == true
        case .saveImageAs, .rotateLeft, .rotateRight, .flipHorizontal, .flipVertical, .resizeImage, .cropImage,
             .straightenImage, .adjustLighting, .adjustColors, .adjustCurves, .adjustLevels, .sharpenImage,
             .blurImage, .applyGrayscale, .applySepia, .applyNegative,
             ViewerToolsPanel.showRotateFlipAction, ViewerToolsPanel.showColorEffectsAction:
            return canEditCurrent
        // Phase 6 tools: enabled once their file implements the action.
        case .addDropShadow, .addFrame, .applyBumpMap, .applySketch, .applyOilPaint, .applyLens,
             .drawAnnotations, .cloneStamp, .healingBrush, .removeRedEye:
            return canEditCurrent && action.map { responds(to: $0) } == true
        case .editComment:
            guard !isClosing, let entry = model.current else { return false }
            return ["jpg", "jpeg", "jpe"].contains(entry.url.pathExtension.lowercased())
        default:
            return nil
        }
    }

    // MARK: - Commands

    @objc func saveImage(_ sender: Any?) {
        guard validateEditAction(.saveImage) == true, let session = editSession, let window,
              window.attachedSheet == nil else { return }
        closeTool(applying: true)
        guard session.document.isDirty else { return }
        save(session, on: window) { [weak self] saved in
            if saved { self?.editsWereSaved(session) }
            self?.updateChrome()
        }
    }

    @objc func saveImageAs(_ sender: Any?) {
        guard canEditCurrent, let entry = current?.entry, let window, window.attachedSheet == nil else { return }
        closeTool(applying: true)
        let session = editSession
        Self.presentSaveAs(entry, session?.document, window) { [weak self] url in
            if url != nil, let session { self?.editsWereSaved(session) }
            self?.updateChrome()
        }
    }

    /// Save for `session`: over the file, unless another application has
    /// changed the file since the edits began, when it is Save As instead
    /// (asked again just before writing, since the change can arrive while
    /// "Replace the original?" is up).
    private func save(_ session: EditSession, on window: NSWindow, completion: @escaping (Bool) -> Void) {
        let entry = session.document.entry
        guard session.externalChange == .none else {
            Self.presentSaveAs(entry, session.document, window) { completion($0 != nil) }
            return
        }
        SavePresenter.save(entry: entry, document: session.document, on: window,
                           canReplace: { session.externalChange == .none }, completion: completion)
    }

    /// Shows Save As; a hook so tests can record it instead of a panel.
    static var presentSaveAs: (_ entry: FolderEntry, _ document: EditDocument?, _ window: NSWindow,
                               _ completion: @escaping (URL?) -> Void) -> Void = { entry, document, window, completion in
        SavePresenter.presentSaveAs(entry: entry, document: document, on: window, completion: completion)
    }

    @objc func revertToSaved(_ sender: Any?) {
        guard let session = editSession, session.document.isDirty, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Do you want to revert “\(session.document.entry.name)” to the saved version?"
        alert.informativeText = "Your current changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.editSession === session else { return }
            self.endEditSession(reloading: true)
        }
    }

    @objc func editComment(_ sender: Any?) {
        guard validateEditAction(.editComment) == true, let entry = model.current, let window,
              window.attachedSheet == nil else { return }
        CommentEditor.present(for: entry.url, on: window) { [weak self] _ in self?.updateChrome() }
    }

    @objc func rotateLeft(_ sender: Any?) { applyImmediately(.rotate90(turns: 3)) }
    @objc func rotateRight(_ sender: Any?) { applyImmediately(.rotate90(turns: 1)) }
    @objc func flipHorizontal(_ sender: Any?) { applyImmediately(.flip(horizontal: true)) }
    @objc func flipVertical(_ sender: Any?) { applyImmediately(.flip(horizontal: false)) }
    @objc func applyGrayscale(_ sender: Any?) { applyImmediately(.grayscale) }
    @objc func applySepia(_ sender: Any?) { applyImmediately(.sepia(intensity: 1)) }
    @objc func applyNegative(_ sender: Any?) { applyImmediately(.negative) }

    /// One undo step, applied now. The Rotate & Flip and Color Effects
    /// inspectors stay open for the next press; any other tool closes first.
    private func applyImmediately(_ operation: EditOperation) {
        guard let session = editSessionForCurrent() else {
            NSSound.beep()
            return
        }
        if let tool = activeTool, tool.state != nil { closeToolKeepingChanges() }
        session.document.apply(operation)
    }

    @objc func adjustLighting(_ sender: Any?) { openAdjustment(.lighting) }
    @objc func adjustColors(_ sender: Any?) { openAdjustment(.colors) }
    @objc func sharpenImage(_ sender: Any?) { openAdjustment(.sharpen) }
    @objc func blurImage(_ sender: Any?) { openAdjustment(.blur) }
    @objc func straightenImage(_ sender: Any?) { openAdjustment(.straighten) }

    @objc func adjustCurves(_ sender: Any?) {
        if case .curves? = activeTool { return }
        guard let session = beginOpeningTool(replacing: true) else { return }
        let state = CurvesToolState(document: session.document)
        present(.curves(state), inspector: CurvesInspectorView(state: state, actions: inspectorActions()))
        loadHistogram(for: session) { [weak state] in state?.histogram = $0 }
    }

    @objc func adjustLevels(_ sender: Any?) {
        if case .levels? = activeTool { return }
        guard let session = beginOpeningTool(replacing: true) else { return }
        let state = LevelsToolState(document: session.document)
        present(.levels(state), inspector: LevelsInspectorView(state: state, actions: inspectorActions()))
        loadHistogram(for: session) { [weak state] in state?.histogram = $0 }
    }

    @objc func cropImage(_ sender: Any?) {
        openCrop()
    }

    @objc func resizeImage(_ sender: Any?) {
        guard let session = beginOpeningTool(), let window else { return }
        let request = toolRequest
        session.whenPrepared { [weak self] size in
            guard let self, self.toolRequest == request, self.editSession === session, window.attachedSheet == nil
            else { return }
            ResizeSheet.present(size: size, on: window) { [weak self] operation in
                guard let self, self.editSession === session, let operation else { return }
                session.document.apply(operation)
            }
        }
    }

    @objc func showRotateFlipTool(_ sender: Any?) {
        if case .immediate(let title)? = activeTool, title == "Rotate & Flip" { return }
        guard beginOpeningTool(replacing: true) != nil else { return }
        let actions = [
            ImmediateAction(title: "Rotate Left", symbol: "rotate.left", action: .rotateLeft),
            ImmediateAction(title: "Rotate Right", symbol: "rotate.right", action: .rotateRight),
            ImmediateAction(title: "Flip Horizontal", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            action: .flipHorizontal),
            ImmediateAction(title: "Flip Vertical", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                            action: .flipVertical),
            ImmediateAction(title: "Straighten…", symbol: "level", action: .straightenImage),
        ]
        presentImmediate(title: "Rotate & Flip", actions: actions, footer: "Each turn or flip is one step to undo.")
    }

    @objc func showColorEffectsTool(_ sender: Any?) {
        if case .immediate(let title)? = activeTool, title == "Color Effects" { return }
        guard beginOpeningTool(replacing: true) != nil else { return }
        let actions = [
            ImmediateAction(title: "Grayscale", symbol: "circle.lefthalf.filled", action: .applyGrayscale),
            ImmediateAction(title: "Sepia", symbol: "camera.filters", action: .applySepia),
            ImmediateAction(title: "Negative", symbol: "plusminus.circle", action: .applyNegative),
        ]
        presentImmediate(title: "Color Effects", actions: actions, footer: "Effects apply to the whole image at once.")
    }

    /// The control bar's edit button: pins the tools panel open, or closes it
    /// (cancelling a tool that is open).
    @objc func toggleToolsPanel(_ sender: Any?) {
        if flyouts.isPinned(.left) {
            closeToolKeepingChanges()
            if flyouts.isPinned(.left) { flyouts.setPinned(false, edge: .left) }
        } else {
            flyouts.setPinned(true, edge: .left)
        }
        pinsChanged()
    }

    // MARK: - Tools

    private func openAdjustment(_ kind: AdjustmentKind) {
        if case .adjustment(let state)? = activeTool, state.kind == kind { return }
        guard let session = beginOpeningTool(replacing: true) else { return }
        let state = AdjustmentToolState(kind: kind, document: session.document)
        present(.adjustment(state), inspector: AdjustmentInspectorView(state: state, actions: inspectorActions()))
        if kind == .straighten {
            let grid = StraightenGridView(canvas: canvas)
            container.canvasOverlay = grid
            canvas.onViewChange = { [weak grid] in grid?.needsDisplay = true }
        }
    }

    /// Opens the crop tool once the output size is known; `then` runs with
    /// its state (the snapshot harness picks a preset through it).
    func openCrop(then: ((CropToolState) -> Void)? = nil) {
        if case .crop(let state)? = activeTool {
            then?(state)
            return
        }
        // Once the original is decoded (the usual case after any edit) the
        // tool opens in this event, in place of the one open now.
        let prepared = editSessionForCurrent()?.document.outputSize != nil
        guard let session = beginOpeningTool(replacing: prepared) else { return }
        let request = toolRequest
        let open: (CGSize) -> Void = { [weak self] size in
            guard let self, self.toolRequest == request, self.editSession === session, self.activeTool == nil else { return }
            let state = CropToolState(document: session.document, imageSize: size)
            let overlay = CropOverlayView(canvas: self.canvas, state: state)
            overlay.onApply = { [weak self] in self?.closeTool(applying: true) }
            self.present(.crop(state), inspector: CropInspectorView(state: state, actions: self.inspectorActions()))
            self.container.canvasOverlay = overlay
            self.canvas.onViewChange = { [weak overlay] in overlay?.selectionChanged() }
            then?(state)
        }
        if prepared, let size = session.document.outputSize {
            open(size)
        } else {
            session.whenPrepared(open)
        }
    }

    /// Closes any open tool and returns the session for a new one, or beeps.
    /// Each call supersedes tools still waiting for a decode.
    ///
    /// `replacing` is for a tool whose inspector shows at once: the panel
    /// stays pinned for it rather than unpinning and sliding back.
    func beginOpeningTool(replacing: Bool = false) -> EditSession? {
        guard let session = editSessionForCurrent() else {
            NSSound.beep()
            return nil
        }
        closeToolKeepingChanges(replacing: replacing)
        toolRequest += 1
        return session
    }

    func inspectorActions() -> InspectorActions {
        InspectorActions(back: { [weak self] in self?.closeTool() },
                         reset: { [weak self] in self?.activeTool?.state?.reset() },
                         cancel: { [weak self] in self?.closeTool() },
                         apply: { [weak self] in self?.closeTool(applying: true) })
    }

    private func presentImmediate(title: String, actions: [ImmediateAction], footer: String) {
        let view = ImmediateActionsInspectorView(
            title: title, actions: actions, footer: footer,
            back: { [weak self] in self?.closeTool() },
            perform: { [weak self] action in
                guard let self else { return }
                NSApp.sendAction(action, to: self, from: nil)
            })
        present(.immediate(title: title), inspector: view)
    }

    /// Shows a tool's inspector in the tools panel, pinned open and widened,
    /// with the canvas beside it and the wheel zooming.
    func present(_ tool: OpenEditTool, inspector: some View) {
        activeTool = tool
        let host = NSHostingView(rootView: inspector)
        host.sizingOptions = []
        toolsPanel.showInspector(host)
        flyouts.setThickness(ViewerToolsPanel.inspectorWidth, edge: .left)
        if !flyouts.isPinned(.left) {
            flyouts.setPinned(true, edge: .left)
            toolPinnedPanel = true
        }
        canvas.scrollingKeepsImage = true
        pinsChanged()
    }

    /// Opens a tool defined in its own file: its inspector in the tools
    /// panel and, optionally, a view over the canvas for pointer work (a
    /// brush, a lens centre, drawn objects). The overlay sits above the
    /// canvas and below the HUD and panels, exactly as the crop overlay does,
    /// and `onViewChange` runs whenever zoom or pan moves the image under it.
    /// Call after `beginOpeningTool` succeeded.
    func presentTool(_ state: any EditToolState, inspector: some View, overlay: NSView? = nil,
                     onViewChange: (() -> Void)? = nil) {
        present(.custom(state), inspector: inspector)
        container.canvasOverlay = overlay
        canvas.onViewChange = onViewChange
    }

    /// Closes the open tool: its changes committed with `applying`, dropped
    /// otherwise. The panel goes back to the list, and unpins if the tool
    /// pinned it (staying out while the pointer is over it), unless another
    /// tool is `replacing` it in the same event.
    func closeTool(applying: Bool = false, replacing: Bool = false) {
        guard let tool = activeTool else { return }
        activeTool = nil
        if applying { tool.state?.apply() } else { tool.state?.cancel() }
        container.canvasOverlay = nil
        canvas.onViewChange = nil
        guard !replacing else { return }
        canvas.scrollingKeepsImage = false
        toolsPanel.showList()
        flyouts.setThickness(ViewerToolsPanel.width, edge: .left)
        if toolPinnedPanel {
            toolPinnedPanel = false
            let pointer = window.map { container.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            flyouts.unpinKeepingOpen(.left, pointer: isClosing ? nil : pointer)
        }
        if !isClosing {
            pinsChanged()
            // The inspector's text fields may have had the keyboard.
            if let window, window.firstResponder !== canvas { window.makeFirstResponder(canvas) }
        }
    }

    /// Closes the open tool on the way to another command (a different
    /// tool, rotate, the edit button). A tool of hand-made steps (brush
    /// strokes, drawn objects) applies them first: a drawing or twenty
    /// strokes shouldn't vanish because ⌘R was pressed, and only Cancel, Esc,
    /// Back or Undo drop them. A tool of settings (sliders, an effect that
    /// previews as it opens) is cancelled, so looking through the tools
    /// doesn't stack every effect looked at; its settings take seconds to set
    /// again.
    func closeToolKeepingChanges(replacing: Bool = false) {
        let handMade = activeTool?.state is EditToolSteps && activeTool?.hasPendingChanges == true
        closeTool(applying: handMade, replacing: replacing)
    }

    /// Return applies the open tool and Esc cancels it, before the viewer's
    /// own meanings for those keys (full screen, close).
    func handleToolKey(_ event: NSEvent) -> Bool {
        guard let tool = activeTool, tool.state?.capturesKeyboard != true,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case NSCarriageReturnCharacter, NSEnterCharacter:
            closeTool(applying: true)
            return true
        case 0x1B:
            closeTool()
            return true
        default:
            return false
        }
    }

    /// A small histogram of the image for curves and levels, from its
    /// thumbnail, counted off the main thread.
    private func loadHistogram(for session: EditSession, assign: @escaping (ImageHistogram) -> Void) {
        AppServices.thumbnails.request(session.document.entry, pixelSize: 256) { image in
            guard let image else { return }
            Task {
                let histogram = await BlockingWork.run { ImageHistogram.compute(from: image) }
                if let histogram { assign(histogram) }
            }
        }
    }

    // MARK: - Snapshot harness (debug only)

    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugEditLighting:`):
    /// opens Lighting with brightness and contrast moved, as a drag would.
    /// No menu item or key sends it.
    @objc func debugEditLighting(_ sender: Any?) {
        adjustLighting(nil)
        guard case .adjustment(let state)? = activeTool else { return }
        state.setValue(0.45, section: 0, slider: 0)
        state.setValue(0.25, section: 0, slider: 1)
    }

    /// Debug only: the crop tool at 3:2, mid-drag so the grid and size show.
    @objc func debugEditCropThreeTwo(_ sender: Any?) {
        openCrop { state in
            state.setPreset(.threeTwo)
            state.update { selection in
                let r = selection.rect
                selection.setRect(r.insetBy(dx: r.width * 0.08, dy: r.height * 0.08))
            }
            state.isDragging = true
        }
    }

    /// Debug only: Curves with an S-curve on the master channel.
    @objc func debugEditCurves(_ sender: Any?) {
        adjustCurves(nil)
        guard case .curves(let state)? = activeTool else { return }
        state.setCurves(.sCurve)
        state.selectedIndex = 2
    }
}
