import Foundation
import MinivuCore

/// One folder, listed and sorted, ready to filter. A plain value made off
/// the main thread, so neither listing nor sorting ever costs the UI a frame.
nonisolated struct FolderSnapshot: Sendable {
    let folder: URL
    /// Subfolders first, then images, each group in the sort order.
    private(set) var entries: [FolderEntry]
    /// Each entry's name folded for searching, in the same order. Folding
    /// once here keeps typing in the search field cheap on a huge folder.
    private(set) var searchKeys: [String]

    init(contents: FolderContents, order: FileSortOrder) {
        folder = contents.folder
        entries = FolderListing.sorted(contents.subfolders, by: order) + FolderListing.sorted(contents.images, by: order)
        searchKeys = entries.map { BrowserModel.searchKey($0.name) }
    }

    /// The same entries in another order, without reading the disk again.
    func resorted(by order: FileSortOrder) -> FolderSnapshot {
        FolderSnapshot(contents: FolderContents(folder: folder, subfolders: entries.filter(\.isDirectory),
                                                images: entries.filter { !$0.isDirectory }), order: order)
    }

    mutating func remove(_ urls: Set<URL>) {
        let keep = entries.indices.filter { !urls.contains(entries[$0].url) }
        entries = keep.map { entries[$0] }
        searchKeys = keep.map { searchKeys[$0] }
    }
}

/// Everything the browser window shows, with no views: the current folder,
/// its entries after sorting and filtering, the selection and the history.
///
/// Kept apart from AppKit so it can be tested directly, and so the sidebar,
/// grid, preview and status bar all read one source of truth. Views call the
/// methods below; the model reports what changed through `onChange` and the
/// window controller passes that on.
///
/// Folders are listed off the main thread. Every load or re-sort gets a
/// generation number, and a result whose generation is no longer current is
/// dropped: the user moved on while it was being read.
final class BrowserModel {
    /// What changed, so views update only what they need to.
    struct Changes: OptionSet {
        let rawValue: Int
        static let folder = Changes(rawValue: 1 << 0)
        static let entries = Changes(rawValue: 1 << 1)
        static let selection = Changes(rawValue: 1 << 2)
        static let state = Changes(rawValue: 1 << 3)
        static let history = Changes(rawValue: 1 << 4)
        static let all: Changes = [.folder, .entries, .selection, .state, .history]
    }

    enum State: Equatable {
        /// No folder yet.
        case empty
        case loading
        case loaded
        /// Shown in place of the grid.
        case failed(String)
    }

    /// A place in the history: the folder and what was selected in it, so
    /// Back returns to the same photo.
    struct Location: Equatable {
        var folder: URL
        var selection: URL?
    }

    typealias Lister = @Sendable (_ folder: URL, _ includeHidden: Bool) throws -> FolderContents

    private(set) var folder: URL?
    private(set) var state: State = .empty
    /// Visible entries: sorted, then filtered by `filter`.
    private(set) var entries: [FolderEntry] = [] {
        didSet { cachedSelectedBytes = nil }
    }
    private(set) var selection: Set<URL> = [] {
        didSet { cachedSelectedBytes = nil }
    }
    /// The item the preview pane shows and the viewer opens: the one most
    /// recently clicked or moved to.
    private(set) var lead: URL?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private(set) var imageCount = 0
    private(set) var folderCount = 0

