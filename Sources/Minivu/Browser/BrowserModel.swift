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

    /// - Parameters:
    ///   - marks: ratings by file name, for sorting by rating.
    ///   - customOrder: the catalog's arrangement, for Custom Order.
    init(contents: FolderContents, order: FileSortOrder, marks: [String: Catalog.Marks] = [:],
         customOrder: [String] = []) {
        folder = contents.folder
        let images: [FolderEntry]
        var folderOrder = order
        switch order.key {
        case .rating:
            images = MarksOrdering.byRating(contents.images, marks: marks, ascending: order.ascending)
            folderOrder = FileSortOrder()
        case .custom:
            images = MarksOrdering.custom(contents.images, order: customOrder, ascending: order.ascending)
            folderOrder = FileSortOrder()
        default:
            images = FolderListing.sorted(contents.images, by: order)
        }
        // Folders have no rating or place in an arrangement: by name, A to Z.
        entries = FolderListing.sorted(contents.subfolders, by: folderOrder) + images
        searchKeys = entries.map { BrowserModel.searchKey($0.name) }
    }

    /// The same entries in another order, without reading the disk again.
    func resorted(by order: FileSortOrder, marks: [String: Catalog.Marks] = [:],
                  customOrder: [String] = []) -> FolderSnapshot {
        FolderSnapshot(contents: FolderContents(folder: folder, subfolders: entries.filter(\.isDirectory),
                                                images: entries.filter { !$0.isDirectory }),
                       order: order, marks: marks, customOrder: customOrder)
    }

    /// Image names in display order, filters ignored: what a reorder works on.
    var imageNames: [String] { entries.filter { !$0.isDirectory }.map(\.name) }

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
///
/// `@MainActor` is spelled out although it is the target's default: the
/// isolated deinit needs it, and a release build of the tests (which
/// compiles this target for testing) doesn't apply the default to it.
@MainActor final class BrowserModel {
    /// What changed, so views update only what they need to.
    struct Changes: OptionSet {
        let rawValue: Int
        static let folder = Changes(rawValue: 1 << 0)
        static let entries = Changes(rawValue: 1 << 1)
        static let selection = Changes(rawValue: 1 << 2)
        static let state = Changes(rawValue: 1 << 3)
        /// Back, Forward or Enclosing Folder became possible or impossible.
        static let history = Changes(rawValue: 1 << 4)
        /// Ratings, tags or Finder tags changed: `changedMarkNames` says whose.
        static let marks = Changes(rawValue: 1 << 5)
        static let all: Changes = [.folder, .entries, .selection, .state, .history, .marks]
    }

