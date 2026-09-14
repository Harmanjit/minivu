import AppKit

/// The left fly-out: the editing tools of phases 4 to 6 (DESIGN.md 7).
///
/// Only a layout placeholder for now. Every tool is listed, disabled, so the
/// panel's shape and grouping are settled before any tool exists. Plain
/// labels and buttons in a stack view: built once, nothing loaded, nothing
/// to update while it's hidden. The panel's own material comes from the
/// `FlyoutPanelView` it sits in.
final class ViewerToolsPanel: NSView {
    static let width: CGFloat = 220

    struct Tool {
        let title: String
        let symbol: String
    }

    struct Group {
        let title: String
        let tools: [Tool]
    }

    static let groups: [Group] = [
        Group(title: "Adjust", tools: [
            Tool(title: "Resize", symbol: "arrow.up.left.and.arrow.down.right"),
            Tool(title: "Rotate / Flip", symbol: "rotate.right"),
            Tool(title: "Crop", symbol: "crop"),
            Tool(title: "Lighting", symbol: "sun.max"),
            Tool(title: "Colors", symbol: "paintpalette"),
            Tool(title: "Curves", symbol: "point.bottomleft.forward.to.point.topright.scurvepath"),
            Tool(title: "Levels", symbol: "slider.horizontal.3"),
            Tool(title: "Sharpen / Blur", symbol: "drop.halffull"),
        ]),
        Group(title: "Effects", tools: [
            Tool(title: "Color Effects", symbol: "camera.filters"),
            Tool(title: "Artistic", symbol: "paintbrush.pointed"),
            Tool(title: "Lens", symbol: "circle.dashed"),
        ]),
        Group(title: "Draw", tools: [
            Tool(title: "Text", symbol: "textformat"),
            Tool(title: "Lines & Arrows", symbol: "arrow.up.right"),
            Tool(title: "Callouts", symbol: "text.bubble"),
        ]),
        Group(title: "Retouch", tools: [
            Tool(title: "Clone", symbol: "square.on.square"),
            Tool(title: "Heal", symbol: "bandage"),
            Tool(title: "Red-Eye", symbol: "eye"),
        ]),
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))

        let title = NSTextField(labelWithString: "Tools")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let caption = NSTextField(labelWithString: "Coming soon")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        stack.setCustomSpacing(14, after: caption)
        for group in Self.groups {
            let header = NSTextField(labelWithString: group.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(4, after: header)
            for tool in group.tools {
                let row = Self.row(tool)
                stack.addArrangedSubview(row)
                // Full width, so the hover highlight spans the panel.
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            // Breathing room before the next group.
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
        }

        // Scrolls when the window is too short for the whole list.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    private static func row(_ tool: Tool) -> NSButton {
        let button = NSButton(title: tool.title, image: symbol(tool.symbol), target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = false
        button.toolTip = "\(tool.title) (coming soon)"
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
