import AppKit
import QuartzCore
import MinivuCore

/// Cell geometry for one thumbnail size, in points. Plain numbers so the
/// layout can be tested without views.
nonisolated struct ThumbnailLayout: Equatable {
    /// Space between the selection outline and the thumbnail.
    static let inset: CGFloat = 8
    static let labelGap: CGFloat = 6
    static let nameHeight: CGFloat = 15
    /// The star row under the name: always reserved, so rating a photo
    /// doesn't make its row taller than its neighbours'.
    static let starsHeight: CGFloat = 12
    static let detailHeight: CGFloat = 14
    /// The tagged badge's point size and its inset from the picture's corner.
    static let badgeSize: CGFloat = 18
    static let badgeInset: CGFloat = 4

    static let sizeRange: ClosedRange<Double> = 80...320
    /// ⌘= and ⌘- move the size by this much.
    static let sizeStep: Double = 20

    /// Side of the square thumbnail area.
    let side: CGFloat

    init(side: Double) {
        self.side = CGFloat(Self.sizeRange.clamped(side).rounded())
    }

    var itemSize: CGSize {
        CGSize(width: side + 2 * Self.inset,
               height: Self.inset + side + Self.labelGap + Self.nameHeight + Self.starsHeight + Self.detailHeight
                   + Self.inset / 2)
    }

    var thumbnailArea: CGRect { CGRect(x: Self.inset, y: Self.inset, width: side, height: side) }

    /// Label frames, top-down (the cell view is flipped).
    var nameFrame: CGRect {
        CGRect(x: 2, y: Self.inset + side + Self.labelGap, width: itemSize.width - 4, height: Self.nameHeight)
    }
    var starsFrame: CGRect {
        CGRect(x: 2, y: nameFrame.maxY, width: itemSize.width - 4, height: Self.starsHeight)
    }
    var detailFrame: CGRect {
        CGRect(x: 2, y: starsFrame.maxY, width: itemSize.width - 4, height: Self.detailHeight)
    }

    /// The name and the Finder tag dots after it, centred together: the name
    /// gets what's left once the dots have their room.
    static func nameAndDots(in frame: CGRect, textWidth: CGFloat, dotsWidth: CGFloat) -> (name: CGRect, dots: CGRect) {
        guard dotsWidth > 0 else { return (frame, .zero) }
        let gap: CGFloat = 2
        let name = min(textWidth.rounded(.up), max(frame.width - dotsWidth - gap, 0))
        let x = (frame.minX + (frame.width - name - gap - dotsWidth) / 2).rounded()
        let dotsHeight = TagDotsView.diameter + 2
        return (CGRect(x: x, y: frame.minY, width: name, height: frame.height),
                CGRect(x: x + name + gap, y: (frame.midY - dotsHeight / 2).rounded(), width: dotsWidth,
                       height: dotsHeight))
    }

    /// The tagged badge, over the picture's top-left corner.
    func badgeFrame(imageFrame: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + Self.badgeInset, y: imageFrame.minY + Self.badgeInset,
               width: Self.badgeSize, height: Self.badgeSize)
    }

    /// Where a picture of `pixels` sits in the square: as large as fits,
    /// centred, snapped to whole points so edges stay crisp.
    func imageFrame(for pixels: CGSize) -> CGRect {
        Self.aspectFit(pixels, in: thumbnailArea)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = (size.width * scale).rounded(), height = (size.height * scale).rounded()
        return CGRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    /// The next size up or down, on multiples of the step so repeated
    /// presses land on round numbers whatever the slider left.
    static func stepped(_ size: Double, larger: Bool) -> Double {
        let steps = size / sizeStep
        let next = larger ? (steps + 0.001).rounded(.down) + 1 : (steps - 0.001).rounded(.up) - 1
        return sizeRange.clamped(next * sizeStep)
    }
}

