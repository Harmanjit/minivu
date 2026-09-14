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

    private let previousButton = ViewerControlBar.button("chevron.left", "Previous Image (←)", .previousImage)
    private let nextButton = ViewerControlBar.button("chevron.right", "Next Image (→)", .nextImage)
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

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        placeholders.forEach { $0.isEnabled = false }

        let groups: [[NSView]] = [
            [previousButton, nextButton],
            [fitButton, actualSizeButton],
            [zoomOutButton, zoomLabel, zoomInButton],
            [placeholders[0], placeholders[1]],
            [placeholders[2], placeholders[3]],
            [infoButton, fullScreenButton],
        ]
        var views: [NSView] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { views.append(Self.divider()) }
            views.append(contentsOf: group)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// Brings the controls in line with the viewer's state.
    func update(zoomPercent: Double?, canGoPrevious: Bool, canGoNext: Bool, isFullScreen: Bool, infoShown: Bool) {
        zoomLabel.stringValue = zoomPercent.map(ViewerHUD.zoomText) ?? "–"
        previousButton.isEnabled = canGoPrevious
        nextButton.isEnabled = canGoNext
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
