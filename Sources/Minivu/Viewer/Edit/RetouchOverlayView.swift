import AppKit
import MinivuRender

/// What the retouch overlays share: a transparent sibling above the canvas
/// (as the crop overlay is) that takes clicks and keys, passes zoom and pan
/// on, and converts between view points and the normalised image points
/// operations store.
///
/// The overlay becomes first responder while its tool is open, so [ and ]
/// and Delete reach it before the viewer's keys; keys it doesn't use go on
/// to the viewer, so Return still applies and Esc cancels. (⌘Z reaches the
/// tool's state through the viewer's undo, `EditToolSteps`, wherever the
/// keyboard focus is.)
class RetouchOverlayView: NSView {
    weak var canvas: ImageCanvasView?

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (frame.contains(point) ? self : nil)
    }

    /// Zoom or pan moved the image under the overlay.
    func viewChanged() {
        needsDisplay = true
    }

    // MARK: - Coordinates

    /// The shown image's size; operations' normalised points are fractions of it.
    var shownSize: CGSize? {
        guard let size = canvas?.image?.imageSize, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    func viewPoint(_ normalised: CGPoint) -> CGPoint? {
        guard let canvas, let size = shownSize else { return nil }
        return canvas.viewPoint(forImagePoint: CGPoint(x: normalised.x * size.width, y: normalised.y * size.height))
    }

    func normalisedPoint(_ viewPoint: CGPoint) -> CGPoint? {
        guard let canvas, let size = shownSize else { return nil }
        let p = canvas.imagePoint(forViewPoint: viewPoint)
        return CGPoint(x: p.x / size.width, y: p.y / size.height)
    }

    func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// A length given as a fraction of the image's short side, in view points.
    func viewLength(shortSideFraction fraction: Double) -> CGFloat {
        guard let canvas, let size = shownSize else { return 0 }
        let pixels = fraction * Double(min(size.width, size.height))
        return canvas.viewRect(forImageRect: CGRect(x: 0, y: 0, width: pixels, height: pixels)).width
    }

    // MARK: - Drawing helpers

    /// A circle that shows on any image: a dark halo under a light line.
    func strokeCircle(center: CGPoint, radius: CGFloat, in context: CGContext, color: NSColor = .white,
                      dashed: Bool = false) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        context.saveGState()
        if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
        context.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1.25)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    /// A "+" with a gap in the middle, as Photoshop marks a clone source.
    func drawCrosshair(at p: CGPoint, in context: CGContext) {
        let arm: CGFloat = 9, gap: CGFloat = 2.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x - arm, y: p.y)); path.addLine(to: CGPoint(x: p.x - gap, y: p.y))
        path.move(to: CGPoint(x: p.x + gap, y: p.y)); path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - arm)); path.addLine(to: CGPoint(x: p.x, y: p.y - gap))
        path.move(to: CGPoint(x: p.x, y: p.y + gap)); path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
        context.saveGState()
        context.setLineCap(.round)
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(3.5)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Zoom and pan pass through

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.smartMagnify(with: event) }
}

/// The clone stamp and healing brush over the canvas: the brush circle
/// under the pointer, the source crosshair, and the stroke being painted.
///
/// Option-click sets the source; a drag paints. Only what moved is redrawn:
/// the brush and crosshair's old and new bounds as the pointer moves, the
/// newest segment while painting.
final class RetouchBrushOverlayView: RetouchOverlayView {
    let state: RetouchToolState
    /// The pointer in view points, while it is over the overlay.
    private(set) var pointer: CGPoint?
    private var optionDown = false
    private var trackingArea: NSTrackingArea?
    /// While a stroke is dragged, each move redraws only its new segment.
    private var painting = false

