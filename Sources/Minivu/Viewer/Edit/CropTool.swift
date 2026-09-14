import Foundation
import CoreGraphics
import Observation
import MinivuRender

/// The crop tool's aspect presets.
nonisolated enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, fourThree, threeTwo, sixteenNine, fiveFour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .fiveFour: "5:4"
        }
    }

    /// Width over height, or nil for free. `portrait` turns the ratio on its
    /// side (3:2 becomes 2:3); for Original it swaps the image's own sides.
    func ratio(imageSize: CGSize, portrait: Bool) -> CGFloat? {
        let landscape: CGFloat
        switch self {
        case .free: return nil
        case .original:
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            let r = imageSize.width / imageSize.height
            return portrait == (r >= 1) ? 1 / r : r
        case .square: return 1
        case .fourThree: landscape = 4.0 / 3
        case .threeTwo: landscape = 3.0 / 2
        case .sixteenNine: landscape = 16.0 / 9
        case .fiveFour: landscape = 5.0 / 4
        }
        return portrait ? 1 / landscape : landscape
    }
}

/// A crop rectangle and the rules for dragging it, in the output image's
/// pixels (top-left origin). Plain arithmetic, so every drag is testable.
nonisolated struct CropSelection: Equatable, Sendable {
    enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// Smallest side a drag leaves, in image pixels.
    static let minimumSide: CGFloat = 8

    let imageSize: CGSize
    private(set) var rect: CGRect
    /// Width over height, or nil for any shape.
    private(set) var aspect: CGFloat?

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        rect = CGRect(origin: .zero, size: imageSize)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// The rectangle in whole pixels: what the crop will produce.
    var pixelRect: CGRect {
        let r = rect.intersection(bounds)
        guard !r.isNull else { return .zero }
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        return CGRect(x: x0, y: y0, width: max(1, r.maxX.rounded() - x0), height: max(1, r.maxY.rounded() - y0))
    }

    /// The crop as `EditOperation.crop` wants it: normalised, on whole pixels.
    var normalizedRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let p = pixelRect
        return CGRect(x: p.minX / imageSize.width, y: p.minY / imageSize.height,
                      width: p.width / imageSize.width, height: p.height / imageSize.height)
    }

    var operation: EditOperation { .crop(normalizedRect) }

    /// Replaces the rectangle, kept inside the image.
    mutating func setRect(_ newRect: CGRect) {
        rect = Self.fitted(newRect.standardized, in: bounds)
    }

    // MARK: - Aspect

    /// Changes the ratio, reshaping the rectangle about its centre with about
    /// the same area, then shrinking and shifting it to stay inside.
    mutating func setAspect(_ ratio: CGFloat?) {
        aspect = ratio.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        guard let aspect else { return }
        let area = max(rect.width * rect.height, Self.minimumSide * Self.minimumSide)
        var w = (area * aspect).squareRoot(), h = w / aspect
        if w > imageSize.width { w = imageSize.width; h = w / aspect }
        if h > imageSize.height { h = imageSize.height; w = h * aspect }
        rect = Self.fitted(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), in: bounds)
    }

    /// Turns the rectangle on its side about its centre (the free case of
    /// swapping orientation), shrunk to fit.
    mutating func swapSides() {
        var w = rect.height, h = rect.width
        let fit = min(1, imageSize.width / w, imageSize.height / h)
        w *= fit
        h *= fit
        rect = Self.fitted(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), in: bounds)
    }

    // MARK: - Dragging

    /// Moves the whole rectangle from where a drag started, kept inside.
    mutating func move(from start: CGRect, by delta: CGSize) {
        rect = Self.fitted(start.offsetBy(dx: delta.width, dy: delta.height), in: bounds)
    }

    /// Drags `handle` of the rectangle `start` (as it was when the drag
    /// began) to `point`.
    mutating func drag(_ handle: Handle, of start: CGRect, to point: CGPoint) {
        switch handle {
        case .topLeft: rect = corner(anchor: CGPoint(x: start.maxX, y: start.maxY), point: point, sx: -1, sy: -1)
        case .topRight: rect = corner(anchor: CGPoint(x: start.minX, y: start.maxY), point: point, sx: 1, sy: -1)
        case .bottomRight: rect = corner(anchor: CGPoint(x: start.minX, y: start.minY), point: point, sx: 1, sy: 1)
        case .bottomLeft: rect = corner(anchor: CGPoint(x: start.maxX, y: start.minY), point: point, sx: -1, sy: 1)
        case .left, .right, .top, .bottom: rect = edge(handle, of: start, to: point)
        }
    }

    /// A new rectangle drawn from `anchor` (a press outside the current one),
    /// towards whichever side of it the pointer is on.
    mutating func draw(from anchor: CGPoint, to point: CGPoint) {
        rect = corner(anchor: anchor, point: point, sx: point.x < anchor.x ? -1 : 1, sy: point.y < anchor.y ? -1 : 1)
    }

    /// The rectangle from a fixed corner towards the pointer, growing in the
    /// direction (`sx`, `sy`) away from the anchor; a pointer on the wrong
    /// side leaves the minimum size rather than flipping the handle over.
    /// With an aspect ratio the larger of the two spans wins, then both
    /// shrink to fit the image on that side of the anchor.
    private func corner(anchor rawAnchor: CGPoint, point: CGPoint, sx: CGFloat, sy: CGFloat) -> CGRect {
        let a = CGPoint(x: min(max(rawAnchor.x, 0), imageSize.width), y: min(max(rawAnchor.y, 0), imageSize.height))
        var w = max((point.x - a.x) * sx, Self.minimumSide)
        var h = max((point.y - a.y) * sy, Self.minimumSide)
        let maxW = max(sx < 0 ? a.x : imageSize.width - a.x, 1)
        let maxH = max(sy < 0 ? a.y : imageSize.height - a.y, 1)
        if let aspect {
            if w / h > aspect { h = w / aspect } else { w = h * aspect }
            if w > maxW { w = maxW; h = w / aspect }
            if h > maxH { h = maxH; w = h * aspect }
        } else {
            w = min(w, maxW)
            h = min(h, maxH)
        }
        return CGRect(x: sx < 0 ? a.x - w : a.x, y: sy < 0 ? a.y - h : a.y, width: w, height: h)
    }

    /// One side moves; the opposite side stays. With an aspect ratio the
    /// other dimension follows, centred on the rectangle's middle, and the
    /// moved side stops where that would leave the image.
    private func edge(_ handle: Handle, of start: CGRect, to point: CGPoint) -> CGRect {
        let horizontal = handle == .left || handle == .right
        var r = start
        switch handle {
        case .left: r.origin.x = min(max(point.x, 0), start.maxX - Self.minimumSide); r.size.width = start.maxX - r.minX
        case .right: r.size.width = max(min(point.x, imageSize.width), start.minX + Self.minimumSide) - start.minX
        case .top: r.origin.y = min(max(point.y, 0), start.maxY - Self.minimumSide); r.size.height = start.maxY - r.minY
        case .bottom: r.size.height = max(min(point.y, imageSize.height), start.minY + Self.minimumSide) - start.minY
        default: break
        }
        guard let aspect else { return r }
        if horizontal {
            var w = r.width, h = w / aspect
            if h > imageSize.height { h = imageSize.height; w = h * aspect }
            let x = handle == .left ? start.maxX - w : start.minX
            let y = min(max(start.midY - h / 2, 0), imageSize.height - h)
            return CGRect(x: x, y: y, width: w, height: h)
        } else {
            var h = r.height, w = h * aspect
            if w > imageSize.width { w = imageSize.width; h = w / aspect }
            let y = handle == .top ? start.maxY - h : start.minY
            let x = min(max(start.midX - w / 2, 0), imageSize.width - w)
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// `r` shrunk to fit `bounds` if larger, then shifted inside.
    static func fitted(_ r: CGRect, in bounds: CGRect) -> CGRect {
        let w = min(r.width, bounds.width), h = min(r.height, bounds.height)
        let x = min(max(r.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(r.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// The crop tool's state: the selection over the output image, and the
/// preset the inspector shows. Nothing previews on the document while
/// cropping (the overlay shows the result), so Cancel has nothing to undo.
@Observable final class CropToolState: EditToolState {
    private(set) var selection: CropSelection
    private(set) var preset: CropAspect = .free
    private(set) var portrait: Bool
    /// True during a drag, when the overlay shows the thirds grid.
    var isDragging = false

    /// For the overlay, which isn't SwiftUI: every change to the selection.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let document: EditDocument

    init(document: EditDocument, imageSize: CGSize) {
        self.document = document
        selection = CropSelection(imageSize: imageSize)
        portrait = imageSize.height > imageSize.width
    }

    var title: String { "Crop" }
    var hasPendingChanges: Bool { selection.pixelRect != selection.bounds }

    func setPreset(_ preset: CropAspect) {
        self.preset = preset
        // A fixed ratio starts in the image's own orientation.
        portrait = selection.imageSize.height > selection.imageSize.width
        selection.setAspect(preset.ratio(imageSize: selection.imageSize, portrait: portrait))
        onChange?()
    }

    /// Portrait for landscape and back.
    func swapOrientation() {
        portrait.toggle()
        if preset == .free {
            selection.swapSides()
        } else {
            selection.setAspect(preset.ratio(imageSize: selection.imageSize, portrait: portrait))
        }
        onChange?()
    }

    func update(_ body: (inout CropSelection) -> Void) {
        body(&selection)
        onChange?()
    }

    func apply() {
        document.apply(selection.operation)   // the whole image is an identity crop: nothing recorded
    }

    func cancel() {}

    func reset() {
        let size = selection.imageSize
        selection = CropSelection(imageSize: size)
        preset = .free
        portrait = size.height > size.width
        onChange?()
    }
}
