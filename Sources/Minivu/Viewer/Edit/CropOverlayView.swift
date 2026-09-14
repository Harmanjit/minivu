import AppKit
import MinivuRender

/// The crop rectangle over the canvas: the image outside it darkened,
/// corner and edge handles, a rule-of-thirds grid while dragging and the
/// size in pixels.
///
/// A sibling of the canvas with the same frame, above it and below the HUD
/// and panels. It takes every click, so a click never toggles the canvas's
/// zoom and a press never opens the magnifier, but passes scrolling and
/// pinching on, so zoom and pan still work while cropping.
///
/// The selection lives in the output image's pixels (`CropToolState`); the
/// canvas's texture may report a different `imageSize` (a RAW file's
/// embedded preview before the first edit), so points are scaled between
/// the two before going through the canvas transform.
final class CropOverlayView: NSView {
    private weak var canvas: ImageCanvasView?
    let state: CropToolState
    /// A double-click inside the rectangle crops.
    var onApply: (() -> Void)?

    /// Handles are this long along the edge, and this thick.
    static let handleLength: CGFloat = 22
    static let handleThickness: CGFloat = 4
    /// Presses this close to a handle grab it.
    static let grabDistance: CGFloat = 12

    private enum Drag {
        case handle(CropSelection.Handle, start: CGRect)
        case move(start: CGRect, from: CGPoint)
        case draw(anchor: CGPoint)
    }

    private var drag: Drag?

    init(canvas: ImageCanvasView, state: CropToolState) {
        self.canvas = canvas
        self.state = state
        super.init(frame: canvas.frame)
        state.onChange = { [weak self] in self?.selectionChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The canvas zoomed or panned, or the selection changed.
    func selectionChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Coordinates

    private var scale: CGSize {
        let output = state.selection.imageSize
        guard let shown = canvas?.image?.imageSize, output.width > 0, output.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: shown.width / output.width, height: shown.height / output.height)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        guard let canvas else { return .zero }
        let s = scale
        return canvas.viewRect(forImageRect: CGRect(x: rect.minX * s.width, y: rect.minY * s.height,
                                                    width: rect.width * s.width, height: rect.height * s.height))
    }

    private func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        guard let canvas else { return .zero }
        let p = canvas.imagePoint(forViewPoint: viewPoint)
        let s = scale
        return CGPoint(x: p.x / s.width, y: p.y / s.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, canvas?.image != nil else { return }
        let selection = viewRect(state.selection.rect)

        // Everything outside the selection, darkened.
        context.saveGState()
        context.addRect(bounds)
        context.addRect(selection)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        if state.isDragging {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(0.75)
            for i in 1...2 {
                let t = CGFloat(i) / 3
                context.move(to: CGPoint(x: selection.minX + selection.width * t, y: selection.minY))
                context.addLine(to: CGPoint(x: selection.minX + selection.width * t, y: selection.maxY))
                context.move(to: CGPoint(x: selection.minX, y: selection.minY + selection.height * t))
                context.addLine(to: CGPoint(x: selection.maxX, y: selection.minY + selection.height * t))
            }
            context.strokePath()
        }

        // A dark hairline outside the white border keeps it visible on white.
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.stroke(selection.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.stroke(selection)

        drawHandles(around: selection, in: context)
        if state.isDragging { drawSizeLabel(for: selection) }
    }

    private func drawHandles(around r: CGRect, in context: CGContext) {
        let l = min(Self.handleLength, r.width / 2, r.height / 2), t = Self.handleThickness
        var bars: [CGRect] = []
        // Corners: an L on each, drawn just outside the border.
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
            let ox = sx > 0 ? x - t : x, oy = sy > 0 ? y - t : y
            bars.append(CGRect(x: sx > 0 ? ox : x - l, y: oy, width: l + (sx > 0 ? 0 : t), height: t))
            bars.append(CGRect(x: ox, y: sy > 0 ? oy : y - l, width: t, height: l + (sy > 0 ? 0 : t)))
        }
        // Edges: a short bar at each middle.
        bars.append(CGRect(x: r.midX - l / 2, y: r.minY - t, width: l, height: t))
        bars.append(CGRect(x: r.midX - l / 2, y: r.maxY, width: l, height: t))
        bars.append(CGRect(x: r.minX - t, y: r.midY - l / 2, width: t, height: l))
        bars.append(CGRect(x: r.maxX, y: r.midY - l / 2, width: t, height: l))
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bars)
        context.restoreGState()
    }