    var sortOrder: FileSortOrder {
        didSet { if sortOrder != oldValue { resort() } }
    }
    var showHiddenFiles: Bool {
        didSet { if showHiddenFiles != oldValue { reload() } }
    }
    /// Search text: a case- and accent-insensitive substring of the name.
    var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            applyFilter()
            onChange?([.entries, .selection])
        }
    }

    var onChange: ((Changes) -> Void)?

    private let lister: Lister
    private let invalidate: @MainActor (URL) -> Void
    private let watchesFolder: Bool
    private var snapshot: FolderSnapshot?
    private var visibleKeys: [String] = []
    /// Entry index by file name. Every entry is a child of one folder, so
    /// the name identifies it, and it survives the path spellings the file
    /// system hands back (a listing of /var/x reports /private/var/x).
    private var indexByName: [String: Int] = [:]
    private var generation = 0
    /// A disk listing is in flight. A re-sort started now would work from
    /// the older snapshot and, being newer, make the listing's result be
    /// dropped: new files and the cache invalidations with them.
    private var isListing = false
    /// Selected once the listing in progress arrives.
    private var pendingSelection: URL?
    private var watcher: FolderWatcher?
    /// The load or re-sort in flight, for tests to await.
    private(set) var work: Task<Void, Never>?

    /// - Parameters:
    ///   - lister: reads a folder; tests pass a slow or failing one.
    ///   - invalidate: forgets cached thumbnails and textures of a file that
    ///     changed or disappeared.
    ///   - watchesFolder: reload when the folder changes on disk.
    init(sortOrder: FileSortOrder = FileSortOrder(), showHiddenFiles: Bool = false,
         lister: @escaping Lister = { try FolderListing.contents(of: $0, includeHidden: $1) },
         invalidate: @escaping @MainActor (URL) -> Void = BrowserModel.invalidateCaches,
         watchesFolder: Bool = true) {
        self.sortOrder = sortOrder
        self.showHiddenFiles = showHiddenFiles
        self.lister = lister
        self.invalidate = invalidate
        self.watchesFolder = watchesFolder
    }

    static func invalidateCaches(_ url: URL) {
        AppServices.thumbnails.invalidate(url)
        AppServices.images.invalidate(url)
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The parent folder, or nil at the root of the disk.
    var enclosingFolder: URL? {
        guard let folder, folder.path != "/" else { return nil }
        return folder.deletingLastPathComponent()
    }

    /// Shows `target`, selecting `item` once it's listed. Going to the folder
    /// already shown only changes the selection.
    func navigate(to target: URL, selecting item: URL? = nil) {
        if let folder, Self.samePath(folder, target) {
            if let item { select(item) }
            return
        }
        if let folder {
            backStack.append(Location(folder: folder, selection: lead))
            forwardStack.removeAll()
        }
        show(target, selecting: item)
    }

    func goBack() {
        guard let folder, let previous = backStack.popLast() else { return }
        forwardStack.append(Location(folder: folder, selection: lead))
        show(previous.folder, selecting: previous.selection)
    }

    func goForward() {
        guard let folder, let next = forwardStack.popLast() else { return }
        backStack.append(Location(folder: folder, selection: lead))
        show(next.folder, selecting: next.selection)
    }

    /// Up one level, with the folder we came from selected, as Finder does.
    func goToEnclosingFolder() {
        guard let folder, let parent = enclosingFolder else { return }
        navigate(to: parent, selecting: folder)
    }

    private func show(_ target: URL, selecting item: URL?) {
        folder = target.standardizedFileURL
        snapshot = nil
        entries = []
        visibleKeys = []
        indexByName = [:]
        imageCount = 0
        folderCount = 0
        selection = []
        lead = nil
        pendingSelection = item
        state = .loading
        startWatching()
        load()
        onChange?(.all)
    }

    /// Lists the folder again, keeping what is shown until the new listing
    /// arrives (a watcher reload must not flash an empty grid).
    func reload() {
        guard folder != nil else { return }
        load()
    }

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard watchesFolder, let folder else { return }
        // The callback arrives on the watcher's queue. Hop to the main actor
        // asynchronously: `stop()` waits for a running callback, so waiting
        // for the main thread here could deadlock.
        watcher = FolderWatcher(folder: folder) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: - Loading

    private func load() {
        guard let folder else { return }
        generation += 1
        isListing = true
        let generation = self.generation
        let lister = self.lister, hidden = showHiddenFiles, order = sortOrder
        let previous = snapshot.flatMap { Self.samePath($0.folder, folder) ? $0.entries : nil } ?? []
        work = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (FolderSnapshot, [URL]) in
                    let snapshot = FolderSnapshot(contents: try Self.list(folder, hidden, with: lister), order: order)
                    return (snapshot, Self.changedFiles(old: previous, new: snapshot.entries))
                }
            }.value
            self?.finish(result, generation: generation)
        }
    }

    /// Lists with `lister`. A folder that no longer exists fails the volume
    /// check first (there is no volume to ask about); report it as missing,
    /// not as an external drive.
    nonisolated private static func list(_ folder: URL, _ hidden: Bool, with lister: Lister) throws -> FolderContents {
        do {
            return try lister(folder, hidden)
        } catch FolderListingError.notAllowed(let url) where !FileManager.default.fileExists(atPath: url.path) {
            throw FolderListingError.unreadable(url, "The folder doesn’t exist.")
        }
    }

    /// A new order for the same listing. If a listing is still being read it
    /// simply starts again with the new order.
    private func resort() {
        guard let snapshot, state == .loaded, !isListing else {
            reload()
            return
        }
        generation += 1
        let generation = self.generation, order = sortOrder
        work = Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) { snapshot.resorted(by: order) }.value
            self?.finish(.success((sorted, [])), generation: generation)
        }
    }

    private func finish(_ result: Result<(FolderSnapshot, [URL]), Error>, generation: Int) {
        guard generation == self.generation else { return }
        isListing = false
        switch result {
        case .success(let (listing, changed)):
            changed.forEach(invalidate)
            snapshot = listing
            state = .loaded
        case .failure(let error):
            snapshot?.entries.filter { !$0.isDirectory }.forEach { invalidate($0.url) }
            snapshot = nil
            state = .failed(Self.message(for: error))
        }
        applyFilter()
        if let item = pendingSelection, state == .loaded {
            pendingSelection = nil
            select(item, notify: false)
        }
        onChange?([.entries, .selection, .state])
    }

    /// The images that changed size or date, or vanished, between two
    /// listings: their cached thumbnails and textures show the old file.
    nonisolated static func changedFiles(old: [FolderEntry], new: [FolderEntry]) -> [URL] {
        guard !old.isEmpty else { return [] }
        var current: [String: FolderEntry] = [:]
        for entry in new where !entry.isDirectory { current[entry.url.path] = entry }
        return old.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            guard let now = current[entry.url.path] else { return entry.url }
            return now.modified != entry.modified || now.fileSize != entry.fileSize ? entry.url : nil
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case FolderListingError.notAllowed:
            "minivu only works with folders on this Mac’s internal storage."
        case FolderListingError.unreadable(let url, _):
            "“\(url.lastPathComponent)” can’t be opened. It may have been moved or deleted, "
                + "or minivu may not have permission to read it."
        default:
            error.localizedDescription
        }
    }

    // MARK: - Filtering

    nonisolated static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Rebuilds the visible entries and drops selected items the filter hides.
    private func applyFilter() {
        guard let snapshot else {
            entries = []
            visibleKeys = []
            indexByName = [:]
            imageCount = 0
            folderCount = 0
            pruneSelection()
            return
        }
        let query = Self.searchKey(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        if query.isEmpty {
            entries = snapshot.entries
            visibleKeys = snapshot.searchKeys
        } else {
            let keep = snapshot.searchKeys.indices.filter { snapshot.searchKeys[$0].contains(query) }
            entries = keep.map { snapshot.entries[$0] }
            visibleKeys = keep.map { snapshot.searchKeys[$0] }
        }
        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        // `name` is already a String; asking each URL for its last component
        // would cost a string conversion per file on every keystroke.
        for (i, entry) in entries.enumerated() { index[entry.name] = i }
        indexByName = index
        folderCount = entries.prefix { $0.isDirectory }.count
        imageCount = entries.count - folderCount
        pruneSelection()
    }

    private func pruneSelection() {
        selection = selection.filter { index(of: $0) != nil }
        if let lead, !selection.contains(lead) {
            self.lead = selection.min { (index(of: $0) ?? 0) < (index(of: $1) ?? 0) }
        }
    }

    // MARK: - Selection

    /// Where a child of the current folder is in `entries`.
    func index(of url: URL) -> Int? { indexByName[url.lastPathComponent] }

    func entry(for url: URL) -> FolderEntry? { index(of: url).map { entries[$0] } }

    var leadEntry: FolderEntry? { lead.flatMap(entry(for:)) }

    var selectedEntries: [FolderEntry] {
        selection.compactMap(index(of:)).sorted().map { entries[$0] }
    }

    /// Total size of the selected files (folders count as nothing). Kept
    /// until the selection changes: the status bar and the preview both ask,
    /// and after ⌘A on a huge folder the sum is not free.
    var selectedBytes: Int64 {
        if let cachedSelectedBytes { return cachedSelectedBytes }
        let total = selection.reduce(Int64(0)) { total, url in
            guard let entry = entry(for: url), !entry.isDirectory else { return total }
            return total + entry.fileSize
        }
        cachedSelectedBytes = total
        return total
    }
    private var cachedSelectedBytes: Int64?

    /// The selection as the grid reports it. URLs not visible are ignored.
    func setSelection(_ urls: Set<URL>, lead newLead: URL?) {
        let valid = Set(urls.compactMap { entry(for: $0)?.url })
        let resolvedLead = newLead.flatMap { entry(for: $0)?.url }
        guard valid != selection || resolvedLead != lead else { return }
        selection = valid
        lead = resolvedLead.flatMap { valid.contains($0) ? $0 : nil }
        pruneSelection()
        if lead == nil { lead = selection.min { (index(of: $0) ?? 0) < (index(of: $1) ?? 0) } }
        onChange?(.selection)
    }

    /// Selects one item. While the folder is still loading it's remembered
    /// and selected when the listing arrives.
    func select(_ url: URL) {
        select(url, notify: true)
    }

    private func select(_ url: URL, notify: Bool) {
        if state == .loading {
            pendingSelection = url
            return
        }
        guard let entry = entry(for: url) else { return }
        selection = [entry.url]
        lead = entry.url
        if notify { onChange?(.selection) }
    }

    func selectAll() {
        setSelection(Set(entries.map(\.url)), lead: lead ?? entries.first?.url)
    }

    /// What to select after `removed` go away: the next item after them,
    /// else the one before, so ⌘⌫ repeatedly works through a folder.
    func selectionAfterRemoving(_ removed: Set<URL>) -> URL? {
        let indices = removed.compactMap(index(of:)).sorted()
        guard let first = indices.first, let last = indices.last else { return lead }
        let removedIndices = Set(indices)
        let isKept = { (i: Int) in !removedIndices.contains(i) }
        let kept = entries.indices[(last + 1)...].first(where: isKept) ?? entries.indices[..<first].last(where: isKept)
        return kept.map { entries[$0].url }
    }

    /// Takes entries out at once after they were moved to the Trash, rather
    /// than waiting for the watcher's reload to notice.
    func removeEntries(_ urls: Set<URL>) {
        let matched = Set(urls.compactMap { entry(for: $0)?.url })
        guard !matched.isEmpty, snapshot != nil else { return }
        for url in matched where entry(for: url)?.isDirectory == false { invalidate(url) }
        snapshot?.remove(matched)
        applyFilter()
        onChange?([.entries, .selection])
    }

    /// Type-to-select: the first visible entry whose name starts with
    /// `prefix`, ignoring case and accents.
    func firstEntry(withPrefix prefix: String) -> URL? {
        let key = Self.searchKey(prefix)
        guard !key.isEmpty, let i = visibleKeys.firstIndex(where: { $0.hasPrefix(key) }) else { return nil }
        return entries[i].url
    }

    // MARK: - Viewer

    /// The visible images (no folders) in grid order, and where `url` is
    /// among them: what the viewer steps through.
    func imagesForViewer(startingAt url: URL) -> (images: [FolderEntry], index: Int)? {
        let images = entries.filter { !$0.isDirectory }
        guard let target = entry(for: url), let index = images.firstIndex(where: { $0.name == target.name })
        else { return nil }
        return (images, index)
    }

    /// The images either side of `url`, nearest first, next before previous:
    /// what the preview pane prefetches.
    func neighbouringImages(of url: URL) -> [FolderEntry] {
        guard let i = index(of: url) else { return [] }
        let next = entries[(i + 1)...].first { !$0.isDirectory }
        let previous = entries[..<i].last { !$0.isDirectory }
        return [next, previous].compactMap { $0 }
    }

    // MARK: - Text

    /// Window subtitle: "123 images, 4 folders".
    var subtitle: String {
        guard state == .loaded else { return "" }
        return Self.countText(images: imageCount, folders: folderCount)
    }

    nonisolated static func countText(images: Int, folders: Int) -> String {
        var parts: [String] = []
        if images > 0 || folders == 0 { parts.append(images == 1 ? "1 image" : "\(images.formatted()) images") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders.formatted()) folders") }
        return parts.joined(separator: ", ")
    }

    /// Status bar: "12 of 340 selected — 84.1 MB", or the counts when
    /// nothing is selected.
    nonisolated static func selectionText(selected: Int, total: Int, bytes: Int64, images: Int, folders: Int) -> String {
        guard selected > 0 else { return countText(images: images, folders: folders) }
        let count = "\(selected.formatted()) of \(total.formatted()) selected"
        return bytes > 0 ? "\(count) — \(bytes.formatted(.byteCount(style: .file)))" : count
    }

    var statusText: String {
        guard state == .loaded else { return "" }
        return Self.selectionText(selected: selection.count, total: entries.count, bytes: selectedBytes,
                                  images: imageCount, folders: folderCount)
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
