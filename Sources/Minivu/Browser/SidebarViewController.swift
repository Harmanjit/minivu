import AppKit
import MinivuCore

/// Path arithmetic for the sidebar tree, kept free of views to be testable.
nonisolated enum SidebarPaths {
    /// Path components, so /a/b and /a/b/ compare equal and /a/bc is not
    /// inside /a/b.
    static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    }

    /// The folders from `root` down to `target`, both included; nil when
    /// `target` isn't inside `root`.
    static func chain(from root: URL, to target: URL) -> [URL]? {
        let rootParts = components(root), targetParts = components(target)
        guard targetParts.count >= rootParts.count, Array(targetParts.prefix(rootParts.count)) == rootParts else {
            return nil
        }
        var url = root.standardizedFileURL
        var chain = [url]
        for part in targetParts.dropFirst(rootParts.count) {
            url = url.appendingPathComponent(part, isDirectory: true)
            chain.append(url)
        }
        return chain
    }

    /// Which root to reveal `target` under: the deepest one containing it, so
    /// a favourite inside Pictures wins over Pictures itself.
    static func bestRoot(for target: URL, among roots: [URL]) -> Int? {
        roots.indices
            .filter { chain(from: roots[$0], to: target) != nil }
            .max { components(roots[$0]).count < components(roots[$1]).count }
    }

    /// What identifies a folder among its siblings' URLs: the path, without
    /// the trailing slash a directory URL may or may not carry.
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// How a folder's subfolders changed between two listings, matched by URL:
/// the rows that went (indexes into the old list) and the rows that came
/// (indexes into the new list). The outline view removes and inserts just
/// those, so a refresh animates the change instead of reloading the level,
/// which would flicker and forget which rows below were expanded.
nonisolated struct SidebarDiff: Equatable {
    var removed = IndexSet()
    var inserted = IndexSet()

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }

    /// nil when rows present in both lists changed order, which removals
    /// and insertions alone can't express (the sort order changed); the
    /// level must be reloaded then. Duplicate URLs are treated likewise.
    static func between(_ old: [URL], _ new: [URL]) -> SidebarDiff? {
        let oldKeys = old.map(SidebarPaths.key), newKeys = new.map(SidebarPaths.key)
        let oldSet = Set(oldKeys), newSet = Set(newKeys)
        guard oldSet.count == oldKeys.count, newSet.count == newKeys.count else { return nil }
        var diff = SidebarDiff()
        for (i, key) in oldKeys.enumerated() where !newSet.contains(key) { diff.removed.insert(i) }
        for (i, key) in newKeys.enumerated() where !oldSet.contains(key) { diff.inserted.insert(i) }
        // Applying removals, then insertions, must turn old into new.
        let keptOld = oldKeys.filter(newSet.contains), keptNew = newKeys.filter(oldSet.contains)
        return keptOld == keptNew ? diff : nil
    }
}

/// One row of the sidebar. A class, because NSOutlineView identifies rows
/// by object identity.
final class SidebarNode {
    enum Kind { case header, favorite, folder }

    let kind: Kind
    let title: String
    let url: URL?
    let symbolName: String
    /// nil until listed.
    var children: [SidebarNode]?
    /// Whether to draw a disclosure triangle, from a cheap check that stops
    /// at the first subfolder. Unknown (false) until that check is back.
    var mayHaveChildren: Bool
    var isListing = false
    /// A refresh was asked for while a listing was out: list again when it lands.
    var needsRelist = false
    /// The user or a reveal asked to expand this row before its children
    /// were listed.
    var wantsExpansion = false

    init(kind: Kind, title: String, url: URL?, symbolName: String, children: [SidebarNode]? = nil,
         mayHaveChildren: Bool = false) {
        self.kind = kind
        self.title = title
        self.url = url
        self.symbolName = symbolName
        self.children = children
        self.mayHaveChildren = mayHaveChildren
    }

    var isPictures: Bool { kind == .favorite && symbolName == SidebarViewController.picturesSymbol }
}

