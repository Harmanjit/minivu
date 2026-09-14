import AppKit
import MinivuCore

/// What a slide's caption says.
nonisolated enum SlideshowCaptionText {
    /// Whether `style` needs the file's metadata (read off the main thread).
    static func needsMetadata(_ style: SlideshowSettings.Caption) -> Bool {
        style == .nameAndDate || style == .exif
    }

    /// The caption for one image, or nil for none.
    /// - Parameters:
    ///   - summary: the file's metadata; nil until read (the name shows
    ///     meanwhile, so the caption never lags a slide behind).
    static func text(style: SlideshowSettings.Caption, name: String, modified: Date,
                     summary: MetadataSummary?) -> String? {
        switch style {
        case .none:
            return nil
        case .name:
            return name
        case .nameAndDate:
            guard let summary else { return name }
            // The date the photo was taken, else when the file last changed.
            let date = summary.dateTaken ?? modified
            return "\(name)  ·  \(date.formatted(date: .long, time: .shortened))"
        case .exif:
            guard let summary else { return name }
            let parts = [summary.camera, summary.lens, summary.exposure].compactMap { $0 }.filter { !$0.isEmpty }
            // A screenshot or a drawing has no camera: its name says more than nothing.
            return parts.isEmpty ? name : parts.joined(separator: "  ·  ")
        }
    }
}

/// The caption in the bottom-left corner: white text with a soft shadow, so
/// it reads on any photo without a box over the picture.
final class SlideshowCaptionView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 15, weight: .medium)
        textColor = .white
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        self.shadow = shadow
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// A read-out: clicks go to the slideshow beneath (which ends it).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What the caption says, nil while hidden.
    private(set) var text: String?

    /// Shows `text`, or fades out for nil.
    func show(_ text: String?) {
        self.text = text
        if let text { stringValue = text }
        let target: CGFloat = text == nil ? 0 : 1
        guard alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = target
        }
    }
}
