import AppKit
import MinivuCore

/// Five small stars: filled up to the rating, hollow after.
///
/// Drawn with SF Symbols in `draw(_:)`, so the colours resolve against the
/// view's own appearance. Interactive stars show what a click would set
/// while the pointer is over them, and a click on the current rating clears
/// it (as in Lightroom and Music).
final class StarRatingView: NSView {
    var rating = 0 {
        didSet { if rating != oldValue { needsDisplay = true } }
    }
    /// Show the hollow stars when unrated (the cell is hovered, or the HUD).
    var showsEmptyStars = false {
        didSet { if showsEmptyStars != oldValue { needsDisplay = true } }
    }
    /// Takes clicks and shows a hover preview.
    var isInteractive = false {
        didSet { updateTrackingAreas() }
    }
    /// A click chose this rating (0 clears).
    var onRate: ((Int) -> Void)?

    let starSize: CGFloat
    static let spacing: CGFloat = 1.5
    private var hoverRating: Int? {
        didSet { if hoverRating != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    /// The stars' colour: warm enough to find at a glance in a grid of photos,
    /// and readable on both light and dark backgrounds.
    static let filledColor = NSColor.systemOrange

    init(starSize: CGFloat = 10) {
        self.starSize = starSize
        super.init(frame: NSRect(origin: .zero, size: Self.size(starSize: starSize)))
        setAccessibilityRole(.levelIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func size(starSize: CGFloat) -> CGSize {
        CGSize(width: 5 * starSize + 4 * spacing, height: starSize + 2)
    }

    override var intrinsicContentSize: NSSize { Self.size(starSize: starSize) }
    override var isFlipped: Bool { true }

    /// Hidden while there's nothing to show, so it takes no clicks then.
    var hasContent: Bool { rating > 0 || showsEmptyStars || hoverRating != nil }

    override func accessibilityValue() -> Any? { rating }
    override func accessibilityLabel() -> String? { "Rating" }

    override func draw(_ dirtyRect: NSRect) {
        let shown = hoverRating ?? rating
        guard shown > 0 || showsEmptyStars else { return }
        let origin = CGPoint(x: (bounds.width - Self.size(starSize: starSize).width) / 2,
                             y: (bounds.height - starSize) / 2)
        for index in 0..<5 {
            let filled = index < shown
            // Filled stars in the accent; the hover preview a little lighter,
            // so it reads as a proposal rather than the rating.
            let color: NSColor = filled
                ? (hoverRating != nil ? Self.filledColor.withAlphaComponent(0.6) : Self.filledColor)
                : .tertiaryLabelColor
            guard let image = Self.star(filled: filled, size: starSize, color: color) else { continue }
            let rect = CGRect(x: origin.x + CGFloat(index) * (starSize + Self.spacing), y: origin.y,
                              width: starSize, height: starSize)
            image.draw(in: rect)
        }
    }

    private static func star(filled: Bool, size: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    /// The star under `point` (1 to 5), for clicks and the hover preview.
    func starIndex(at point: CGPoint) -> Int {
        let width = Self.size(starSize: starSize).width
        let x = point.x - (bounds.width - width) / 2
        return min(max(Int(x / (starSize + Self.spacing)) + 1, 1), 5)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard isInteractive else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { return }
        hoverRating = starIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverRating = nil
    }

    /// Stars take the click themselves, so rating a photo doesn't also
    /// change the grid's selection.
    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return super.mouseDown(with: event) }
        let star = starIndex(at: convert(event.locationInWindow, from: nil))
        hoverRating = nil
        onRate?(star == rating ? 0 : star)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }
}

/// Finder's tag dots: small overlapping circles, each cut out of the one
/// behind it so they read as separate on any background (a selected cell's
/// fill, a hovered one, the plain grid) without knowing its colour.
final class TagDotsView: NSView {
    nonisolated static let diameter: CGFloat = 8
    nonisolated static let overlap: CGFloat = 3

    var tags: [FinderTag] = [] {
        didSet { if tags != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } }
    }

    /// Finder draws at most three.
    var shownTags: ArraySlice<FinderTag> { tags.prefix(3) }

    nonisolated static func width(for count: Int) -> CGFloat {
        let n = CGFloat(min(count, 3))
        return n == 0 ? 0 : n * diameter - (n - 1) * overlap + 2
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width(for: tags.count), height: Self.diameter + 2) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        // The rings are cleared inside a layer of their own: drawn straight
        // into a shared bitmap (a cached snapshot, a parent's layer) a clear
        // would punch through whatever the cell drew beneath.
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.cgContext.endTransparencyLayer() }
        let y = (bounds.height - Self.diameter) / 2
        // Right to left, so each dot sits over the next, as in Finder.
        for (index, tag) in shownTags.enumerated().reversed() {
            let rect = CGRect(x: 1 + CGFloat(index) * (Self.diameter - Self.overlap), y: y,
                              width: Self.diameter, height: Self.diameter)
            // A transparent ring: the gap between this dot and the one behind.
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
            context.compositingOperation = .sourceOver
            let dot = NSBezierPath(ovalIn: rect)
            if let color = tag.color {
                color.setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    override func accessibilityLabel() -> String? {
        tags.isEmpty ? nil : "Tags: " + tags.map(\.name).joined(separator: ", ")
    }
}

/// The "tagged" mark: a checkmark in an accent-coloured circle.
enum TagBadge {
    static func image(pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]))
        return NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Tagged")?
            .withSymbolConfiguration(configuration)
    }

    static func makeView(pointSize: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = image(pointSize: pointSize)
        view.imageScaling = .scaleNone
        view.setAccessibilityLabel("Tagged")
        // A soft shadow keeps the white check legible on a bright photo.
        view.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            return shadow
        }()
        return view
    }
}
