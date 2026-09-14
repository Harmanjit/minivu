import AppKit
import Combine
import MinivuCore
import MinivuRender

/// The slideshow's window: borderless, black, exactly covering one screen.
final class SlideshowWindow: NSWindow {
    /// ⌘W and Esc (when no view handled it first).
    var onClose: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Windows made in code must not free themselves on close: the
        // controller still holds this one.
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        // Normal level, as the viewer's full screen: it covers the desktop
        // and the app's windows, but alerts and Settings come in front.
        level = .normal
        collectionBehavior = [.fullScreenNone, .managed]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// AppKit enables File > Close Window only for windows with a close
    /// button, which a borderless one lacks, so ⌘W would just beep.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return onClose != nil }
        return super.validateMenuItem(menuItem)
    }
}

/// Holds the picture, the caption and the control bar, and hands keys, clicks
/// and pointer movement to the controller.
final class SlideshowContentView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onClick: (() -> Void)?
    var onPointerMoved: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

/// A slideshow (DESIGN.md 5, Tools): full screen on one display, one slide at
/// a time with a Metal transition between them, captions, and music.
///
/// What plays when is `SlideshowSequence`; the music is `SlideshowMusic`;
/// the picture is `SlideshowView`. This is the glue, and the timing:
///
/// - **Nothing runs between slides** but one scheduled work item for the
///   next. The display link runs only while a transition animates.
/// - **The next and previous slides decode ahead** through
///   `ImageLoader.shared` at the screen's size, so a transition starts the
///   moment the interval is up. If an image isn't ready, the show waits for
///   it; if it can't load, it is skipped.
/// - **A key press never waits for a transition**: → or ← finishes the one
///   under way at once and starts a quick one.
final class SlideshowWindowController: NSWindowController, NSWindowDelegate {
    /// The slideshow on screen, if any. There is one at a time.
    private(set) static var current: SlideshowWindowController?
    /// Where settings are read; tests use a store of their own.
    static var settingsStore = SlideshowSettingsStore.shared
    /// Makes the music's audio player; tests use a silent fake.
    static var makeAudioPlayer: () -> SlideshowAudioPlaying = { SlideshowAudioPlayer() }

    /// Transitions for → and ←: quick, or the setting if that's quicker.
    static let quickTransitionDuration: TimeInterval = 0.35
    /// Pointer stillness before the control bar and cursor hide.
    static let controlsHideDelay: TimeInterval = 2

