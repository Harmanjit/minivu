import AppKit

/// The left fly-out: the editing tools (DESIGN.md 5 and 7).
///
/// Two faces. The list sends each tool's responder-chain action (the same
/// one its menu item sends), so the viewer implements every tool once. When
/// a tool opens, its inspector replaces the list and the viewer pins the
/// panel open, so it doesn't slide away mid-drag; the inspector's back
/// chevron returns to the list.
///
/// The list is plain buttons in a stack view: built once, nothing to update
/// while hidden. The panel's material comes from its `FlyoutPanelView`.
final class ViewerToolsPanel: NSView {
    static let width: CGFloat = 220
    /// Wide enough for the 256 pt curve and levels editors in a grouped form.
    static let inspectorWidth: CGFloat = 316

    struct Tool {
        let title: String
        let symbol: String
        /// nil for tools of later phases, shown disabled.
        let action: Selector?
    }

    struct Group {
        let title: String
        let tools: [Tool]
    }

    /// Shows the rotate and flip commands as an inspector.
    static let showRotateFlipAction = #selector(ViewerWindowController.showRotateFlipTool(_:))
    /// Shows grayscale, sepia and negative as an inspector.
    static let showColorEffectsAction = #selector(ViewerWindowController.showColorEffectsTool(_:))

    static let groups: [Group] = [
        Group(title: "Adjust", tools: [
            Tool(title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", action: .resizeImage),
            Tool(title: "Crop", symbol: "crop", action: .cropImage),
            Tool(title: "Rotate & Flip", symbol: "rotate.right", action: showRotateFlipAction),
            Tool(title: "Straighten", symbol: "level", action: .straightenImage),
            Tool(title: "Lighting", symbol: "sun.max", action: .adjustLighting),
            Tool(title: "Colors", symbol: "paintpalette", action: .adjustColors),
            Tool(title: "Curves", symbol: "point.bottomleft.forward.to.point.topright.scurvepath", action: .adjustCurves),
            Tool(title: "Levels", symbol: "slider.horizontal.3", action: .adjustLevels),
            Tool(title: "Sharpen", symbol: "rhombus", action: .sharpenImage),
            Tool(title: "Blur", symbol: "drop.halffull", action: .blurImage),
        ]),
        Group(title: "Effects", tools: [
            Tool(title: "Color Effects", symbol: "camera.filters", action: showColorEffectsAction),
            Tool(title: "Drop Shadow", symbol: "shadow", action: .addDropShadow),
            Tool(title: "Frame", symbol: "photo.artframe", action: .addFrame),
            Tool(title: "Bump Map", symbol: "mountain.2", action: .applyBumpMap),
            Tool(title: "Sketch", symbol: "pencil.and.scribble", action: .applySketch),
            Tool(title: "Oil Painting", symbol: "paintbrush.pointed", action: .applyOilPaint),
            Tool(title: "Lens", symbol: "circle.dashed", action: .applyLens),
        ]),
        Group(title: "Draw", tools: [
            Tool(title: "Text & Shapes", symbol: "pencil.tip.crop.circle", action: .drawAnnotations),
        ]),
        Group(title: "Retouch", tools: [
            Tool(title: "Clone Stamp", symbol: "square.on.square", action: .cloneStamp),
            Tool(title: "Healing Brush", symbol: "bandage", action: .healingBrush),
            Tool(title: "Red-Eye", symbol: "eye", action: .removeRedEye),
        ]),
    ]

    private let list = NSScrollView()
    private var rows: [(button: NSButton, action: Selector)] = []
    private(set) var inspector: NSView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))

        let title = NSTextField(labelWithString: "Tools")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        stack.setCustomSpacing(12, after: title)
        for group in Self.groups {
            let header = NSTextField(labelWithString: group.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(4, after: header)
            for tool in group.tools {
                let row = makeRow(tool)
                stack.addArrangedSubview(row)
                // Full width, so the hover highlight spans the panel.
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            // Breathing room before the next group.
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
        }

        // Scrolls when the window is too short for the whole list.
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        list.automaticallyAdjustsContentInsets = false
        list.frame = bounds
        list.autoresizingMask = [.width, .height]
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        list.documentView = document
        addSubview(list)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: list.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: - Faces

    /// Replaces the list with a tool's inspector.
    func showInspector(_ view: NSView) {
        inspector?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        inspector = view
        list.isHidden = true
    }

    /// Back to the list.
    func showList() {
        inspector?.removeFromSuperview()
        inspector = nil
        list.isHidden = false
    }

    /// Enables each tool the viewer can run on the image showing. AppKit
    /// validates menu items by itself but not buttons, so the viewer calls
    /// this whenever what it can edit changes.
    func updateAvailability(_ isEnabled: (Selector) -> Bool) {
        for row in rows {
            let enabled = isEnabled(row.action)
            if row.button.isEnabled != enabled { row.button.isEnabled = enabled }
        }
    }

    /// The row for `action`, for tests.
    func row(for action: Selector) -> NSButton? {
        rows.first { $0.action == action }?.button
    }

    // MARK: - Rows

    private func makeRow(_ tool: Tool) -> NSButton {
        let button = NSButton(title: tool.title, image: Self.symbol(tool.symbol), target: nil, action: tool.action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        if let action = tool.action {
            rows.append((button, action))
            button.isEnabled = false   // until the viewer says an image can be edited
        } else {
            button.isEnabled = false
            button.toolTip = "\(tool.title) (coming soon)"
            let soon = NSTextField(labelWithString: "Soon")
            soon.font = .systemFont(ofSize: 10)
            soon.textColor = .tertiaryLabelColor
            soon.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(soon)
            NSLayoutConstraint.activate([
                soon.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
                soon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        return button
    }

    /// The symbol centred in a fixed-width box. Symbols differ in width, and
    /// titles beside them would otherwise start at ragged positions.
    private static func symbol(_ name: String) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return NSImage() }
        let size = symbol.size
        let box = NSSize(width: 22, height: max(16, size.height))
        let image = NSImage(size: box, flipped: false) { rect in
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        // Tinted by the button like the symbol itself (and dimmed when disabled).
        image.isTemplate = true
        return image
    }

    /// Scroll views lay out documents from the top only when they're flipped.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
