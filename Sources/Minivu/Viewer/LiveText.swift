import AppKit
import VisionKit
import MinivuCore
import MinivuRender

/// What Live Text recognised in one picture: all of its text, and
/// VisionKit's analysis for the overlay (nil from a test's fake, which has
/// no way to make one).
struct LiveTextResult {
    var transcript: String
    var analysis: ImageAnalysis?
}

/// Recognises the text in a picture. VisionKit in the app; tests pass a
/// fake, so no test depends on what the system's recogniser makes of a
/// picture, or on its being there at all.
protocol LiveTextAnalyzing: AnyObject {
    /// Whether this Mac can recognise text at all.
    var isSupported: Bool { get }
    func analyze(_ image: CGImage) async throws -> LiveTextResult
}

/// VisionKit's `ImageAnalyzer`, asked for text and nothing else.
///
/// Text recognition runs on the Mac. Visual Look Up, the other analysis a
/// photo app is offered, identifies plants, landmarks and artworks by
/// asking Apple's servers, and minivu has no network entitlement and must
/// never depend on the network, so it is not requested; nor are machine-
/// readable codes, which nothing here would use. The overlay asks for text
/// selection only (see `LiveTextController`), so it never offers a Look Up
/// either.
final class VisionLiveTextAnalyzer: LiveTextAnalyzing {
    /// Made on first use: the first picture analysed, not the viewer
    /// opening, pays for setting it up.
    private lazy var analyzer = ImageAnalyzer()

    var isSupported: Bool { ImageAnalyzer.isSupported }

    func analyze(_ image: CGImage) async throws -> LiveTextResult {
        // Text and nothing else. A value made for this one call and never
        // touched again, so handing it to VisionKit off the main actor
        // shares nothing; the type just isn't marked Sendable.
        nonisolated(unsafe) let configuration = ImageAnalyzer.Configuration(.text)
        let analysis = try await analyzer.analyze(image, orientation: .up, configuration: configuration)
        return LiveTextResult(transcript: analysis.transcript, analysis: analysis)
    }
}

/// The viewer's Live Text, as in Preview: text in the picture can be
/// selected with the pointer and copied, and Edit > Copy Text copies all of
/// it.
///
/// An `ImageAnalysisOverlayView` lies over the Metal canvas, on the
/// canvas's frame, and is told where the picture is within it
/// (`contentsRect(for:)`) after every zoom, pan and resize, so the
/// selectable text stays on the pixels it was read from. The analysis is
/// in the picture's own coordinates, so it outlives every change of view,
/// full screen included.
///
/// **What is analysed** is the picture on the canvas, read back from its
/// texture (`LiveTextImage`): the page shown, an edit's render, the frame a
/// paused animation stopped on. A `Subject` names it, so a sharper copy of
/// the same picture (the user zoomed in) keeps its analysis and anything
/// that changes the picture drops it. A copy at least twice as sharp as the
/// one analysed (counted up to `LiveTextImage.maximumLongEdge`) is
/// analysed once more, the first analysis staying until the second is
/// ready: text too small to read in a picture fitted to the window becomes
/// selectable when the user zooms in to read it, as in Preview, which reads
/// the whole image. The subject is taken when each
/// texture arrives rather than when the analysis starts: an edit changes
/// the document at once but its render comes a moment later, and the
/// picture still on screen meanwhile must not be filed under the edit.
///
/// **When** is lazily. Flipping through a folder with the keyboard analyses
/// nothing, however long each image stays up. Analysis is asked for when
/// the pointer moves over the picture, which is when the user might select
/// something, or by Copy Text, and it starts only once the picture has been
/// on screen for `settleDelay`, so passing over an image on the way to the
/// next one costs nothing. It runs off the main thread, at most one at a
/// time, and is cancelled as soon as the picture it is for leaves the
/// screen. An idle viewer does no work.
///
/// **Not offered** while an edit tool is open (the tool owns the pointer and
/// the picture is changing), while an animation plays, or when View > Live
/// Text is off.
///
/// Data detectors (links, phone numbers, addresses) are left off. Each would
/// underline part of the photo and turn a click there into opening Safari,
/// Maps or FaceTime: another application, and a network connection, from a
/// click that everywhere else on the image toggles the zoom. Selecting the
/// text and copying it does everything they would, at the user's word.
final class LiveTextController: NSObject, ImageAnalysisOverlayViewDelegate {
    /// The picture a texture shows. Equal subjects are the same picture at
    /// whatever resolution.
    struct Subject: Equatable {
        var url: URL
        var modified: Date?
        var page: Int
        /// The edit drawn, an open tool's unapplied change included; empty
        /// for the file as it is.
        var operations: [EditOperation]
        /// The frame a paused animation shows; nil for a still image.
        var frame: Int?
    }

