import AppKit
import MinivuRender

/// The lens's circle on screen, and what a press or drag does to it. Plain
/// geometry, so every drag is testable.
///
/// The lens lives in normalised image coordinates (its radius a fraction of
/// the short side), and the overlay knows only where the canvas draws the
/// image (`imageRect`, view points, top-left origin), so neither the proxy's
/// size nor the zoom enter the arithmetic.
nonisolated enum LensGeometry {
    /// A press this close to the circle (in points) grabs its edge.
    static let grabDistance: CGFloat = 8

    enum Hit: Equatable {
        case edge, inside, outside
    }

    static func center(_ lens: LensEffect, in imageRect: CGRect) -> CGPoint {
        CGPoint(x: imageRect.minX + CGFloat(lens.centerX) * imageRect.width,
                y: imageRect.minY + CGFloat(lens.centerY) * imageRect.height)
    }

    static func radius(_ lens: LensEffect, in imageRect: CGRect) -> CGFloat {
        CGFloat(lens.radius) * min(imageRect.width, imageRect.height)
    }

    static func hit(_ point: CGPoint, lens: LensEffect, in imageRect: CGRect) -> Hit {
        let c = center(lens, in: imageRect)
        let d = hypot(point.x - c.x, point.y - c.y)
        let r = radius(lens, in: imageRect)
        if abs(d - r) <= grabDistance { return .edge }
        return d < r ? .inside : .outside
    }

    /// The lens with its centre at a view point, kept on the image.
    static func moving(_ lens: LensEffect, to point: CGPoint, in imageRect: CGRect) -> LensEffect {
        guard imageRect.width > 0, imageRect.height > 0 else { return lens }
        var moved = lens
        moved.centerX = min(max(Double((point.x - imageRect.minX) / imageRect.width), 0), 1)
        moved.centerY = min(max(Double((point.y - imageRect.minY) / imageRect.height), 0), 1)
        return moved
    }

    /// The lens with its edge through a view point, within its radius range.
    static func resizing(_ lens: LensEffect, to point: CGPoint, in imageRect: CGRect) -> LensEffect {
        let short = min(imageRect.width, imageRect.height)
        guard short > 0 else { return lens }
        let c = center(lens, in: imageRect)
        var resized = lens
        let range = LensEffect.radiusRange
        resized.radius = min(max(Double(hypot(point.x - c.x, point.y - c.y) / short), range.lowerBound), range.upperBound)
        return resized
    }
}

/// The lens tool's overlay: a thin circle where the lens is, which a drag
/// inside moves and a drag on its edge resizes.
///
/// A sibling of the canvas with its frame, as `CropOverlayView` is: it takes
/// clicks (so the canvas doesn't zoom or show the magnifier) and passes
/// scrolling and pinching on. It redraws only the circle's old and new
/// bounds when the lens changes, and everything when the view zooms or pans.
final class LensOverlayView: NSView {
    private weak var canvas: ImageCanvasView?
    let state: EffectToolState<LensEffect>
    /// A double-click inside the lens applies it.
    var onApply: (() -> Void)?

    private enum Drag {
        case move(offset: CGSize)
        case resize
    }

    private var drag: Drag?
    /// The circle's bounds as last drawn, to redraw them when it moves.
    private var drawnBounds: CGRect = .null

    init(canvas: ImageCanvasView, state: EffectToolState<LensEffect>) {
        self.canvas = canvas
        self.state = state
        super.init(frame: canvas.frame)
        state.onChange = { [weak self] in self?.lensChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Where the canvas draws the image, in this view's points.
    var imageRect: CGRect? {
        guard let canvas, let image = canvas.image else { return nil }
        return canvas.viewRect(forImageRect: CGRect(origin: .zero, size: image.imageSize))
    }

    /// The canvas zoomed or panned: the whole circle moved.
    func viewChanged() {
        needsDisplay = true
        drawnBounds = .null
    }

    private func lensChanged() {
        let next = circleBounds
        if drawnBounds.isNull || next.isNull {
            needsDisplay = true
        } else {
            setNeedsDisplay(drawnBounds.union(next))
        }
        drawnBounds = next
    }

    /// Everything the circle, its knob and centre mark cover.
    private var circleBounds: CGRect {
        guard let rect = imageRect else { return .null }
        let c = LensGeometry.center(state.payload, in: rect), r = LensGeometry.radius(state.payload, in: rect)
        return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r).insetBy(dx: -8, dy: -8)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let rect = imageRect else { return }
        let lens = state.payload
        let c = LensGeometry.center(lens, in: rect), r = LensGeometry.radius(lens, in: rect)
        drawnBounds = circleBounds
        let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)

        // A dark hairline outside the white one keeps it visible on white.
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: circle.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.strokeEllipse(in: circle)

        // The centre, a small cross; and a knob on the edge that says "drag me".
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        context.move(to: CGPoint(x: c.x - 5, y: c.y))
        context.addLine(to: CGPoint(x: c.x + 5, y: c.y))
        context.move(to: CGPoint(x: c.x, y: c.y - 5))
        context.addLine(to: CGPoint(x: c.x, y: c.y + 5))
        context.strokePath()
        let knob = CGPoint(x: c.x + r * cos(.pi / 4), y: c.y + r * sin(.pi / 4))
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: knob.x - 4, y: knob.y - 4, width: 8, height: 8))
        context.restoreGState()
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let rect = imageRect else { return }
        let location = convert(event.locationInWindow, from: nil)
        let lens = state.payload
        let hit = LensGeometry.hit(location, lens: lens, in: rect)
        if event.clickCount == 2, hit != .outside {
            drag = nil
            onApply?()
            return
        }
        switch hit {
        case .edge:
            drag = .resize
        case .inside:
            let c = LensGeometry.center(lens, in: rect)
            drag = .move(offset: CGSize(width: c.x - location.x, height: c.y - location.y))
            NSCursor.closedHand.push()
        case .outside:
            // The lens jumps to the press and follows the drag.
            drag = .move(offset: .zero)
            state.update { $0 = LensGeometry.moving($0, to: location, in: rect) }
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let rect = imageRect else { return }
        let location = convert(event.locationInWindow, from: nil)
        state.update { lens in
            switch drag {
            case .move(let offset):
                lens = LensGeometry.moving(lens, to: CGPoint(x: location.x + offset.width, y: location.y + offset.height),
                                           in: rect)
            case .resize:
                lens = LensGeometry.resizing(lens, to: location, in: rect)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.pop() }
        drag = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Return or Esc can close the tool mid-drag, removing the overlay before
    /// its mouse-up: the closed hand pushed for the move comes off the
    /// cursor stack here instead of staying on it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, case .move = drag {
            NSCursor.pop()
            drag = nil
        }
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// The circle isn't a rectangle, so cursor rects can't describe it; the
    /// pointer's position picks the cursor as it moves instead.
    private func updateCursor(at point: CGPoint) {
        guard let rect = imageRect else { return }
        switch LensGeometry.hit(point, lens: state.payload, in: rect) {
        case .edge: NSCursor.crosshair.set()
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.arrow.set()
        }
    }

    // MARK: - Zoom and pan pass through

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.smartMagnify(with: event) }
}
