import AppKit
import MinivuCore

/// The mark on a video's thumbnail (G18): a play triangle and the length
/// ("0:12") on a dark capsule over the picture's bottom-right corner, as
/// Photos and the Finder mark theirs. White on translucent black reads on
/// any frame and under every theme, so it ignores the appearance.
///
/// Until the length has been read (it comes with the dimensions, after the
/// thumbnail) the capsule holds the triangle alone.
final class VideoBadgeView: NSView {
    nonisolated static let height: CGFloat = 16
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 3

    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Seconds; nil while unknown.
    var duration: Double? {
        didSet {
            guard duration != oldValue else { return }
            label.stringValue = duration.map(VideoFrames.durationText) ?? ""
            label.isHidden = duration == nil
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous

        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        symbol.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .white
        label.isHidden = true
        for view in [symbol, label] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        // The cell speaks for itself ("video, 0:12"); see ThumbnailCellView.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let symbolWidth: CGFloat = 8
        let text = label.isHidden ? 0 : Self.gap + ceil(label.intrinsicContentSize.width)
        return NSSize(width: Self.padding * 2 + symbolWidth + text, height: Self.height)
    }

    override func layout() {
        super.layout()
        let symbolSize = CGSize(width: 8, height: 9)
        symbol.frame = CGRect(x: Self.padding, y: ((bounds.height - symbolSize.height) / 2).rounded(),
                              width: symbolSize.width, height: symbolSize.height)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: symbol.frame.maxX + Self.gap, y: ((bounds.height - labelHeight) / 2).rounded(),
                             width: max(bounds.width - symbol.frame.maxX - Self.gap - Self.padding + 2, 0),
                             height: labelHeight)
    }
}
