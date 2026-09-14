import AppKit

/// The bottom fly-out: navigation, zoom and view controls.
///
/// Buttons send the same responder-chain actions as the menu and keyboard
/// (MinivuActions.swift), so each command has one implementation, in the
/// viewer controller. AppKit only validates menu items and toolbar items
/// automatically, so the controller calls `update` when state changes.
///
/// Rotate, slideshow and edit are placeholders for later phases (DESIGN.md
/// 7): present so the layout is settled, and visibly disabled.
final class ViewerControlBar: NSView {
    static let height: CGFloat = 48

    /// Toggles the right-hand info panel; implemented by the viewer.
    static let toggleInfoAction = #selector(ViewerWindowController.toggleInfoPanel(_:))
    /// Pages and playback are the viewer's own too: no menu sends them.
    static let previousPageAction = #selector(ViewerWindowController.previousPage(_:))
    static let nextPageAction = #selector(ViewerWindowController.nextPage(_:))
    static let togglePlaybackAction = #selector(ViewerWindowController.togglePlayback(_:))

    private let previousButton = ViewerControlBar.button("chevron.left", "Previous Image (←)", .previousImage)
    private let nextButton = ViewerControlBar.button("chevron.right", "Next Image (→)", .nextImage)
    // Up and down for pages, as Preview's toolbar has them, so they don't
    // read as another pair of image arrows.
    private let previousPageButton = ViewerControlBar.button("chevron.up", "Previous Page (⌥←)",
                                                             ViewerControlBar.previousPageAction)
    private let nextPageButton = ViewerControlBar.button("chevron.down", "Next Page (⌥→)",
                                                         ViewerControlBar.nextPageAction)
    private let pageLabel = NSTextField(labelWithString: "")
    private let playbackButton = ViewerControlBar.button("pause.circle", "Pause (P)",
                                                         ViewerControlBar.togglePlaybackAction)
    /// Shown only for documents with pages and for animations. Each carries
    /// its own divider, so a hidden group leaves no double line behind.
    private lazy var pageGroup = Self.optionalGroup([previousPageButton, pageLabel, nextPageButton])
    private lazy var playbackGroup = Self.optionalGroup([playbackButton])
    private let fitButton = ViewerControlBar.button("arrow.down.right.and.arrow.up.left", "Fit to Window (*)",
                                                    .fitToWindow)
    private let actualSizeButton = ViewerControlBar.button("1.magnifyingglass", "Actual Size (/)", .actualSize)
    private let zoomOutButton = ViewerControlBar.button("minus.magnifyingglass", "Zoom Out (−)", .zoomOut)
    private let zoomInButton = ViewerControlBar.button("plus.magnifyingglass", "Zoom In (+)", .zoomIn)
    private let fullScreenButton = ViewerControlBar.button("display", "Full Screen (Return)", .toggleFullScreenViewer)
    private let infoButton = ViewerControlBar.button("info.circle", "Show Info", ViewerControlBar.toggleInfoAction)
    private let zoomLabel = NSTextField(labelWithString: "")

    /// Later phases; never enabled here.
    private let placeholders = [
        ViewerControlBar.button("rotate.left", "Rotate Left (coming soon)", nil),
        ViewerControlBar.button("rotate.right", "Rotate Right (coming soon)", nil),
        ViewerControlBar.button("play.fill", "Slideshow (coming soon)", nil),
        ViewerControlBar.button("slider.horizontal.3", "Edit (coming soon)", nil),
    ]
    private lazy var placeholderGroups = [Self.group([placeholders[0], placeholders[1]]),
                                          Self.group([placeholders[2], placeholders[3]])]
    private let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        placeholders.forEach { $0.isEnabled = false }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        pageLabel.lineBreakMode = .byClipping
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for "999 / 999" without the bar shifting as pages turn.
        pageLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let views: [NSView] = [previousButton, nextButton, pageGroup, playbackGroup, Self.divider(),
                               fitButton, actualSizeButton, Self.divider(),
                               zoomOutButton, zoomLabel, zoomInButton]
            + placeholderGroups
            + [Self.divider(), infoButton, fullScreenButton]
        views.forEach(stack.addArrangedSubview)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Centred when there is room; pinned to the leading edge when there
        // isn't, rather than squeezing the buttons (two required constraints
        // that can't both hold would make AppKit break one at random).
        let centered = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centered,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func layout() {
        super.layout()
        fitPlaceholders()
    }

