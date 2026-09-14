import AppKit

/// The four screen edges that reveal a panel (DESIGN.md 5).
nonisolated enum FlyoutEdge: CaseIterable, Hashable {
    case top, bottom, left, right
}

/// Where fly-out panels sit and which edge the pointer is touching, as plain
/// rectangle arithmetic so it can be tested without windows.
///
/// Rectangles are in the container's coordinates, origin bottom left (the
/// container is not flipped). `area` is the part of the container panels may
/// use: all of it in full screen on a plain display, less the camera housing
/// on a notched one, and less the title bar in a window.
nonisolated enum FlyoutGeometry {
    /// How close to an edge the pointer must come. Small, so passing near an
    /// edge while panning doesn't throw a panel over the image.
    static let triggerDistance: CGFloat = 4

    /// The edge the pointer is touching, or nil. In a corner, the nearer edge
    /// wins, and top and bottom beat the sides on a tie: the filmstrip and
    /// the controls are the panels people reach for most.
    static func edge(at point: CGPoint, in area: CGRect, threshold: CGFloat = triggerDistance) -> FlyoutEdge? {
        guard area.insetBy(dx: -threshold, dy: -threshold).contains(point) else { return nil }
        let distances: [(FlyoutEdge, CGFloat)] = [
            (.top, area.maxY - point.y), (.bottom, point.y - area.minY),
            (.left, point.x - area.minX), (.right, area.maxX - point.x),
        ]
        return distances.filter { $0.1 <= threshold }.min { $0.1 < $1.1 }?.0
    }

    /// The panel's frame while showing. Top and bottom panels span the full
    /// width. Side panels run between them, but only between panels that are
    /// pinned open: a pinned filmstrip stays visible when the tools slide in,
    /// while a passing hover doesn't make the side panels jump.
    static func openFrame(for edge: FlyoutEdge, thickness: CGFloat, in area: CGRect,
                          pinnedThickness: [FlyoutEdge: CGFloat] = [:]) -> CGRect {
        switch edge {
        case .top:
            return CGRect(x: area.minX, y: area.maxY - thickness, width: area.width, height: thickness)
        case .bottom:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: thickness)
        case .left, .right:
            let below = pinnedThickness[.bottom] ?? 0
            let above = pinnedThickness[.top] ?? 0
            let x = edge == .left ? area.minX : area.maxX - thickness
            return CGRect(x: x, y: area.minY + below, width: thickness,
                          height: max(0, area.height - below - above))
        }
    }

    /// The same frame pushed just past its edge, where it slides in from.
    static func closedFrame(for edge: FlyoutEdge, thickness: CGFloat, in area: CGRect,
                            pinnedThickness: [FlyoutEdge: CGFloat] = [:]) -> CGRect {
        let open = openFrame(for: edge, thickness: thickness, in: area, pinnedThickness: pinnedThickness)
        switch edge {
        case .top: return open.offsetBy(dx: 0, dy: thickness)
        case .bottom: return open.offsetBy(dx: 0, dy: -thickness)
        case .left: return open.offsetBy(dx: -thickness, dy: 0)
        case .right: return open.offsetBy(dx: thickness, dy: 0)
        }
    }
}

/// A translucent panel for one edge: the system HUD material, flush with
/// its edge, with only the corners that face the image rounded.
final class FlyoutPanelView: NSVisualEffectView {
    static let cornerRadius: CGFloat = 12

