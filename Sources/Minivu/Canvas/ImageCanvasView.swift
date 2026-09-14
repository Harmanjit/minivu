import AppKit
import Combine
import QuartzCore
import MinivuCore
import MinivuRender

/// What the canvas asks of whoever owns it (the viewer).
protocol ImageCanvasViewDelegate: AnyObject {
    /// The wheel or a swipe asked for another image: +1 next, -1 previous.
    func canvasRequestsNavigation(_ canvas: ImageCanvasView, offset: Int)
    func canvasDidChangeZoom(_ canvas: ImageCanvasView)
    /// The current texture is being magnified; load a sharper one and hand
    /// it over with `setImage(_:preserveView: true)`. Asked once per texture.
    /// At `.fit` the window has outgrown the texture, so a screen-sized load
    /// for `drawablePixelSize` is enough; otherwise load full resolution.
    func canvasNeedsFullResolution(_ canvas: ImageCanvasView)
    func canvasDidDoubleClick(_ canvas: ImageCanvasView)
}

extension ImageCanvasViewDelegate {
    func canvasRequestsNavigation(_ canvas: ImageCanvasView, offset: Int) {}
    func canvasDidChangeZoom(_ canvas: ImageCanvasView) {}
    func canvasNeedsFullResolution(_ canvas: ImageCanvasView) {}
    func canvasDidDoubleClick(_ canvas: ImageCanvasView) {}
}

/// The image canvas (DESIGN.md 4.4): an NSView backed by a CAMetalLayer.
///
/// The view is deliberately thin. `ViewportTransform` holds zoom and pan,
/// `CanvasInteraction` decides what each gesture means (and is unit tested),
/// and `CanvasRenderer` draws. What's left here is AppKit plumbing: events
/// in, one Metal frame out whenever something changed.
///
/// Frames are drawn by a display link that runs only while a redraw is
/// pending. An idle canvas costs nothing: no timer, no frames.
final class ImageCanvasView: NSView, SnapshotProviding {
    enum ZoomMode {
        /// Best fit; follows the window as it resizes.
        case fit
        /// One image pixel per screen pixel.
        case actualSize
        case custom
    }

    enum ClickAction {
        case toggleZoom, none
    }

    weak var delegate: ImageCanvasViewDelegate?
    var clickAction: ClickAction = .toggleZoom
    var magnifierEnabled = true

    private(set) var image: ImageTexture?
    private(set) var zoomMode: ZoomMode = .fit
    private(set) var transform = ViewportTransform(zoom: 1, center: .zero)

    var zoomPercent: Double { Double(transform.zoom) * 100 }

    /// The drawable's size in pixels. Its long edge is the pixel size to ask
    /// `ImageLoader.load` for.
    var drawablePixelSize: CGSize {
        CGSize(width: (bounds.width * backingScale).rounded(), height: (bounds.height * backingScale).rounded())
    }

    /// Surround colour in linear light. Follows the viewer background
    /// preference unless set explicitly.
    var background: SIMD3<Float> {
        get {
            backgroundOverride ?? SIMD3(repeating: Preferences.shared.viewerBackground.linearLevel)
        }
        set {
            backgroundOverride = newValue
            setNeedsRedraw()
        }
    }

    private var backgroundOverride: SIMD3<Float>?
    private let renderer: CanvasRenderer?
    private var displayLink: CADisplayLink?
    private var needsRedraw = true
    /// The display headroom the frame on screen was drawn for.
    private var lastFrameHeadroom: Float?
    private var preferencesObserver: AnyCancellable?

