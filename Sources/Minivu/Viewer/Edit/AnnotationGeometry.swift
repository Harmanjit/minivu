import Foundation
import CoreGraphics
import MinivuRender

/// A grab point of the selected object.
nonisolated enum AnnotationHandle: Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// A line's endpoints.
    case start, end
    /// A callout's tail.
    case tail
    /// Above the top edge of a box that can turn.
    case rotate

    /// Where a box handle sits in the box's own coordinates, as a multiple of
    /// its half width and height: (-1, -1) is the top-left corner.
    var unit: CGPoint? {
        switch self {
        case .topLeft: CGPoint(x: -1, y: -1)
        case .top: CGPoint(x: 0, y: -1)
        case .topRight: CGPoint(x: 1, y: -1)
        case .right: CGPoint(x: 1, y: 0)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0, y: 1)
        case .bottomLeft: CGPoint(x: -1, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        case .start, .end, .tail, .rotate: nil
        }
    }

    static let boxHandles: [AnnotationHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
}

/// Hit testing, handles and the arithmetic of every drag in the drawing
/// tool, as pure functions of an object and points in image pixels (top-left
/// origin) of an image `size`, so each gesture is testable without a view.
///
/// Objects store normalised geometry (see `Annotation`); these functions
/// work in pixels, where a rotation is a real rotation and a square is
/// square, and convert back.
nonisolated enum AnnotationGeometry {
    /// Smallest side a resize leaves, in image pixels.
    static let minimumSide: CGFloat = 4

    static func normalized(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1))
    }

    static func normalized(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX / max(size.width, 1), y: r.minY / max(size.height, 1),
               width: r.width / max(size.width, 1), height: r.height / max(size.height, 1))
    }

    // MARK: - Handles

    /// The handles of `a` in image pixels. `rotateDistance` is how far above
    /// the top edge the rotation handle sits, in image pixels (the overlay
    /// keeps it a constant distance on screen).
    static func handles(for a: Annotation, in size: CGSize, rotateDistance: CGFloat) -> [(AnnotationHandle, CGPoint)] {
        if a.kind.isLine {
            return [(.start, a.pixelPoint(a.start, in: size)), (.end, a.pixelPoint(a.end, in: size))]
        }
        let t = a.boxTransform(in: size)
        let box = a.localBox(in: size)
        var result = AnnotationHandle.boxHandles.map { handle -> (AnnotationHandle, CGPoint) in
            let u = handle.unit!
            return (handle, CGPoint(x: u.x * box.width / 2, y: u.y * box.height / 2).applying(t))
        }
        if a.kind == .callout {
            result.append((.tail, a.pixelPoint(a.tailPoint, in: size)))
        }
        if a.kind.canRotate {
            result.append((.rotate, CGPoint(x: 0, y: box.minY - rotateDistance).applying(t)))
        }
        return result
    }

    /// The handle within `tolerance` of `point`, nearest first.
    static func handle(at point: CGPoint, of a: Annotation, in size: CGSize, rotateDistance: CGFloat,
                       tolerance: CGFloat) -> AnnotationHandle? {
        handles(for: a, in: size, rotateDistance: rotateDistance)
            .map { ($0.0, hypot($0.1.x - point.x, $0.1.y - point.y)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Hit testing

    /// The topmost object under `point` (the last in the list wins).
    static func hitTest(_ objects: [Annotation], at point: CGPoint, in size: CGSize, tolerance: CGFloat) -> UUID? {
        objects.last { contains($0, point: point, in: size, tolerance: tolerance) }?.id
    }

    /// Whether a click at `point` picks `a`. Filled shapes, text, callouts and
    /// highlights are picked anywhere inside; an outline-only rectangle or
    /// oval and a line only near their stroke, so the picture inside a
    /// frame stays clickable for what lies under it.
    static func contains(_ a: Annotation, point: CGPoint, in size: CGSize, tolerance: CGFloat) -> Bool {
        let halfStroke = a.strokePixelWidth(in: size) / 2
        if a.kind.isLine {
            let p = a.pixelPoint(a.start, in: size), q = a.pixelPoint(a.end, in: size)
            let reach = tolerance + max(halfStroke, a.arrowheads == .none ? 0 : AnnotationRenderer.arrowheadLength(a, in: size) / 2)
            return distance(from: point, toSegment: p, q) <= reach
        }
        let local = point.applying(a.boxTransform(in: size).inverted())
        let box = a.localBox(in: size)
        let a2 = box.width / 2, b2 = box.height / 2
        let filled = a.fillColor.alpha > 0 || a.kind == .text || a.kind == .callout || a.kind == .highlight
        if a.kind == .callout, !box.contains(local) {
            let tail = a.pixelPoint(a.tailPoint, in: size)
            let center = CGPoint(x: 0, y: 0).applying(a.boxTransform(in: size))
            if distance(from: point, toSegment: center, tail) <= tolerance + min(box.width, box.height) * 0.15 {
                return true
            }
        }
        switch a.kind {
        case .oval:
            guard a2 > 0, b2 > 0 else { return false }
            let r = hypot(local.x / a2, local.y / b2)
            if filled && r <= 1 { return true }
            return abs(r - 1) * min(a2, b2) <= tolerance + halfStroke
        default:
            let outer = box.insetBy(dx: -(tolerance + halfStroke), dy: -(tolerance + halfStroke))
            guard outer.contains(local) else { return false }
            if filled { return true }
            let inner = box.insetBy(dx: tolerance + halfStroke, dy: tolerance + halfStroke)
            return inner.isNull || inner.width <= 0 || inner.height <= 0 || !inner.contains(local)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Dragging

    /// `a` moved by `delta` image pixels.
    static func moved(_ a: Annotation, by delta: CGSize, in size: CGSize) -> Annotation {
        let n = CGSize(width: delta.width / max(size.width, 1), height: delta.height / max(size.height, 1))
        var b = a
        b.frame = a.frame.offsetBy(dx: n.width, dy: n.height)
        b.start = CGPoint(x: a.start.x + n.width, y: a.start.y + n.height)
        b.end = CGPoint(x: a.end.x + n.width, y: a.end.y + n.height)
        b.tailPoint = CGPoint(x: a.tailPoint.x + n.width, y: a.tailPoint.y + n.height)
        return b
    }

    /// `point` moved to the nearest 45° direction from `origin`, keeping its
    /// distance along that direction.
    static func constrained45(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy) * cos(atan2(dy, dx) - angle)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Drags `handle` of `start` (the object as it was when the drag began) to
    /// `point`. Box handles resize about the opposite handle along the box's
    /// own (possibly turned) axes, never flipping past it; `constrain` keeps
    /// the proportions from a corner. Line endpoints move freely, or at 45°
    /// steps from the other end with `constrain`. The tail follows the
    /// pointer; the rotation handle turns about the centre, in 15° steps with
    /// `constrain`.
    static func dragged(_ start: Annotation, handle: AnnotationHandle, to point: CGPoint, in size: CGSize,
                        constrain: Bool) -> Annotation {
        var a = start
        switch handle {
        case .start, .end:
            let other = a.pixelPoint(handle == .start ? start.end : start.start, in: size)
            let p = constrain ? constrained45(point, from: other) : point
            if handle == .start { a.start = normalized(p, in: size) } else { a.end = normalized(p, in: size) }
        case .tail:
            a.tailPoint = normalized(point, in: size)
        case .rotate:
            let center = CGPoint(x: 0, y: 0).applying(start.boxTransform(in: size))
            var degrees = atan2(point.y - center.y, point.x - center.x) * 180 / .pi + 90
            if constrain { degrees = (degrees / 15).rounded() * 15 }
            degrees = degrees.truncatingRemainder(dividingBy: 360)
            if degrees > 180 { degrees -= 360 }
            if degrees <= -180 { degrees += 360 }
            a.rotation = abs(degrees) < 1e-9 ? 0 : degrees
        default:
            a.frame = resizedFrame(start, handle: handle, to: point, in: size, keepAspect: constrain)
        }
        return a
    }

    private static func resizedFrame(_ start: Annotation, handle: AnnotationHandle, to point: CGPoint, in size: CGSize,
                                     keepAspect: Bool) -> CGRect {
        guard let u = handle.unit else { return start.frame }
        let t = start.boxTransform(in: size)
        let box = start.localBox(in: size)
        let w0 = max(box.width, minimumSide), h0 = max(box.height, minimumSide)
        // The fixed point: the opposite handle (for an edge, the middle of the
        // opposite edge), in the box's coordinates and in the image.
        let anchorLocal = CGPoint(x: -u.x * box.width / 2, y: -u.y * box.height / 2)
        let anchor = anchorLocal.applying(t)
        // The pointer relative to the anchor, along the box's own axes.
        let rotation = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
        let q = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y).applying(rotation.inverted())
        var w = u.x != 0 ? max(q.x * u.x, minimumSide) : box.width
        var h = u.y != 0 ? max(q.y * u.y, minimumSide) : box.height
        if keepAspect, u.x != 0, u.y != 0 {
            let scale = max(w / w0, h / h0)
            w = w0 * scale
            h = h0 * scale
        }
        // The new centre, from the anchor along the box's axes.
        let offset = CGPoint(x: u.x * w / 2, y: u.y * h / 2).applying(rotation)
        let center = CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)
        return normalized(CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), in: size)
    }

    // MARK: - Creating

    /// An object drawn by dragging from `anchor` to `point` with `template`'s
    /// kind and style. `constrain` makes boxes square (ovals circles) and
    /// lines 45°. A callout's tail starts below its bubble's left side, and
    /// text starts one line tall (the tool fits its height to the text).
    static func created(from template: Annotation, anchor: CGPoint, to point: CGPoint, in size: CGSize,
                        constrain: Bool) -> Annotation {
        var a = template
        if a.kind.isLine {
            a.start = normalized(anchor, in: size)
            a.end = normalized(constrain ? constrained45(point, from: anchor) : point, in: size)
            return a
        }
        var dx = point.x - anchor.x, dy = point.y - anchor.y
        if constrain {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect = CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
        a.frame = normalized(rect, in: size)
        a.rotation = 0
        if a.kind == .callout {
            let tail = CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY + max(rect.height * 0.6, 20))
            a.tailPoint = normalized(CGPoint(x: min(max(tail.x, 0), size.width), y: min(max(tail.y, 0), size.height)),
                                     in: size)
        }
        return a
    }

    /// A text or callout placed with a click rather than a drag: a default
    /// width, its top-left at the click (kept inside the image).
    static func placed(from template: Annotation, at point: CGPoint, in size: CGSize) -> Annotation {
        let width = min(size.width * (template.kind == .callout ? 0.3 : 0.4), max(size.width - point.x, size.width * 0.1))
        let height = max(template.fontPixelSize(in: size) * 1.6, 1)
        let origin = CGPoint(x: min(max(point.x, 0), max(size.width - width, 0)),
                             y: min(max(point.y, 0), max(size.height - height, 0)))
        return created(from: template, anchor: origin, to: CGPoint(x: origin.x + width, y: origin.y + height), in: size,
                       constrain: false)
    }
}