    let host: LiveTextOverlayHost
    var overlay: ImageAnalysisOverlayView { host.overlay }
    var analyzer: LiveTextAnalyzing = VisionLiveTextAnalyzer()
    /// How long a picture must have been on screen before it is analysed.
    var settleDelay: TimeInterval = 0.4
    /// Where the picture lies in the canvas, in the canvas's own points, or
    /// nil when there is none.
    var pictureRect: () -> CGRect? = { nil }
    /// The canvas the overlay lies over, for converting `pictureRect`.
    weak var canvas: NSView?

    /// The texture on the canvas and the picture it shows.
    private(set) var shown: (texture: ImageTexture, subject: Subject)?
    /// The analysis of a picture, kept while that picture is on screen, and
    /// the long side of the image it was read from (`analysedSide(of:)`).
    private(set) var result: (subject: Subject, value: LiveTextResult, side: Int)?
    private var running: (subject: Subject, side: Int, task: Task<LiveTextResult?, Never>, number: Int)?
    /// Counts analyses started, so one cancelled and replaced by another of
    /// the same picture can't report in its place.
    private var started = 0
    private var settleWork: DispatchWorkItem?
    /// When the current texture arrived, in system uptime.
    private var shownSince: TimeInterval = 0
    /// Whether analysis may run and the overlay take the pointer.
    private(set) var isActive = false

    override init() {
        host = LiveTextOverlayHost(overlay: ImageAnalysisOverlayView())
        super.init()
        overlay.delegate = self
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        overlay.selectableItemsHighlighted = false
        overlay.setAccessibilityLabel(localized("Text in the image"))
        host.isHidden = true
    }

    // MARK: - What is shown

    /// The canvas shows another texture, or none. Called for every texture,
    /// sharper copies and animation frames included, so it does no work
    /// beyond comparing subjects and sizes.
    func show(_ texture: ImageTexture?, subject: Subject?) {
        guard let texture, let subject else {
            shown = nil
            forget()
            return
        }
        let changed = shown?.subject != subject
        shown = (texture, subject)
        guard changed else {
            // A sharper copy of a picture whose text the user has asked for
            // already (it is analysed, or being analysed): read it again
            // if it is at least twice as sharp. Nothing else asks, since the
            // user may zoom with the keyboard and never move the pointer.
            if result != nil || running != nil, needsAnalysis { requestAnalysis() }
            return
        }
        shownSince = ProcessInfo.processInfo.systemUptime
        if result?.subject != subject { forget() }
        if let running, running.subject != subject {
            running.task.cancel()
            self.running = nil
        }
        settleWork?.cancel()
        settleWork = nil
    }

    /// The user is moving to another picture: work for the one on screen
    /// is no longer wanted. Its analysis, if made, stays until the next
    /// texture replaces it, since the picture stays up until then.
    func cancelPending() {
        settleWork?.cancel()
        settleWork = nil
        running?.task.cancel()
        running = nil
    }

