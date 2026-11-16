import AppKit
import SwiftUI
import Observation
import MinivuRender

/// The perspective corners on screen, and what a press or drag does to
/// them. Plain geometry, so every drag is testable.
///
/// Corners live in normalised image coordinates and the overlay knows only
/// where the canvas draws the image (`imageRect`, view points, top-left
/// origin), as for the lens.
nonisolated enum PerspectiveGeometry {
    /// A press this close to a corner (in points) grabs it.
    static let grabDistance: CGFloat = 12

    static func point(_ normalised: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(x: imageRect.minX + normalised.x * imageRect.width, y: imageRect.minY + normalised.y * imageRect.height)
    }

    /// A view point as a normalised position, held to the image.
    static func normalised(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGPoint(x: min(max((point.x - imageRect.minX) / imageRect.width, 0), 1),
                       y: min(max((point.y - imageRect.minY) / imageRect.height, 0), 1))
    }

    /// The corner a press at `point` grabs (0 top left, clockwise), the
    /// nearest within reach.
    static func corner(at point: CGPoint, quad: PerspectiveQuad, in imageRect: CGRect) -> Int? {
        let distances = quad.corners.map { c -> CGFloat in
            let p = Self.point(c, in: imageRect)
            return hypot(p.x - point.x, p.y - point.y)
        }
        guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[nearest] <= grabDistance else { return nil }
        return nearest
    }

    /// The point at `u` across and `v` down the quadrilateral, blending its
    /// corners, for the guide lines drawn inside it.
    static func blend(_ quad: PerspectiveQuad, u: CGFloat, v: CGFloat) -> CGPoint {
        let top = CGPoint(x: quad.topLeft.x + (quad.topRight.x - quad.topLeft.x) * u,
                          y: quad.topLeft.y + (quad.topRight.y - quad.topLeft.y) * u)
        let bottom = CGPoint(x: quad.bottomLeft.x + (quad.bottomRight.x - quad.bottomLeft.x) * u,
                             y: quad.bottomLeft.y + (quad.bottomRight.y - quad.bottomLeft.y) * u)
        return CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
    }

    static var cornerTitles: [String] {
        [localized("Top left"), localized("Top right"), localized("Bottom right"), localized("Bottom left")]
    }
}

/// The perspective tool's state: the four corners over the image as it is
/// before the correction. Like the crop tool, nothing previews while the
/// corners are being placed (the overlay needs the uncorrected picture
/// under it); Show Result previews the correction and hides the corners.
@Observable final class PerspectiveToolState: EditToolState {
    enum Detection: Equatable {
        case idle, running, found, none
    }

    private(set) var quad = PerspectiveQuad()
    private(set) var showsResult = false
    var detection = Detection.idle

    /// For the overlay, which isn't SwiftUI: every change to the corners or
    /// to Show Result.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let document: EditDocument
    /// Applied or cancelled: a detection finishing afterwards changes nothing.
    @ObservationIgnored private var isClosed = false

    init(document: EditDocument) {
        self.document = document
    }

    var title: String { localized("Perspective") }
    var operation: EditOperation { .perspective(quad) }
    var hasPendingChanges: Bool { !operation.isIdentity }

    func update(_ body: (inout PerspectiveQuad) -> Void) {
        guard !isClosed else { return }
        var next = quad
        body(&next)
        next.corners = next.corners.map {
            CGPoint(x: min(max($0.x.isFinite ? $0.x : 0, 0), 1), y: min(max($0.y.isFinite ? $0.y : 0, 0), 1))
        }
        guard next != quad else { return }
        quad = next
        if detection != .running { detection = .idle }
        refreshPreview()
        onChange?()
    }

    /// Moves corner `index` (0 top left, clockwise) to a normalised point.
    func setCorner(_ index: Int, to point: CGPoint) {
        guard quad.corners.indices.contains(index) else { return }
        update {
            var corners = $0.corners
            corners[index] = point
            $0.corners = corners
        }
    }

    func setShowsResult(_ shows: Bool) {
        guard !isClosed, shows != showsResult else { return }
        showsResult = shows
        refreshPreview()
        onChange?()
    }

    /// The Auto button's answer: the corners found, or nil when nothing
    /// four-sided stood out.
    func useDetected(_ found: PerspectiveQuad?) {
        guard !isClosed else { return }
        if let found {
            detection = .running   // kept through the update below
            update { $0 = found }
            detection = .found
        } else {
            detection = .none
        }
    }

    func apply() {
        guard !isClosed else { return }
        isClosed = true
        document.apply(operation)   // the image's own corners, or a folded quad, commit nothing
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        document.preview = nil
    }

    func reset() {
        update { $0 = PerspectiveQuad() }
        setShowsResult(false)
        detection = .idle
    }

    private func refreshPreview() {
        let op = operation
        document.preview = showsResult && !op.isIdentity ? op : nil
    }
}

// MARK: - Overlay

/// The perspective tool's overlay: the quadrilateral with a guide grid
/// inside it, the image outside it dimmed, and a handle on each corner to
/// drag. A sibling of the canvas with its frame, as `CropOverlayView` is;
/// scrolling and pinching pass through to the canvas. Hidden while the
/// result is shown, so clicks reach the canvas then.
final class PerspectiveOverlayView: NSView {
    private weak var canvas: ImageCanvasView?
    let state: PerspectiveToolState
    /// A double-click inside the quadrilateral applies it.
    var onApply: (() -> Void)?

    private var dragging: (corner: Int, offset: CGSize)?

