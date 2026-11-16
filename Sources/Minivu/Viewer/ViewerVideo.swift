import AppKit
import AVFoundation
import AVKit
import MinivuCore

/// Videos in the viewer (G18): the first frame shows on the canvas like any
/// photo (decoded through the image loader, so it is cached, prefetched and
/// HDR like one), with a play button over it. Asking to play (the button,
/// Space, P, the control bar) makes the player; moving to another item,
/// closing the viewer, or the window being hidden stops it, and moving on
/// releases it. Nothing plays on its own.
///
/// **AVKit's `AVPlayerView`** rather than an `AVPlayerLayer` with controls
/// of minivu's own: it brings the scrubber, the volume and mute control,
/// HDR on screens that have it, VoiceOver labels, Reduce Motion and the
/// system's look, all of which a layer would need written and kept up. It
/// is made only when wanted, so flipping through a folder of videos costs
/// one decoded frame each and never a player. What minivu takes away: its
/// full-screen, picture-in-picture and sharing buttons (the viewer has its
/// own full screen, and Share is in the File menu), and the keyboard, which
/// stays with the viewer so the arrows keep moving between items.
extension ViewerWindowController {
    /// A video is the current item.
    var isShowingVideo: Bool { model.current?.kind == .video }

    var isVideoPlaying: Bool { videoPlayback?.isPlaying ?? false }

    /// "Video, 1:05", once the length is read; "Video" until then.
    var videoHUDText: String {
        guard let entry = model.current, let read = videoInfo, read.url == entry.url, let info = read.info else {
            return localized("Video")
        }
        let duration = VideoFrames.durationText(info.duration)
        return localized(.init("Video, \(duration)", comment: "HUD: a video and its length, such as 1:05"))
    }

    /// The navigation happened: any player stops and goes, and a video
    /// gets its play button and has its length read.
    func videoEntryChanged(_ entry: FolderEntry) {
        stopVideo()
        videoInfoTask?.cancel()
        videoInfoTask = nil
        if container.videoStage !== videoStage {
            videoStage.onPlay = { [weak self] in self?.toggleVideoPlayback() }
            container.videoStage = videoStage
        }
        guard entry.kind == .video else { return }
        guard videoInfo?.url != entry.url else { return }
        videoInfo = nil
        let url = entry.url
        videoInfoTask = Task { [weak self] in
            let info = await BlockingWork.run { VideoFrames.info(for: url) }
            guard !Task.isCancelled, let self, !self.isClosing, self.model.current?.url == url else { return }
            self.videoInfo = (url, info)
            self.updateChrome()
        }
    }

    /// The play button shows over a video's still once it is up, and never
    /// over an item minivu couldn't show.
    func updateVideoChrome() {
        let showsButton = isShowingVideo && videoPlayback == nil && displayed == current && canvas.image != nil
            && errorLabel.isHidden
        videoStage.showsPlayButton = showsButton
    }

    /// Space, P, the control bar and the play button: makes the player the
    /// first time and starts it, then pauses and resumes it.
    func toggleVideoPlayback() {
        guard isShowingVideo, !isClosing else { return }
        if let videoPlayback {
            videoPlayback.toggle()
        } else {
            startVideo()
        }
        hud.flash()
    }

    /// The player for the current video, playing. Not for an item that
    /// failed to show: AVFoundation would only fail again, silently.
    func startVideo() {
        guard let entry = model.current, entry.kind == .video, videoPlayback == nil, errorLabel.isHidden,
              let window else { return }
        let playback = VideoPlayback(url: entry.url, showsHDR: Preferences.shared.showHDR)
        playback.view.keyHandler = { [weak self] event in self?.handleVideoViewKey(event) ?? false }
        playback.onStateChange = { [weak self] in self?.updateChrome() }
        videoPlayback = playback
        videoStage.show(playback.view)
        // A press on the player's controls must not take the keyboard from
        // the viewer, or the arrows would step frames instead of items.
        if window.firstResponder !== canvas { window.makeFirstResponder(canvas) }
        playback.play()
        updateChrome()
    }

    /// The canvas, for anything inside the player that would take the
    /// keyboard; nil otherwise. The player view itself refuses it, but
    /// AVKit's scrubber, volume slider and buttons are its own subviews, and
    /// with Keyboard navigation on in System Settings a click on one makes
    /// it first responder. The arrows and Space would then scrub and step
    /// frames rather than move between items, so the window hands the
    /// keyboard back to the canvas instead. The controls still work with
    /// the mouse, and VoiceOver drives them through accessibility, which
    /// needs no first responder.
    func keyboardRedirect(for responder: NSResponder) -> NSResponder? {
        guard let playerView = videoPlayback?.view, let view = responder as? NSView,
              view.isDescendant(of: playerView) else { return nil }
        return canvas
    }

    /// Pauses a playing video; nothing otherwise.
    func pauseVideo() {
        videoPlayback?.pause()
    }

    /// Stops the player and lets it go: the item, its decoder and the view.
    func stopVideo() {
        guard let playback = videoPlayback else { return }
        videoPlayback = nil
        playback.stop()
        videoStage.show(nil)
    }

    /// M (and Image > Mute Video): sound off or back on.
    @objc func toggleMute(_ sender: Any?) {
        guard isShowingVideo else { return }
        if videoPlayback == nil { VideoPlayback.mutedByUser.toggle() } else { videoPlayback?.toggleMute() }
        updateChrome()
        hud.flash()
    }

    /// Image > Play Video / Pause Video for a video; nil when the current
    /// item isn't one, so the animation's validation answers.
    func validateVideoPlayback(_ menuItem: NSMenuItem) -> Bool? {
        guard isShowingVideo else { return nil }
        menuItem.title = MenuStateTitles.videoPlayback(isPlaying: isVideoPlaying)
        return errorLabel.isHidden && !isClosing
    }

