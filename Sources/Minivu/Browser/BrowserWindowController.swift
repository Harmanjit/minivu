import AppKit
import Combine
import MinivuCore

/// The browser window: folder sidebar | thumbnail grid | preview pane, in
/// FastStone's arrangement with the current macOS look.
///
/// The controller is the glue. It owns the `BrowserModel`, forwards each
/// model change to the views that show it, and handles the menu and
/// toolbar commands (`MinivuActions`) for the whole window, so they work
/// whether the grid, the sidebar or the preview has the focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserModel

    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    let grid: GridViewController
    let preview = PreviewPaneController()
    private let toolbarController = BrowserToolbar()
    private let sidebarItem: NSSplitViewItem
    private let gridItem: NSSplitViewItem
    let previewItem: NSSplitViewItem
    private var subscriptions: Set<AnyCancellable> = []
    /// A file opened from Finder, shown in the viewer once its folder is listed.
    private var pendingViewerFile: URL?
    private var isAnimatingPreview = false
    /// A folder just made, whose name is edited once it's listed.
    var pendingRename: URL?
    /// A copy or move is running (one at a time: its sheets would collide).
    var isTransferring = false
    /// The transfer in flight, for tests to await.
    var transferWork: Task<Void, Never>?
    /// Answers name clashes instead of an alert; for tests.
    var transferConflictResolver: FileTransfer.ConflictResolver?
    /// Where Replace and the Undo of a copy put items; tests use a folder.
    var transferTrash: FileTransfer.Trasher = TransferChecks.trash

    /// - Parameter catalog: where ratings and tags live; tests pass their own.
    init(catalog: Catalog = .shared) {
        model = BrowserModel(sortOrder: Preferences.shared.sortOrder,
                             showHiddenFiles: Preferences.shared.showHiddenFiles, catalog: catalog)
        grid = GridViewController(model: model)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        gridItem = NSSplitViewItem(viewController: grid)
        // An inspector item, so the toolbar can split above its divider
        // (`.inspectorTrackingSeparator`) as it does above the sidebar's.
        previewItem = NSSplitViewItem(inspectorWithViewController: preview)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 900, height: 560)
        window.title = "minivu"
        super.init(window: window)

        buildSplitView()
        window.contentViewController = splitController
        // Setting the content view controller sizes the window to it, so the
        // default frame, then any saved one, are applied afterwards.
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.center()
        window.setFrameAutosaveName("BrowserWindow")
        window.toolbar = toolbarController.makeToolbar()
        window.delegate = self
        window.initialFirstResponder = grid.collectionView

        connect()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildSplitView() {
        sidebar.view.frame.size.width = 220
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true

        gridItem.minimumThickness = 360

        preview.view.frame.size.width = 320
        previewItem.minimumThickness = 240
        previewItem.maximumThickness = 640
        previewItem.canCollapse = true

        // Resizing the window grows the grid, not the side panes.
        sidebarItem.holdingPriority = .defaultLow + 10
        previewItem.holdingPriority = .defaultLow + 10
        gridItem.holdingPriority = .defaultLow

        splitController.splitView.dividerStyle = .thin
        // Remembers the panes' widths and whether each is collapsed.
        splitController.splitView.autosaveName = "BrowserSplit"
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(gridItem)
        splitController.addSplitViewItem(previewItem)
    }

    private func connect() {
        // However the preview pane gets collapsed (the toolbar, the menu, a
        // drag, or the split view restoring its saved state), a hidden
        // preview decodes nothing. While `togglePreviewPane` animates, it
        // decides instead, once the pane has its final width.
        NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification,
                                             object: splitController.splitView)
            .sink { [weak self] _ in
                guard let self, !self.isAnimatingPreview else { return }
                self.preview.isVisible = !self.previewItem.isCollapsed
            }
            .store(in: &subscriptions)
        model.onChange = { [weak self] changes in self?.modelChanged(changes) }
        model.onFolderChangedOnDisk = { [weak self] folder in self?.sidebar.folderChangedOnDisk(folder) }
        sidebar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        grid.onOpen = { [weak self] entry in self?.open(entry) }
        grid.onNavigate = { [weak self] url in self?.navigate(to: url) }
        preview.onOpenViewer = { [weak self] in self?.openInViewer(nil) }
        preview.onStep = { [weak self] offset in self?.stepSelection(by: offset) }
        preview.onRate = { [weak self] stars in
            guard let self, let lead = self.model.leadEntry, !lead.isDirectory else { return }
            self.model.setRating(stars, for: [lead.url])
        }
        preview.onToggleTag = { [weak self] in
            guard let self, let lead = self.model.leadEntry, !lead.isDirectory else { return }
            self.model.toggleTag(for: [lead.url])
        }
        grid.onDropFiles = { [weak self] files, destination, move in self?.transfer(files, to: destination, move: move) }
        grid.onRename = { [weak self] url, name in self?.commitRename(url, to: name) }
        sidebar.onDropFiles = { [weak self] files, destination, move in
            self?.transfer(files, to: destination, move: move)
        }
        toolbarController.onSearch = { [weak self] text in self?.model.filter = text }
        toolbarController.onFinderTagFilter = { [weak self] name in self?.filterByFinderTag(name) }

        // The model follows the preferences, whichever window or menu set them.
        // (`@Published` passes the new value before it is stored.)
        Preferences.shared.$sortOrder
            .dropFirst()
            .sink { [weak self] order in self?.model.sortOrder = order }
            .store(in: &subscriptions)
        Preferences.shared.$showHiddenFiles
            .dropFirst()
            .sink { [weak self] show in self?.model.showHiddenFiles = show }
            .store(in: &subscriptions)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // The split view restores a collapsed preview without posting a
        // resize, so without this the first photo would still be decoded
        // for a pane nobody can see.
        preview.isVisible = !previewItem.isCollapsed
        window?.makeFirstResponder(grid.collectionView)
    }

    // MARK: - Opening

    func open(folder: URL) {
        navigate(to: folder)
    }

    /// Shows the file's folder with the file selected, then the viewer on it.
    func open(file: URL) {
        model.filter = ""
        toolbarController.clearSearch()
        pendingViewerFile = file
        model.navigate(to: file.deletingLastPathComponent(), selecting: file)
        openPendingViewerIfReady()
    }

    private func navigate(to folder: URL) {
        pendingViewerFile = nil
        model.navigate(to: folder)
    }

    /// An image opens in the viewer; a folder opens in the browser.
    private func open(_ entry: FolderEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            showViewer(on: entry.url)
        }
    }

    /// The wheel over the preview moves the grid's selection to the next or
    /// previous image, as it moves the viewer; the grid follows the new lead
    /// into view.
    private func stepSelection(by offset: Int) {
        guard let url = model.image(offset, from: model.lead, wrap: Preferences.shared.wrapAround) else { return }
        model.select(url)
    }

    private func showViewer(on url: URL) {
        guard let (images, index) = model.imagesForViewer(startingAt: url) else { return }
        let folder = model.folder
        ViewerWindowController.show(images: images, index: index,
                                    fullScreen: Preferences.shared.openViewerFullScreen) { [weak self] entry in
            guard let self else { return }
            // The model finds entries by name, so a photo from a folder the
            // browser has since left would select its namesake here.
            if let entry, self.model.folder == folder { self.model.select(entry.url) }
            self.grid.scrollLeadIntoView()
            self.window?.makeFirstResponder(self.grid.collectionView)
        }
    }

    /// Opens the viewer for `open(file:)` once the listing has the file.
    private func openPendingViewerIfReady() {
        guard let file = pendingViewerFile, model.state != .loading else { return }
        pendingViewerFile = nil
        guard model.state == .loaded, let lead = model.lead, lead.lastPathComponent == file.lastPathComponent
        else { return }
        showViewer(on: lead)
    }

    // MARK: - Model changes

    private func modelChanged(_ changes: BrowserModel.Changes) {
        if changes.contains(.folder), let folder = model.folder {
            window?.title = FileManager.default.displayName(atPath: folder.path)
            UserDefaults.standard.set(folder.path, forKey: AppDelegate.lastFolderKey)
            sidebar.reveal(folder)
            pendingRename = nil
        }
        grid.modelChanged(changes)
        if changes.contains(.entries) || changes.contains(.state) {
            window?.subtitle = model.subtitle
        }
        if changes.contains(.entries) || changes.contains(.selection) {
            preview.show(previewContent())
        }
        if changes.contains(.entries) || changes.contains(.selection) || changes.contains(.marks) {
            preview.showMarks(model.leadEntry.flatMap { $0.isDirectory || model.selection.count != 1 ? nil : $0 }
                .map { model.marks(for: $0.url) })
        }
        if changes.contains(.entries), let url = pendingRename, model.entry(for: url) != nil {
            pendingRename = nil
            grid.beginRename(url)
        }
        toolbarController.updateFilter(isActive: model.marksFilter.isActive, finderTags: model.finderTagsInFolder,
                                       selectedTag: model.marksFilter.finderTag)
        // History changes arrive after a listing, with no event to trigger
        // the toolbar's own validation.
        window?.toolbar?.validateVisibleItems()
        toolbarController.setNavigation(canGoBack: model.canGoBack, canGoForward: model.canGoForward)
        openPendingViewerIfReady()
    }

    /// Folders whose contents changed through minivu: the sidebar lists
    /// them again if it has.
    func sidebarFolderChanged(_ folders: [URL]) {
        folders.forEach(sidebar.folderChangedOnDisk)
    }

    private func previewContent() -> PreviewPaneController.Content {
        let selected = model.selection.count
        if selected > 1 { return .multiple(count: selected, bytes: model.selectedBytes) }
        guard let lead = model.leadEntry else { return .none }
        if lead.isDirectory { return .folder(lead) }
        return .image(lead, neighbours: model.neighbouringImages(of: lead.url))
    }

}