    private var press: CanvasInteraction.PressClassifier?
    private var lastDragLocation: CGPoint = .zero
    /// Where a click toggled from, so a double-click can undo that toggle.
    private var viewBeforeClick: (transform: ViewportTransform, mode: ZoomMode)?
    private var wheel = CanvasInteraction.WheelInterpreter()
    /// Magnifier centre in view points, while it's showing.
    private var magnifierLocation: CGPoint?
    private var magnifierScroll: CGFloat = 0
    private var askedForFullResolution = false
    private var isPannable = false

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(frame frameRect: NSRect) {
        do {
            renderer = try CanvasRenderer()
        } catch {
            log.error("Canvas renderer unavailable: \(error, privacy: .public)")
            renderer = nil
        }
        super.init(frame: frameRect)
        wantsLayer = true
        // We present frames ourselves; AppKit must never ask the layer to
        // redraw or it would call display on a layer that has no contents
        // to give.
        layerContentsRedrawPolicy = .never
        preferencesObserver = Preferences.shared.objectWillChange
            // objectWillChange fires before the new value is stored; a hop to
            // the next main queue turn reads the new one.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ImageCanvasView is made in code") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        CanvasRenderer.configure(layer)
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Whether a click gives the canvas keyboard focus. The viewer wants it
    /// (keys drive navigation there); the browser preview turns it off so the
    /// grid keeps the arrow keys after the user clicks the preview.
    var takesKeyboardFocus = true
    override var acceptsFirstResponder: Bool { takesKeyboardFocus }

    // MARK: - Image

    /// Shows `texture`. `preserveView` keeps zoom and pan (a sharper texture
    /// of the same image arrived); otherwise the new image is fitted.
    func setImage(_ texture: ImageTexture?, preserveView: Bool) {
        if texture !== image { askedForFullResolution = false }
        image = texture
        if !preserveView {
            // A double-click must not restore another image's zoom and pan.
            viewBeforeClick = nil
        }
        if preserveView, texture != nil, zoomMode != .fit {
            clampTransform()
        } else {
            applyFit()
        }
        updateDynamicRange()
        viewDidChange(zoomChanged: !preserveView)
    }

    // MARK: - Zoom

    func fit() {
        guard image != nil else { return }
        applyFit()
        viewDidChange(zoomChanged: true)
    }

    /// Actual size, keeping the image point under `viewPoint` (or the view
    /// centre) in place.
    func actualSize(at viewPoint: CGPoint?) {
        guard let image else { return }
        transform = transform.actualSize(about: pixelPoint(viewPoint), viewSize: drawablePixelSize)
            .clamped(imageSize: image.imageSize, viewSize: drawablePixelSize)
        zoomMode = .actualSize
        viewDidChange(zoomChanged: true)
    }

    func toggleFitActual(at viewPoint: CGPoint?) {
        if zoomMode == .fit { actualSize(at: viewPoint) } else { fit() }
    }

    func zoomIn() {
        zoom(by: CanvasInteraction.nextZoom(above: transform.zoom) / transform.zoom, at: nil)
    }

    func zoomOut() {
        zoom(by: CanvasInteraction.nextZoom(below: transform.zoom) / transform.zoom, at: nil)
    }

    /// Zooms by `factor` about `viewPoint` (view points; nil for the centre).
    func zoom(by factor: CGFloat, at viewPoint: CGPoint?) {
        guard let image, factor > 0, factor != 1 else { return }
        let zoomed = transform.zoomed(by: factor, about: pixelPoint(viewPoint), viewSize: drawablePixelSize)
            .clamped(imageSize: image.imageSize, viewSize: drawablePixelSize)
        guard zoomed != transform else { return }   // already at a limit
        transform = zoomed
        zoomMode = abs(transform.zoom - 1) < 1e-6 ? .actualSize : .custom
        viewDidChange(zoomChanged: true)
    }

    private func applyFit() {
        guard let image else {
            zoomMode = .fit   // nothing to preserve; the next image starts fitted
            return
        }
        transform = .bestFit(imageSize: image.imageSize, viewSize: drawablePixelSize,
                             enlargeSmall: Preferences.shared.enlargeSmallImages)
        zoomMode = .fit
    }

    private func clampTransform() {
        guard let image else { return }
        transform = transform.clamped(imageSize: image.imageSize, viewSize: drawablePixelSize)
    }

    /// After any change to the image, zoom or pan: redraw, update the cursor
    /// and tell the delegate what it needs to know.
    private func viewDidChange(zoomChanged: Bool) {
        updatePannable()
        setNeedsRedraw()
        if zoomChanged { delegate?.canvasDidChangeZoom(self) }
        requestFullResolutionIfNeeded()
    }

    private func requestFullResolutionIfNeeded() {
        guard let image, !askedForFullResolution else { return }
        var zoom = transform.zoom
        if magnifierLocation != nil {
            zoom = max(zoom, CanvasInteraction.magnifierZoom(preference: Preferences.shared.magnifierZoom,
                                                             currentZoom: transform.zoom))
        }
        let needed = CanvasInteraction.needsHigherResolution(
            isFullResolution: image.isFullResolution, currentZoom: zoom,
            imageLongEdge: max(image.imageSize.width, image.imageSize.height),
            textureLongEdge: max(image.textureSize.width, image.textureSize.height))
        guard needed else { return }
        askedForFullResolution = true
        delegate?.canvasNeedsFullResolution(self)
    }

    /// View points (top-left origin, since the view is flipped) to drawable
    /// pixels. nil means the view centre.
    private func pixelPoint(_ viewPoint: CGPoint?) -> CGPoint {
        guard let viewPoint else {
            let size = drawablePixelSize
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        return CGPoint(x: viewPoint.x * backingScale, y: viewPoint.y * backingScale)
    }

    // MARK: - Drawing

    /// Asks for one frame on the next display refresh.
    func setNeedsRedraw() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Pause first: anything that changes during the draw unpauses again.
        link.isPaused = true
        guard needsRedraw else { return }
        drawFrame()
    }

    /// Draws one frame now. While the layer presents with transactions (live
    /// resize) the present must wait for the GPU, whoever asked for the frame.
    private func drawFrame() {
        guard let renderer, let layer = metalLayer, window != nil else { return }
        let size = drawablePixelSize
        guard size.width >= 1, size.height >= 1 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        needsRedraw = false
        let headroom = displayHeadroom
        lastFrameHeadroom = headroom
        renderer.draw(currentFrame(headroom: headroom), to: drawable,
                      presentsWithTransaction: layer.presentsWithTransaction)
    }

    private func currentFrame(headroom: Float) -> CanvasFrame {
        var frame = CanvasFrame(image: image, transform: transform, background: background,
                                displayHeadroom: headroom, pixelatedZoom: Preferences.shared.pixelatedZoom)
        if let location = magnifierLocation, image != nil {
            frame.magnifier = Magnifier(center: pixelPoint(location),
                                        radius: CGFloat(Preferences.shared.magnifierRadius) * backingScale,
                                        zoom: CanvasInteraction.magnifierZoom(preference: Preferences.shared.magnifierZoom,
                                                                              currentZoom: transform.zoom))
        }
        return frame
    }

    /// How far above SDR white the screen can show right now. Read on every
    /// frame because it changes with display brightness, and as the system
    /// ramps EDR up after an HDR image appears; each change posts
    /// `didChangeScreenParametersNotification`, which asks for a frame, so
    /// nothing polls. Without EDR on the layer it is 1 whatever the screen
    /// says: the compositor would clip anything brighter.
    private var displayHeadroom: Float {
        guard metalLayer?.wantsExtendedDynamicRangeContent == true, let screen = window?.screen else { return 1 }
        return max(1, Float(screen.maximumExtendedDynamicRangeColorComponentValue))
    }

    /// EDR on while an HDR image is shown on a screen that can show some of
    /// it (the potential headroom, which unlike the current one doesn't wait
    /// for someone to ask for EDR first). Off otherwise, because EDR raises
    /// the backlight and costs power for content that never needs it.
    private func updateDynamicRange() {
        guard let layer = metalLayer else { return }
        let potential = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        CanvasRenderer.setExtendedDynamicRange(
            CanvasRenderer.wantsExtendedDynamicRange(for: image, potentialHeadroom: potential), on: layer)
    }

    /// Renders the current frame offscreen as an 8-bit sRGB image, at the
    /// drawable's pixel size. SDR: highlights are tone mapped as on an SDR
    /// screen.
    func snapshotImage() -> CGImage? {
        let size = drawablePixelSize
        return renderer?.snapshot(currentFrame(headroom: 1), width: Int(size.width), height: Int(size.height))
    }

    // MARK: - Window, screen and size

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link retains its target, so it must not outlive the
        // window: that would keep the view alive forever.
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSWindow.didChangeScreenNotification, object: window)
        // An NSView display link follows the view to whichever screen it is on.
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDynamicRange()
        backingChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingChanged()
    }

    @objc private func screenParametersChanged() {
        // New screen, resolution or EDR headroom. When EDR content first
        // appears the system raises the headroom over a second or two and
        // posts this for each step, so the image brightens smoothly; then it
        // stops and the canvas is idle again.
        updateDynamicRange()
        // Another app's EDR (a video, say) posts this too. When scale, size
        // and the headroom the last frame used are all unchanged, the frame
        // on screen is still right: skip it.
        if !needsRedraw, let layer = metalLayer, layer.contentsScale == backingScale,
           layer.drawableSize == drawablePixelSize, lastFrameHeadroom == displayHeadroom {
            return
        }
        backingChanged()
    }

    private func backingChanged() {
        metalLayer?.contentsScale = backingScale
        sizeChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer?.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer?.presentsWithTransaction = false
        setNeedsRedraw()
    }

    /// Fit follows the window; any other zoom keeps the image point at the
    /// view centre where it is (`ViewportTransform.center` is exactly that
    /// point, so only the clamp is needed).
    ///
    /// A fitted zoom changes with the window, so the delegate hears about it
    /// (the zoom readout) and a window grown past the texture asks for more
    /// pixels, as any other zoom change would.
    private func sizeChanged() {
        let oldZoom = transform.zoom
        if zoomMode == .fit { applyFit() } else { clampTransform() }
        updatePannable()
        if image != nil, transform.zoom != oldZoom { delegate?.canvasDidChangeZoom(self) }
        requestFullResolutionIfNeeded()
        if inLiveResize, metalLayer?.presentsWithTransaction == true {
            // Draw now, inside the resize transaction, so the image never
            // shows stretched or a frame behind the window edge.
            drawFrame()
        } else {
            setNeedsRedraw()
        }
    }

    /// Settings changed: the next frame reads background, pixelated zoom and
    /// magnifier values afresh; "enlarge small images" changes the fit.
    private func preferencesChanged() {
        if zoomMode == .fit, image != nil {
            let old = transform
            applyFit()
            if transform != old {
                viewDidChange(zoomChanged: true)
                return
            }
        }
        setNeedsRedraw()
    }

    // MARK: - Cursor

    private func updatePannable() {
        let pannable = image.map {
            CanvasInteraction.imageExceedsView(transform, imageSize: $0.imageSize, viewSize: drawablePixelSize)
        } ?? false
        guard pannable != isPannable else { return }
        isPannable = pannable
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if isPannable { addCursorRect(bounds, cursor: .openHand) }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            cancelPress()
            // Triple clicks and beyond mean nothing more.
            guard event.clickCount == 2 else { return }
            // The first click of the pair already toggled the zoom; put it back
            // so a double-click means only what the delegate makes of it.
            if let before = viewBeforeClick, let image {
                transform = before.transform.clamped(imageSize: image.imageSize, viewSize: drawablePixelSize)
                zoomMode = before.mode
                viewBeforeClick = nil
                viewDidChange(zoomChanged: true)
            }
            delegate?.canvasDidDoubleClick(self)
            return
        }
        viewBeforeClick = nil
        let classifier = CanvasInteraction.PressClassifier(location: location, time: event.timestamp,
                                                           allowsHold: magnifierEnabled && image != nil)
        press = classifier
        lastDragLocation = location
        if classifier.allowsHold { scheduleHoldCheck(after: CanvasInteraction.PressClassifier.holdDelay) }
    }

    /// A one-shot check when the hold delay is up, for a pointer that never
    /// moves (no events arrive to ask). Not a repeating timer.
    private func scheduleHoldCheck(after delay: TimeInterval) {
        perform(#selector(holdDelayElapsed), with: nil, afterDelay: delay, inModes: [.common])
    }

    @objc private func holdDelayElapsed() {
        guard var current = press else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let state = current.update(time: now)
        press = current
        switch state {
        case .hold:
            beginMagnifier(at: lastDragLocation)
        case .pending:
            // The run loop can fire a hair before the event clock says the
            // delay is up; check once more for the remainder (bounded, in case
            // an event carried a timestamp from another clock).
            let remaining = current.startTime + CanvasInteraction.PressClassifier.holdDelay - now
            if remaining > 0, remaining < CanvasInteraction.PressClassifier.holdDelay {
                scheduleHoldCheck(after: remaining + 0.005)
            }
        case .click, .drag:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = press else { return }
        let location = convert(event.locationInWindow, from: nil)
        let state = current.moved(to: location, time: event.timestamp)
        press = current
        switch state {
        case .drag:
            cancelHoldTimer()
            if isPannable {
                NSCursor.closedHand.set()
                pan(byPoints: CGSize(width: location.x - lastDragLocation.x, height: location.y - lastDragLocation.y))
            }
        case .hold:
            if magnifierLocation == nil { beginMagnifier(at: location) } else { moveMagnifier(to: location) }
        case .pending, .click:
            break
        }
        lastDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        guard var current = press else { return }
        let location = convert(event.locationInWindow, from: nil)
        cancelPress()
        switch current.released(at: location, time: event.timestamp) {
        case .click:
            guard clickAction == .toggleZoom, image != nil else { return }
            viewBeforeClick = (transform, zoomMode)
            toggleFitActual(at: location)
        case .drag:
            window?.invalidateCursorRects(for: self)
        case .hold, .pending:
            break
        }
    }

    private func cancelPress() {
        cancelHoldTimer()
        press = nil
        endMagnifier()
    }

    private func cancelHoldTimer() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(holdDelayElapsed), object: nil)
    }

    /// Moves the content by `delta` view points (content follows the pointer).
    /// Also used by the viewer's arrow keys when zoomed in.
    func pan(byPoints delta: CGSize) {
        guard let image else { return }
        let pixels = CGSize(width: delta.width * backingScale, height: delta.height * backingScale)
        let moved = transform.panned(by: pixels).clamped(imageSize: image.imageSize, viewSize: drawablePixelSize)
        guard moved != transform else { return }
        transform = moved
        setNeedsRedraw()
    }

    // MARK: - Magnifier

    private func beginMagnifier(at location: CGPoint) {
        guard magnifierEnabled, image != nil else { return }
        magnifierLocation = location
        magnifierScroll = 0
        NSCursor.crosshair.set()
        setNeedsRedraw()
        requestFullResolutionIfNeeded()
    }

    private func moveMagnifier(to location: CGPoint) {
        magnifierLocation = location
        setNeedsRedraw()
    }

    private func endMagnifier() {
        guard magnifierLocation != nil else { return }
        magnifierLocation = nil
        window?.invalidateCursorRects(for: self)
        setNeedsRedraw()
    }

    /// Scrolling while the magnifier shows changes its zoom preference: one
    /// step per wheel notch, or per 20 points of trackpad travel.
    private func scrollMagnifier(_ event: NSEvent) {
        // Momentum would keep changing the zoom after the fingers lift.
        guard event.momentumPhase.isEmpty else { return }
        let prefs = Preferences.shared
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            magnifierScroll += dy
            while abs(magnifierScroll) >= 20 {
                steps += magnifierScroll > 0 ? 1 : -1
                magnifierScroll -= magnifierScroll > 0 ? 20 : -20
            }
        } else if dy != 0 {
            steps = dy > 0 ? 1 : -1
        }
        guard steps != 0 else { return }
        var zoom = prefs.magnifierZoom
        for _ in 0..<abs(steps) { zoom = CanvasInteraction.steppedMagnifierZoom(zoom, in: steps > 0) }
        prefs.magnifierZoom = zoom   // the preferences observer redraws
        requestFullResolutionIfNeeded()
    }

    // MARK: - Scroll and gestures

    override func scrollWheel(with event: NSEvent) {
        if magnifierLocation != nil {
            scrollMagnifier(event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        let wheelEvent = CanvasInteraction.WheelEvent(
            mode: Preferences.shared.wheelAction == .zoom ? .zoom : .navigate,
            commandKey: event.modifierFlags.contains(.command),
            precise: event.hasPreciseScrollingDeltas,
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            invertedFromDevice: event.isDirectionInvertedFromDevice,
            phase: Self.phase(event.phase), momentumPhase: Self.phase(event.momentumPhase),
            imageExceedsView: isPannable)
        switch wheel.interpret(wheelEvent) {
        case .navigate(let offset):
            delegate?.canvasRequestsNavigation(self, offset: offset)
        case .zoom(let factor):
            zoom(by: factor, at: location)
        case .pan(let delta):
            pan(byPoints: delta)
        case .none:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        toggleFitActual(at: convert(event.locationInWindow, from: nil))
    }

    private static func phase(_ phase: NSEvent.Phase) -> CanvasInteraction.ScrollPhase {
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }
}
