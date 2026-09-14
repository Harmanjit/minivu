import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// Settings > Slideshow's preview: the chosen transition, drawn by the
/// slideshow's own shader between two small made-up pictures.
///
/// At rest it shows the transition half way, which says what it does
/// without moving. When the transition or its duration changes, or the
/// preview is clicked, it plays once at the chosen speed, holds the new
/// picture a moment and settles back. The display link runs only while it
/// plays, so an open Settings window costs nothing.
struct SlideshowTransitionPreview: NSViewRepresentable {
    var choice: SlideshowSettings.TransitionChoice
    var duration: Double

    func makeNSView(context: Context) -> SlideshowTransitionPreviewView {
        let view = SlideshowTransitionPreviewView()
        view.configure(choice: choice, duration: duration, animate: false)
        return view
    }

    func updateNSView(_ view: SlideshowTransitionPreviewView, context: Context) {
        view.configure(choice: choice, duration: duration, animate: true)
    }
}

final class SlideshowTransitionPreviewView: NSView, SnapshotProviding {
    /// Settled progress: the transition half way.
    static let restingProgress: Float = 0.5
    /// How long the new picture stays after playing.
    static let holdDuration: TimeInterval = 0.7

    private let renderer = try? SlideshowRenderer()
    private var displayLink: CADisplayLink?
    private var needsRedraw = true
    private var choice: SlideshowSettings.TransitionChoice?
    private var duration: Double = 1
    /// The transition shown; in random mode, the last one picked.
    private var transition: SlideshowTransition = .crossFade
    private var playStart: CFTimeInterval?
    private var frameTime: CFTimeInterval = 0
    private var settleWork: DispatchWorkItem?
    /// Showing the new picture after playing, until it settles.
    private var holding = false

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        toolTip = "Click to play"
        SlideshowPreviewPictures.load { [weak self] in self?.setNeedsRedraw() }
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

    /// Takes new settings; a real change plays the transition.
    func configure(choice: SlideshowSettings.TransitionChoice, duration: Double, animate: Bool) {
        let changed = choice != self.choice || duration != self.duration
        let choiceChanged = choice != self.choice
        self.choice = choice
        self.duration = duration
        if choiceChanged {
            switch choice {
            case .fixed(let fixed): transition = fixed
            case .random: transition = .random(after: nil)
            }
        }
        if changed, animate { play() } else if changed { setNeedsRedraw() }
    }

    override func mouseDown(with event: NSEvent) {
        play()
    }

    private func play() {
        if choice == .random { transition = .random(after: transition) }
        settleWork?.cancel()
        settleWork = nil
        holding = false
        playStart = CACurrentMediaTime()
        frameTime = playStart ?? 0
        displayLink?.isPaused = false
    }

    private var progress: Float {
        if holding { return 1 }
        guard let playStart else { return Self.restingProgress }
        return Float(min(max((frameTime - playStart) / max(duration, 0.1), 0), 1))
    }

    private func setNeedsRedraw() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        frameTime = link.targetTimestamp
        if let playStart, frameTime - playStart >= duration {
            self.playStart = nil
            holding = true
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.holding = false
                self.settleWork = nil
                self.setNeedsRedraw()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
            needsRedraw = true
        }
        link.isPaused = playStart == nil
        guard playStart != nil || needsRedraw else { return }
        draw()
    }

    private var currentFrame: SlideshowFrame {
        SlideshowFrame(from: SlideshowPreviewPictures.first, to: SlideshowPreviewPictures.second, transition: transition,
                       progress: progress, enlargeSmallImages: true)
    }

    private func draw() {
        guard let renderer, let layer = metalLayer, let window else { return }
        let scale = window.backingScaleFactor
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        layer.contentsScale = scale
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        needsRedraw = false
        renderer.draw(currentFrame, to: drawable)
    }

    func snapshotImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        return renderer?.snapshot(currentFrame, width: Int(bounds.width * scale), height: Int(bounds.height * scale))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        settleWork?.cancel()
        settleWork = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRedraw()
    }
}

