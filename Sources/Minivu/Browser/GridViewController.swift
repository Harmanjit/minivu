import AppKit
import Combine
import MinivuCore

/// The thumbnail grid, with the status bar under it.
///
/// An `NSCollectionView` recycles cells, so a folder of ten thousand photos
/// costs as many views as fit on screen. Data comes from `BrowserModel`;
/// selection flows both ways: clicks and arrow keys go to the model, and
/// selections the model makes (opening a file, Back, the Trash) come back
/// and scroll into view.
final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewPrefetching {
    let model: BrowserModel
    let collectionView = GridCollectionView()
    let statusBar = StatusBarView()

    /// Open an image in the viewer, or go into a folder.
    var onOpen: ((FolderEntry) -> Void)?

    private let scrollView = NSScrollView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let messageField = NSTextField(wrappingLabelWithString: "")
    /// Thumbnails requested just ahead of the visible rows, by file.
    private var prefetches: [URL: ThumbnailRequest] = [:]
    /// Set while the model's selection is pushed into the view, so the view
    /// doesn't report it straight back.
    private var isApplyingSelection = false
    /// Set while a click or arrow key's selection is passed to the model:
    /// the view already shows it and has scrolled as it needs to.
    private var isReportingSelection = false
    /// The lead the grid last showed, to scroll only when it moves.
    private var shownLead: URL?
    private var subscriptions: Set<AnyCancellable> = []

    private var thumbnailLayout = ThumbnailLayout(side: Preferences.shared.thumbnailSize)

    init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        flowLayout.itemSize = thumbnailLayout.itemSize
        flowLayout.minimumInteritemSpacing = 6
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 12, left: 14, bottom: 16, right: 14)

        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [ThemeColors.contentBackground]
        collectionView.register(ThumbnailCell.self, forItemWithIdentifier: ThumbnailCell.identifier)
        // Dragging to Finder copies the files; nothing in minivu moves them.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.onOpen = { [weak self] indexPath in self?.open(at: indexPath) }
        collectionView.onTypeSelect = { [weak self] prefix in
            guard let self, let url = self.model.firstEntry(withPrefix: prefix) else { return }
            self.model.select(url)
        }
        collectionView.onContextClick = { [weak self] indexPath in self?.contextClicked(indexPath) }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ThemeColors.contentBackground

        messageField.alignment = .center
        messageField.textColor = .secondaryLabelColor
        messageField.font = .systemFont(ofSize: 15, weight: .medium)
        messageField.isHidden = true

        statusBar.onNavigate = { [weak self] url in self?.navigateFromPathBar(url) }

        for view in [scrollView, statusBar, messageField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            messageField.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageField.centerYAnchor.constraint(equalTo: container.safeAreaLayoutGuide.centerYAnchor),
            messageField.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            messageField.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
        ])
        view = container

        // `@Published` sends the new value before storing it; the value is
        // passed in, so nothing reads the preference early.
        Preferences.shared.$thumbnailSize
            .removeDuplicates()
            .sink { [weak self] size in self?.setThumbnailSize(size) }
            .store(in: &subscriptions)
        // Gray and Dark share an appearance, so a switch between them isn't
        // an appearance change: the colours must be set again.
        Preferences.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.themeChanged() }
            .store(in: &subscriptions)
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: - Model changes

    func modelChanged(_ changes: BrowserModel.Changes) {
        if changes.contains(.entries) {
            cancelPrefetches()
            collectionView.reloadData()
            if changes.contains(.folder) { scrollToTop() }
        }
        if changes.contains(.entries) || changes.contains(.selection) {
            applyModelSelection()
        }
        if changes.contains(.entries) || changes.contains(.state) {
            updateMessage()
        }
        statusBar.update(text: model.statusText, folder: model.folder)
    }

    /// Pushes the model's selection into the view if they differ (they don't
    /// when the change started with a click), and scrolls to a lead the model
    /// moved (opening a file, Back, the Trash). A reload that keeps the lead
    /// leaves the scroll position alone: the watcher may reload while the
    /// user is looking somewhere else entirely.
    private func applyModelSelection() {
        let paths = Set(model.selection.compactMap(model.index(of:)).map { IndexPath(item: $0, section: 0) })
        if paths != collectionView.selectionIndexPaths {
            isApplyingSelection = true
            collectionView.selectionIndexPaths = paths
            isApplyingSelection = false
        }
        let leadMoved = model.lead != shownLead
        shownLead = model.lead
        if leadMoved, !isReportingSelection { scrollLeadIntoView() }
    }

    /// The top of a new folder. The clip view's origin sits under the
    /// toolbar (the grid scrolls beneath it), so the top is minus the inset.
    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollLeadIntoView() {
        guard let lead = model.lead, let index = model.index(of: lead) else { return }
        // Layout first: after a reload the item has no frame to scroll to yet.
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        else { return }
        // A little room around it, rather than flush against the status bar.
        collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -flowLayout.minimumLineSpacing))
    }

    private func updateMessage() {
        let message: String? = switch model.state {
        case .failed(let text): text
        case .loaded where model.entries.isEmpty: model.filter.isEmpty ? "No Images" : "No Matches"
        default: nil
        }
        messageField.stringValue = message ?? ""
        messageField.isHidden = message == nil
    }

    private func themeChanged() {
        collectionView.backgroundColors = [ThemeColors.contentBackground]
        scrollView.backgroundColor = ThemeColors.contentBackground
    }

    // MARK: - Thumbnail size

    private func setThumbnailSize(_ size: Double) {
        let layout = ThumbnailLayout(side: size)
        guard layout != thumbnailLayout else { return }
        thumbnailLayout = layout
        flowLayout.itemSize = layout.itemSize
        cancelPrefetches()
        for case let cell as ThumbnailCell in collectionView.visibleItems() {
            if let entry = cell.entry { cell.configure(entry, layout: layout, backingScale: backingScale) }
        }
        scrollLeadIntoView()
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.entries.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailCell.identifier, for: indexPath)
        if let cell = item as? ThumbnailCell, model.entries.indices.contains(indexPath.item) {
            cell.configure(model.entries[indexPath.item], layout: thumbnailLayout, backingScale: backingScale)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? ThumbnailCell)?.loadIfNeeded()
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? ThumbnailCell)?.cancelLoading()
    }

    // MARK: - Prefetching

    /// Starts thumbnails for rows about to scroll into view, so they arrive
    /// with the cells rather than after them.
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let pixelSize = Int((thumbnailLayout.side * backingScale).rounded())
        for indexPath in indexPaths where model.entries.indices.contains(indexPath.item) {
            let entry = model.entries[indexPath.item]
            guard !entry.isDirectory, prefetches[entry.url] == nil,
                  AppServices.thumbnails.cachedImage(for: entry, pixelSize: pixelSize) == nil else { continue }
            let url = entry.url
            prefetches[url] = AppServices.thumbnails.request(entry, pixelSize: pixelSize) { [weak self] _ in
                self?.prefetches[url] = nil
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where model.entries.indices.contains(indexPath.item) {
            prefetches.removeValue(forKey: model.entries[indexPath.item].url)?.cancel()
        }
    }

    private func cancelPrefetches() {
        prefetches.values.forEach { $0.cancel() }
        prefetches.removeAll()
    }

    // MARK: - Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection(added: indexPaths)
    }

    /// A click on another item deselects the old one and then selects the new
    /// one, as two calls. Reporting the empty moment in between would make
    /// the preview drop its picture, so deselection is reported a turn later,
    /// by when the selection (if any) has already arrived.
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelection else { return }
        DispatchQueue.main.async { [weak self] in self?.reportSelection(added: []) }
    }

    /// Tells the model what the view now selects. The lead is the item just
    /// clicked or arrowed to; when a shift-click or shift-arrow adds several
    /// at once, it's the one farthest from the old lead (the end that moved).
    private func reportSelection(added: Set<IndexPath>) {
        guard !isApplyingSelection else { return }
        let entries = model.entries
        let urls = Set(collectionView.selectionIndexPaths.compactMap {
            entries.indices.contains($0.item) ? entries[$0.item].url : nil
        })
        var lead = model.lead
        let anchor = lead.flatMap(model.index(of:)) ?? 0
        if let farthest = added.map(\.item).filter(entries.indices.contains).max(by: { abs($0 - anchor) < abs($1 - anchor) }) {
            lead = entries[farthest].url
        }
        isReportingSelection = true
        model.setSelection(urls, lead: lead)
        isReportingSelection = false
    }

    // MARK: - Opening and menus

    private func open(at indexPath: IndexPath?) {
        let entry = indexPath.flatMap { model.entries.indices.contains($0.item) ? model.entries[$0.item] : nil }
            ?? model.leadEntry
        guard let entry else { return }
        onOpen?(entry)
    }

    /// A right-click on an unselected item selects it first, as in Finder.
    private func contextClicked(_ indexPath: IndexPath?) {
        guard let indexPath, !collectionView.selectionIndexPaths.contains(indexPath),
              model.entries.indices.contains(indexPath.item) else { return }
        model.select(model.entries[indexPath.item].url)
    }

    private func navigateFromPathBar(_ url: URL) {
        guard AppDelegate.isReadableFolder(url) else { NSSound.beep(); return }
        model.navigate(to: url)
    }

    // MARK: - Drag out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard model.entries.indices.contains(indexPath.item) else { return nil }
        return model.entries[indexPath.item].url as NSURL
    }
}