    /// What a disk listing or a re-sort hands back to the main actor.
    nonisolated struct Listing: Sendable {
        var snapshot: FolderSnapshot
        /// Files whose cached thumbnails and textures are out of date.
        var changed: [URL]
        /// Read with the listing; nil for a re-sort, which keeps the marks.
        var marks: [String: Catalog.Marks]?
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
    typealias FolderCheck = @Sendable (_ folder: URL) -> Bool

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

    /// Rating, tag and Finder tag filters. They stay as the user moves
    /// between folders, as FastStone's do.
    var marksFilter = MarksFilter() {
        didSet {
            guard marksFilter != oldValue else { return }
            applyFilter()
            onChange?([.entries, .selection])
        }
    }

    /// The catalog's stars and tag for each image of the folder, by name.
    /// Only marked files have an entry.
    private(set) var marks: [String: Catalog.Marks] = [:]
    /// Finder tags by name (folders too), read after each listing.
    private(set) var finderTags: [String: [FinderTag]] = [:]
    /// Every Finder tag used in the folder, one per name, sorted: the filter menu.
    private(set) var finderTagsInFolder: [FinderTag] = []
    /// The names whose marks or Finder tags the last `.marks` change was
    /// about; nil when it was about every entry.
    private(set) var changedMarkNames: Set<String>?
    let catalog: Catalog
    /// Entries in the folder before any filter.
    var totalCount: Int { snapshot?.entries.count ?? 0 }

    var onChange: ((Changes) -> Void)?
    /// The folder's watcher saw something added, removed or renamed in it,
    /// before the reload that follows: the sidebar lists its subfolders again.
    var onFolderChangedOnDisk: ((URL) -> Void)?

    private let lister: Lister
    private let isReadableFolder: FolderCheck
    private let invalidate: @MainActor (URL) -> Void
    private let watchesFolder: Bool
    private var snapshot: FolderSnapshot? {
        didSet { imageNameSet = nil }
    }
    /// The snapshot's image names, made when a drop first asks.
    private var imageNameSet: Set<String>?
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
    /// Selected, all of them, once the next listing arrives (files just
    /// copied, moved or renamed in).
    private var pendingSelections: [URL] = []
    /// Catalog changes that came in while a listing was being read. The
    /// listing may have read the catalog before them, so they are applied
    /// again when it lands; otherwise a star set during a reload would
    /// flick back until the next change.
    private var catalogChangesDuringListing: [URL] = []
    /// Reads Finder tags after a listing; replaced by the next listing.
    private var finderTagReader: Task<[String: [FinderTag]]?, Never>?
    /// The Finder tag read in flight, for tests to await.
    private(set) var finderTagWork: Task<Void, Never>?
    private var catalogObserver: NSObjectProtocol?
    /// The parent whose readability the next listing checks: set by each
    /// navigation, cleared when a listing that checked it lands.
    private var parentToCheck: URL?
    private var watcher: FolderWatcher?
    /// The load or re-sort in flight, for tests to await.
    private(set) var work: Task<Void, Never>?

    /// - Parameters:
    ///   - lister: reads a folder; tests pass a slow or failing one.
    ///   - invalidate: forgets cached thumbnails and textures of a file that
    ///     changed or disappeared.
    ///   - watchesFolder: reload when the folder changes on disk.
    ///   - isReadableFolder: whether a folder can be opened; tests count calls.
    ///   - catalog: ratings, tags and custom order; tests pass their own.
    init(sortOrder: FileSortOrder = FileSortOrder(), showHiddenFiles: Bool = false,
         lister: @escaping Lister = { try FolderListing.contents(of: $0, includeHidden: $1) },
         invalidate: @escaping @MainActor (URL) -> Void = BrowserModel.invalidateCaches,
         watchesFolder: Bool = true,
         isReadableFolder: @escaping FolderCheck = BrowserModel.canOpenFolder,
         catalog: Catalog = .shared) {
        self.sortOrder = sortOrder
        self.showHiddenFiles = showHiddenFiles
        self.lister = lister
        self.isReadableFolder = isReadableFolder
        self.invalidate = invalidate
        self.watchesFolder = watchesFolder
        self.catalog = catalog
        // Any catalog's change names its files, so a model can listen to all
        // of them and pick out its own folder's.
        catalogObserver = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil,
                                                                 queue: .main) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            MainActor.assumeIsolated { self?.catalogChanged(urls) }
        }
    }

    isolated deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        finderTagReader?.cancel()
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

    /// Whether Go > Enclosing Folder can show the parent. Under the sandbox
    /// the parent of a folder the user opened is often off limits, and going
    /// there would only show an error.
    ///
    /// Menus and the toolbar validate many times a second, so this is an
    /// answer kept from a check made once per navigation, off the main
    /// thread with the listing. Until that check is back the previous
    /// answer stands: in the usual case (both readable) the button doesn't
    /// blink off and on at every step.
    private(set) var canGoToEnclosingFolder = false

    /// Whether a folder can be opened for reading right now. Opening the
    /// directory is the honest test under the sandbox: a folder can exist,
    /// and `fileExists` say so, while reading it is refused.
    nonisolated static func canOpenFolder(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
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
        marks = [:]
        finderTags = [:]
        finderTagsInFolder = []
        changedMarkNames = nil
        finderTagReader?.cancel()
        pendingSelections = []
        catalogChangesDuringListing = []
        pendingSelection = item
        parentToCheck = enclosingFolder
        if parentToCheck == nil { canGoToEnclosingFolder = false }
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

    /// Lists again and selects `items` (those of them that are in this
    /// folder) once they are listed: files just copied, moved or renamed here.
    func reload(thenSelect items: [URL]) {
        guard let folder else { return }
        pendingSelections = items.filter { Self.samePath($0.deletingLastPathComponent(), folder) }
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
            Task { @MainActor in
                guard let self, let current = self.folder, Self.samePath(current, folder) else { return }
                self.onFolderChangedOnDisk?(current)
                self.reload()
            }
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
        let parent = parentToCheck, isReadableFolder = self.isReadableFolder, catalog = self.catalog
        work = Task { [weak self] in
            let (result, parentIsReadable) = await BlockingWork.run(qos: .userInitiated) {
                let result = Result { () throws -> Listing in
                    let contents = try Self.list(folder, hidden, with: lister)
                    DebugMarks.seedIfRequested(folder: folder, names: Set(contents.images.map(\.name)), catalog: catalog)
                    // Files moved or renamed in Finder get their marks back
                    // (matched by file identifier) before the marks are read.
                    catalog.heal(folder: folder)
                    // One catalog read for the folder, with the listing, so a
                    // grid sorted by rating arrives in its order.
                    let marks = Self.marksByName(contents.images, in: catalog)
                    let custom = order.key == .custom ? catalog.customOrder(in: folder) : []
                    let snapshot = FolderSnapshot(contents: contents, order: order, marks: marks, customOrder: custom)
                    return Listing(snapshot: snapshot, changed: Self.changedFiles(old: previous, new: snapshot.entries),
                                   marks: marks)
                }
                return (result, parent.map(isReadableFolder))
            }
            guard let self else { return }
            if let parent, let parentIsReadable, parent == self.parentToCheck, generation == self.generation {
                self.parentToCheck = nil
                self.canGoToEnclosingFolder = parentIsReadable
            }
            self.finish(result, generation: generation)
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
        let generation = self.generation, order = sortOrder, marks = self.marks, catalog = self.catalog
        work = Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                let custom = order.key == .custom ? catalog.customOrder(in: snapshot.folder) : []
                return snapshot.resorted(by: order, marks: marks, customOrder: custom)
            }.value
            self?.finish(.success(Listing(snapshot: sorted, changed: [], marks: nil)), generation: generation)
        }
    }

    nonisolated static func marksByName(_ images: [FolderEntry], in catalog: Catalog) -> [String: Catalog.Marks] {
        guard !images.isEmpty else { return [:] }
        var result: [String: Catalog.Marks] = [:]
        for (url, marks) in catalog.marks(for: images.map(\.url)) where marks != .none {
            result[url.lastPathComponent] = marks
        }
        return result
    }

    private func finish(_ result: Result<Listing, Error>, generation: Int) {
        guard generation == self.generation else { return }
        isListing = false
        switch result {
        case .success(let listing):
            listing.changed.forEach(invalidate)
            snapshot = listing.snapshot
            state = .loaded
            if let marks = listing.marks {
                if marks != self.marks { changedMarkNames = nil }
                self.marks = marks
                readFinderTags()
            }
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
        if !pendingSelections.isEmpty, state == .loaded {
            let found = pendingSelections.compactMap { entry(for: $0)?.url }
            pendingSelections = []
            if let first = found.first {
                selection = Set(found)
                lead = first
            }
        }
        #if DEBUG
        if let name = DebugMarks.selection, !Self.debugSelectionDone, state == .loaded,
           let url = entries.first(where: { $0.name == name })?.url {
            Self.debugSelectionDone = true
            select(url, notify: false)
        }
        #endif
        onChange?([.entries, .selection, .state, .history, .marks])
        if !catalogChangesDuringListing.isEmpty {
            let urls = catalogChangesDuringListing
            catalogChangesDuringListing = []
            catalogChanged(urls)
        }
    }

    #if DEBUG
    private static var debugSelectionDone = false
    #endif

    // MARK: - Marks

    /// Reads every entry's Finder tags off the main thread: one extended
    /// attribute read each, too many for the main thread in a big folder, and
    /// never worth holding the listing back for. A newer listing cancels it.
    private func readFinderTags() {
        finderTagReader?.cancel()
        guard let snapshot else { return }
        let urls = snapshot.entries.map(\.url), folder = snapshot.folder
        let reader = Task.detached(priority: .utility) { () -> [String: [FinderTag]]? in
            var tags: [String: [FinderTag]] = [:]
            for (index, url) in urls.enumerated() {
                if index % 128 == 0, Task.isCancelled { return nil }
                let found = FinderTag.read(from: url)
                if !found.isEmpty { tags[url.lastPathComponent] = found }
            }
            return tags
        }
        finderTagReader = reader
        finderTagWork = Task { [weak self] in
            guard let tags = await reader.value, !reader.isCancelled, let self,
                  let current = self.folder, Self.samePath(current, folder) else { return }
            self.applyFinderTags(tags)
        }
    }

    private func applyFinderTags(_ tags: [String: [FinderTag]]) {
        guard tags != finderTags else { return }
        var changed = Set<String>()
        for name in Set(tags.keys).union(finderTags.keys) where tags[name] != finderTags[name] { changed.insert(name) }
        finderTags = tags
        var seen = Set<String>()
        finderTagsInFolder = tags.values.joined()
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        changedMarkNames = changed
        if marksFilter.finderTag != nil {
            applyFilter()
            onChange?([.marks, .entries, .selection])
        } else {
            onChange?(.marks)
        }
    }

    /// Whether the folder has an image of this name, shown or filtered out.
    func containsImage(named name: String) -> Bool {
        if imageNameSet == nil { imageNameSet = Set(snapshot?.imageNames ?? []) }
        return imageNameSet?.contains(name) ?? false
    }

    func marks(for url: URL) -> Catalog.Marks { marks[url.lastPathComponent] ?? .none }
    func finderTags(for url: URL) -> [FinderTag] { finderTags[url.lastPathComponent] ?? [] }

    /// The selected images; folders have no rating or tag.
    var selectedImageURLs: [URL] { selectedEntries.filter { !$0.isDirectory }.map(\.url) }

    /// Whether any selected item is an image: menu validation's question,
    /// answered without sorting a big selection for every item it checks.
    var hasSelectedImages: Bool { selection.contains { entry(for: $0)?.isDirectory == false } }

    /// Catalog writes go through one serial queue, off the main thread
    /// (DESIGN.md 6, rule 1), so two quick key presses land in order.
    nonisolated static let catalogWrites = DispatchQueue(label: "minivu.catalog-writes", qos: .userInitiated)

    /// Rates `urls`. The grid updates when the catalog reports the change.
    func setRating(_ rating: Int, for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let catalog = self.catalog
        Self.catalogWrites.async { catalog.setRating(rating, for: urls) }
    }

    /// Tags them all, unless every one is tagged already: then untags them
    /// (Finder's rule for a mixed selection and a checkbox).
    func toggleTag(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let tag = !urls.allSatisfy { marks(for: $0).isTagged }
        let catalog = self.catalog
        Self.catalogWrites.async { catalog.setTagged(tag, for: urls) }
    }

    /// Custom Order: moves images to just before `target` (the end for nil)
    /// and stores the folder's new arrangement. Hidden images keep their
    /// places relative to the rest.
    func moveImages(_ urls: [URL], before target: URL?) {
        guard sortOrder.key == .custom, let snapshot, let folder else { return }
        let names = snapshot.imageNames
        let known = Set(names)
        let moving = urls.map(\.lastPathComponent).filter(known.contains)
        guard !moving.isEmpty else { return }
        var order = MarksOrdering.reordered(names, moving: moving, before: target?.lastPathComponent)
        guard order != names else { return }
        // Descending shows the arrangement back to front.
        if !sortOrder.ascending { order.reverse() }
        let catalog = self.catalog, stored = order
        Self.catalogWrites.async { catalog.setCustomOrder(stored, in: folder) }
    }

    /// The catalog changed some files, or a folder's order. Marks of this
    /// folder's files are read again (one small read), then only what they
    /// affect is redone: the cells, the filter, or the order.
    func catalogChanged(_ urls: [URL]) {
        if isListing { catalogChangesDuringListing += urls }
        guard let folder, state == .loaded else { return }
        var files: [URL] = []
        var orderChanged = false
        for url in urls {
            if Self.samePath(url, folder) {
                orderChanged = true
            } else if Self.samePath(url.deletingLastPathComponent(), folder) {
                files.append(url)
            }
        }
        var changed = Set<String>()
        if !files.isEmpty {
            let fresh = catalog.marks(for: files)
            for url in files {
                let name = url.lastPathComponent, value = fresh[url] ?? .none
                guard (marks[name] ?? .none) != value else { continue }
                marks[name] = value == .none ? nil : value
                changed.insert(name)
            }
        }
        let resorts = (!changed.isEmpty && sortOrder.key == .rating) || (orderChanged && sortOrder.key == .custom)
        let refilters = !changed.isEmpty && marksFilter.isActive
        guard !changed.isEmpty || resorts else { return }
        changedMarkNames = changed

        // A mark that hides everything selected moves the selection on, as
        // the Trash does, so culling with a filter up keeps going.
        var next: URL?
        if refilters, !selection.isEmpty {
            let hidden = selection.filter { url in
                guard let entry = entry(for: url) else { return false }
                return !marksFilter.passes(entry, marks: marks(for: url), finderTags: finderTags(for: url))
            }
            if hidden == selection { next = selectionAfterRemoving(hidden) }
        }
        if resorts {
            if let next { pendingSelection = next }
            resort()
            onChange?(.marks)
        } else if refilters {
            applyFilter()
            if let next { select(next, notify: false) }
            onChange?([.marks, .entries, .selection])
        } else {
            onChange?(.marks)
        }
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
        let marksFilter = self.marksFilter
        if query.isEmpty, !marksFilter.isActive {
            entries = snapshot.entries
            visibleKeys = snapshot.searchKeys
        } else {
            let keep = snapshot.searchKeys.indices.filter { i in
                if !query.isEmpty, !snapshot.searchKeys[i].contains(query) { return false }
                guard marksFilter.isActive else { return true }
                let entry = snapshot.entries[i]
                return marksFilter.passes(entry, marks: marks[entry.name] ?? .none, finderTags: finderTags[entry.name] ?? [])
            }
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

    /// The image `offset` images after `url` (before it, when negative),
    /// skipping folders: where the preview pane's wheel steps to. Past either
    /// end it wraps round when `wrap`, as the viewer does, and otherwise
    /// stops; nil when that leaves it where it was. From a folder, or from
    /// nothing, it starts at the first image.
    func image(_ offset: Int, from url: URL?, wrap: Bool) -> URL? {
        // Folders come first, so the images are one run at the end.
        let images = folderCount..<entries.count
        guard offset != 0, !images.isEmpty else { return nil }
        guard let current = url.flatMap(index(of:)), images.contains(current) else {
            return entries[images.lowerBound].url
        }
        var target = current - images.lowerBound + offset
        target = wrap ? ((target % images.count) + images.count) % images.count
                      : min(max(target, 0), images.count - 1)
        let index = images.lowerBound + target
        return index == current ? nil : entries[index].url
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

    /// Status bar: the selection, or "12 of 340 shown" while a search or a
    /// filter hides some of the folder.
    var statusText: String {
        guard state == .loaded else { return "" }
        if selection.isEmpty, isFiltering {
            return Self.shownText(shown: entries.count, total: totalCount)
        }
        return Self.selectionText(selected: selection.count, total: entries.count, bytes: selectedBytes,
                                  images: imageCount, folders: folderCount)
    }

    /// A search or a marks filter is narrowing the folder.
    var isFiltering: Bool {
        marksFilter.isActive || !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func shownText(shown: Int, total: Int) -> String {
        "\(shown.formatted()) of \(total.formatted()) shown"
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