    private func drawSizeLabel(for selection: CGRect) {
        let rect = state.selection.pixelRect
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var box = CGRect(x: selection.midX - size.width / 2 - 8, y: selection.maxY + 10,
                         width: size.width + 16, height: size.height + 6)
        if box.maxY > bounds.maxY - 4 { box.origin.y = selection.maxY - box.height - 10 }
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        path.fill()
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attributes)
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (frame.contains(point) ? self : nil)
    }

    /// The handle under a point, nearest first; corners win over edges.
    private func handle(at point: CGPoint) -> CropSelection.Handle? {
        let r = viewRect(state.selection.rect)
        let positions: [(CropSelection.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
        ]
        if let corner = positions.map({ ($0.0, hypot($0.1.x - point.x, $0.1.y - point.y)) })
            .filter({ $0.1 <= Self.grabDistance }).min(by: { $0.1 < $1.1 }) {
            return corner.0
        }
        let g = Self.grabDistance
        if point.y > r.minY + g, point.y < r.maxY - g {
            if abs(point.x - r.minX) <= g { return .left }
            if abs(point.x - r.maxX) <= g { return .right }
        }
        if point.x > r.minX + g, point.x < r.maxX - g {
            if abs(point.y - r.minY) <= g { return .top }
            if abs(point.y - r.maxY) <= g { return .bottom }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let rect = state.selection.rect
        if event.clickCount == 2, viewRect(rect).contains(location) {
            drag = nil
            onApply?()
            return
        }
        if let handle = handle(at: location) {
            drag = .handle(handle, start: rect)
        } else if viewRect(rect).contains(location) {
            drag = .move(start: rect, from: imagePoint(location))
            NSCursor.closedHand.push()
        } else {
            drag = .draw(anchor: clampedImagePoint(location))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        state.isDragging = true
        state.update { selection in
            switch drag {
            case .handle(let handle, let start):
                selection.drag(handle, of: start, to: point)
            case .move(let start, let from):
                selection.move(from: start, by: CGSize(width: point.x - from.x, height: point.y - from.y))
            case .draw(let anchor):
                selection.draw(from: anchor, to: point)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.pop() }
        drag = nil
        state.isDragging = false
        selectionChanged()
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

    private func clampedImagePoint(_ viewPoint: CGPoint) -> CGPoint {
        let p = imagePoint(viewPoint), size = state.selection.imageSize
        return CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        let r = viewRect(state.selection.rect)
        guard r.width > 0, r.height > 0 else { return }
        let g = Self.grabDistance
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(r.insetBy(dx: g, dy: g), cursor: .openHand)
        func square(_ p: CGPoint) -> CGRect { CGRect(x: p.x - g, y: p.y - g, width: 2 * g, height: 2 * g) }
        addCursorRect(CGRect(x: r.minX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)),
                      cursor: .frameResize(position: .left, directions: .all))
        addCursorRect(CGRect(x: r.maxX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)),
                      cursor: .frameResize(position: .right, directions: .all))
        addCursorRect(CGRect(x: r.minX + g, y: r.minY - g, width: max(0, r.width - 2 * g), height: 2 * g),
                      cursor: .frameResize(position: .top, directions: .all))
        addCursorRect(CGRect(x: r.minX + g, y: r.maxY - g, width: max(0, r.width - 2 * g), height: 2 * g),
                      cursor: .frameResize(position: .bottom, directions: .all))
        addCursorRect(square(CGPoint(x: r.minX, y: r.minY)), cursor: .frameResize(position: .topLeft, directions: .all))
        addCursorRect(square(CGPoint(x: r.maxX, y: r.minY)), cursor: .frameResize(position: .topRight, directions: .all))
        addCursorRect(square(CGPoint(x: r.maxX, y: r.maxY)), cursor: .frameResize(position: .bottomRight, directions: .all))
        addCursorRect(square(CGPoint(x: r.minX, y: r.maxY)), cursor: .frameResize(position: .bottomLeft, directions: .all))
    }

    // MARK: - Zoom and pan pass through

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.smartMagnify(with: event) }
}

/// The straighten tool's guide: a grid of thin lines over the image, for
/// lining a horizon or a wall up against. It takes no clicks.
final class StraightenGridView: NSView {
    private weak var canvas: ImageCanvasView?
    static let divisions = 8

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let image = canvas.image, let context = NSGraphicsContext.current?.cgContext else { return }
        let r = canvas.viewRect(forImageRect: CGRect(origin: .zero, size: image.imageSize)).intersection(bounds)
        guard !r.isNull, r.width > 0 else { return }
        // Square cells, so vertical and horizontal lines are equally dense.
        let step = max(r.width, r.height) / CGFloat(Self.divisions)
        context.setLineWidth(1)
        for pass in 0..<2 {
            context.setStrokeColor(pass == 0 ? NSColor.black.withAlphaComponent(0.25).cgColor
                                             : NSColor.white.withAlphaComponent(0.45).cgColor)
            let offset: CGFloat = pass == 0 ? 0.5 : 0
            var x = r.midX.truncatingRemainder(dividingBy: step)
            while x < r.maxX {
                if x > r.minX {
                    context.move(to: CGPoint(x: x + offset, y: r.minY))
                    context.addLine(to: CGPoint(x: x + offset, y: r.maxY))
                }
                x += step
            }
            var y = r.midY.truncatingRemainder(dividingBy: step)
            while y < r.maxY {
                if y > r.minY {
                    context.move(to: CGPoint(x: r.minX, y: y + offset))
                    context.addLine(to: CGPoint(x: r.maxX, y: y + offset))
                }
                y += step
            }
            context.strokePath()
        }
    }
}