    init(canvas: ImageCanvasView, state: PerspectiveToolState) {
        self.canvas = canvas
        self.state = state
        super.init(frame: canvas.frame)
        state.onChange = { [weak self] in self?.stateChanged() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localized("Perspective corners"))
        setAccessibilityHelp(localized("Drag each corner onto a corner of something that should be rectangular, or set them in the tools panel."))
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

    private func stateChanged() {
        isHidden = state.showsResult
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let rect = imageRect else { return }
        let quad = state.quad
        let points = quad.corners.map { PerspectiveGeometry.point($0, in: rect) }
        let outline = CGMutablePath()
        outline.addLines(between: points)
        outline.closeSubpath()

        // The image outside the quadrilateral dimmed, as the crop does.
        let dim = CGMutablePath()
        dim.addRect(rect)
        dim.addPath(outline)
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.addPath(dim)
        context.fillPath(using: .evenOdd)

        // Thirds inside, following the perspective, to line up with.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(0.5)
        for t in [CGFloat(1) / 3, CGFloat(2) / 3] {
            let a = PerspectiveGeometry.point(PerspectiveGeometry.blend(quad, u: t, v: 0), in: rect)
            let b = PerspectiveGeometry.point(PerspectiveGeometry.blend(quad, u: t, v: 1), in: rect)
            let c = PerspectiveGeometry.point(PerspectiveGeometry.blend(quad, u: 0, v: t), in: rect)
            let d = PerspectiveGeometry.point(PerspectiveGeometry.blend(quad, u: 1, v: t), in: rect)
            context.move(to: a); context.addLine(to: b)
            context.move(to: c); context.addLine(to: d)
        }
        context.strokePath()

        // A dark hairline outside the white one keeps it visible on white.
        context.setLineWidth(2.5)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(outline)
        context.strokePath()
        context.setLineWidth(1)
        context.setStrokeColor((quad.isValid ? NSColor.white : NSColor.systemRed).withAlphaComponent(0.95).cgColor)
        context.addPath(outline)
        context.strokePath()

        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        for p in points {
            context.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
        context.restoreGState()
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let rect = imageRect else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let corner = PerspectiveGeometry.corner(at: location, quad: state.quad, in: rect) {
            let p = PerspectiveGeometry.point(state.quad.corners[corner], in: rect)
            dragging = (corner, CGSize(width: p.x - location.x, height: p.y - location.y))
            NSCursor.closedHand.push()
        } else if event.clickCount == 2, contains(location, rect: rect) {
            onApply?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging, let rect = imageRect else { return }
        let location = convert(event.locationInWindow, from: nil)
        let target = CGPoint(x: location.x + dragging.offset.width, y: location.y + dragging.offset.height)
        state.setCorner(dragging.corner, to: PerspectiveGeometry.normalised(target, in: rect))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { NSCursor.pop() }
        dragging = nil
    }

    /// Return or Esc can close the tool mid-drag: the closed hand comes off
    /// the cursor stack here instead of staying on it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, dragging != nil {
            NSCursor.pop()
            dragging = nil
        }
    }

    private func contains(_ point: CGPoint, rect: CGRect) -> Bool {
        let path = CGMutablePath()
        path.addLines(between: state.quad.corners.map { PerspectiveGeometry.point($0, in: rect) })
        path.closeSubpath()
        return path.contains(point)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragging == nil, let rect = imageRect else { return }
        let location = convert(event.locationInWindow, from: nil)
        if PerspectiveGeometry.corner(at: location, quad: state.quad, in: rect) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Zoom and pan pass through

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.smartMagnify(with: event) }
}

// MARK: - Inspector

struct PerspectiveInspectorView: View {
    @Bindable var state: PerspectiveToolState
    let actions: InspectorActions
    let detect: () -> Void

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                HStack {
                    Button("Auto", action: detect)
                        .disabled(state.detection == .running || state.showsResult)
                        .help("Find the most prominent rectangle in the photo")
                    if state.detection == .running {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Toggle("Show result", isOn: Binding(get: { state.showsResult }, set: { state.setShowsResult($0) }))
            } footer: {
                InspectorFootnote(detectionText)
            }
            Section {
                ForEach(0..<4, id: \.self) { index in
                    cornerRow(index)
                }
            } header: {
                Text("Corners")
            } footer: {
                InspectorFootnote(localized("Across and down, as percentages of the image. Drag the corners on the canvas onto the corners of something that should be rectangular."))
            }
        }
    }

    private var detectionText: String {
        switch state.detection {
        case .idle: localized("Auto looks for the most prominent rectangle: a document, a screen, a window or a building’s face.")
        case .running: localized("Looking for a rectangle…")
        case .found: localized("The corners are on the rectangle found. Adjust them if needed.")
        case .none: localized("No rectangle stood out. Drag the corners instead.")
        }
    }

    private func cornerRow(_ index: Int) -> some View {
        let title = PerspectiveGeometry.cornerTitles[index]
        let point = state.quad.corners[index]
        return LabeledContent(title) {
            HStack(spacing: 4) {
                percentField(localized(.init("\(title), across", comment: "VoiceOver: %@ is a corner, such as Top left; across is its x position")),
                    value: point.x) { x in
                    state.setCorner(index, to: CGPoint(x: x, y: state.quad.corners[index].y))
                }
                percentField(localized(.init("\(title), down", comment: "VoiceOver: %@ is a corner, such as Top left; down is its y position")),
                    value: point.y) { y in
                    state.setCorner(index, to: CGPoint(x: state.quad.corners[index].x, y: y))
                }
            }
        }
    }

    private func percentField(_ label: String, value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        TextField(label, value: Binding(get: { Double(value) * 100 }, set: { set(CGFloat($0 / 100)) }),
                  format: .number.precision(.fractionLength(1)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 56)
            .disabled(state.showsResult)
            .accessibilityLabel(label)
    }
}