    /// Starts a slideshow of `images` from `startIndex` on `screen` (nil for
    /// the main screen). `onEnd` gets the image last shown, when the show
    /// ends. With a slideshow already running, it comes forward instead.
    @discardableResult
    static func start(images: [FolderEntry], startIndex: Int, screen: NSScreen?,
                      onEnd: @escaping (FolderEntry?) -> Void) -> SlideshowWindowController? {
        guard !images.isEmpty else { return nil }
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return current
        }
        let controller = SlideshowWindowController(images: images, startIndex: startIndex, screen: screen,
                                                   store: settingsStore, onEnd: onEnd)
        current = controller
        controller.begin()
        return controller
    }

    /// How the show moves.
    private enum Step: Equatable {
        /// The opening slide, faded in from black.
        case first
        /// The interval is up.
        case auto
        /// → and ←.
        case next, previous
    }

    private struct Slide {
        var index: Int
        var texture: ImageTexture
    }

    private struct Transition {
        var from: ImageTexture?
        var to: ImageTexture
        var kind: SlideshowTransition
        var direction: SlideshowDirection
        var start: CFTimeInterval
        var duration: CFTimeInterval
        /// Debug only: held at this progress (see `debugFreezeSlideshowTransition`).
        var frozenProgress: Float?
    }

    let images: [FolderEntry]
    private(set) var sequence: SlideshowSequence
    private let store: SlideshowSettingsStore
    private var settings: SlideshowSettings { store.settings }
    private let onEnd: (FolderEntry?) -> Void
    /// Long edge of the screen in pixels: the size slides decode at.
    private let pixelSize: Int
    private let music: SlideshowMusic?

    private let content = SlideshowContentView()
    private let slideView = SlideshowView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let caption = SlideshowCaptionView()
    private let controlBar = SlideshowControlBar()

    /// The slide on screen, or arriving in the transition under way.
    private var shown: Slide?
    private var transition: Transition?
    /// When the frame being drawn will show, from the display link.
    private var frameTime: CFTimeInterval = 0
    private var lastTransition: SlideshowTransition?
    /// Decoded neighbours, ready to show.
    private var ready: [Int: ImageTexture] = [:]
    private var handles: [Int: LoadHandle] = [:]
    /// A move waiting for its image to decode.
    private var pendingStep: Step?
    private var advanceWork: DispatchWorkItem?
    private(set) var isPaused = false
    /// Paused by the gear button; resumes when the slideshow is key again.
    private var pausedForSettings = false
    private var activity: NSObjectProtocol?
    /// Settings' Volume and Play Music, followed by the music while the show runs.
    private var musicSettings: AnyCancellable?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private(set) var hasEnded = false

    private var controlsWork: DispatchWorkItem?
    private var lastPointerMove: TimeInterval = 0
    /// Debug only: the bar stays up.
    private var controlsPinned = false

    /// Metadata for captions, for the slides around the current one.
    private var summaries: [URL: MetadataSummary] = [:]
    private var summaryTasks: [URL: Task<Void, Never>] = [:]

    /// Debug only (snapshots): a transition held part way, and a caption style.
    private var debugFreeze: (kind: SlideshowTransition, progress: Float)?
    private var debugCaption: SlideshowSettings.Caption?

    private init(images: [FolderEntry], startIndex: Int, screen: NSScreen?, store: SlideshowSettingsStore,
                 onEnd: @escaping (FolderEntry?) -> Void) {
        self.images = images
        self.store = store
        self.onEnd = onEnd
        let settings = store.settings
        sequence = SlideshowSequence(count: images.count, start: startIndex, shuffled: settings.order == .shuffle,
                                     loops: settings.loop)
        music = settings.playsMusic
            ? SlideshowMusic(items: settings.playlist, shuffle: settings.shuffleMusic, volume: settings.volume,
                             player: Self.makeAudioPlayer(),
                             refreshBookmarks: { [store] refreshed in store.refreshPlaylistBookmarks(refreshed) })
            : nil
        let screen = screen ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        pixelSize = Int((max(frame.width, frame.height) * (screen?.backingScaleFactor ?? 2)).rounded())
        let window = SlideshowWindow(frame: frame)
        super.init(window: window)
        // Borderless content rects can be adjusted on creation; the frame
        // must be exactly the screen's.
        window.setFrame(frame, display: false)
        window.delegate = self
        window.onClose = { [weak self] in self?.end() }
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    private func buildContent(in window: NSWindow) {
        window.contentView = content
        content.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        content.onClick = { [weak self] in self?.end() }
        content.onPointerMoved = { [weak self] in self?.pointerMoved() }

        slideView.frame = content.bounds
        slideView.autoresizingMask = [.width, .height]
        slideView.frameProvider = { [weak self] headroom in
            self?.currentFrame(headroom: headroom) ?? .still(nil)
        }
        slideView.onAnimationFrame = { [weak self] time in self?.animationFrame(at: time) }
        content.addSubview(slideView)

        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.onCommand = { [weak self] command in self?.controlBarCommand(command) }
        content.addSubview(controlBar)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: controlBar.leadingAnchor, constant: -24),
            controlBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
        ])
        updateControls()
    }

    // MARK: - Starting and ending

    private func begin() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        // A slideshow is watched, not worked in: the display mustn't sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                         reason: "Slideshow")
        NSCursor.setHiddenUntilMouseMoves(true)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaySettingsChanged),
                                               name: .minivuDisplaySettingsChanged, object: nil)
        // Settings can be open beside the show (its gear pauses it): the
        // volume and Play Music apply to the music at once. The playlist,
        // shuffle and order stay as the show started.
        if let music {
            musicSettings = store.$settings
                .map { ($0.volume, $0.musicEnabled) }
                .removeDuplicates { $0 == $1 }
                .sink { [weak music] volume, enabled in
                    music?.setVolume(volume)
                    music?.setEnabled(enabled)
                }
        }
        slideView.setNeedsRedraw()
        perform(.first)
    }

    /// Esc, a click, the close button, ⌘W, or the end of a show that doesn't
    /// loop. Stops all work, gives the display its sleep back, lets the music
    /// fade out, and reports the last slide.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        advanceWork?.cancel()
        controlsWork?.cancel()
        summaryTasks.values.forEach { $0.cancel() }
        summaryTasks = [:]
        handles.values.forEach { $0.cancel() }
        handles = [:]
        ready = [:]
        pendingStep = nil
        transition = nil
        slideView.stopAnimating()
        musicSettings = nil
        music?.finish()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        NotificationCenter.default.removeObserver(self)
        restorePresentationOptions()
        NSCursor.setHiddenUntilMouseMoves(false)

        let entry = shown.map { images[$0.index] }
        slideView.frameProvider = nil
        slideView.onAnimationFrame = nil
        if let window = window as? SlideshowWindow {
            window.delegate = nil
            window.onClose = nil
            // Taking the view out of the window stops its display link, which
            // would otherwise keep the view and renderer alive.
            window.contentView = nil
            window.close()
        }
        if Self.current === self { Self.current = nil }
        onEnd(entry)
    }

    // MARK: - Moving

    /// Moves the show, once the slide it moves to has decoded.
    private func perform(_ step: Step) {
        guard !hasEnded else { return }
        let target: Int? = switch step {
        case .first: sequence.current.flatMap { sequence.failed.contains($0) ? sequence.next : $0 }
        case .auto, .next: sequence.next
        case .previous: sequence.previous
        }
        guard let target else {
            pendingStep = nil
            // The end of a show that doesn't loop, or nothing would load. A
            // looping show with one playable slide just keeps showing it, and
            // a key press at either end only brings the controls up.
            if step == .first || !sequence.hasPlayable || (step == .auto && sequence.isOverAfterCurrent) {
                end()
            } else if step != .auto {
                pointerMoved()
            }
            return
        }
        // Cleared before asking for the texture: a cache hit delivers at once
        // through `loaded`, which would otherwise run the stale pending step
        // too and move the show twice.
        pendingStep = nil
        guard let texture = texture(for: target) else {
            if sequence.failed.contains(target) {
                perform(step)   // it failed at once: on to the one after
            } else {
                pendingStep = step
            }
            return
        }
        guard !hasEnded else { return }
        switch step {
        case .first: if sequence.current != target { sequence.advance() }
        case .auto, .next: sequence.advance()
        case .previous: sequence.goBack()
        }
        show(texture, index: target, step: step)
    }

    /// The texture for image `index` if it has decoded; otherwise asks for it.
    private func texture(for index: Int) -> ImageTexture? {
        if let texture = ready[index] { return texture }
        request(index)
        return ready[index]   // a cache hit arrives at once
    }

    private func request(_ index: Int) {
        guard ready[index] == nil, handles[index] == nil, !sequence.failed.contains(index) else { return }
        var delivered = false
        let handle = AppServices.images.load(images[index], pixelSize: pixelSize) { [weak self] result in
            delivered = true
            self?.loaded(index, result)
        }
        if !delivered { handles[index] = handle }
    }

    private func loaded(_ index: Int, _ result: Result<ImageTexture, Error>) {
        handles[index] = nil
        guard !hasEnded else { return }
        switch result {
        case .success(let texture):
            ready[index] = texture
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            log.info("Slideshow skips \(self.images[index].name, privacy: .public): \(error, privacy: .public)")
            sequence.markFailed(index)
        }
        if let step = pendingStep { perform(step) }
        if debugFreeze != nil { applyDebugFreeze() }
    }

    /// Starts the transition to `texture`. One already under way ends at
    /// once: its slide becomes the one going away.
    private func show(_ texture: ImageTexture, index: Int, step: Step) {
        advanceWork?.cancel()
        advanceWork = nil
        let kind: SlideshowTransition
        switch (step, settings.transition) {
        case (.first, _): kind = .crossFade
        case (_, .fixed(let fixed)): kind = fixed
        case (_, .random): kind = .random(after: lastTransition)
        }
        if step != .first { lastTransition = kind }
        let quick = step == .next || step == .previous
        let duration = quick ? min(Self.quickTransitionDuration, settings.transitionDuration)
                             : settings.transitionDuration
        transition = Transition(from: shown?.texture, to: texture, kind: kind,
                                direction: step == .previous ? .backward : .forward, start: CACurrentMediaTime(),
                                duration: duration)
        frameTime = CACurrentMediaTime()
        shown = Slide(index: index, texture: texture)
        updateCaption()
        updateDynamicRange()
        slideView.startAnimating()
        preloadNeighbours()
    }

    private func animationFrame(at time: CFTimeInterval) {
        frameTime = time
        guard let transition else {
            slideView.stopAnimating()
            return
        }
        if transition.frozenProgress == nil, time - transition.start >= transition.duration {
            transitionFinished()
        }
    }

    private func transitionFinished() {
        transition = nil
        slideView.stopAnimating()   // one more frame: the slide at rest
        updateDynamicRange()
        scheduleAdvance()
        if debugFreeze != nil { applyDebugFreeze() }
    }

    private func scheduleAdvance() {
        advanceWork?.cancel()
        advanceWork = nil
        guard !isPaused, !hasEnded, shown != nil, transition == nil, debugFreeze == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.advanceWork = nil
            self.perform(.auto)
        }
        advanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.interval, execute: work)
    }

    /// Decodes the slides either side and reads their captions' metadata;
    /// forgets anything further away, so memory stays at a few screen-sized
    /// textures however long the show.
    private func preloadNeighbours() {
        let wanted = Set([sequence.next, sequence.previous].compactMap { $0 })
        for (index, handle) in handles where !wanted.contains(index) {
            handle.cancel()
            handles[index] = nil
        }
        ready = ready.filter { wanted.contains($0.key) }
        for index in [sequence.next, sequence.previous].compactMap({ $0 }) { request(index) }

        let urls = Set(([shown?.index] + wanted.map { $0 }).compactMap { $0 }.map { images[$0].url })
        summaries = summaries.filter { urls.contains($0.key) }
        if SlideshowCaptionText.needsMetadata(captionStyle) {
            for url in urls where summaries[url] == nil { readSummary(url) }
        }
    }

    // MARK: - Drawing

    private func currentFrame(headroom: Float) -> SlideshowFrame {
        let enlarge = Preferences.shared.enlargeSmallImages
        guard let transition else {
            return .still(shown?.texture, displayHeadroom: headroom, enlargeSmallImages: enlarge)
        }
        let progress = transition.frozenProgress
            ?? Float(min(max((frameTime - transition.start) / max(transition.duration, 0.001), 0), 1))
        return SlideshowFrame(from: transition.from, to: transition.to, transition: transition.kind, progress: progress,
                              direction: transition.direction, displayHeadroom: headroom, enlargeSmallImages: enlarge)
    }

    /// EDR on while an HDR slide is on screen (either side of a transition),
    /// when HDR is on in Settings and the screen can show some of it.
    private func updateDynamicRange() {
        let frame = currentFrame(headroom: 1)
        let wanted = Preferences.shared.showHDR
            && SlideshowRenderer.wantsExtendedDynamicRange(for: frame, potentialHeadroom: slideView.potentialHeadroom)
        slideView.setExtendedDynamicRange(wanted)
    }

    // MARK: - Captions

    private var captionStyle: SlideshowSettings.Caption { debugCaption ?? settings.caption }

    private func updateCaption() {
        guard let index = shown?.index else {
            caption.show(nil)
            return
        }
        let entry = images[index]
        let style = captionStyle
        if SlideshowCaptionText.needsMetadata(style), summaries[entry.url] == nil {
            // Usually read ahead; if not, the caption follows in a moment.
            // Meanwhile it fades out: the previous slide's caption must not
            // stay under this one, and a file name swapping for a camera
            // line a moment later would flicker.
            caption.show(nil)
            readSummary(entry.url)
            return
        }
        caption.show(SlideshowCaptionText.text(style: style, name: entry.name, modified: entry.modified,
                                               summary: summaries[entry.url]))
    }

    private func readSummary(_ url: URL) {
        guard summaryTasks[url] == nil else { return }
        summaryTasks[url] = Task { [weak self] in
            let summary = await BlockingWork.run(qos: .utility) { MetadataReader.summary(for: url) }
            guard let self, !Task.isCancelled else { return }
            self.summaryTasks[url] = nil
            self.summaries[url] = summary
            if let index = self.shown?.index, self.images[index].url == url { self.updateCaption() }
        }
    }

    // MARK: - Pausing and controls

    func setPaused(_ paused: Bool) {
        guard paused != isPaused, !hasEnded else { return }
        isPaused = paused
        if paused {
            advanceWork?.cancel()
            advanceWork = nil
            if pendingStep == .auto { pendingStep = nil }
            music?.pause()
        } else {
            pausedForSettings = false
            music?.resume()
            scheduleAdvance()
        }
        updateControls()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Menu shortcuts (⌘Q, ⌘,) go on to the menu bar.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case 0x20:
            if !event.isARepeat {
                setPaused(!isPaused)
                pointerMoved()   // the bar shows which it is now
            }
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey, NSPageDownFunctionKey:
            perform(.next)
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSPageUpFunctionKey:
            perform(.previous)
        case 0x1B:
            end()
        default:
            return false
        }
        return true
    }

    private func controlBarCommand(_ command: SlideshowControlBar.Command) {
        switch command {
        case .previous: perform(.previous)
        case .playPause: setPaused(!isPaused)
        case .next: perform(.next)
        case .mute:
            music?.setMuted(!(music?.isMuted ?? false))
            updateControls()
        case .settings: openSettings()
        case .close: end()
        }
    }

    /// Settings come up in front of the show, which waits for them.
    private func openSettings() {
        if !isPaused {
            setPaused(true)
            pausedForSettings = true
        }
        (NSApp.delegate as? AppDelegate)?.showSettings(pane: .slideshow)
    }

    private func updateControls() {
        controlBar.update(isPaused: isPaused, hasMusic: music != nil, isMuted: music?.isMuted ?? false)
    }

    /// Pointer events arrive over a hundred times a second, so a move only
    /// notes the time; one pending work item checks it when due.
    private func pointerMoved() {
        guard !hasEnded else { return }
        lastPointerMove = ProcessInfo.processInfo.systemUptime
        controlBar.setShown(true)
        guard controlsWork == nil else { return }
        scheduleControlsHide(after: Self.controlsHideDelay)
    }

    private func scheduleControlsHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasEnded else { return }
            self.controlsWork = nil
            guard !self.controlsPinned else { return }
            let still = ProcessInfo.processInfo.systemUptime - self.lastPointerMove
            if still < Self.controlsHideDelay {
                self.scheduleControlsHide(after: Self.controlsHideDelay - still)
            } else if self.pointerIsOverControls {
                self.scheduleControlsHide(after: Self.controlsHideDelay)
            } else {
                self.controlBar.setShown(false)
                if self.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
        controlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var pointerIsOverControls: Bool {
        guard let window else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controlBar.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    // MARK: - Window, screen and settings

    func windowDidBecomeKey(_ notification: Notification) {
        applyPresentationOptions()
        if pausedForSettings { setPaused(false) }
    }

    func windowDidResignKey(_ notification: Notification) {
        restorePresentationOptions()
    }

    /// The menu bar and Dock make way while the show is key, and come back
    /// whenever it isn't (Settings, another app), as in the viewer's full screen.
    private func applyPresentationOptions() {
        if savedPresentationOptions == nil { savedPresentationOptions = NSApp.presentationOptions }
        NSApp.presentationOptions = [.autoHideMenuBar, .hideDock]
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions else { return }
        savedPresentationOptions = nil
        NSApp.presentationOptions = saved
    }

    /// A resolution change: keep covering the screen. EDR headroom changes
    /// post this too; the view redraws for those itself.
    @objc private func screensChanged() {
        guard let window, let frame = (window.screen ?? NSScreen.main)?.frame, window.frame != frame else { return }
        window.setFrame(frame, display: true)
    }

    /// HDR or RAW settings changed: decoded neighbours are stale. The slide
    /// on screen stays until the next one.
    @objc private func displaySettingsChanged() {
        handles.values.forEach { $0.cancel() }
        handles = [:]
        ready = [:]
        updateDynamicRange()
        preloadNeighbours()
        if let step = pendingStep { perform(step) }
    }

    // MARK: - Testing and debugging

    /// The image of the slide on screen, for tests.
    var shownIndex: Int? { shown?.index }
    var isTransitioning: Bool { transition != nil }
    /// Whether the display link is running.
    var isAnimating: Bool { slideView.isAnimating }
    var keepsDisplayAwake: Bool { activity != nil }
    var areControlsShown: Bool { controlBar.isShown }
    var captionText: String? { caption.text }
    var musicPlayer: SlideshowMusic? { music }
    /// Whether image `index` has decoded ahead and is ready to show.
    func hasDecoded(_ index: Int) -> Bool { ready[index] != nil }

    /// Debug only, for the snapshot harness: holds a transition from the
    /// slide on screen to the next part way, with the control bar up, so a
    /// picture shows what a transition looks like. Sent with
    /// `MINIVU_ACTIONS="startSlideshow:;debugFreezeSlideshowTransition:"`;
    /// `MINIVU_DEBUG_TRANSITION` names the transition (iris by default),
    /// `MINIVU_DEBUG_PROGRESS` how far (0.5), and `MINIVU_DEBUG_CAPTION` a
    /// caption style. No menu item or key sends it.
    @objc func debugFreezeSlideshowTransition(_ sender: Any?) {
        let environment = ProcessInfo.processInfo.environment
        let kind = environment["MINIVU_DEBUG_TRANSITION"].flatMap(SlideshowTransition.init(rawValue:)) ?? .iris
        let progress = environment["MINIVU_DEBUG_PROGRESS"].flatMap(Float.init) ?? 0.5
        debugCaption = environment["MINIVU_DEBUG_CAPTION"].flatMap(SlideshowSettings.Caption.init(rawValue:))
        setPaused(true)
        debugFreeze = (kind, min(max(progress, 0), 1))
        controlsPinned = true
        controlBar.setShown(true, animated: false)
        applyDebugFreeze()
    }

    private func applyDebugFreeze() {
        guard let freeze = debugFreeze, let shown, transition?.frozenProgress == nil else { return }
        // Wait for the opening fade to finish, and for the next slide.
        guard transition == nil, let next = sequence.next, let texture = texture(for: next) else { return }
        transition = Transition(from: shown.texture, to: texture, kind: freeze.kind, direction: .forward, start: 0,
                                duration: 1, frozenProgress: freeze.progress)
        updateCaption()
        updateDynamicRange()
        slideView.stopAnimating()
    }
}
