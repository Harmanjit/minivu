import AppKit
import MinivuRender

/// The drawing tool over the canvas: creates objects by dragging, selects,
/// moves, resizes and turns them, and edits text in place.
///
/// **What it draws.** The canvas shows the document's preview, which the edit
/// graph renders with every object that isn't being manipulated. This view
/// draws the rest (objects being dragged or typed in) straight into its own
/// layer through the canvas's zoom and pan, with the same renderer, plus the
/// selection handles. A drag therefore costs one Core Graphics draw of one
/// object per mouse event, never a render; the view redraws only the
/// rectangles that object and the handles covered before and after.
///
/// **Handing back.** When a drag ends, the object returns to the preview,
/// which takes a render to arrive. Until the canvas shows a newer texture
/// (plus one frame, since the canvas presents on its next display refresh
/// while this view commits sooner) the view keeps drawing it, so nothing
/// blinks. A highlight drawn here is a translucent wash rather than a
/// multiply (a layer can't multiply with the Metal layer beneath it).
///
/// A sibling of the canvas with its frame, like the crop overlay: it takes
/// every click and passes scrolling and pinching on, so zoom and pan still
/// work while drawing.
final class AnnotationOverlayView: NSView, NSMenuItemValidation, NSTextViewDelegate {
    private weak var canvas: ImageCanvasView?
    let state: AnnotationToolState

    /// Handle squares, in points.
    static let handleSize: CGFloat = 8
    /// Presses this close to a handle grab it.
    static let grabDistance: CGFloat = 8
    /// How far above a box its rotation handle sits.
    static let rotateDistance: CGFloat = 24
    /// Presses this close to a thin object pick it.
    static let clickTolerance: CGFloat = 5
    /// A press must move this far before it creates an object.
    static let dragThreshold: CGFloat = 3

    private enum Drag {
        case create(anchor: CGPoint, id: UUID?)
        case move(start: Annotation, from: CGPoint, moved: Bool)
        case handle(AnnotationHandle, start: Annotation, moved: Bool)
    }

    private var drag: Drag?
    /// Where the press began, in view points.
    private var pressLocation: CGPoint = .zero

    /// Objects no longer live that the canvas may not show yet.
    private var leaving: Set<UUID> = []
    /// The canvas texture when they stopped being live.
    private weak var leavingImage: ImageTexture?
    private var leavingClearScheduled = false

    /// What was drawn where last time, to invalidate only that.
    private var drawnRects: [UUID: CGRect] = [:]
    private var chromeRect: CGRect?

    private(set) var textView: AnnotationTextView?

    init(canvas: ImageCanvasView, state: AnnotationToolState) {
        self.canvas = canvas
        self.state = state
        super.init(frame: canvas.frame)
        state.onChange = { [weak self] in self?.stateChanged() }
        state.onLiveEnded = { [weak self] ids in self?.liveEnded(ids) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Coordinates

    var imageSize: CGSize { state.imageSize }

    /// Image pixels of the output (top-left origin) to view points. The
    /// canvas's texture may report another `imageSize` (a RAW preview before
    /// the first render), so its points are scaled to the output's first.
    var imageToView: CGAffineTransform {
        guard let canvas, let shown = canvas.image?.imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return .identity
        }
        let sx = shown.width / imageSize.width, sy = shown.height / imageSize.height
        let origin = canvas.viewPoint(forImagePoint: .zero)
        let far = canvas.viewPoint(forImagePoint: CGPoint(x: 1000 * sx, y: 1000 * sy))
        return CGAffineTransform(a: (far.x - origin.x) / 1000, b: 0, c: 0, d: (far.y - origin.y) / 1000,
                                 tx: origin.x, ty: origin.y)
    }

    /// View points per image pixel.
    var pointsPerPixel: CGFloat { max(imageToView.a, 1e-6) }

    func imagePoint(forViewPoint point: CGPoint) -> CGPoint {
        point.applying(imageToView.inverted())
    }

    private func viewBounds(of a: Annotation) -> CGRect {
        a.paintedBounds(in: imageSize).applying(imageToView).insetBy(dx: -2, dy: -2)
    }

    private func chromeBounds(of a: Annotation) -> CGRect {
        let handles = AnnotationGeometry.handles(for: a, in: imageSize, rotateDistance: Self.rotateDistance / pointsPerPixel)
        let points = handles.map { $0.1.applying(imageToView) }
        var r = a.kind.isLine ? CGRect.null : a.paintedBounds(in: imageSize).applying(imageToView)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -Self.handleSize - 3, dy: -Self.handleSize - 3)
    }

