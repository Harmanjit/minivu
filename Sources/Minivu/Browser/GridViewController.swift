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
    /// A folder in the path bar was clicked.
    var onNavigate: ((URL) -> Void)?
    /// Files were dropped to be copied or moved into a folder:
    /// (files, destination, move).
    var onDropFiles: (([URL], URL, Bool) -> Void)?
    /// The inline name editor finished with a new name: (file, name).
    var onRename: ((URL, String) -> Void)?

    let scrollView = NSScrollView()
    let flowLayout = NSCollectionViewFlowLayout()
    private let messageField = NSTextField(wrappingLabelWithString: "")
    /// An accent outline round the grid while files dragged from elsewhere
    /// would land in the folder it shows.
    let dropHighlight = DropHighlightView()
    /// The name being edited in place, if any.
    var renameEditor: InlineRenameEditor?
    /// Volume answers for the drag in progress, by destination path, so
    /// validating a drop at every pointer move reads no file system.
    var dropVolumeCache: (sequence: Int, answers: [String: Bool]) = (-1, [:])
    /// Thumbnails requested just ahead of the visible rows, by file, with
    /// the item each was asked for.
    private var prefetches: [URL: (request: ThumbnailRequest, item: Int)] = [:]
    /// Set while the model's selection is pushed into the view, so the view
    /// doesn't report it straight back.
    private var isApplyingSelection = false
    /// Set while a click or arrow key's selection is passed to the model:
    /// the view already shows it and has scrolled as it needs to.
    private var isReportingSelection = false
    /// The lead the grid last showed, to scroll only when it moves.
    private var shownLead: URL?
    /// Grid width at the last layout, and whether the lead was on screen
    /// just before this one: see `viewDidLayout`.
    private var laidOutWidth: CGFloat = 0
    private var leadWasVisible = false
    private var subscriptions: Set<AnyCancellable> = []

    private(set) var thumbnailLayout = ThumbnailLayout(side: Preferences.shared.thumbnailSize)

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
        // Dragging to Finder copies the files. Inside minivu (onto a folder
        // cell or a sidebar row) the drop follows Finder's move/copy rules.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.onOpen = { [weak self] indexPath in self?.open(at: indexPath) }
        collectionView.onTypeSelect = { [weak self] prefix in
            guard let self, let url = self.model.firstEntry(withPrefix: prefix) else { return }
            self.model.select(url)
        }
        collectionView.onRateKey = { [weak self] stars in
            guard let self else { return }
            self.model.setRating(stars, for: self.model.selectedImageURLs)
        }
        collectionView.onToggleTagKey = { [weak self] in
            guard let self else { return }
            self.model.toggleTag(for: self.model.selectedImageURLs)
        }
        collectionView.onDragEnded = { [weak self] in self?.dropHighlight.isHidden = true }
        collectionView.onContextClick = { [weak self] indexPath in self?.contextClicked(indexPath) }
        collectionView.onSelectAll = { [weak self] in self?.model.selectAll() }

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

        dropHighlight.isHidden = true
        for view in [scrollView, statusBar, messageField, dropHighlight] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            // Below the toolbar, where the visible grid starts.
            dropHighlight.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 2),
            dropHighlight.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            dropHighlight.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            dropHighlight.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -2),
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

    /// A new width reflows the rows, and the scroll position, kept in
    /// points, would leave the selected photo somewhere off screen. So a
    /// lead that was visible before the window or a pane resized is scrolled
    /// back into view; one the user had scrolled away from stays away.
    override func viewWillLayout() {
        super.viewWillLayout()
        leadWasVisible = leadFrame().map { collectionView.visibleRect.intersects($0) } ?? false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard width != laidOutWidth else { return }
        laidOutWidth = width
        if leadWasVisible { scrollLeadIntoView() }
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: - Model changes

    func modelChanged(_ changes: BrowserModel.Changes) {
        if changes.contains(.folder) { renameEditor?.cancel() }
        if changes.contains(.entries) {
            cancelPrefetches()
            collectionView.reloadData()
            if changes.contains(.folder) { scrollToTop() }
            // The file being renamed went away (deleted or renamed in Finder).
            if let editor = renameEditor, model.entry(for: editor.url) == nil { editor.cancel() }
        } else if changes.contains(.marks) {
            refreshMarks(names: model.changedMarkNames)
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
        guard model.lead != nil else { return }
        // Layout first: after a reload the item has no frame to scroll to yet.
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = leadFrame() else { return }
        // A little room around it, rather than flush against the status bar.
        collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -flowLayout.minimumLineSpacing))
    }

    private func leadFrame() -> CGRect? {
        guard let lead = model.lead, let index = model.index(of: lead) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    /// Stars, badges and tag dots on the visible cells whose files changed
    /// (all visible cells for nil). Cells scrolled away pick theirs up when
    /// they are configured again.
    private func refreshMarks(names: Set<String>?) {
        for case let cell as ThumbnailCell in collectionView.visibleItems() {
            guard let entry = cell.entry, names?.contains(entry.name) ?? true else { continue }
            cell.thumbnailView.setMarks(entry.isDirectory ? .none : model.marks(for: entry.url),
                                        finderTags: model.finderTags(for: entry.url))
        }
    }

    private func updateMessage() {
        let message: String? = switch model.state {
        case .failed(let text): text
        case .loaded where model.entries.isEmpty: model.isFiltering ? "No Matches" : "No Images"
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
        renameEditor?.cancel()
        for case let cell as ThumbnailCell in collectionView.visibleItems() {
            if let entry = cell.entry {
                cell.configure(entry, layout: layout, backingScale: backingScale, marks: model.marks(for: entry.url),
                               finderTags: model.finderTags(for: entry.url))
            }
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
            let entry = model.entries[indexPath.item]
            cell.configure(entry, layout: thumbnailLayout, backingScale: backingScale, marks: model.marks(for: entry.url),
                           finderTags: model.finderTags(for: entry.url))
            cell.onRate = { [weak self] url, stars in self?.model.setRating(stars, for: [url]) }
            cell.thumbnailView.isRenaming = renameEditor?.url == entry.url
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let cell = item as? ThumbnailCell else { return }
        cell.loadIfNeeded()
        // The cell's own request has joined the prefetch's job, so the
        // prefetch lets go. Otherwise it would keep the decode alive after
        // the cell scrolled away and cancelled: every photo flown past
        // would still be decoded, long after the scrolling stopped.
        if let url = cell.entry?.url { prefetches.removeValue(forKey: url)?.request.cancel() }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? ThumbnailCell)?.cancelLoading()
    }

    // MARK: - Prefetching

    /// Starts thumbnails for rows about to scroll into view, so they arrive
    /// with the cells rather than after them.
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        dropDistantPrefetches()
        let pixelSize = Int((thumbnailLayout.side * backingScale).rounded())
        for indexPath in indexPaths where model.entries.indices.contains(indexPath.item) {
            let entry = model.entries[indexPath.item]
            guard !entry.isDirectory, prefetches[entry.url] == nil,
                  AppServices.thumbnails.cachedImage(for: entry, pixelSize: pixelSize) == nil else { continue }
            let url = entry.url
            let request = AppServices.thumbnails.request(entry, pixelSize: pixelSize) { [weak self] _ in
                self?.prefetches[url] = nil
            }
            prefetches[url] = (request, indexPath.item)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where model.entries.indices.contains(indexPath.item) {
            prefetches.removeValue(forKey: model.entries[indexPath.item].url)?.request.cancel()
        }
    }

    /// Cancels prefetches for rows the grid has scrolled well past without
    /// showing (a fling), which the collection view never cancels itself.
    private func dropDistantPrefetches() {
        guard !prefetches.isEmpty else { return }
        let visible = collectionView.indexPathsForVisibleItems().map(\.item)
        guard let first = visible.min(), let last = visible.max() else { return }
        for (url, prefetch) in prefetches where !Self.isNear(prefetch.item, visible: first...last) {
            prefetch.request.cancel()
            prefetches[url] = nil
        }
    }

    /// Within a screenful of the visible items, either way: where the
    /// collection view prefetches, and where the user may scroll back to.
    nonisolated static func isNear(_ item: Int, visible: ClosedRange<Int>) -> Bool {
        let span = visible.count
        return item >= visible.lowerBound - span && item <= visible.upperBound + span
    }

    private func cancelPrefetches() {
        prefetches.values.forEach { $0.request.cancel() }
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
        onNavigate?(url)
    }

    // MARK: - Drag out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        renameEditor == nil
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
    var onSelectAll: (() -> Void)?
    /// 0 to 5 pressed: rate the selection.
    var onRateKey: ((Int) -> Void)?
    /// ` pressed: tag or untag the selection.
    var onToggleTagKey: (() -> Void)?
    /// A drag left the grid or finished, over it or not.
    var onDragEnded: (() -> Void)?

    /// What a key means in the grid besides moving and type-to-select.
    nonisolated enum MarkKey: Equatable {
        case rate(Int), toggleTag
    }

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
        if modifiers.isEmpty, let characters = event.characters {
            if event.timestamp - lastKeyTime > Self.typingPause { typed = "" }
            if let mark = Self.markKey(characters, continuingName: !typed.isEmpty) {
                typed = ""
                guard !event.isARepeat else { return }
                switch mark {
                case .rate(let stars): onRateKey?(stars)
                case .toggleTag: onToggleTagKey?()
                }
                return
            }
            if Self.isTypeSelectText(characters, continuing: !typed.isEmpty) {
                lastKeyTime = event.timestamp
                typed += characters
                onTypeSelect?(typed)
                return
            }
        }
        // Any other key (an arrow, say) ends the name being typed, as in Finder.
        typed = ""
        super.keyDown(with: event)
    }

    /// 0–5 rate and ` (backquote) tags, as in the viewer (DESIGN.md 5).
    /// Letters always type-select, and a digit or backquote typed within the
    /// typing pause continues the name ("IMG_2"), so a name can still be
    /// typed whole; only a fresh key press is a mark. T tags in the viewer
    /// but types a name here, as it would in Finder; ⌘T works in both.
    nonisolated static func markKey(_ characters: String, continuingName: Bool) -> MarkKey? {
        guard !continuingName else { return nil }
        switch characters {
        case "0", "1", "2", "3", "4", "5": return .rate(Int(characters)!)
        case "`": return .toggleTag
        default: return nil
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragEnded?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragEnded?()
    }

    /// Printable text. Arrows and function keys arrive as characters in
    /// Unicode's private use area, and a space only continues a name.
    nonisolated static func isTypeSelectText(_ characters: String, continuing: Bool) -> Bool {
        guard let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1 else { return false }
        if scalar == " " { return continuing }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// ⌘A goes to the model, which keeps the lead where it is. The view's
    /// own select-all reports every item as newly added, and the lead would
    /// jump to whichever end of the folder is farthest away.
    override func selectAll(_ sender: Any?) {
        onSelectAll?()
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
        guard indexPath != nil else {
            // On the background: what Finder offers there.
            let menu = NSMenu()
            menu.addItem(withTitle: "New Folder", action: .newFolder, keyEquivalent: "")
            return menu
        }
        return Self.itemMenu()
    }

    /// The menu for items. Validated like the menu bar's items, so entries
    /// grey out for folders, RAW files and anything else they can't apply to.
    static func itemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: .openInViewer, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: .renameItem, keyEquivalent: "")
        let copyTo = menu.addItem(withTitle: "Copy To", action: nil, keyEquivalent: "")
        copyTo.submenu = RecentDestinationsMenu.make(title: "Copy To", action: .copyToFolder)
        let moveTo = menu.addItem(withTitle: "Move To", action: nil, keyEquivalent: "")
        moveTo.submenu = RecentDestinationsMenu.make(title: "Move To", action: .moveToFolder)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Tag", action: .toggleTag, keyEquivalent: "")
        let rating = menu.addItem(withTitle: "Rating", action: nil, keyEquivalent: "")
        rating.submenu = ratingMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rotate Left", action: .rotateLeft, keyEquivalent: "")
        menu.addItem(withTitle: "Rotate Right", action: .rotateRight, keyEquivalent: "")
        menu.addItem(withTitle: "Edit Comment…", action: .editComment, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: .revealInFinder, keyEquivalent: "")
        menu.addItem(withTitle: "Move to Trash", action: .moveToTrash, keyEquivalent: "")
        return menu
    }

    /// "No Rating" and one to five stars, tagged with the rating.
    static func ratingMenu() -> NSMenu {
        let menu = NSMenu(title: "Rating")
        for stars in 0...5 {
            let title = stars == 0 ? "No Rating" : String(repeating: "★", count: stars)
            menu.addItem(withTitle: title, action: .setRating, keyEquivalent: "").tag = stars
        }
        return menu
    }
}