    init(canvas: ImageCanvasView, state: RetouchToolState) {
        self.state = state
        super.init(canvas: canvas)
        state.onChange = { [weak self] in
            guard let self, !self.painting else { return }
            self.needsDisplay = true
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        movePointer(to: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        movePointer(to: nil)
    }

    /// Moves the drawn brush (also used by the snapshot harness, which has
    /// no pointer).
    func movePointer(to point: CGPoint?) {
        setNeedsDisplay(decorationBounds())
        pointer = point
        setNeedsDisplay(decorationBounds())
    }

    override func flagsChanged(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        if option != optionDown {
            optionDown = option
            setNeedsDisplay(decorationBounds())
        }
        super.flagsChanged(with: event)
    }

    private var brushRadius: CGFloat { viewLength(shortSideFraction: state.radiusFraction) }

    /// Where the brush and the source crosshair are drawn now.
    private func decorationBounds() -> CGRect {
        var rect = CGRect.null
        let r = brushRadius + 4
        if let pointer { rect = rect.union(CGRect(x: pointer.x - r, y: pointer.y - r, width: 2 * r, height: 2 * r)) }
        if let source = sourceViewPoint() {
            let s = max(r, 14)
            rect = rect.union(CGRect(x: source.x - s, y: source.y - s, width: 2 * s, height: 2 * s))
        }
        return rect.isNull ? .zero : rect
    }

    /// The source for the brush where it is now: the live stroke's newest
    /// point while painting, the pointer otherwise.
    private func sourceViewPoint() -> CGPoint? {
        if let stroke = state.liveStroke, let last = stroke.points.last {
            return viewPoint(CGPoint(x: last.x + stroke.sourceOffset.dx, y: last.y + stroke.sourceOffset.dy))
        }
        let brush = pointer.flatMap { normalisedPoint($0) }
        return state.source.sourcePoint(forBrushAt: brush).flatMap { viewPoint($0) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, shownSize != nil else { return }
        let radius = brushRadius

        if let stroke = state.liveStroke {
            // The stroke so far, translucent, until the render shows the result.
            let path = CGMutablePath()
            let points = stroke.points.compactMap { viewPoint($0) }
            if let first = points.first {
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                if points.count == 1 { path.addLine(to: first) }
                context.saveGState()
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setLineWidth(2 * radius)
                context.addPath(path)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
                context.strokePath()
                context.restoreGState()
            }
        }

        if let source = sourceViewPoint() {
            strokeCircle(center: source, radius: radius, in: context, dashed: true)
            drawCrosshair(at: source, in: context)
        }

        if let pointer {
            strokeCircle(center: pointer, radius: radius, in: context)
            if optionDown {
                // Option: the next click picks the source here.
                drawCrosshair(at: pointer, in: context)
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = location(of: event)
        pointer = location
        guard let point = normalisedPoint(location) else { return }
        if event.modifierFlags.contains(.option) {
            state.setSource(point)
            return
        }
        if state.beginStroke(at: point) {
            painting = true
        } else {
            NSSound.beep()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = location(of: event)
        let before = decorationBounds()
        let lastPoint = state.liveStroke?.points.last.flatMap { viewPoint($0) }
        pointer = location
        guard let point = normalisedPoint(location) else { return }
        state.continueStroke(to: point)
        let r = brushRadius + 4
        var dirty = before.union(decorationBounds())
        if let lastPoint {
            dirty = dirty.union(CGRect(x: min(lastPoint.x, location.x) - r, y: min(lastPoint.y, location.y) - r,
                                       width: abs(lastPoint.x - location.x) + 2 * r,
                                       height: abs(lastPoint.y - location.y) + 2 * r))
        }
        setNeedsDisplay(dirty)
    }

    override func mouseUp(with event: NSEvent) {
        let location = location(of: event)
        pointer = location
        painting = false
        state.endStroke(at: normalisedPoint(location))
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "[":
            state.stepBrushSize(larger: false)
        case "]":
            state.stepBrushSize(larger: true)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Red-eye circles over the canvas. A drag draws a circle from its centre;
/// a click makes one of the default size; dragging an existing circle moves
/// it, and Delete removes the selected one.
final class RedEyeOverlayView: RetouchOverlayView {
    let state: RedEyeToolState

    private enum Drag {
        case new(center: CGPoint, start: CGPoint, current: CGPoint)
        case move(index: Int, grab: CGVector)
    }

    private var drag: Drag?
    /// A press that moves less than this many points is a click.
    static let clickDistance: CGFloat = 3

    init(canvas: ImageCanvasView, state: RedEyeToolState) {
        self.state = state
        super.init(canvas: canvas)
        state.onChange = { [weak self] in self?.needsDisplay = true }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, shownSize != nil else { return }
        for (index, spot) in state.spots.enumerated() {
            guard let centre = viewPoint(spot.center) else { continue }
            let radius = viewLength(shortSideFraction: spot.radius)
            if index == state.selection {
                let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                context.fillEllipse(in: rect)
                strokeCircle(center: centre, radius: radius, in: context, color: .controlAccentColor)
            } else {
                strokeCircle(center: centre, radius: radius, in: context)
            }
        }
        if case .new(let center, let start, let current)? = drag,
           hypot(current.x - start.x, current.y - start.y) >= Self.clickDistance,
           let centre = viewPoint(center) {
            strokeCircle(center: centre, radius: hypot(current.x - centre.x, current.y - centre.y), in: context,
                         dashed: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = location(of: event)
        guard let point = normalisedPoint(location), let size = shownSize else { return }
        // A few points of slop around a circle, in image pixels.
        let slop = Double(4 / max(viewLength(shortSideFraction: 1) / min(size.width, size.height), 1e-6))
        if let index = state.spot(at: point, slop: slop) {
            state.selection = index
            let centre = state.spots[index].center
            drag = .move(index: index, grab: CGVector(dx: centre.x - point.x, dy: centre.y - point.y))
            needsDisplay = true
        } else {
            drag = .new(center: point, start: location, current: location)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = location(of: event)
        switch drag {
        case .new(let center, let start, _)?:
            drag = .new(center: center, start: start, current: location)
            needsDisplay = true
        case .move(let index, let grab)?:
            guard let point = normalisedPoint(location) else { return }
            state.moveSpot(index, to: CGPoint(x: point.x + grab.dx, y: point.y + grab.dy))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard case .new(let center, let start, _)? = drag, let size = shownSize, let canvas else { return }
        let location = location(of: event)
        if hypot(location.x - start.x, location.y - start.y) < Self.clickDistance {
            state.addSpot(center: center, radius: RedEyeSpot.defaultRadius)
        } else {
            let a = canvas.imagePoint(forViewPoint: viewPoint(center) ?? start)
            let b = canvas.imagePoint(forViewPoint: location)
            state.addSpot(center: center, radius: Double(hypot(b.x - a.x, b.y - a.y)) / Double(min(size.width, size.height)))
        }
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           key == NSDeleteCharacter || key == NSDeleteFunctionKey || key == NSBackspaceCharacter,
           let selected = state.selection {
            state.removeSpot(selected)
            return
        }
        super.keyDown(with: event)
    }
}