    // MARK: - Changes

    /// The canvas zoomed or panned, or the texture under the view changed.
    func viewChanged() {
        needsDisplay = true
        recordDrawnRects()
        layoutTextView()
        window?.invalidateCursorRects(for: self)
    }

    private func stateChanged() {
        syncTextView()
        invalidateChangedRects()
        window?.invalidateCursorRects(for: self)
    }

    private func liveEnded(_ ids: Set<UUID>) {
        leaving.formUnion(ids)
        leavingImage = canvas?.image
        invalidateChangedRects()
        // A preview identical to the one on screen renders nothing new; don't
        // draw these twice for longer than a render could take.
        let pending = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !pending.isDisjoint(with: self.leaving) else { return }
            self.leaving.subtract(pending)
            self.invalidateChangedRects()
        }
    }

    /// The objects this view draws itself.
    private var drawnIDs: Set<UUID> { state.liveIDs.union(leaving) }

    private func currentRects() -> ([UUID: CGRect], CGRect?) {
        var rects: [UUID: CGRect] = [:]
        for id in drawnIDs {
            if let a = state.object(id) { rects[id] = viewBounds(of: a) }
        }
        return (rects, state.selected.map { chromeBounds(of: $0) })
    }

    private func recordDrawnRects() {
        (drawnRects, chromeRect) = currentRects()
    }

    private func invalidateChangedRects() {
        let (rects, chrome) = currentRects()
        for (id, rect) in rects where drawnRects[id] != rect {
            setNeedsDisplay(rect)
            if let old = drawnRects[id] { setNeedsDisplay(old) }
        }
        for (id, old) in drawnRects where rects[id] == nil { setNeedsDisplay(old) }
        if chrome != chromeRect {
            if let chromeRect { setNeedsDisplay(chromeRect) }
            if let chrome { setNeedsDisplay(chrome) }
        }
        drawnRects = rects
        chromeRect = chrome
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, canvas?.image != nil else { return }
        checkLeaving()
        let transform = imageToView
        let ids = drawnIDs
        let objects = state.objects.filter { ids.contains($0.id) && viewBounds(of: $0).intersects(dirtyRect) }
        if !objects.isEmpty {
            AnnotationRenderer.draw(objects, in: context, imageSize: imageSize, baseTransform: transform,
                                    options: AnnotationRenderer.Options(omitsTextOf: state.editingID,
                                                                        approximatesHighlights: true))
        }
        if let selected = state.selected, chromeBounds(of: selected).intersects(dirtyRect) {
            drawChrome(for: selected, in: context)
        }
    }

    /// Once the canvas shows a newer texture, objects handed back to the
    /// preview stop being drawn here, a frame later.
    private func checkLeaving() {
        guard !leaving.isEmpty, !leavingClearScheduled, let image = canvas?.image, image !== leavingImage else { return }
        leavingClearScheduled = true
        let clearing = leaving
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.leavingClearScheduled = false
            self.leaving.subtract(clearing.subtracting(self.state.liveIDs))
            self.invalidateChangedRects()
        }
    }

    private func drawChrome(for a: Annotation, in context: CGContext) {
        let transform = imageToView
        let accent = NSColor.controlAccentColor.cgColor
        context.saveGState()
        context.setLineWidth(1)
        if !a.kind.isLine {
            // The box outline, turned with the object.
            let box = a.localBox(in: imageSize)
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                .map { $0.applying(a.boxTransform(in: imageSize)).applying(transform) }
            let outline = CGMutablePath()
            outline.addLines(between: corners)
            outline.closeSubpath()
            context.addPath(outline)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(3)
            context.strokePath()
            context.addPath(outline)
            context.setStrokeColor(accent)
            context.setLineWidth(1)
            context.strokePath()
        }
        let handles = AnnotationGeometry.handles(for: a, in: imageSize, rotateDistance: Self.rotateDistance / pointsPerPixel)
        let positions = Dictionary(handles.map { ($0.0, $0.1.applying(transform)) }, uniquingKeysWith: { a, _ in a })
        if let rotate = positions[.rotate] {
            let top = CGPoint(x: 0, y: a.localBox(in: imageSize).minY)
                .applying(a.boxTransform(in: imageSize)).applying(transform)
            context.move(to: top)
            context.addLine(to: rotate)
            context.setStrokeColor(accent)
            context.strokePath()
        }
        context.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 2, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        let s = Self.handleSize
        for (handle, p) in handles.map({ ($0.0, $0.1.applying(transform)) }) {
            let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            switch handle {
            case .rotate, .start, .end:
                context.addEllipse(in: rect.insetBy(dx: -0.5, dy: -0.5))
                context.setFillColor(NSColor.white.cgColor)
                context.fillPath()
                context.addEllipse(in: rect.insetBy(dx: -0.5, dy: -0.5))
            case .tail:
                let diamond = CGMutablePath()
                diamond.addLines(between: [CGPoint(x: p.x, y: p.y - s * 0.75), CGPoint(x: p.x + s * 0.75, y: p.y),
                                           CGPoint(x: p.x, y: p.y + s * 0.75), CGPoint(x: p.x - s * 0.75, y: p.y)])
                diamond.closeSubpath()
                context.addPath(diamond)
                context.setFillColor(NSColor.systemYellow.cgColor)
                context.fillPath()
                context.addPath(diamond)
            default:
                context.addRect(rect)
                context.setFillColor(NSColor.white.cgColor)
                context.fillPath()
                context.addRect(rect)
            }
            context.saveGState()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(accent)
            context.setLineWidth(1)
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if state.editingID != nil {
            // A click outside the text being typed commits it, and does nothing else.
            state.endTextEditing()
            window?.makeFirstResponder(self)
            drag = nil
            return
        }
        window?.makeFirstResponder(self)
        guard canvas?.image != nil else { return }
        pressLocation = location
        let point = imagePoint(forViewPoint: location)
        let ppp = pointsPerPixel
        let hit = AnnotationGeometry.hitTest(state.objects, at: point, in: imageSize, tolerance: Self.clickTolerance / ppp)

        if event.clickCount == 2, let hit, state.object(hit)?.kind.hasText == true {
            drag = nil
            state.beginTextEditing(hit)
            return
        }
        if let selected = state.selected,
           let handle = AnnotationGeometry.handle(at: point, of: selected, in: imageSize,
                                                  rotateDistance: Self.rotateDistance / ppp,
                                                  tolerance: Self.grabDistance / ppp) {
            drag = .handle(handle, start: selected, moved: false)
            return
        }
        if let hit, let object = state.object(hit),
           state.tool == .select || hit == state.selectedID || object.kind == state.tool.objectKind {
            state.select(hit)
            drag = .move(start: object, from: point, moved: false)
            return
        }
        state.select(nil)
        drag = state.tool == .select ? nil : .create(anchor: clampedToImage(point), id: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = drag else { return }
        let location = convert(event.locationInWindow, from: nil)
        let point = imagePoint(forViewPoint: location)
        let constrain = event.modifierFlags.contains(.shift)
        switch current {
        case .create(let anchor, let id):
            guard let kind = state.tool.objectKind else { return }
            if id == nil, hypot(location.x - pressLocation.x, location.y - pressLocation.y) < Self.dragThreshold { return }
            let template = id.flatMap { state.object($0) } ?? state.newObject(kind)
            var a = AnnotationGeometry.created(from: template, anchor: anchor, to: clampedToImage(point), in: imageSize,
                                               constrain: constrain)
            if let id {
                a.id = id
                state.replace(a)
            } else {
                state.add(a, live: true)
                drag = .create(anchor: anchor, id: a.id)
            }
        case .move(let start, let from, let moved):
            if !moved {
                guard hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= Self.dragThreshold else { return }
                state.recordUndo("Move \(start.kind.title)")
                state.beginLive(start.id)
                drag = .move(start: start, from: from, moved: true)
            }
            var delta = CGSize(width: point.x - from.x, height: point.y - from.y)
            if constrain {
                if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
            }
            state.replace(AnnotationGeometry.moved(start, by: delta, in: imageSize))
        case .handle(let handle, let start, let moved):
            if !moved {
                state.recordUndo(handle == .rotate ? "Rotate \(start.kind.title)" : "Resize \(start.kind.title)")
                state.beginLive(start.id)
                drag = .handle(handle, start: start, moved: true)
            }
            var a = AnnotationGeometry.dragged(start, handle: handle, to: point, in: imageSize, constrain: constrain)
            if a.kind == .text, a.autoresizesHeight, handle != .rotate, handle.unit?.x != 0 {
                state.fitHeight(&a)
            }
            state.replace(a)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let current = drag else { return }
        switch current {
        case .create(_, nil):
            // A click with the text or callout tool places one and starts typing.
            guard let kind = state.tool.objectKind, kind.hasText else { return }
            var a = AnnotationGeometry.placed(from: state.newObject(kind), at: imagePoint(forViewPoint: pressLocation),
                                              in: imageSize)
            state.fitHeight(&a)
            state.add(a, live: true)
            state.beginTextEditing(a.id)
        case .create(_, let id?):
            if let a = state.object(id), a.kind.hasText {
                var fitted = a
                if fitted.autoresizesHeight { state.fitHeight(&fitted) }
                state.replace(fitted)
                state.beginTextEditing(id)
            }
            state.endLive()
        case .move(_, _, let moved), .handle(_, _, let moved):
            if moved { state.endLive() }
        }
    }

    private func clampedToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        if flags == .command, characters.lowercased() == "d" {
            if state.selectedID != nil { state.duplicateSelection() } else { NSSound.beep() }
            return
        }
        let isDelete = [NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey].contains(Int(scalar.value))
        guard flags.subtracting(.shift).isEmpty, state.selectedID != nil else {
            // The viewer reads Delete as "previous image": pressed once too
            // often after deleting an object, it would leave the image.
            if isDelete, flags.subtracting(.shift).isEmpty {
                NSSound.beep()
                return
            }
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(scalar.value) {
        case _ where isDelete:
            state.deleteSelection()
        case 0x1B:
            // Esc lets go of the selection first; with nothing selected it
            // reaches the viewer, which cancels the tool.
            state.select(nil)
        case NSLeftArrowFunctionKey: state.nudge(dx: -step, dy: 0)
        case NSRightArrowFunctionKey: state.nudge(dx: step, dy: 0)
        case NSUpArrowFunctionKey: state.nudge(dx: 0, dy: -step)
        case NSDownArrowFunctionKey: state.nudge(dx: 0, dy: step)
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { state.copySelection() }
    @objc func cut(_ sender: Any?) { state.cutSelection() }
    @objc func paste(_ sender: Any?) { state.paste() }
    @objc func delete(_ sender: Any?) { state.deleteSelection() }

    /// ⌘Z and ⇧⌘Z take back and redo the tool's own changes, before the Edit
    /// menu sees them; with none left they go on to the menu, whose Undo (like
    /// every tool's) cancels a tool with changes. Handled as key equivalents
    /// rather than as `undo:` because declaring that selector in Swift turns
    /// `ViewerWindow`'s string selectors for it into warnings.
    ///
    /// Whatever has the keyboard, except text being typed (its own typing
    /// undo comes first): the overlay loses first responder to a click on
    /// the filmstrip or a panel, and ⌘Z must not then throw the whole drawing
    /// away. Key equivalents reach every view of the key window, so this
    /// still runs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, !(window.firstResponder is NSText),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, state.undoName != nil {
            state.undo()
            return true
        }
        if flags == [.command, .shift], state.redoName != nil {
            state.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return state.selectedID != nil
        case #selector(paste(_:)):
            return !AnnotationToolState.clipboard.isEmpty
        default:
            return false
        }
    }

    // MARK: - Text editing

    /// Shows, moves or removes the text view to match `state.editingID`.
    private func syncTextView() {
        guard let id = state.editingID, state.object(id) != nil else {
            if textView != nil {
                let hadKeyboard = window?.firstResponder === textView
                removeTextView()
                if hadKeyboard { window?.makeFirstResponder(self) }
            }
            return
        }
        if textView?.objectID != id {
            removeTextView()
            let view = AnnotationTextView(objectID: id)
            view.delegate = self
            view.onCancel = { [weak self] in
                self?.state.endTextEditing()
            }
            view.string = state.object(id)?.text ?? ""
            addSubview(view)
            textView = view
            layoutTextView()
            window?.makeFirstResponder(view)
            view.selectAll(nil)
        } else {
            layoutTextView()
        }
    }

    /// The tool closed (or the viewer is switching windows) while text was
    /// being typed: its typing leaves the window's undo manager with it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, textView != nil { textView?.undoManager?.removeAllActions() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Removes the text view, and its typing from the window's undo manager:
    /// the tool records the typing as one step of its own, and the text
    /// view's entries would otherwise keep it alive and come back as "Undo
    /// Typing" into text that is no longer on screen. (Removing them by
    /// target doesn't work: AppKit registers them on private objects. The
    /// viewer window's manager holds nothing else while a tool is open.)
    private func removeTextView() {
        guard let textView else { return }
        textView.undoManager?.removeAllActions()
        textView.removeFromSuperview()
        self.textView = nil
    }

    /// Places the text view over the object's text block at the canvas's
    /// zoom, in the object's font and colour, turned with it.
    private func layoutTextView() {
        guard let textView, let a = state.object(textView.objectID) else { return }
        let ppp = pointsPerPixel
        let local = AnnotationRenderer.textRect(for: a, in: imageSize)
        let center = CGPoint(x: 0, y: 0).applying(a.boxTransform(in: imageSize)).applying(imageToView)
        let angle = CGFloat(a.kind.canRotate ? a.rotation * .pi / 180 : 0)
        let offset = CGPoint(x: local.midX * ppp, y: local.midY * ppp)
            .applying(CGAffineTransform(rotationAngle: angle))
        let size = CGSize(width: max(local.width * ppp, 4), height: max(local.height * ppp, 4))
        textView.frameCenterRotation = 0
        textView.frame = CGRect(x: center.x + offset.x - size.width / 2, y: center.y + offset.y - size.height / 2,
                                width: size.width, height: size.height)
        textView.frameCenterRotation = a.kind.canRotate ? CGFloat(a.rotation) : 0
        let font = AnnotationRenderer.font(for: a, pixelSize: a.fontPixelSize(in: imageSize) * ppp) as NSFont
        let color = NSColor(annotationColor: a.textColor)
        if textView.font != font { textView.font = font }
        if textView.textColor != color { textView.textColor = color }
        textView.insertionPointColor = color
        let alignment: NSTextAlignment = switch a.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        if textView.alignment != alignment { textView.alignment = alignment }
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        state.setText(textView.string, of: textView.objectID)
    }

    // MARK: - Cursor, zoom and pan

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: state.tool == .select ? .arrow : .crosshair)
        if let textView { addCursorRect(textView.frame, cursor: .iBeam) }
    }

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.smartMagnify(with: event) }
}

/// Typing into a text object or callout. Transparent, so the object's own
/// background and bubble (drawn by the overlay) show behind the letters.
final class AnnotationTextView: NSTextView {
    let objectID: UUID
    /// Esc ends typing (not the tool).
    var onCancel: (() -> Void)?
    /// A text view made on its own container doesn't own the text storage at
    /// the top of that stack; this does.
    private let storage = NSTextStorage()

    init(objectID: UUID) {
        self.objectID = objectID
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        objectID = UUID()
        super.init(frame: frameRect, textContainer: container)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

extension NSColor {
    /// An annotation's sRGB colour.
    convenience init(annotationColor c: EditColor) {
        self.init(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}