/// The collection view with the browser's keys and clicks: Return and
/// double-click open, typing a name selects it, right-click shows a menu.
/// Arrows, shift and command selection are NSCollectionView's own.
final class GridCollectionView: NSCollectionView {
    /// Double-click (the item clicked) or Return (nil: the lead item).
    var onOpen: ((IndexPath?) -> Void)?
    var onTypeSelect: ((String) -> Void)?
    var onContextClick: ((IndexPath?) -> Void)?

    private var typed = ""
    private var lastKeyTime: TimeInterval = 0
    /// Finder's pause for type-to-select: longer than this starts a new name.
    private static let typingPause: TimeInterval = 1

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {   // Return, keypad Enter
            onOpen?(nil)
            return
        }
        if modifiers.isEmpty, let characters = event.characters, Self.isTypeSelectText(characters, continuing: !typed.isEmpty) {
            if event.timestamp - lastKeyTime > Self.typingPause { typed = "" }
            lastKeyTime = event.timestamp
            typed += characters
            onTypeSelect?(typed)
            return
        }
        super.keyDown(with: event)
    }

    /// Printable text. Arrows and function keys arrive as characters in
    /// Unicode's private use area, and a space only continues a name.
    nonisolated static func isTypeSelectText(_ characters: String, continuing: Bool) -> Bool {
        guard let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1 else { return false }
        if scalar == " " { return continuing }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) { onOpen?(indexPath) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        onContextClick?(indexPath)
        guard indexPath != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: .openInViewer, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: .revealInFinder, keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: .moveToTrash, keyEquivalent: "")
        return menu
    }
}