    /// Whether analysis may run and the overlay take the pointer. Turning
    /// it off stops all work and takes the overlay away. The analysis of
    /// the picture on screen is kept and comes back with Live Text for that
    /// same picture, so closing an edit tool that changed nothing doesn't
    /// read the picture again; any other picture drops it (`show`).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        host.isHidden = !active
        if !active {
            cancelPending()
            if overlay.analysis != nil { overlay.analysis = nil }
        } else if let result, result.subject == shown?.subject {
            overlay.analysis = result.value.analysis
            overlay.setContentsRectNeedsUpdate()
        }
    }

    /// Ends every piece of work, for a closing viewer.
    func stop() {
        setActive(false)
        shown = nil
        forget()
    }

    private func forget() {
        result = nil
        if overlay.analysis != nil { overlay.analysis = nil }
    }

    // MARK: - Analysis

    /// The long side of the image analysing `texture` hands the recogniser:
    /// the texture's own, up to `LiveTextImage.maximumLongEdge`.
    static func analysedSide(of texture: ImageTexture) -> Int {
        min(max(texture.texture.width, texture.texture.height), LiveTextImage.maximumLongEdge)
    }

    /// Whether the picture on screen wants analysing: nothing is made or
    /// under way for it, or only from a copy less than half as sharp as
    /// the one shown now.
    private var needsAnalysis: Bool {
        guard let shown else { return false }
        let side = Self.analysedSide(of: shown.texture)
        if let result, result.subject == shown.subject, side < 2 * result.side { return false }
        if let running, running.subject == shown.subject, side < 2 * running.side { return false }
        return true
    }

    /// The pointer moved over the picture: the user may be about to select
    /// text, so the picture is analysed once it has settled.
    func pointerMoved() {
        requestAnalysis()
    }

    /// Analyses the picture on screen once it has been there for
    /// `settleDelay`, unless that is done, running or already waiting.
    func requestAnalysis() {
        guard isActive, analyzer.isSupported, needsAnalysis, settleWork == nil else { return }
        let wait = shownSince + settleDelay - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else {
            start()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.settleWork = nil
            self?.start()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// What Copy Text gets from `recognisedText()`.
    enum Recognition: Equatable {
        /// All the text read; empty when the picture has none.
        case text(String)
        /// Nothing could be read: no picture, or the analysis failed.
        case failed
        /// The user moved on before the analysis finished: another picture,
        /// or Live Text put aside. Nothing to report.
        case cancelled
    }

    /// All the text recognised in the picture on screen, analysing it now
    /// if that hasn't been done (Copy Text doesn't wait for the picture to
    /// settle: the user asked), or if only a much less sharp copy was read.
    func recognisedText() async -> Recognition {
        guard isActive, analyzer.isSupported, let subject = shown?.subject else { return .failed }
        if needsAnalysis {
            settleWork?.cancel()
            settleWork = nil
            start()
        }
        // The analysis under way, and any sharper one that replaces it
        // meanwhile (a texture twice as sharp arrived).
        var cancelled = false
        while let task = running?.task, running?.subject == subject {
            let value = await task.value
            guard isActive, shown?.subject == subject else { return .cancelled }
            if let value { return .text(value.transcript) }
            cancelled = task.isCancelled
            if running?.task == task { break }
        }
        // A sharper reading that didn't finish leaves the first one.
        if result?.subject == subject, let result { return .text(result.value.transcript) }
        return cancelled ? .cancelled : .failed
    }

    /// Reads the texture back off the main thread, recognises its text and
    /// keeps the result if the picture is still the one on screen.
    private func start() {
        guard isActive, let (texture, subject) = shown else { return }
        running?.task.cancel()
        let analyzer = analyzer
        started += 1
        let number = started
        let side = Self.analysedSide(of: texture)
        let task = Task { [weak self] () -> LiveTextResult? in
            let image = await BlockingWork.run { LiveTextImage.render(texture) }
            guard !Task.isCancelled else { return nil }
            let value: LiveTextResult? = if let image { try? await analyzer.analyze(image) } else { nil }
            guard !Task.isCancelled else { return nil }
            self?.finished(value, side: side, number: number, for: subject)
            return value
        }
        running = (subject, side, task, number)
    }

    private func finished(_ value: LiveTextResult?, side: Int, number: Int, for subject: Subject) {
        guard running?.number == number else { return }
        running = nil
        guard isActive, let value, shown?.subject == subject else { return }
        result = (subject, value, side)
        overlay.analysis = value.analysis
        overlay.setContentsRectNeedsUpdate()
    }

    /// For tests: the analysis under way, if any.
    var runningTask: Task<LiveTextResult?, Never>? { running?.task }
    var isWaitingToSettle: Bool { settleWork != nil }

    // MARK: - Selection

    /// The text selected with the pointer, or nil when there is none.
    var selectedText: String? {
        guard overlay.analysis != nil, overlay.hasActiveTextSelection else { return nil }
        let text = overlay.selectedText
        return text.isEmpty ? nil : text
    }

    /// A press in the window: one away from the text ends a selection, as a
    /// click beside selected text does anywhere else. `point` is in window
    /// coordinates.
    func mouseDown(atWindowPoint point: CGPoint) {
        guard overlay.analysis != nil, overlay.hasActiveTextSelection else { return }
        if !overlay.hasText(at: host.overlayPoint(overlay.convert(point, from: nil))) { overlay.resetSelection() }
    }

    // MARK: - Following the canvas

    /// Zoom, pan or the canvas's size changed.
    func viewChanged() {
        if overlay.analysis != nil { overlay.setContentsRectNeedsUpdate() }
    }

    /// The picture's rectangle as a fraction of the overlay's bounds,
    /// measured from the top left: VisionKit's unit space counts down from
    /// the top whatever the view's own coordinates (measured: the overlay
    /// is not flipped, yet text drawn at the top of a picture is found by
    /// `hasText(at:)` near y = 0). Zoomed in, it reaches past the bounds on
    /// the sides cut off; panned, it moves with the picture.
    static func contentsRect(of picture: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (picture.minX - bounds.minX) / bounds.width, y: (picture.minY - bounds.minY) / bounds.height,
                      width: picture.width / bounds.width, height: picture.height / bounds.height)
    }

    // MARK: - ImageAnalysisOverlayViewDelegate

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        guard let canvas, let picture = pictureRect() else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var rect = overlayView.convert(picture, from: canvas)
        if !overlayView.isFlipped { rect.origin.y = overlayView.bounds.height - rect.maxY }
        return Self.contentsRect(of: rect, in: overlayView.bounds)
    }

    /// Selection only, and only on text.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        analysisType.contains(.textSelection) && overlayView.hasText(at: point)
    }

    /// The text's own menu (Copy, Look Up in the dictionary, Services)
    /// stays; the items about the image as a whole go, since the viewer's
    /// own commands already copy and share it and its subject lifting is
    /// not asked for.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent,
                     at point: CGPoint) -> NSMenu {
        let imageTags: Set<Int> = [ImageAnalysisOverlayView.MenuTag.copyImage, ImageAnalysisOverlayView.MenuTag.shareImage,
                                   ImageAnalysisOverlayView.MenuTag.copySubject,
                                   ImageAnalysisOverlayView.MenuTag.shareSubject,
                                   ImageAnalysisOverlayView.MenuTag.lookupItem]
        for item in menu.items where imageTags.contains(item.tag) {
            menu.removeItem(item)
        }
        return menu
    }

    /// Once nothing is selected the keyboard goes back to the canvas, so
    /// the arrow keys flip images and Copy copies the picture again.
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        guard !overlayView.hasActiveTextSelection, let window = overlayView.window,
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: host),
              let canvas else { return }
        window.makeFirstResponder(canvas)
    }
}

/// Holds the overlay on the canvas's frame and lets the pointer through to
/// the canvas everywhere but on text: a click beside the text still toggles
/// the zoom, a drag there still pans and a press and hold still shows the
/// magnifier.
final class LiveTextOverlayHost: NSView {
    let overlay: ImageAnalysisOverlayView

    init(overlay: ImageAnalysisOverlayView) {
        self.overlay = overlay
        super.init(frame: .zero)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        // Only the overlay's text is worth announcing, not this holder.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, overlay.analysis != nil else { return nil }
        let local = overlay.convert(point, from: superview)
        guard overlay.hasText(at: overlayPoint(local)) || overlay.hasActiveTextSelection && overlay.bounds.contains(local)
        else { return nil }
        return super.hitTest(point)
    }

    /// A point in the overlay's coordinates as `hasText(at:)` takes it:
    /// from the top left, like `contentsRect` (see
    /// `LiveTextController.contentsRect(of:in:)`).
    func overlayPoint(_ local: CGPoint) -> CGPoint {
        overlay.isFlipped ? local : CGPoint(x: local.x, y: overlay.bounds.height - local.y)
    }
}