/// The source-list sidebar: Favorites, each expandable into its folder tree.
///
/// Children are listed only when a row is expanded, off the main thread,
/// so a tree over a whole photo library costs nothing until it's opened.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let picturesSymbol = "photo.on.rectangle"

    /// A row was chosen by the user.
    var onNavigate: ((URL) -> Void)?

    /// Internal so tests can expand and collapse rows as a click would.
    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let header = SidebarNode(kind: .header, title: "Favorites", url: nil, symbolName: "", children: [])
    /// The folder the browser shows, to select its row.
    private var currentFolder: URL?
    /// Set while selecting a row in code, so it isn't taken for a click.
    private var isSelectingInCode = false
    /// Set while a row is expanded in code. `expandItem` asks the delegate
    /// too, and a row opened because its first listing just arrived (or to
    /// reveal a folder below it) must not be taken for the user opening it
    /// again: that would list every row twice.
    private var isExpandingInCode = false
    /// Listings started, for tests.
    private(set) var listingsStarted = 0
    /// Folders listed again because the folder being revealed wasn't among
    /// their children, so a folder that really is hidden isn't relisted
    /// over and over. Cleared for each new folder.
    private var relistedForReveal: Set<String> = []
    private var favoritesObserver: NSObjectProtocol?
    private let picturesFolder: URL
    private let favoriteFolders: () -> [URL]

    /// The folders are parameters so tests can show a tree of their own.
    init(picturesFolder: URL = BookmarkStore.picturesFolder,
         favoriteFolders: @escaping () -> [URL] = { BookmarkStore.shared.folders }) {
        self.picturesFolder = picturesFolder
        self.favoriteFolders = favoriteFolders
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.autosaveExpandedItems = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Folder")
        addButton.title = "Add Folder"
        addButton.imagePosition = .imageLeading
        addButton.imageHugsTitle = true
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        addButton.contentTintColor = .secondaryLabelColor
        addButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        addButton.target = nil
        addButton.action = .addFolderToSidebar
        addButton.toolTip = "Add a folder to the sidebar"

        let container = NSView()
        for view in [scrollView, addButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = container

        reloadFavorites()
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .minivuFavoritesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFavorites() }
        }
    }

    // MARK: - Favourites

    private func reloadFavorites() {
        let pictures = SidebarNode(kind: .favorite, title: "Pictures", url: picturesFolder,
                                   symbolName: Self.picturesSymbol)
        let others = favoriteFolders()
            .filter { !BrowserModel.samePath($0, picturesFolder) }
            .map { SidebarNode(kind: .favorite, title: FileManager.default.displayName(atPath: $0.path), url: $0,
                               symbolName: "folder") }
        let favorites = [pictures] + others
        header.children = favorites
        outlineView.reloadData()
        outlineView.expandItem(header)
        checkForSubfolders(favorites)
        reveal(currentFolder)
    }

    /// Finds out in the background which favourites can expand.
    private func checkForSubfolders(_ nodes: [SidebarNode]) {
        let urls = nodes.compactMap(\.url)
        Task { [weak self] in
            let answers = await Task.detached(priority: .utility) {
                urls.map { FolderListing.hasSubfolders($0) }
            }.value
            guard let self else { return }
            for (node, answer) in zip(nodes, answers) where node.children == nil && node.mayHaveChildren != answer {
                node.mayHaveChildren = answer
                self.reloadRow(node, children: false)
            }
        }
    }

    // MARK: - Children

    /// A subfolder as the background listing found it. Only what's new costs
    /// a lookup: names and disclosure checks are kept from the rows already
    /// shown.
    private struct Found: Sendable {
        let url: URL
        let title: String
        let hasSubfolders: Bool
    }

    /// Lists a row's subfolders off the main thread: the first time, or
    /// again with `refresh` (the row was expanded again, the browser went
    /// into it, or it changed on disk) to pick up folders made or deleted in
    /// Finder since. A refresh asked for while a listing is out runs once
    /// that one lands, so a burst of changes costs at most two listings.
    ///
    /// `recheckChildren` looks again at whether each subfolder already
    /// shown has subfolders of its own. The folder watcher only reports
    /// changes one level deep, so its refreshes skip that: in a folder of
    /// big subfolders it would be a directory scan each, per change.
    private func listChildren(of node: SidebarNode, refresh: Bool = false, recheckChildren: Bool = true) {
        guard let url = node.url, refresh || node.children == nil else { return }
        guard !node.isListing else {
            if refresh { node.needsRelist = true }
            return
        }
        node.isListing = true
        listingsStarted += 1
        // Rows already shown keep their title, and rows whose own children
        // are listed know whether they have any: neither needs the disk again.
        var known: [String: (title: String, hasSubfolders: Bool?)] = [:]
        for child in node.children ?? [] {
            guard let childURL = child.url else { continue }
            let listed = child.children.map { !$0.isEmpty }
            known[SidebarPaths.key(childURL)] = (child.title, recheckChildren ? listed : listed ?? child.mayHaveChildren)
        }
        Task { [weak self, known] in
            // One listing plus, per new or unexpanded subfolder, a check that
            // stops at its first subfolder: cheap even beside folders of
            // 10,000 photos. Display names are looked up here too: each is a
            // file system call, too many to make on the main thread.
            let found = await Task.detached(priority: .userInitiated) {
                FolderListing.subfolders(of: url).map { folder in
                    let old = known[SidebarPaths.key(folder)]
                    return Found(url: folder,
                                 title: old?.title ?? FileManager.default.displayName(atPath: folder.path),
                                 hasSubfolders: old?.hasSubfolders ?? FolderListing.hasSubfolders(folder))
                }
            }.value
            guard let self else { return }
            node.isListing = false
            self.apply(found, to: node)
            if node.needsRelist {
                node.needsRelist = false
                self.listChildren(of: node, refresh: true)
            }
        }
    }

    /// Shows a listing. The first one fills the row in; later ones keep the
    /// row objects of folders still there (with their expanded rows and the
    /// selection) and animate only what came and went.
    private func apply(_ found: [Found], to node: SidebarNode) {
        guard let old = node.children else {
            node.children = found.map(makeNode)
            node.mayHaveChildren = !found.isEmpty
            reloadRow(node, children: true)
            if node.wantsExpansion {
                node.wantsExpansion = false
                expandInCode(node)
            }
            reveal(currentFolder)
            return
        }

        var existing: [String: SidebarNode] = [:]
        for child in old { if let url = child.url { existing[SidebarPaths.key(url)] = child } }
        var triangleChanged: [SidebarNode] = []
        let children = found.map { folder -> SidebarNode in
            guard let child = existing[SidebarPaths.key(folder.url)] else { return makeNode(folder) }
            if child.children == nil, child.mayHaveChildren != folder.hasSubfolders {
                child.mayHaveChildren = folder.hasSubfolders
                triangleChanged.append(child)
            }
            return child
        }
        let diff = SidebarDiff.between(old.compactMap(\.url), children.compactMap(\.url))
        guard diff?.isEmpty != true || !triangleChanged.isEmpty else { return }

        let wasEmpty = old.isEmpty
        node.children = children
        node.mayHaveChildren = !children.isEmpty
        // A selected row that goes away deselects; that isn't a click.
        isSelectingInCode = true
        if let diff {
            // Removals first, against the old rows, then insertions at their
            // places in the new list. For a collapsed row these only update
            // the outline view's bookkeeping.
            outlineView.beginUpdates()
            if !diff.removed.isEmpty {
                outlineView.removeItems(at: diff.removed, inParent: node, withAnimation: .effectFade)
            }
            if !diff.inserted.isEmpty {
                outlineView.insertItems(at: diff.inserted, inParent: node, withAnimation: .effectFade)
            }
            outlineView.endUpdates()
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        // The disclosure triangle comes and goes with the first and last child.
        if wasEmpty != children.isEmpty { outlineView.reloadItem(node, reloadChildren: false) }
        for child in triangleChanged { outlineView.reloadItem(child, reloadChildren: false) }
        isSelectingInCode = false
        // Rows kept their selection through the update. Only a reveal that
        // was waiting for this listing looks again: revealing after every
        // refresh would reopen rows the user had collapsed.
        if let url = node.url, relistedForReveal.contains(SidebarPaths.key(url)) { reveal(currentFolder) }
    }

    private func makeNode(_ folder: Found) -> SidebarNode {
        SidebarNode(kind: .folder, title: folder.title, url: folder.url, symbolName: "folder",
                    mayHaveChildren: folder.hasSubfolders)
    }

    private func expandInCode(_ node: SidebarNode) {
        isExpandingInCode = true
        outlineView.expandItem(node)
        isExpandingInCode = false
    }

    private func reloadRow(_ node: SidebarNode, children: Bool) {
        isSelectingInCode = true
        outlineView.reloadItem(node, reloadChildren: children)
        isSelectingInCode = false
    }

    /// The browser's folder changed on disk. If its row has been listed, its
    /// subfolders are listed again; if not, only whether it has any is
    /// checked again, for the disclosure triangle.
    func folderChangedOnDisk(_ folder: URL) {
        guard isViewLoaded, let node = listedNode(for: folder) else { return }
        if node.children != nil {
            listChildren(of: node, refresh: true, recheckChildren: false)
            return
        }
        guard let url = node.url else { return }
        Task { [weak self] in
            let answer = await Task.detached(priority: .utility) { FolderListing.hasSubfolders(url) }.value
            guard let self, node.children == nil, node.mayHaveChildren != answer else { return }
            node.mayHaveChildren = answer
            self.reloadRow(node, children: false)
        }
    }

    /// The row for `folder` if the tree already has one, listing nothing.
    private func listedNode(for folder: URL) -> SidebarNode? {
        let favorites = header.children ?? []
        guard let rootIndex = SidebarPaths.bestRoot(for: folder, among: favorites.compactMap(\.url)),
              let root = favorites[rootIndex].url,
              let chain = SidebarPaths.chain(from: root, to: folder) else { return nil }
        var node = favorites[rootIndex]
        for url in chain.dropFirst() {
            let name = url.lastPathComponent
            guard let child = node.children?.first(where: { $0.url?.lastPathComponent == name }) else { return nil }
            node = child
        }
        return node
    }

    // MARK: - Reveal

    /// The folder of the selected row, for tests.
    var selectedFolder: URL? { (outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode)?.url }

    /// Every row's title top to bottom, indented two spaces a level, for tests.
    var rowOutline: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? SidebarNode, node.kind != .header else { return nil }
            return String(repeating: "  ", count: outlineView.level(forRow: row) - 1) + node.title
        }
    }

    /// Selects the row for `folder` when it lies under a favourite, expanding
    /// (and listing) the rows above it; clears the selection otherwise.
    /// Listing is asynchronous, so this runs again as each level arrives.
    ///
    /// Going to a new folder also lists its row's subfolders again, if they
    /// were listed before, since they may have changed while the browser was
    /// elsewhere; and a folder missing from its parent's listing (made in
    /// Finder since) has the parent listed again, once.
    func reveal(_ folder: URL?) {
        let isNewFolder = folder.map { new in currentFolder.map { !BrowserModel.samePath($0, new) } ?? true } ?? false
        currentFolder = folder
        if isNewFolder { relistedForReveal = [] }
        guard isViewLoaded else { return }
        let favorites = header.children ?? []
        guard let folder,
              let rootIndex = SidebarPaths.bestRoot(for: folder, among: favorites.compactMap(\.url)),
              let chain = SidebarPaths.chain(from: favorites[rootIndex].url!, to: folder) else {
            select(nil)
            return
        }
        var node = favorites[rootIndex]
        for url in chain.dropFirst() {
            guard let children = node.children else {
                node.wantsExpansion = true
                listChildren(of: node)
                select(nil)
                return
            }
            let name = url.lastPathComponent
            guard let child = children.first(where: { $0.url?.lastPathComponent == name }) else {
                // Hidden, or created since the parent was listed: list the
                // parent again, and look again when that lands.
                if let parent = node.url, relistedForReveal.insert(SidebarPaths.key(parent)).inserted {
                    listChildren(of: node, refresh: true)
                }
                select(nil)
                return
            }
            isSelectingInCode = true
            expandInCode(node)
            isSelectingInCode = false
            node = child
        }
        select(node)
        if isNewFolder, node.children != nil { listChildren(of: node, refresh: true) }
    }

    private func select(_ node: SidebarNode?) {
        let row = node.map { outlineView.row(forItem: $0) } ?? -1
        let current = outlineView.selectedRow
        guard row != current else { return }
        isSelectingInCode = true
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
        isSelectingInCode = false
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return 1 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return header }
        return node.children?[index] ?? header
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if node.kind == .header { return true }
        return node.children.map { !$0.isEmpty } ?? node.mayHaveChildren
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    /// Expanding a row lists its subfolders: the first time before it opens,
    /// and every later time again, while it shows the last listing, so
    /// folders made or deleted in Finder meanwhile appear and go.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if node.children == nil {
            node.wantsExpansion = true
            listChildren(of: node)
        } else if !isExpandingInCode, node.kind != .header, !outlineView.isItemExpanded(node) {
            listChildren(of: node, refresh: true)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.kind == .header {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, image: false)
            cell.textField?.stringValue = node.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("DataCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, image: true)
        cell.textField?.stringValue = node.title
        cell.imageView?.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
        cell.toolTip = node.url?.path
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, image: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if image {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            imageView.contentTintColor = .controlAccentColor
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            ])
        } else {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .tertiaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingInCode, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode,
              let url = node.url else { return }
        if let currentFolder, BrowserModel.samePath(currentFolder, url) { return }
        onNavigate?(url)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode, let url = node.url else { return }
        let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealClicked(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = url
        if node.kind == .favorite, !node.isPictures {
            let remove = menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeClicked(_:)),
                                      keyEquivalent: "")
            remove.target = self
            remove.representedObject = url
        }
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        BookmarkStore.shared.remove(url)
        NotificationCenter.default.post(name: .minivuFavoritesChanged, object: nil)
    }
}