    init(edge: FlyoutEdge) {
        super.init(frame: .zero)
        material = .hudWindow
        // The panel floats over the canvas in the same window, so it blurs
        // the image behind it rather than the desktop.
        blendingMode = .withinWindow
        // Stay translucent when the window isn't key (a Finder window in
        // front after Reveal in Finder), rather than turning flat grey.
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // The layer is not flipped: min Y is the bottom.
        layer?.maskedCorners = switch edge {
        case .top: [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .bottom: [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .left: [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .right: [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
        // A hairline keeps the panel's edge readable over dark photos.
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }
}

/// Slides edge panels in when the pointer touches an edge and out when it
/// leaves them.
///
/// Driven entirely by one tracking area on the container, which reports
/// pointer movement only while the pointer moves: nothing runs while it is
/// still, so an idle viewer costs nothing (DESIGN.md 6). An `NSResponder`
/// because a tracking area delivers its events to an owner object, and
/// making the controller the owner keeps them from arriving twice through
/// the view hierarchy.
final class FlyoutController: NSResponder {
    static let animationDuration: TimeInterval = 0.18

    private struct Panel {
        let view: NSView
        let thickness: CGFloat
        /// Showing, or sliding in.
        var isOpen = false
        /// Stays open until toggled off (F for the filmstrip, the info button).
        var isPinned = false
    }

    private weak var container: NSView?
    private var panels: [FlyoutEdge: Panel] = [:]
    /// Where panels live; the container sets it on every layout.
    private(set) var area: CGRect = .zero

    /// Every pointer movement over the container, for hiding the cursor.
    var onPointerMoved: (() -> Void)?
    /// A panel became visible (true) or finished sliding away (false). The
    /// filmstrip and info panel only do work while they can be seen.
    var onVisibilityChange: ((FlyoutEdge, Bool) -> Void)?

    init(container: NSView) {
        self.container = container
        super.init()
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        container.addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// Adds `view` as the panel for `edge`, hidden until the edge is touched.
    func add(_ view: NSView, edge: FlyoutEdge, thickness: CGFloat) {
        panels[edge] = Panel(view: view, thickness: thickness)
        view.isHidden = true
        view.alphaValue = 0
        container?.addSubview(view)
    }

    func isOpen(_ edge: FlyoutEdge) -> Bool { panels[edge]?.isOpen ?? false }
    func isPinned(_ edge: FlyoutEdge) -> Bool { panels[edge]?.isPinned ?? false }

    /// True while a panel the pointer opened (not a pinned one) is out.
    var hasTransientPanelOpen: Bool { panels.values.contains { $0.isOpen && !$0.isPinned } }

    // MARK: - Layout

    /// Places every panel for a new container size, without animation.
    /// Container layout also runs for unrelated reasons (the HUD's text
    /// changing size), and setting frames then would cut a slide short, so
    /// an unchanged area leaves the panels alone.
    func layout(in area: CGRect) {
        guard area != self.area else { return }
        self.area = area
        for (edge, panel) in panels {
            panel.view.frame = frame(for: edge, open: panel.isOpen)
        }
    }

    private func frame(for edge: FlyoutEdge, open: Bool) -> CGRect {
        guard let panel = panels[edge] else { return .zero }
        var pinned: [FlyoutEdge: CGFloat] = [:]
        for (other, state) in panels where state.isPinned && state.isOpen { pinned[other] = state.thickness }
        return open
            ? FlyoutGeometry.openFrame(for: edge, thickness: panel.thickness, in: area, pinnedThickness: pinned)
            : FlyoutGeometry.closedFrame(for: edge, thickness: panel.thickness, in: area, pinnedThickness: pinned)
    }

    // MARK: - Showing and hiding

    func setPinned(_ pinned: Bool, edge: FlyoutEdge, animated: Bool = true) {
        guard panels[edge] != nil else { return }
        panels[edge]!.isPinned = pinned
        setOpen(pinned, edge: edge, animated: animated)
        // Side panels make room for pinned top and bottom panels.
        if edge == .top || edge == .bottom { relayoutSides(animated: animated) }
    }

    func togglePinned(_ edge: FlyoutEdge) {
        setPinned(!isPinned(edge), edge: edge)
    }

    /// Closes panels the pointer opened; pinned ones stay.
    func hideTransientPanels(animated: Bool = true) {
        for (edge, panel) in panels where panel.isOpen && !panel.isPinned {
            setOpen(false, edge: edge, animated: animated)
        }
    }

    private func setOpen(_ open: Bool, edge: FlyoutEdge, animated: Bool) {
        guard let panel = panels[edge], panel.isOpen != open || panel.view.isHidden == open else { return }
        panels[edge]!.isOpen = open
        let view = panel.view
        if open {
            if view.isHidden {
                // Start from just past the edge, so it slides rather than pops.
                view.frame = frame(for: edge, open: false)
                view.isHidden = false
                onVisibilityChange?(edge, true)
            }
        }
        let target = frame(for: edge, open: open)
        guard animated else {
            view.frame = target
            view.alphaValue = open ? 1 : 0
            if !open { finishClosing(edge) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().frame = target
            // Fading as well as sliding: in a window the panel would
            // otherwise slide under the transparent title bar.
            view.animator().alphaValue = open ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panels[edge]?.isOpen == false else { return }
                self.finishClosing(edge)
            }
        }
    }

    /// A closed panel is hidden, so it draws nothing and takes no clicks.
    private func finishClosing(_ edge: FlyoutEdge) {
        guard let view = panels[edge]?.view, !view.isHidden else { return }
        view.isHidden = true
        onVisibilityChange?(edge, false)
    }

    private func relayoutSides(animated: Bool) {
        for edge in [FlyoutEdge.left, .right] {
            guard let panel = panels[edge], !panel.view.isHidden else { continue }
            let target = frame(for: edge, open: panel.isOpen)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.animationDuration
                    panel.view.animator().frame = target
                }
            } else {
                panel.view.frame = target
            }
        }
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?()
        guard let container else { return }
        pointerMoved(to: container.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // Left the window (or the display, in full screen).
        hideTransientPanels()
    }

    /// Keeps the panel under the pointer, closes transient panels it left,
    /// and opens the panel of an edge it touched.
    func pointerMoved(to point: CGPoint) {
        // Measured against where panels are going, not where an animation has
        // them this instant, so a panel sliding in doesn't close itself.
        let inside = panels.filter { $0.value.isOpen && frame(for: $0.key, open: true).contains(point) }.keys
        for (edge, panel) in panels where panel.isOpen && !panel.isPinned && !inside.contains(edge) {
            setOpen(false, edge: edge, animated: true)
        }
        guard inside.isEmpty, let edge = FlyoutGeometry.edge(at: point, in: area),
              panels[edge]?.isOpen == false else { return }
        setOpen(true, edge: edge, animated: true)
    }
}
