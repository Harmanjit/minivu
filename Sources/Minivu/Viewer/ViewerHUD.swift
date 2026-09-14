import AppKit

/// The small overlay in the top-left corner: file name, position in the
/// folder, pixel size, zoom and, for photos, the exposure.
///
/// It flashes up when the image or zoom changes and fades away on its own,
/// so it answers "where am I?" without sitting on the photo. I pins it.
/// The fade is one restartable work item, not a repeating timer: nothing
/// runs while the viewer is idle.
final class ViewerHUD: NSVisualEffectView {
    static let visibleDuration: TimeInterval = 1.5

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let exposureLabel = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    private(set) var isPinned = false

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        // A dark overlay on any theme: it sits on a photo, not on the app's chrome.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        for label in [detailLabel, exposureLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        let stack = NSStackView(views: [nameLabel, detailLabel, exposureLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            // Long names truncate in the middle, keeping the extension.
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// The HUD is a read-out: clicks go to the image beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Content

    /// - Parameters:
    ///   - pixelSize: nil until the image is decoded, so the previous image's
    ///     size never shows beside the new name.
    ///   - exposure: nil for non-photos and until the metadata is read.
    func update(name: String, position: String, pixelSize: CGSize?, zoomPercent: Double?, exposure: String?) {
        nameLabel.stringValue = name
        detailLabel.stringValue = Self.detailText(position: position, pixelSize: pixelSize, zoomPercent: zoomPercent)
        exposureLabel.stringValue = exposure ?? ""
        exposureLabel.isHidden = exposure == nil
    }

    /// "3 / 120 · 6000 × 4000 · 25%", leaving out what isn't known.
    nonisolated static func detailText(position: String, pixelSize: CGSize?, zoomPercent: Double?) -> String {
        var parts: [String] = []
        if !position.isEmpty { parts.append(position) }
        if let size = pixelSize, size.width > 0, size.height > 0 {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if let zoom = zoomPercent { parts.append(zoomText(zoom)) }
        return parts.joined(separator: "  ·  ")
    }

    /// Whole percents, with one decimal below 10% so tiny zooms don't all
    /// read "3%".
    nonisolated static func zoomText(_ percent: Double) -> String {
        percent < 9.95 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    // MARK: - Showing

    /// Shows the HUD now and, unless pinned, fades it out after a moment.
    func flash() {
        fadeWork?.cancel()
        fadeWork = nil
        setVisible(true, duration: 0.12)
        guard !isPinned else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.setVisible(false, duration: 0.35)
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            fadeWork?.cancel()
            fadeWork = nil
            setVisible(true, duration: 0.12)
        } else {
            flash()
        }
    }

    /// Stops a pending fade, for closing the viewer.
    func cancelFade() {
        fadeWork?.cancel()
        fadeWork = nil
    }

    private func setVisible(_ visible: Bool, duration: TimeInterval) {
        let target: CGFloat = visible ? 1 : 0
        guard alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = target
        }
    }
}
