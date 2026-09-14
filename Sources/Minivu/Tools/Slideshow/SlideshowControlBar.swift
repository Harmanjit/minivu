import AppKit

/// The small translucent bar that appears when the pointer moves during a
/// slideshow: previous, play/pause, next, music on/off, Settings, close.
///
/// Its buttons tell the slideshow through `onCommand` rather than the
/// responder chain: the slideshow window is the only thing they can mean.
final class SlideshowControlBar: NSVisualEffectView {
    enum Command: Int {
        case previous, playPause, next, mute, settings, close
    }

    static let height: CGFloat = 44

    var onCommand: ((Command) -> Void)?

    private lazy var previousButton = button("backward.fill", "Previous (←)", .previous)
    private lazy var playPauseButton = button("pause.fill", "Pause (Space)", .playPause)
    private lazy var nextButton = button("forward.fill", "Next (→)", .next)
    private lazy var muteButton = button("speaker.wave.2.fill", "Mute Music", .mute)
    private lazy var settingsButton = button("gearshape", "Slideshow Settings", .settings)
    private lazy var closeButton = button("xmark", "End Slideshow (Esc)", .close)
    private lazy var musicGroup = NSStackView(views: [Self.divider(), muteButton])

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        // Over a photo, not the app's chrome: dark in every theme.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0

        musicGroup.orientation = .horizontal
        musicGroup.spacing = 2
        let stack = NSStackView(views: [previousButton, playPauseButton, nextButton, musicGroup, Self.divider(),
                                        settingsButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// A press between the buttons stays in the bar; beneath it, a click
    /// would end the slideshow.
    override func mouseDown(with event: NSEvent) {}

    /// - Parameters:
    ///   - hasMusic: the show plays music, so the mute button applies.
    func update(isPaused: Bool, hasMusic: Bool, isMuted: Bool) {
        let playTitle = isPaused ? "Play (Space)" : "Pause (Space)"
        if playPauseButton.toolTip != playTitle {
            playPauseButton.image = Self.symbol(isPaused ? "play.fill" : "pause.fill", playTitle)
            playPauseButton.toolTip = playTitle
        }
        if musicGroup.isHidden == hasMusic { musicGroup.isHidden = !hasMusic }
        let muteTitle = isMuted ? "Play Music" : "Mute Music"
        if muteButton.toolTip != muteTitle {
            muteButton.image = Self.symbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", muteTitle)
            muteButton.toolTip = muteTitle
        }
    }

    private(set) var isShown = false

    func setShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isShown else { return }
        isShown = shown
        let target: CGFloat = shown ? 1 : 0
        guard animated else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.35
            animator().alphaValue = target
        }
    }

    /// Hidden, it takes no clicks: a click where it was ends the show.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    // MARK: - Parts

    private func button(_ symbolName: String, _ toolTip: String, _ command: Command) -> NSButton {
        let button = NSButton(image: Self.symbol(symbolName, toolTip), target: self, action: #selector(pressed(_:)))
        button.tag = command.rawValue
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = toolTip
        // Never the key focus, even with keyboard navigation on: Space must
        // always pause the show, not press whichever button was last focused.
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let command = Command(rawValue: sender.tag) else { return }
        onCommand?(command)
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: ViewerControlBar.spokenName(description))
            ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? image
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 20),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
        let padded = NSStackView(views: [line])
        padded.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return padded
    }
}
