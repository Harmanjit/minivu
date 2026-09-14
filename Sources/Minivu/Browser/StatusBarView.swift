import AppKit

/// The strip under the grid: counts and selection on the left, the current
/// folder's path on the right (like Finder's status and path bars in one).
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    /// A path component was clicked.
    var onNavigate: ((URL) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let pathControl = NSPathControl()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.backgroundColor = .clear
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        // The path gives way first: it truncates its middle components.
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for view in [separator, label, pathControl] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            pathControl.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
            pathControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(text: String, folder: URL?) {
        if label.stringValue != text { label.stringValue = text }
        if pathControl.url != folder { pathControl.url = folder }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        onNavigate?(url)
    }
}
