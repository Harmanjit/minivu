import AppKit
import QuartzCore
import MinivuRender

/// The slideshow's picture: an NSView backed by a CAMetalLayer set up like
/// the canvas (extended linear Display P3, half-float, EDR when an HDR slide
/// shows).
///
/// Frames come from a display link that runs only while a transition
/// animates, plus one frame whenever something else changes (a new still,
/// the screen's headroom). Between slides the link is paused and nothing is
/// drawn: a slide at rest costs nothing.
final class SlideshowView: NSView, SnapshotProviding {
    /// The frame to draw, for the display headroom it will be shown at.
    var frameProvider: ((Float) -> SlideshowFrame)?
    /// Called on each refresh while animating, before drawing, with the time
    /// the frame will reach the screen. The owner may stop animating here.
    var onAnimationFrame: ((CFTimeInterval) -> Void)?

    private let renderer: SlideshowRenderer?
    private var displayLink: CADisplayLink?
    private(set) var isAnimating = false
    private var needsRedraw = true
    /// The headroom the frame on screen was drawn for.
    private var lastFrameHeadroom: Float?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override init(frame frameRect: NSRect) {
        do {
            renderer = try SlideshowRenderer()
        } catch {
            log.error("Slideshow renderer unavailable: \(error, privacy: .public)")
            renderer = nil
        }
        super.init(frame: frameRect)
        wantsLayer = true
        // Frames are presented by hand; AppKit must never ask the layer to draw.
        layerContentsRedrawPolicy = .never
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        CanvasRenderer.configure(layer)
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    /// The drawable's size in pixels.
    var drawablePixelSize: CGSize {
        CGSize(width: (bounds.width * backingScale).rounded(), height: (bounds.height * backingScale).rounded())
    }

    // MARK: - Drawing

    func startAnimating() {
        isAnimating = true
        displayLink?.isPaused = false
    }

    /// Stops the link after one more frame, which shows where things ended.
    func stopAnimating() {
        isAnimating = false
        setNeedsRedraw()
    }

    /// One frame on the next refresh.
    func setNeedsRedraw() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if isAnimating { onAnimationFrame?(link.targetTimestamp) }
        // Paused before drawing: anything that asks for a frame meanwhile
        // unpauses it again.
        link.isPaused = !isAnimating
        guard isAnimating || needsRedraw else { return }
        draw()
    }

    private func draw() {
        guard let renderer, let layer = metalLayer, window != nil, let frameProvider else { return }
        let size = drawablePixelSize
        guard size.width >= 1, size.height >= 1 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        needsRedraw = false
        let headroom = displayHeadroom
        lastFrameHeadroom = headroom
        renderer.draw(frameProvider(headroom), to: drawable)
    }

    // MARK: - HDR

    /// How far above SDR white the screen can show now; 1 without EDR on the
    /// layer, when the compositor would clip anything brighter.
    var displayHeadroom: Float {
        guard metalLayer?.wantsExtendedDynamicRangeContent == true, let window,
              let headroom = Displays.provider.headroom(of: window) else { return 1 }
        return max(1, Float(headroom.current))
    }

    /// What the screen could reach with EDR on.
    var potentialHeadroom: CGFloat {
        window.flatMap(Displays.provider.headroom(of:))?.potential ?? 1
    }

    func setExtendedDynamicRange(_ enabled: Bool) {
        guard let layer = metalLayer, layer.wantsExtendedDynamicRangeContent != enabled else { return }
        CanvasRenderer.setExtendedDynamicRange(enabled, on: layer)
        setNeedsRedraw()
    }

    /// Renders what is on screen offscreen, as SDR, for snapshots.
    func snapshotImage() -> CGImage? {
        guard let frameProvider else { return nil }
        let size = drawablePixelSize
        return renderer?.snapshot(frameProvider(1), width: Int(size.width), height: Int(size.height))
    }

    // MARK: - Window and screen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The link retains its target, so it must not outlive the window.
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.isPaused = !(isAnimating || needsRedraw)
        link.add(to: .main, forMode: .common)
        displayLink = link
        metalLayer?.contentsScale = backingScale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = backingScale
        setNeedsRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRedraw()
    }

    /// A new resolution, or EDR headroom rising as the display brightens for
    /// an HDR slide; or (from the controller) the window moved to another
    /// display. Another app's EDR posts this too: when nothing this view
    /// draws for has changed, the frame on screen is still right.
    @objc func screenChanged() {
        if !needsRedraw, !isAnimating, metalLayer?.drawableSize == drawablePixelSize,
           lastFrameHeadroom == displayHeadroom {
            return
        }
        setNeedsRedraw()
    }
}