    /// The placeholders for later phases give way when the bar is too narrow
    /// for every control that works: a document's page controls in a small
    /// window would otherwise push Info and Full Screen off the end. Hiding
    /// them lays the bar out again, which lands here once more and changes
    /// nothing, so this settles in one extra pass.
    private func fitPlaceholders() {
        let placeholderWidth = placeholderGroups.reduce(0) { $0 + $1.fittingSize.width + stack.spacing }
        let hidden = placeholderGroups.allSatisfy(\.isHidden)
        let needed = stack.fittingSize.width + (hidden ? placeholderWidth : 0)
        let hide = needed > bounds.width - 16
        for group in placeholderGroups where group.isHidden != hide { group.isHidden = hide }
    }

    /// Where the viewer is in a document with pages.
    struct Pages: Equatable {
        /// "2 / 10".
        var text: String
        var canGoPrevious: Bool
        var canGoNext: Bool
    }

    /// Brings the controls in line with the viewer's state.
    /// - Parameters:
    ///   - pages: nil unless the image has more than one page.
    ///   - isPlaying: nil unless the image is animated.
    func update(zoomPercent: Double?, canGoPrevious: Bool, canGoNext: Bool, isFullScreen: Bool, infoShown: Bool,
                pages: Pages? = nil, isPlaying: Bool? = nil) {
        zoomLabel.stringValue = zoomPercent.map(ViewerHUD.zoomText) ?? "–"
        previousButton.isEnabled = canGoPrevious
        nextButton.isEnabled = canGoNext

        if pageGroup.isHidden != (pages == nil) || playbackGroup.isHidden != (isPlaying == nil) {
            needsLayout = true   // the placeholders may have to make room, or may come back
        }
        if pageGroup.isHidden != (pages == nil) { pageGroup.isHidden = pages == nil }
        if let pages {
            pageLabel.stringValue = pages.text
            previousPageButton.isEnabled = pages.canGoPrevious
            nextPageButton.isEnabled = pages.canGoNext
        }
        if playbackGroup.isHidden != (isPlaying == nil) { playbackGroup.isHidden = isPlaying == nil }
        if let isPlaying {
            // The button shows what a press does.
            let title = isPlaying ? "Pause (P)" : "Play (P)"
            if playbackButton.toolTip != title {
                playbackButton.image = Self.symbol(isPlaying ? "pause.circle" : "play.circle", title)
                playbackButton.toolTip = title
            }
        }
        let hasImage = zoomPercent != nil
        for button in [fitButton, actualSizeButton, zoomOutButton, zoomInButton] { button.isEnabled = hasImage }

        // A display and a window rather than arrows, which would look just
        // like the fit button's.
        let symbol = isFullScreen ? "macwindow" : "display"
        let title = isFullScreen ? "Show in a Window (Return)" : "Full Screen (Return)"
        if fullScreenButton.toolTip != title {
            fullScreenButton.image = Self.symbol(symbol, title)
            fullScreenButton.toolTip = title
        }
        infoButton.state = infoShown ? .on : .off
        // The bezel only shows under the pointer, so the tint carries the state.
        infoButton.contentTintColor = infoShown ? .controlAccentColor : nil
        infoButton.toolTip = infoShown ? "Hide Info" : "Show Info"
    }

    // MARK: - Parts

    private static func button(_ symbolName: String, _ toolTip: String, _ action: Selector?) -> NSButton {
        let button = NSButton(image: symbol(symbolName, toolTip), target: nil, action: action)
        // The toolbar look: no bezel until the pointer is over the button.
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.setButtonType(action == toggleInfoAction ? .pushOnPushOff : .momentaryPushIn)
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? image
    }

    /// A divider and `views`, which show and hide together.
    private static func group(_ views: [NSView]) -> NSStackView {
        let group = NSStackView(views: [divider()] + views)
        group.orientation = .horizontal
        group.spacing = 4
        group.alignment = .centerY
        return group
    }

    /// A group hidden until `update` says it applies.
    private static func optionalGroup(_ views: [NSView]) -> NSStackView {
        let group = group(views)
        group.isHidden = true
        return group
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
