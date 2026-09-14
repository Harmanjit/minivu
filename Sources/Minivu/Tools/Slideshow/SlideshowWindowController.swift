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
    /// The slide, kept clear of a notched display's camera housing: "fit"
    /// must show the whole picture, not tuck its top behind the camera. The
    /// strip above stays the window's black.
    var picture: NSView? {
        didSet { needsLayout = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// The camera housing's height on the display the show is on.
    var topInset: CGFloat {
        window.flatMap(Displays.provider.display(of:))?.safeAreaTop ?? 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        let area = DisplayPlacement.pictureArea(in: bounds, safeAreaTop: topInset, flipped: isFlipped)
        if let picture, picture.frame != area { picture.frame = area }
        super.layout()
    }

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
///   `ImageLoader.shared` fitted to the screen, so a transition starts the
///   moment the interval is up. If an image isn't ready, the show waits for
///   it; if it can't load, it is skipped.
/// - **A key press never waits for a transition**: → or ← finishes the one
///   under way at once and starts a quick one.
final class SlideshowWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
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

    /// Starts a slideshow of `images` from `startIndex`, started from
    /// `origin` (the browser or viewer window; nil for none). It plays on the
    /// display Settings > Viewer chooses for the full-screen viewer, as
    /// FastStone's slideshow follows its viewer: over a full-screen viewer it
    /// plays on the viewer's display, and with "Another display" a show
    /// started in the browser leaves the browser's display free.
    /// `onEnd` gets the image last shown, when the show ends. With a
    /// slideshow already running, it comes forward instead.
    @discardableResult
    static func start(images: [FolderEntry], startIndex: Int, from origin: NSWindow?,
                      onEnd: @escaping (FolderEntry?) -> Void) -> SlideshowWindowController? {
        guard !images.isEmpty else { return nil }
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return current
        }
        let from = origin.flatMap(Displays.provider.display(of:)) ?? Displays.originDisplay()
        let controller = SlideshowWindowController(images: images, startIndex: startIndex,
                                                   display: Displays.fullScreenDisplay(current: from),
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
    /// The picture area in pixels, which slides decode fitted into, both
    /// slides of a transition alike. Only zoom draws a slide past fit: the
    /// old one, 30% at most, as it fades out.
    private var fitSize: CGSize
    /// The display the show covers, by id (see `ViewerWindowController.fullScreenDisplayID`).
    private(set) var displayID: UInt32?
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

    private init(images: [FolderEntry], startIndex: Int, display: DisplayInfo?, store: SlideshowSettingsStore,
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
        let frame = display?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        fitSize = Self.pictureFitSize(on: display ?? DisplayInfo(id: 0, frame: frame))
        displayID = display?.id
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
        content.picture = slideView
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
        NotificationCenter.default.addObserver(self, selector: #selector(windowChangedScreen),
                                               name: NSWindow.didChangeScreenNotification, object: window)
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
        FullScreenPresentation.shared.release(self)
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
        let handle = AppServices.images.load(images[index], fitting: fitSize) { [weak self] result in
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
        var kind: SlideshowTransition
        switch (step, settings.transition) {
        case (.first, _): kind = .crossFade
        case (_, .fixed(let fixed)): kind = fixed
        case (_, .random): kind = .random(after: lastTransition)
        }
        if step != .first { lastTransition = kind }
        kind = kind.reducingMotion(Motion.isReduced)
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

    /// The menu bar and Dock make way while the show is key, and come back
    /// whenever it isn't (Settings, another app, a full-screen viewer on
    /// another display, which hides them again itself): see
    /// `FullScreenPresentation`.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !hasEnded else { return }
        FullScreenPresentation.shared.hide(for: self)
        if pausedForSettings { setPaused(false) }
    }

    func windowDidResignKey(_ notification: Notification) {
        FullScreenPresentation.shared.release(self)
    }

    /// A resolution change: keep covering the display. Its display unplugged:
    /// go on on one that is left, chosen as when a show starts, rather than
    /// play on where nobody can see it. EDR headroom changes post this too;
    /// the view redraws for those itself.
    @objc private func screensChanged() {
        guard !hasEnded, window != nil else { return }
        let displays = Displays.provider.displays
        guard !displays.isEmpty else { return }   // the last display went; wait for one to come
        guard let display = displays.first(where: { $0.id == displayID }) ?? Displays.fullScreenDisplay(current: nil)
        else { return }
        place(on: display)
    }

    /// Covers `display`: the picture below any camera housing, slides decoded
    /// for its size, and HDR for what it can show.
    private func place(on display: DisplayInfo) {
        guard let window else { return }
        displayID = display.id
        if window.frame != display.frame { window.setFrame(display.frame, display: true) }
        content.needsLayout = true
        displayChanged(to: display)
    }

    /// The window is on another display (moved, or its display replaced):
    /// EDR headroom, the colour space the picture is converted to, backing
    /// scale and the size slides decode at may all differ.
    @objc private func windowChangedScreen() {
        guard !hasEnded, let window, let display = Displays.provider.display(of: window) else { return }
        content.needsLayout = true
        displayChanged(to: display)
    }

    private func displayChanged(to display: DisplayInfo) {
        updateDynamicRange()
        slideView.screenChanged()
        // Slides decoded for a smaller picture would be soft on this one;
        // decoded for one at least as large both ways they are only sampled
        // down, and stay. (A portrait photo fitted to a landscape display is
        // too small for a portrait one, though that display is no larger.)
        let size = Self.pictureFitSize(on: display)
        guard size != fitSize else { return }
        let sharper = size.width > fitSize.width || size.height > fitSize.height
        fitSize = size
        if sharper { reloadNeighbours() }
    }

    /// The picture area on `display` in pixels: below any camera housing.
    private static func pictureFitSize(on display: DisplayInfo) -> CGSize {
        let area = DisplayPlacement.pictureArea(in: CGRect(origin: .zero, size: display.frame.size),
                                                safeAreaTop: display.safeAreaTop, flipped: true)
        return CGSize(width: (area.width * display.backingScale).rounded(),
                      height: (area.height * display.backingScale).rounded())
    }

    /// Window > Move to Next Display (⌃⌥⌘→): the show goes on on the next
    /// display, left to right.
    @objc func moveToNextDisplay(_ sender: Any?) {
        guard !hasEnded, let window else { return }
        let provider = Displays.provider
        let displays = provider.displays
        let current = displays.first { $0.id == displayID } ?? provider.display(of: window)
        guard displays.count > 1, let next = DisplayPlacement.next(after: current, in: displays),
              next.id != current?.id else { return }
        place(on: next)
        window.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case .moveToNextDisplay: !hasEnded && Displays.provider.displays.count > 1
        default: true
        }
    }

    /// HDR or RAW settings changed: decoded neighbours are stale. The slide
    /// on screen stays until the next one.
    @objc private func displaySettingsChanged() {
        updateDynamicRange()
        reloadNeighbours()
    }

    /// Forgets the decoded neighbours and decodes them again; a move waiting
    /// for one waits for the new decode.
    private func reloadNeighbours() {
        handles.values.forEach { $0.cancel() }
        handles = [:]
        ready = [:]
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
    /// The view size in pixels that slides are fitted into for decoding, for tests.
    var decodeFitSize: CGSize { fitSize }
    /// The picture's frame in the window, for tests.
    var pictureFrame: CGRect { slideView.frame }
    var musicPlayer: SlideshowMusic? { music }
    /// Whether image `index` has decoded ahead and is ready to show.
    func hasDecoded(_ index: Int) -> Bool { ready[index] != nil }

    #if DEBUG
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
    #endif

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
