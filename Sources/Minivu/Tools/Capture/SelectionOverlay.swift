import AppKit

/// The dimmed, crosshair overlay of Capture > Selection…: one borderless,
/// transparent window over each screen (menu bar and Dock included). Drag a
/// rectangle on any of them; letting go (or Return) captures it, Esc or a
/// click without a drag in no rectangle cancels.
final class SelectionOverlayController {
    struct Selection: Equatable {
        /// Global AppKit coordinates.
        var rect: CGRect
        var screen: CaptureScreen
    }

    private(set) var windows: [SelectionOverlayWindow] = []
    private let screens: [CaptureScreen]
    private var completion: ((Selection?) -> Void)?

    init(screens: [CaptureScreen], completion: @escaping (Selection?) -> Void) {
        self.screens = screens
        self.completion = completion
    }

    /// `preset` starts with a rectangle already dragged (the debug action).
    /// `ordersFront` false makes the windows without putting them on screen
    /// (tests, which must not dim the tester's displays).
    func show(preset: (rect: CGRect, screen: CaptureScreen)? = nil, ordersFront: Bool = true) {
        for screen in screens {
            let window = SelectionOverlayWindow(screen: screen)
            let view = window.overlayView
            view.onBegin = { [weak self, weak view] in
                // One selection at a time, on the screen where the drag began.
                self?.windows.forEach { if $0.overlayView !== view { $0.overlayView.selection = nil } }
            }
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                self.finish(rect.map { Selection(rect: $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                                                 screen: screen) })
            }
            if let preset, preset.screen == screen {
                view.selection = preset.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            }
            windows.append(window)
        }
        guard ordersFront else { return }
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let pointer = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(pointer) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
    }

    /// Closes every overlay window before the capture starts, so none of them
    /// is on screen when it is taken.
    func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        completion(selection)
    }

    func cancel() { finish(nil) }
}

final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView

    init(screen: CaptureScreen) {
        overlayView = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), scale: screen.scale)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, the Dock and full-screen apps, on every Space.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = overlayView
        initialFirstResponder = overlayView
        makeFirstResponder(overlayView)
        setFrame(screen.frame, display: false)
    }

    // A borderless window refuses key status unless asked, and the overlay
    // needs it for Esc and Return.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionOverlayView: NSView {
    /// The dragged rectangle, in this view's coordinates.
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onFinish: ((CGRect?) -> Void)?
    private let scale: CGFloat
    private var dragStart: CGPoint?

    static let dimming = NSColor(white: 0, alpha: 0.35)

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        onBegin?()
        selection = CaptureGeometry.selection(from: point, to: point, bounds: bounds, scale: scale)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        selection = CaptureGeometry.selection(from: start, to: convert(event.locationInWindow, from: nil),
                                              bounds: bounds, scale: scale)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if let selection, CaptureGeometry.isUsable(selection) {
            onFinish?(selection)
        } else {
            selection = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:   // Esc
            onFinish?(nil)
        case 36, 76:   // Return, Enter
            if let selection, CaptureGeometry.isUsable(selection) { onFinish?(selection) }
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.dimming.setFill()
        bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        // A white line with a faint dark edge reads on light and dark screens.
        NSColor(white: 0, alpha: 0.35).setStroke()
        NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        let line = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        line.lineWidth = 1
        line.stroke()
        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = CaptureGeometry.sizeLabel(for: selection, scale: scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        let frame = CaptureGeometry.labelFrame(for: selection,
                                               labelSize: CGSize(width: size.width + 2 * padding.width,
                                                                 height: size.height + 2 * padding.height),
                                               bounds: bounds)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: frame.minX + padding.width, y: frame.minY + padding.height),
                                withAttributes: attributes)
    }
}
