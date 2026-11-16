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
        Group(title: localized(.init("Adjust", comment: "Submenu of colour and tone adjustments")), tools: [
            Tool(title: localized("Resize"), symbol: "arrow.up.left.and.arrow.down.right", action: .resizeImage),
            Tool(title: localized("Canvas Size"), symbol: "square.dashed", action: .changeCanvasSize),
            Tool(title: localized(.init("Crop", comment: "Verb: crop the image")), symbol: "crop", action: .cropImage),
            Tool(title: localized("Rotate & Flip"), symbol: "rotate.right", action: showRotateFlipAction),
            Tool(title: localized("Straighten"), symbol: "level", action: .straightenImage),
            Tool(title: localized("Perspective"), symbol: "perspective", action: .correctPerspective),
            Tool(title: localized("RAW Adjustments"), symbol: "camera.aperture", action: .adjustRaw),
            Tool(title: localized("Auto Enhance"), symbol: "wand.and.stars", action: .autoEnhance),
            Tool(title: localized("Lighting"), symbol: "sun.max", action: .adjustLighting),
            Tool(title: localized("Colors"), symbol: "paintpalette", action: .adjustColors),
            Tool(title: localized("Curves"), symbol: "point.bottomleft.forward.to.point.topright.scurvepath", action: .adjustCurves),
            Tool(title: localized(.init("Levels", comment: "Adjustment: black point, white point and gamma")),
                symbol: "slider.horizontal.3", action: .adjustLevels),
            Tool(title: localized("Sharpen"), symbol: "rhombus", action: .sharpenImage),
            Tool(title: localized("Blur"), symbol: "drop.halffull", action: .blurImage),
            Tool(title: localized("Noise Reduction"), symbol: "circle.dotted", action: .reduceNoise),
        ]),
        Group(title: localized(.init("Effects", comment: "Submenu of image effects")), tools: [
            Tool(title: localized("Color Effects"), symbol: "camera.filters", action: showColorEffectsAction),
            Tool(title: localized("Drop Shadow"), symbol: "shadow", action: .addDropShadow),
            Tool(title: localized(.init("Frame", comment: "Effect: a picture frame (border) around the image, not a video frame")),
                symbol: "photo.artframe", action: .addFrame),
            Tool(title: localized("Bump Map"), symbol: "mountain.2", action: .applyBumpMap),
            Tool(title: localized(.init("Sketch", comment: "Effect: pencil drawing")), symbol: "pencil.and.scribble", action: .applySketch),
            Tool(title: localized("Oil Painting"), symbol: "paintbrush.pointed", action: .applyOilPaint),
            Tool(title: localized(.init("effect.lens", defaultValue: "Lens", comment: "Effect: magnifying-lens distortion")),
                symbol: "circle.dashed", action: .applyLens),
            Tool(title: localized("Vignette"), symbol: "circle.lefthalf.striped.horizontal", action: .addVignette),
        ]),
        Group(title: localized(.init("Draw", comment: "Heading of the drawing tools")), tools: [
            Tool(title: localized("Text and Shapes"), symbol: "pencil.tip.crop.circle", action: .drawAnnotations),
            Tool(title: localized("Watermark"), symbol: "c.circle", action: .addWatermark),
        ]),
        Group(title: localized(.init("Retouch", comment: "Submenu of retouching tools")), tools: [
            Tool(title: localized("Clone Stamp"), symbol: "square.on.square", action: .cloneStamp),
            Tool(title: localized("Healing Brush"), symbol: "bandage", action: .healingBrush),
            Tool(title: localized("Red-Eye Removal"), symbol: "eye", action: .removeRedEye),
            Tool(title: localized("Remove Background"), symbol: "person.and.background.dotted", action: .removeBackground),
        ]),
    ]

    private let list = NSScrollView()
    private var rows: [(button: NSButton, action: Selector)] = []
    private(set) var inspector: NSView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))

        let title = NSTextField(labelWithString: localized(.init("viewer.tools.title", defaultValue: "Tools",
                                                                 comment: "Title of the viewer's panel of editing tools")))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        stack.setCustomSpacing(12, after: title)
        for group in Self.groups {
            let header = NSTextField(labelWithString: group.title.localizedUppercase)
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
            button.toolTip = localized(.init("\(tool.title) (coming soon)", comment: "Tooltip: %@ is a tool not available yet"))
            let soon = NSTextField(labelWithString: localized(.init("Soon", comment: "Badge on a tool not available yet")))
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

    static let symbolBoxWidth: CGFloat = 20

    /// The symbol centred in a fixed-width box. Symbols differ in width, and
    /// titles beside them would otherwise start at ragged positions.
    private static func symbol(_ name: String) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return NSImage() }
        // A symbol wider than the box (Bump Map's mountains) is scaled down to
        // fit it, so it can't run into its title.
        let natural = symbol.size
        let fit = min(1, Self.symbolBoxWidth / max(natural.width, 1))
        let size = NSSize(width: natural.width * fit, height: natural.height * fit)
        let box = NSSize(width: Self.symbolBoxWidth, height: max(16, natural.height))
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
