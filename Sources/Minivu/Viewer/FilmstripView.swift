import AppKit
import MinivuCore

/// The top fly-out: a horizontal strip of the folder's thumbnails, with the
/// image on screen highlighted. Click one to jump to it.
///
/// An `NSCollectionView` so a folder of ten thousand photos costs the same
/// as fifty: only the cells in view exist, and they are recycled as the
/// strip scrolls. Thumbnails come from the same `ThumbnailService` as the
/// browser grid, so a folder already browsed shows its strip at once.
///
/// The strip only works while it's on screen. Hidden, it asks for nothing
/// and cancels what it asked for (DESIGN.md 6, rule 5); shown again, it
/// catches up with the current image in one step.
final class FilmstripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 96
    static let itemSize = NSSize(width: 104, height: 76)

    /// A thumbnail was clicked.
    var onSelect: ((Int) -> Void)?

    private var images: [FolderEntry] = []
    private var currentIndex = 0
    private(set) var isActive = false
    /// Data changed while hidden; reload when shown.
    private var needsReload = true

    private let scrollView = HorizontalScrollView()
    private let collectionView = FilmstripCollectionView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        collectionView.addGestureRecognizer(click)

        scrollView.documentView = collectionView
        // In a window with a full-size content view, scroll views pad
        // themselves for the title bar; this strip sits below it already.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: - State

    func setImages(_ images: [FolderEntry], current: Int) {
        self.images = images
        currentIndex = current
        needsReload = true
        if isActive {
            catchUp(animated: false)
        } else {
            // Down to no items now (the count is zero until shown). Left with
            // the old ones, the next layout could ask for an item of a list
            // that has since changed.
            collectionView.reloadData()
        }
    }

    func setCurrent(_ index: Int) {
        guard index != currentIndex else { return }
        currentIndex = index
        guard isActive else { return }
        updateHighlights()
        scrollToCurrent(animated: true)
    }

    /// Visible (true) or slid away (false).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            catchUp(animated: false)
        } else {
            for case let item as FilmstripItem in collectionView.visibleItems() { item.cancelThumbnail() }
        }
    }

    private func catchUp(animated: Bool) {
        if needsReload {
            needsReload = false
            collectionView.reloadData()
            // Lay out now so the scroll below knows where the item is.
            collectionView.layoutSubtreeIfNeeded()
        } else {
            // Cells that stayed alive while hidden had their requests cancelled.
            for case let item as FilmstripItem in collectionView.visibleItems() { item.reloadThumbnailIfNeeded() }
        }
        updateHighlights()
        scrollToCurrent(animated: animated)
    }

    private func updateHighlights() {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: indexPath) as? FilmstripItem)?.isCurrent = indexPath.item == currentIndex
        }
    }

    private func scrollToCurrent(animated: Bool) {
        guard images.indices.contains(currentIndex) else { return }
        let indexPath = IndexPath(item: currentIndex, section: 0)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
            }
        } else {
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
        }
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        onSelect?(indexPath.item)
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        isActive || !needsReload ? images.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        if let item = item as? FilmstripItem, images.indices.contains(indexPath.item) {
            // A window resize lays out the hidden strip too; its cells wait
            // for `catchUp` before asking for thumbnails.
            item.show(images[indexPath.item], loadsThumbnail: isActive)
            item.isCurrent = indexPath.item == currentIndex
        }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? FilmstripItem)?.cancelThumbnail()
    }
}

/// Never takes the keyboard: arrow keys must keep flipping images, even
/// after a click on the strip.
private final class FilmstripCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// A mouse wheel scrolls a horizontal strip sideways. Trackpads already
/// scroll in both directions, so only line-based wheel events are turned.
private final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let cgEvent = event.cgEvent?.copy() else { return super.scrollWheel(with: event) }
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(event.scrollingDeltaY))
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: cgEvent) ?? event)
    }
}

/// One thumbnail in the strip.
private final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")
    /// Thumbnail tier to ask for: the cell's height at 2x, rounded up by
    /// `ThumbnailService` to its 256 px tier.
    static let thumbnailPixels = Int(FilmstripView.itemSize.height * 2)

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private var entry: FolderEntry?
    private var request: ThumbnailRequest?

    var isCurrent = false {
        didSet { ringLayer.isHidden = !isCurrent }
    }

    override func loadView() {
        let view = CellView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.onLayout = { [weak self] in self?.layoutLayers() }
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        ringLayer.borderWidth = 2
        ringLayer.cornerRadius = 7
        ringLayer.cornerCurve = .continuous
        ringLayer.borderColor = NSColor.controlAccentColor.cgColor
        ringLayer.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        ringLayer.isHidden = true
        view.layer?.addSublayer(ringLayer)
        view.layer?.addSublayer(imageLayer)
        self.view = view
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = view.bounds
        imageLayer.frame = view.bounds.insetBy(dx: 5, dy: 5)
        let scale = view.window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        ringLayer.contentsScale = scale
        CATransaction.commit()
    }

    func show(_ entry: FolderEntry, loadsThumbnail: Bool) {
        if entry != self.entry {
            cancelThumbnail()
            self.entry = entry
            view.toolTip = entry.name
            setImage(nil)
        }
        if loadsThumbnail { reloadThumbnailIfNeeded() }
    }

    /// Asks for the thumbnail unless it's showing or already on its way.
    /// A memory-cache hit is drawn synchronously, so scrolling back shows
    /// thumbnails without a blank frame.
    func reloadThumbnailIfNeeded() {
        guard let entry, imageLayer.contents == nil, request == nil else { return }
        if let image = AppServices.thumbnails.cachedImage(for: entry, pixelSize: Self.thumbnailPixels) {
            setImage(image)
            return
        }
        request = AppServices.thumbnails.request(entry, pixelSize: Self.thumbnailPixels) { [weak self] image in
            guard let self, self.entry == entry else { return }
            self.request = nil
            self.setImage(image)
        }
    }

    func cancelThumbnail() {
        request?.cancel()
        request = nil
    }

    private func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        entry = nil
        isCurrent = false
        setImage(nil)
    }

    /// Reports size and scale changes so the layers follow the cell.
    private final class CellView: NSView {
        var onLayout: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onLayout?()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            onLayout?()
        }
    }
}
