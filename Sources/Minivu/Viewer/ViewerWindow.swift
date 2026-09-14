import AppKit

/// The viewer's window, in either of its two forms.
///
/// **Full screen** is a borderless window exactly the size of the display:
/// "true full screen" as FastStone does it. It appears instantly, on the
/// display the user is looking at, without the Spaces animation or a new
/// Space that macOS full screen brings. **Windowed** is an ordinary titled
/// window. The controller keeps one of each and moves the same content view
/// between them, so the canvas (and its zoom and pan) survives the switch.
final class ViewerWindow: NSWindow {
    enum Style {
        case fullScreen, windowed
    }

    let style: Style

    /// A press anywhere in the window, before the view under it sees it. The
    /// controller hides fly-out panels when the press lands on the image, so
    /// panels never sit over the magnifier.
    var onMouseDown: ((NSEvent) -> Void)?

    init(style: Style, frame: NSRect) {
        self.style = style
        let mask: NSWindow.StyleMask = switch style {
        case .fullScreen: [.borderless]
        case .windowed: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        }
        super.init(contentRect: frame, styleMask: mask, backing: .buffered, defer: false)
        // Windows made in code must not free themselves on close: the
        // controller still holds them, and ARC would release them again.
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        backgroundColor = .black
        switch style {
        case .fullScreen:
            // Normal level: it covers the desktop and the app's own windows
            // but stays below alerts, and other apps come in front of it as
            // usual when switched to.
            level = .normal
            hasShadow = false
            isOpaque = true
            // Never part of macOS full screen or Mission Control's shuffling.
            collectionBehavior = [.fullScreenNone, .managed]
        case .windowed:
            titlebarAppearsTransparent = true
            titleVisibility = .visible
            // Wide enough for the control bar's full row of buttons.
            minSize = NSSize(width: 640, height: 400)
            // The green button (and ⌃⌘F) mean minivu's own full screen, see
            // `toggleFullScreen`; this keeps macOS from offering its own.
            collectionBehavior = [.fullScreenNone]
        }
    }

    /// Borderless windows can't become key by default; this one takes the
    /// keyboard for the whole viewer.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?(event) }
        super.sendEvent(event)
    }

    /// ⌘W. AppKit's version presses the close button, which a borderless
    /// window doesn't have, so it would just beep.
    override func performClose(_ sender: Any?) {
        guard style == .fullScreen else { return super.performClose(sender) }
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

    /// View > Enter Full Screen means the viewer's own full screen.
    override func toggleFullScreen(_ sender: Any?) {
        NSApp.sendAction(.toggleFullScreenViewer, to: nil, from: sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performClose(_:)):
            return true
        case #selector(toggleFullScreen(_:)):
            menuItem.title = style == .fullScreen ? "Exit Full Screen" : "Enter Full Screen"
            return true
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

/// The viewer's content: the canvas filling the window, with the HUD and the
/// fly-out panels layered above it.
///
/// The canvas stays clear of the title bar in a window, and of the camera
/// housing on a notched display in full screen, so "fit" really shows the
/// whole image. Panels use the same area.
final class ViewerContainerView: NSView {
    let canvas: ImageCanvasView
    /// Offered every key press the canvas passes up; returns whether it was
    /// handled, otherwise the press continues up the responder chain.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Told the usable area on each layout, for the panels and HUD.
    var layoutHandler: ((CGRect) -> Void)?

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.autoresizingMask = []
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var acceptsFirstResponder: Bool { true }

    /// Height taken from the top: the title bar in a window, the camera
    /// housing on a notched display (zero elsewhere).
    var topInset: CGFloat {
        guard let window else { return 0 }
        if window.styleMask.contains(.titled) {
            return max(0, bounds.height - window.contentLayoutRect.maxY)
        }
        return window.screen?.safeAreaInsets.top ?? 0
    }

    /// The part of the view the image and panels use.
    var contentArea: CGRect {
        var area = bounds
        area.size.height = max(0, area.height - topInset)
        return area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// Frames and constraint constants are set before `super.layout()`, which
    /// solves the constraints: a constant changed afterwards would only take
    /// effect on the next layout pass, leaving the HUD a pass behind.
    override func layout() {
        let area = contentArea
        if canvas.frame != area { canvas.frame = area }
        layoutHandler?(area)
        super.layout()
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}
