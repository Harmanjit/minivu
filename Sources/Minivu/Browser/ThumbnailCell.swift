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
    static let detailHeight: CGFloat = 14

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
               height: Self.inset + side + Self.labelGap + Self.nameHeight + Self.detailHeight + Self.inset / 2)
    }

    var thumbnailArea: CGRect { CGRect(x: Self.inset, y: Self.inset, width: side, height: side) }

    /// Label frames, top-down (the cell view is flipped).
    var nameFrame: CGRect {
        CGRect(x: 2, y: Self.inset + side + Self.labelGap, width: itemSize.width - 4, height: Self.nameHeight)
    }
    var detailFrame: CGRect {
        CGRect(x: 2, y: nameFrame.maxY, width: itemSize.width - 4, height: Self.detailHeight)
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

    var layoutInfo = ThumbnailLayout(side: 150) {
        didSet { if layoutInfo != oldValue { needsLayout = true } }
    }
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

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
        nameField.frame = info.nameFrame
        detailField.frame = info.detailFrame
    }

    /// Colours resolve here, against the view's appearance, so Bright, Gray
    /// and Dark all redraw correctly (the theme change asks every view to).
    override func updateLayer() {
        layer?.backgroundColor = isSelected ? ThemeColors.selectionFill.cgColor : .clear
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
    }

    /// Shows `entry` with a thumbnail side of `side` points.
    func configure(_ entry: FolderEntry, layout: ThumbnailLayout, backingScale: CGFloat) {
        let sameFile = self.entry == entry
        self.entry = entry
        cellView.layoutInfo = layout
        cellView.nameField.stringValue = entry.name
        view.toolTip = entry.name
        wantedPixelSize = Int((layout.side * backingScale).rounded())

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
    }

    nonisolated static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}