/// Two small pictures for the preview, drawn once with Core Graphics: a
/// warm evening and a cool night, different enough in colour and shape that
/// every transition reads.
enum SlideshowPreviewPictures {
    private(set) static var first: ImageTexture?
    private(set) static var second: ImageTexture?
    private static var waiting: [() -> Void] = []
    private static var loading = false

    nonisolated static let pixelSize = CGSize(width: 640, height: 360)

    /// Calls `ready` once both exist (at once if they do).
    static func load(_ ready: @escaping () -> Void) {
        if first != nil, second != nil { return ready() }
        waiting.append(ready)
        guard !loading else { return }
        loading = true
        Task {
            let textures = await BlockingWork.run(qos: .userInitiated) { () -> (ImageTexture?, ImageTexture?) in
                (upload(drawEvening()), upload(drawNight()))
            }
            first = textures.0
            second = textures.1
            loading = false
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    nonisolated private static func upload(_ image: CGImage?) -> ImageTexture? {
        guard let image else { return nil }
        let decoded = DecodedImage(image: image, orientation: .up, imageSize: CGSize(width: image.width, height: image.height),
                                   isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        return try? TextureUploader.upload(decoded)
    }

    nonisolated private static func context() -> CGContext? {
        CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    nonisolated private static func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: [bottom, top] as CFArray,
                   locations: [0, 1])
    }

    /// Sunset sky, a low sun, and dark hills.
    nonisolated private static func drawEvening() -> CGImage? {
        guard let c = context() else { return nil }
        let w = pixelSize.width, h = pixelSize.height
        if let sky = gradient(CGColor(red: 0.35, green: 0.2, blue: 0.55, alpha: 1),
                              CGColor(red: 1.0, green: 0.62, blue: 0.3, alpha: 1)) {
            c.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.3), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        c.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.6, alpha: 1))
        c.fillEllipse(in: CGRect(x: w * 0.58, y: h * 0.32, width: h * 0.34, height: h * 0.34))
        c.setFillColor(CGColor(red: 0.28, green: 0.12, blue: 0.2, alpha: 1))
        let far = CGMutablePath()
        far.move(to: .zero)
        far.addCurve(to: CGPoint(x: w, y: h * 0.3), control1: CGPoint(x: w * 0.3, y: h * 0.62),
                     control2: CGPoint(x: w * 0.6, y: h * 0.1))
        far.addLine(to: CGPoint(x: w, y: 0))
        c.addPath(far)
        c.fillPath()
        c.setFillColor(CGColor(red: 0.14, green: 0.06, blue: 0.12, alpha: 1))
        let near = CGMutablePath()
        near.move(to: CGPoint(x: 0, y: h * 0.18))
        near.addCurve(to: CGPoint(x: w, y: h * 0.12), control1: CGPoint(x: w * 0.4, y: h * 0.02),
                      control2: CGPoint(x: w * 0.7, y: h * 0.36))
        near.addLine(to: CGPoint(x: w, y: 0))
        near.addLine(to: .zero)
        c.addPath(near)
        c.fillPath()
        return c.makeImage()
    }

    /// Deep blue sky, a moon, and a sea with a pale reflection.
    nonisolated private static func drawNight() -> CGImage? {
        guard let c = context() else { return nil }
        let w = pixelSize.width, h = pixelSize.height
        if let sky = gradient(CGColor(red: 0.02, green: 0.05, blue: 0.18, alpha: 1),
                              CGColor(red: 0.12, green: 0.35, blue: 0.55, alpha: 1)) {
            c.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        c.setFillColor(CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1))
        c.fillEllipse(in: CGRect(x: w * 0.2, y: h * 0.62, width: h * 0.2, height: h * 0.2))
        c.setFillColor(CGColor(red: 0.03, green: 0.14, blue: 0.24, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.4))
        c.setFillColor(CGColor(red: 0.8, green: 0.88, blue: 1, alpha: 0.5))
        for row in 0..<6 {
            let y = h * (0.34 - CGFloat(row) * 0.055)
            let width = h * (0.16 - CGFloat(row) * 0.015)
            c.fill(CGRect(x: w * 0.2 + h * 0.1 - width / 2, y: y, width: width, height: h * 0.012))
        }
        return c.makeImage()
    }
}