    func validateVideoMute(_ menuItem: NSMenuItem) -> Bool {
        let muted = videoPlayback?.isMuted ?? VideoPlayback.mutedByUser
        menuItem.title = MenuStateTitles.mute(isMuted: muted)
        return isShowingVideo && !isClosing
    }

    /// Show HDR changed in Settings: a player on screen follows it.
    func videoDisplaySettingsChanged() {
        videoPlayback?.showsHDR = Preferences.shared.showHDR
    }

    /// A key that reached the player view (it never takes the keyboard, but
    /// AppKit can still hand it one after a click): the viewer's table first.
    private func handleVideoViewKey(_ event: NSEvent) -> Bool {
        container.keyHandler?(event) ?? false
    }

    // MARK: - Testing

    /// The view a player shows in, for tests; nil without one.
    var videoPlayerView: AVPlayerView? { videoPlayback?.view }
}

/// One video's player and the view it plays in.
///
/// Made when the user asks to play, never before, and dropped by `stop()`:
/// the item goes from the player and the player from the view, so the
/// decoder and its buffers go with them rather than lingering until the
/// next video.
final class VideoPlayback {
    /// Sound stays as the user last left it across videos while the viewer
    /// runs, as in QuickTime. Tests set it so nothing can sound.
    static var mutedByUser = false

    /// Players made and not yet stopped. Never more than one: the viewer is
    /// the only place one is made, minivu shows one viewer at a time, and it
    /// stops its player before showing another item (the tests hold it to
    /// that).
    private(set) static var liveCount = 0

    let player: AVPlayer
    let view = VideoPlayerView()
    /// Playing, paused, muted or finished: the HUD, menu and control bar
    /// say so.
    var onStateChange: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var isStopped = false

    init(url: URL, showsHDR: Bool) {
        Self.liveCount += 1
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player = AVPlayer(playerItem: item)
        player.isMuted = Self.mutedByUser
        player.actionAtItemEnd = .pause
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        // Not the system's Now Playing: minivu shows clips, it isn't a
        // media player the user would steer from the menu bar.
        view.updatesNowPlayingInfoCenter = false
        view.videoGravity = .resizeAspect
        self.showsHDR = showsHDR
        applyDynamicRange()
        view.setAccessibilityLabel(localized("Video player"))

        // KVO calls back on whichever thread changed the value: the handlers
        // are nonisolated and hop to the main actor.
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.onStateChange?() }
        })
        observations.append(player.observe(\.isMuted, options: [.new]) { @Sendable [weak self] _, change in
            let muted = change.newValue
            Task { @MainActor in
                if let muted { VideoPlayback.mutedByUser = muted }
                self?.onStateChange?()
            }
        })
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStateChange?() }
        }
    }

    /// Show HDR in Settings. Off, the video is shown in standard range where
    /// AVKit lets minivu choose (macOS 26); before that AVKit decides, which
    /// is HDR on a screen that has it.
    var showsHDR: Bool {
        didSet { if showsHDR != oldValue { applyDynamicRange() } }
    }

    private func applyDynamicRange() {
        if #available(macOS 26.0, *) {
            view.preferredDisplayDynamicRange = showsHDR ? .automatic : .standard
        }
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }
    var isMuted: Bool { player.isMuted }

    /// Plays from where it is, or from the start once it has reached the end.
    func play() {
        if let item = player.currentItem, item.duration.isNumeric,
           item.currentTime().seconds >= item.duration.seconds - 0.05 {
            player.seek(to: .zero)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func toggleMute() {
        player.isMuted.toggle()
    }

    /// Stops and lets everything go. The view leaves its superview, the
    /// player its item.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        Self.liveCount -= 1
        onStateChange = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        view.player = nil
        view.keyHandler = nil
        view.removeFromSuperview()
    }
}

/// `AVPlayerView` that leaves the keyboard to the viewer: it never becomes
/// first responder, so Space, the arrows and every other viewer key keep
/// their meaning (AVPlayerView's own would step frames with the arrows).
final class VideoPlayerView: AVPlayerView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// Lies over the canvas, on its frame: the play button centred over a
/// video's still, later the player filling it. Empty space passes clicks,
/// the scroll wheel and the magnifier through to the canvas.
final class VideoStageView: NSView {
    /// The play button was pressed.
    var onPlay: (() -> Void)?

    let playButton: NSButton = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        let image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play Video")?
            .withSymbolConfiguration(configuration)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.contentTintColor = .white
        button.setAccessibilityLabel(localized("Play Video"))
        button.toolTip = localized(.init("Play Video (Space)", comment: "Tooltip: keep the key in brackets"))
        // Taking the keyboard would leave the viewer's keys with a button.
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            return shadow
        }()
        return button
    }()
    private(set) var playerView: NSView?

    static let buttonSide: CGFloat = 72

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playButton.target = self
        playButton.action = #selector(playPressed)
        playButton.isHidden = true
        addSubview(playButton)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    var showsPlayButton: Bool {
        get { !playButton.isHidden }
        set { if playButton.isHidden == newValue { playButton.isHidden = !newValue } }
    }

    /// Puts `view` (a player's) in, filling the stage, or takes it out.
    func show(_ view: NSView?) {
        guard view !== playerView else { return }
        playerView?.removeFromSuperview()
        playerView = view
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: playButton)
        }
    }

    override func layout() {
        super.layout()
        let side = Self.buttonSide
        playButton.frame = CGRect(x: (bounds.midX - side / 2).rounded(), y: (bounds.midY - side / 2).rounded(),
                                  width: side, height: side)
        playerView?.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Only the button and the player take the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc private func playPressed() {
        onPlay?()
    }
}