extension ClosedRange where Bound == Double {
    nonisolated func clamped(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// The view of one grid cell: a thumbnail drawn by a plain `CALayer` (the
/// `CGImage` goes straight to the layer, no `NSImage` in between), the name
/// and a detail line.
final class ThumbnailCellView: NSView {
    private let imageLayer = CALayer()
    let nameField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let stars = StarRatingView(starSize: 10)
    let dots = TagDotsView()
    let tagBadge = TagBadge.makeView(pointSize: 14)

    var layoutInfo = ThumbnailLayout(side: 150) {
        didSet { if layoutInfo != oldValue { needsLayout = true } }
    }
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    /// A folder under a drag of files: where they would go.
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }
    /// The pointer is over the cell: a light fill, and hollow stars to click.
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateStars()
        }
    }
    /// Images take ratings; folders show no stars at all.
    var isRatable = false {
        didSet { if isRatable != oldValue { updateStars() } }
    }
    private var hoverArea: NSTrackingArea?
    /// Folder icons get no frame; photos get a hairline so dark pictures
    /// don't melt into a dark background.
    private var isIcon = false
    private var imagePixels: CGSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        imageLayer.contentsGravity = .resizeAspect
        // Thumbnails are cached at 256 or 512 px and usually drawn smaller:
        // trilinear filtering keeps the downscale smooth instead of shimmery.
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        // Frames change as cells are reused; they must not animate.
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(imageLayer)

        for field in [nameField, detailField] {
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            field.cell?.truncatesLastVisibleLine = true
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.textColor = .labelColor
        detailField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        detailField.textColor = .secondaryLabelColor

        stars.isHidden = true
        tagBadge.isHidden = true
        dots.isHidden = true
        for view in [stars, dots, tagBadge] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a rating, the tagged badge and Finder tag dots. Laying out and
    /// drawing happen only when something actually changed, so refreshing
    /// every visible cell after a catalog change costs nearly nothing.
    func setMarks(_ marks: Catalog.Marks, finderTags: [FinderTag]) {
        if stars.rating != marks.rating {
            stars.rating = marks.rating
            updateStars()
        }
        if tagBadge.isHidden == marks.isTagged { tagBadge.isHidden = !marks.isTagged }
        if dots.tags != finderTags {
            dots.tags = finderTags
            dots.isHidden = finderTags.isEmpty || isRenaming
            needsLayout = true
        }
    }

    /// The name is being edited in a field over it. The label and tag dots
    /// step aside: a bezeled field is translucent in Dark Mode, and they
    /// would show through it.
    var isRenaming = false {
        didSet {
            guard isRenaming != oldValue else { return }
            nameField.isHidden = isRenaming
            dots.isHidden = isRenaming || dots.tags.isEmpty
            needsLayout = true
        }
    }

    private func updateStars() {
        stars.showsEmptyStars = isHovered && isRatable
        stars.isInteractive = isRatable
        let hidden = !isRatable || !(stars.rating > 0 || isHovered)
        if stars.isHidden != hidden { stars.isHidden = hidden }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A reused cell starts without the pointer over it.
    func resetHover() { isHovered = false }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Core Animation copies a `CGImage`'s pixels for the render server and
    /// keeps that copy for as long as the `CGImage` object lives. The
    /// thumbnail cache keeps its images, so after a scroll through a big
    /// folder every cached thumbnail had a second copy (measured: 194 MB
    /// beside the cache's own 191 MB). A new `CGImage` sharing the cached
    /// pixels (`copy()` copies no bytes) ties Core Animation's copy to this
    /// cell instead, and it goes when the cell moves on (measured: 43 MB).
    /// Scrolling back to a photo makes the copy again, a fraction of a
    /// millisecond. The folder icon is one image for every cell, so it keeps
    /// its single copy.
    func setImage(_ image: CGImage?, isIcon: Bool) {
        self.isIcon = isIcon
        imageLayer.contents = isIcon ? image : image?.copy()
        imagePixels = image.map { CGSize(width: $0.width, height: $0.height) }
        needsLayout = true
        needsDisplay = true
    }

    var hasImage: Bool { imageLayer.contents != nil }

    override func layout() {
        super.layout()
        let info = layoutInfo
        var frame = imagePixels.map(info.imageFrame(for:)) ?? info.thumbnailArea
        // Icons carry their own transparent margin but still look heavier
        // than photos at full size; a little air balances the row.
        if isIcon { frame = frame.insetBy(dx: (frame.width * 0.08).rounded(), dy: (frame.height * 0.08).rounded()) }
        imageLayer.frame = frame
        tagBadge.frame = info.badgeFrame(imageFrame: frame)
        if dots.isHidden {
            nameField.frame = info.nameFrame
        } else {
            // The text's natural width: a label's intrinsic size follows the
            // frame it last had, so it would shrink with every layout.
            let textWidth = nameField.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? 0
            let placed = ThumbnailLayout.nameAndDots(in: info.nameFrame, textWidth: textWidth,
                                                     dotsWidth: TagDotsView.width(for: dots.tags.count))
            nameField.frame = placed.name
            dots.frame = placed.dots
        }
        stars.frame = info.starsFrame
        detailField.frame = info.detailFrame
    }

    /// Colours resolve here, against the view's appearance, so Bright, Gray
    /// and Dark all redraw correctly (the theme change asks every view to).
    override func updateLayer() {
        let fill: NSColor? = isDropTarget ? ThemeColors.selectionFill
            : isSelected ? ThemeColors.selectionFill
            : isHovered ? ThemeColors.hoverFill : nil
        layer?.backgroundColor = fill?.cgColor ?? .clear
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        let framed = hasImage && !isIcon
        imageLayer.borderWidth = framed ? 1 / max(1, window?.backingScaleFactor ?? 2) : 0
        imageLayer.borderColor = NSColor.separatorColor.cgColor
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// One item in the thumbnail grid.
///
/// A cell asks for its thumbnail when configured and cancels the request
/// when it scrolls away or is reused, so fast scrolling through ten thousand
/// photos decodes only where the user stops (DESIGN.md 6, rule 5).
final class ThumbnailCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("minivu.thumbnail")

    private(set) var entry: FolderEntry?
    private var cellView: ThumbnailCellView { view as! ThumbnailCellView }
    private var thumbnailRequest: ThumbnailRequest?
    private var sizeRequest: PixelSizeRequest?
    /// Pixel size asked of the thumbnail service for what's showing now.
    private var shownPixelSize = 0
    private var wantedPixelSize = 0
    /// Bumped on every configure, so a completion meant for this cell's
    /// previous entry is ignored even if it was already on its way.
    private var generation = 0

    /// The system folder icon, rendered once at a size that stays sharp at
    /// the largest thumbnail on Retina.
    private static let folderIcon: CGImage? = {
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        return NSWorkspace.shared.icon(for: .folder).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    override func loadView() {
        view = ThumbnailCellView(frame: NSRect(origin: .zero, size: ThumbnailLayout(side: 150).itemSize))
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        cellView.isSelected = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        cellView.isDropTarget = highlightState == .asDropTarget && entry?.isDirectory == true
    }

    /// A click on the cell's stars: the file and the rating chosen.
    var onRate: ((URL, Int) -> Void)?

    /// The cell's view, for the grid's inline rename and for tests.
    var thumbnailView: ThumbnailCellView { cellView }

    /// Shows `entry` with a thumbnail side of `side` points, its rating, tag
    /// and Finder tags.
    func configure(_ entry: FolderEntry, layout: ThumbnailLayout, backingScale: CGFloat,
                   marks: Catalog.Marks = .none, finderTags: [FinderTag] = []) {
        let sameFile = self.entry == entry
        self.entry = entry
        cellView.layoutInfo = layout
        if cellView.nameField.stringValue != entry.name {
            cellView.nameField.stringValue = entry.name
            cellView.needsLayout = true
        }
        view.toolTip = entry.name
        wantedPixelSize = Int((layout.side * backingScale).rounded())
        cellView.isRatable = !entry.isDirectory
        cellView.setMarks(entry.isDirectory ? .none : marks, finderTags: finderTags)
        cellView.stars.onRate = { [weak self] rating in
            guard let url = self?.entry?.url else { return }
            self?.onRate?(url, rating)
        }

        if entry.isDirectory {
            cancelLoading()
            cellView.setImage(Self.folderIcon, isIcon: true)
            cellView.detailField.stringValue = ""
            return
        }
        if !sameFile {
            cancelLoading()
            generation += 1
            shownPixelSize = 0
            // A smaller cached tier is better than a blank while the right
            // one loads (after the size slider moved, say).
            cellView.setImage(AppServices.thumbnails.cachedImage(for: entry, pixelSize: 1), isIcon: false)
            cellView.detailField.stringValue = PixelSizeCache.shared.cachedSize(for: entry).map(Self.dimensions) ?? ""
        }
        loadIfNeeded()
    }

    /// Requests whatever is missing. Called again when the cell comes back
    /// on screen after `cancelLoading`.
    func loadIfNeeded() {
        guard let entry, !entry.isDirectory else { return }
        let tier = ThumbnailService.tier(forPixelSize: wantedPixelSize)
        if thumbnailRequest == nil, !cellView.hasImage || shownPixelSize < tier {
            if let image = AppServices.thumbnails.cachedImage(for: entry, pixelSize: wantedPixelSize) {
                cellView.setImage(image, isIcon: false)
                shownPixelSize = tier
                loadPixelSizeIfNeeded()
            } else {
                let generation = self.generation
                thumbnailRequest = AppServices.thumbnails.request(entry, pixelSize: wantedPixelSize) { [weak self] image in
                    guard let self, self.generation == generation else { return }
                    self.thumbnailRequest = nil
                    if let image {
                        self.cellView.setImage(image, isIcon: false)
                        self.shownPixelSize = tier
                        // The cell grew past this tier while it was loading.
                        if tier < ThumbnailService.tier(forPixelSize: self.wantedPixelSize) { self.loadIfNeeded() }
                    }
                    self.loadPixelSizeIfNeeded()
                }
            }
        } else if cellView.hasImage {
            loadPixelSizeIfNeeded()
        }
    }

    /// Dimensions come after the thumbnail: they're a nicety, and reading
    /// headers must not compete with the pictures for the disk.
    private func loadPixelSizeIfNeeded() {
        guard let entry, sizeRequest == nil, cellView.detailField.stringValue.isEmpty else { return }
        if let size = PixelSizeCache.shared.cachedSize(for: entry) {
            cellView.detailField.stringValue = Self.dimensions(size)
            return
        }
        let generation = self.generation
        sizeRequest = PixelSizeCache.shared.request(entry) { [weak self] size in
            guard let self, self.generation == generation else { return }
            self.sizeRequest = nil
            self.cellView.detailField.stringValue = size.map(Self.dimensions) ?? ""
        }
    }

    func cancelLoading() {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        sizeRequest?.cancel()
        sizeRequest = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoading()
        generation += 1
        entry = nil
        shownPixelSize = 0
        cellView.setImage(nil, isIcon: false)
        cellView.detailField.stringValue = ""
        cellView.resetHover()
        cellView.isRenaming = false
    }

    nonisolated static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}