// MARK: - MinivuActions

/// In an extension so the compiler's check for near-miss action names
/// doesn't take `open(folder:)` for a misspelt `openFolder(_:)`.
extension BrowserWindowController: MinivuActions, NSMenuItemValidation, NSToolbarItemValidation {
    @objc func openInViewer(_ sender: Any?) {
        guard let entry = model.leadEntry else { return }
        open(entry)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = model.selectedEntries.map(\.url)
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let folder = model.folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    /// Moves the selection to the Trash: reversible from Finder, so there is
    /// no confirmation, as in Finder and Photos.
    @objc func moveToTrash(_ sender: Any?) {
        let urls = model.selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        let next = model.selectionAfterRemoving(Set(urls))
        let folder = model.folder
        Task { [weak self] in
            do {
                let moved = try await NSWorkspace.shared.recycle(urls)
                // Entries are matched by name: if the user moved to another
                // folder meanwhile, its namesakes must stay.
                guard let self, self.model.folder == folder else { return }
                self.didTrash(Set(moved.keys), thenSelect: next)
            } catch {
                // Some files may have gone anyway: list again to show what's
                // left, and say what went wrong.
                guard let self else { return }
                self.model.reload()
                if let window = self.window {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func didTrash(_ urls: Set<URL>, thenSelect next: URL?) {
        model.removeEntries(urls)
        if let next, model.entry(for: next) != nil { model.select(next) }
    }

    /// Compares the 2 to 4 selected images; ← and → in the window step
    /// through the rest of the folder in the browser's order.
    @objc func compareSelected(_ sender: Any?) {
        let selected = model.selectedEntries.filter { !$0.isDirectory }
        guard CompareModel.paneRange.contains(selected.count) else { return }
        CompareWindowController.show(entries: selected, allImages: model.entries.filter { !$0.isDirectory })
    }

    /// 2 to 4 images selected. Stops counting at 5: validation runs often,
    /// and a ⌘A selection of a huge folder shouldn't be sorted for it.
    private var canCompareSelection: Bool {
        var images = 0
        for url in model.selection where model.entry(for: url)?.isDirectory == false {
            images += 1
            if images > CompareModel.paneRange.upperBound { return false }
        }
        return CompareModel.paneRange.contains(images)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        pendingViewerFile = nil
        model.goToEnclosingFolder()
    }

    @objc func goBack(_ sender: Any?) {
        pendingViewerFile = nil
        model.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        pendingViewerFile = nil
        model.goForward()
    }

    /// Each key keeps the direction it was last used in, as Finder's columns
    /// do, and starts in its natural one: highest rating first, everything
    /// else A to Z, oldest or smallest first.
    @objc func sortBy(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, SortKey.allCases.indices.contains(tag) else { return }
        Preferences.shared.sortOrder = SortDirectionMemory.switching(from: Preferences.shared.sortOrder,
                                                                     to: SortKey.allCases[tag])
    }

    @objc func toggleSortDirection(_ sender: Any?) {
        switch (sender as? NSMenuItem)?.tag {
        case SortDirectionTag.ascending: Preferences.shared.sortOrder.ascending = true
        case SortDirectionTag.descending: Preferences.shared.sortOrder.ascending = false
        default: Preferences.shared.sortOrder.ascending.toggle()
        }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Preferences.shared.showHiddenFiles.toggle()
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        let collapse = !previewItem.isCollapsed
        if collapse { preview.isVisible = false }
        isAnimatingPreview = true
        NSAnimationContext.runAnimationGroup { _ in
            previewItem.animator().isCollapsed = collapse
        } completionHandler: { [weak self] in
            // Only once the pane has its width: a preview loaded mid-animation
            // would be decoded for a sliver and then again at full size.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAnimatingPreview = false
                self.preview.isVisible = !self.previewItem.isCollapsed
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        Preferences.shared.thumbnailSize = ThumbnailLayout.stepped(Preferences.shared.thumbnailSize, larger: true)
    }

    @objc func zoomOut(_ sender: Any?) {
        Preferences.shared.thumbnailSize = ThumbnailLayout.stepped(Preferences.shared.thumbnailSize, larger: false)
    }

    /// Reached when the grid isn't the first responder (the sidebar is);
    /// the grid handles ⌘A itself when it has the focus.
    @objc override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        let order = Preferences.shared.sortOrder
        switch action {
        case .sortBy:
            let keys = SortKey.allCases
            menuItem.state = keys.indices.contains(menuItem.tag) && keys[menuItem.tag] == order.key ? .on : .off
        case .toggleSortDirection:
            let ascending = menuItem.tag == SortDirectionTag.ascending
            menuItem.state = menuItem.tag != 0 && ascending == order.ascending ? .on : .off
        case .toggleHiddenFiles:
            menuItem.state = Preferences.shared.showHiddenFiles ? .on : .off
        case .togglePreviewPane:
            menuItem.title = previewItem.isCollapsed ? "Show Preview Pane" : "Hide Preview Pane"
        default:
            updateManagementState(menuItem)
        }
        return canPerform(action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return canPerform(action)
    }

    private func canPerform(_ action: Selector) -> Bool {
        switch action {
        case .openInViewer: model.leadEntry != nil
        case .revealInFinder: model.folder != nil
        case .moveToTrash: !model.selection.isEmpty && !isTypingText
        case .compareSelected: canCompareSelection
        case .goToEnclosingFolder: model.canGoToEnclosingFolder
        case .goBack: model.canGoBack
        case .goForward: model.canGoForward
        case .zoomIn: Preferences.shared.thumbnailSize < ThumbnailLayout.sizeRange.upperBound
        case .zoomOut: Preferences.shared.thumbnailSize > ThumbnailLayout.sizeRange.lowerBound
        case #selector(selectAll(_:)): !model.entries.isEmpty
        default: canPerformManagement(action) ?? canPerformEditing(action) ?? canPerformTools(action) ?? true
        }
    }

    /// ⌘⌫ in a text field (the search field) deletes to the start of the
    /// line. AppKit offers the key to the menu bar first, so Move to Trash
    /// would take it and trash the selected photos. A disabled item lets
    /// the key through; the context menu and toolbar still work.
    private var isTypingText: Bool {
        window?.firstResponder is NSText && NSApp.currentEvent?.type == .keyDown
    }

    // MARK: - NSWindowDelegate

    /// Back from Finder (or another window): Finder tags set meanwhile
    /// changed only extended attributes, which the folder watcher misses.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshFinderTags(of: grid.visibleURLs)
    }

    func windowWillClose(_ notification: Notification) {
        preview.isVisible = false
    }
}
