import Foundation
import MinivuCore

/// One folder, listed and sorted, ready to filter. A plain value made off
/// the main thread, so neither listing nor sorting ever costs the UI a frame.
nonisolated struct FolderSnapshot: Sendable {
    let folder: URL
    /// The entries come from more than one folder (the flat view, a search,
    /// a collection: G3), so the model knows them by path; otherwise by name.
    let keysByPath: Bool
    /// Subfolders first, then images, each group in the sort order.
    private(set) var entries: [FolderEntry]
    /// Each entry's name folded for searching, in the same order. Folding
    /// once here keeps typing in the search field cheap on a huge folder.
    private(set) var searchKeys: [String]

    /// - Parameters:
    ///   - marks: ratings by file name, for sorting by rating.
    ///   - customOrder: the catalog's arrangement, for Custom Order.
    ///   - keysByPath: entries from several folders (`keysByPath`). Custom
    ///     Order is a folder's own, so such a list shows it by name.
    init(contents: FolderContents, order: FileSortOrder, marks: [String: Catalog.Marks] = [:],
         customOrder: [String] = [], keysByPath: Bool = false) {
        folder = contents.folder
        self.keysByPath = keysByPath
        let images: [FolderEntry]
        var folderOrder = order
        switch order.key {
        case .rating:
            images = MarksOrdering.byRating(contents.images, marks: marks, ascending: order.ascending,
                                            key: { Self.key(of: $0, byPath: keysByPath) })
            folderOrder = FileSortOrder()
        case .custom where keysByPath:
            images = FolderListing.sorted(contents.images, by: FileSortOrder(key: .name, ascending: order.ascending))
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
                       order: order, marks: marks, customOrder: customOrder, keysByPath: keysByPath)
    }

    /// Image names in display order, filters ignored: what a reorder works on.
    var imageNames: [String] { entries.filter { !$0.isDirectory }.map(\.name) }

    /// What the model knows images by, in display order, filters ignored.
    var imageKeys: [String] { entries.filter { !$0.isDirectory }.map { Self.key(of: $0, byPath: keysByPath) } }

    /// An entry's key: its name in a folder, its path in a list from many.
    static func key(of entry: FolderEntry, byPath: Bool) -> String {
        byPath ? entry.url.path : entry.name
    }

    static func key(of url: URL, byPath: Bool) -> String {
        byPath ? url.path : url.lastPathComponent
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
        /// What each image shows: its catalog row's marks, or its own.
        var marks: [String: Catalog.Marks]?
        /// The catalog's rows and the files' own marks (G2) the listing
        /// knew of, with `marks`.
        var catalogRows: [String: Catalog.Marks] = [:]
        var fileMarks: [String: Catalog.Marks] = [:]
        /// Images whose own marks were found in the cache, with or without any.
        var fileMarksKnown: Set<String> = []
        /// Read with the listing while a Finder tag filter is on, so the
        /// filter has them; nil when the usual asynchronous read will do.
        var finderTags: [String: [FinderTag]]?
        /// A tree or list stopped at a walk limit (G3).
        var isTruncated = false
    }

    enum State: Equatable {
        /// No folder yet.
        case empty
        case loading
        case loaded
        /// Shown in place of the grid.
        case failed(String)
    }

    /// A place in the history: the folder, or the list shown instead of
    /// one (G3), and what was selected in it, so Back returns to the same
    /// photo.
    struct Location: Equatable {
        var folder: URL?
        var list: VirtualList?
        var selection: URL?

        init(folder: URL? = nil, list: VirtualList? = nil, selection: URL? = nil) {
            self.folder = folder
            self.list = list
            self.selection = selection
        }
    }

    typealias Lister = @Sendable (_ folder: URL, _ includeHidden: Bool) throws -> FolderContents
    typealias FolderCheck = @Sendable (_ folder: URL) -> Bool
    /// Reads a folder tree for the flat view; tests pass a slow one.
    typealias TreeLister = @Sendable (_ root: URL, _ includeHidden: Bool, _ cancel: CancellationFlag,
                                      _ batch: ([FolderEntry]) -> Void) throws -> TreeEnumerator.Result
    /// Reads a virtual list's images (`VirtualList.load`); tests pass their own.
    typealias ListLoader = @Sendable (_ list: VirtualList, _ context: VirtualList.Context, _ cancel: CancellationFlag,
                                      _ batch: ([FolderEntry]) -> Void) throws -> VirtualList.Outcome

    /// The folder shown; in the flat view, the folder at the top of the
    /// tree. Nil while a list is shown.
    private(set) var folder: URL?
    /// The list shown instead of a folder (G3): search results, a smart
    /// folder or a collection.
    private(set) var list: VirtualList?
    /// The flat view (G3): the folder's images and those of every folder
    /// below it, as one list without the subfolders. It stays on as the
    /// user moves between folders, as the filters do, and has no effect on
    /// a list.
    var flatView = false {
        didSet {
            guard flatView != oldValue, let folder else { return }
            show(Location(folder: folder, selection: lead))
        }
    }
    /// The last tree or list stopped at a walk limit, so there may be more.
    private(set) var isTruncated = false
    /// Images from more than one folder are shown (the flat view or a
    /// list): the grid names each one's folder, and commands that work on
    /// "this folder" (New Folder, Paste, Custom Order) step aside.
    var showsManyFolders: Bool { snapshot?.keysByPath ?? (list != nil || flatView) }
    private(set) var state: State = .empty
    /// Visible entries: sorted, then filtered by `filter`.
    private(set) var entries: [FolderEntry] = [] {
        didSet { cachedSelectedBytes = nil; cachedSelectedMarks = nil; cachedSelectedLabel = nil }
    }
    private(set) var selection: Set<URL> = [] {
        didSet { cachedSelectedBytes = nil; cachedSelectedMarks = nil; cachedSelectedLabel = nil }
    }
    /// The item the preview pane shows and the viewer opens: the one most
    /// recently clicked or moved to.
    private(set) var lead: URL?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private(set) var imageCount = 0
    /// How many of `imageCount` are videos (G18), for the tools that
    /// leave them out.
    private(set) var videoCount = 0
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
            readEveryFileMarksIfNeeded()
        }
    }

    /// The filters past rating and tags (G3): type, date taken, camera,
    /// lens, exposure, keywords, colour label, location, shape and size.
    /// They stay as the user moves between folders, as the others do. The
    /// headers they need are read in the background (`readFilterMetadata`).
    var metadataFilter = MetadataCriteria() {
        didSet {
            guard metadataFilter != oldValue else { return }
            applyFilter()
            onChange?([.entries, .selection])
            readFilterMetadataIfNeeded()
        }
    }

    /// What the metadata filter knows of each image read so far, by key.
    private(set) var filterMetadata: [String: FilterMetadata] = [:]
    private var filterMetadataCancel = CancellationFlag()
    /// The metadata read in flight, for tests to await.
    private(set) var filterMetadataWork: Task<Void, Never>?

    /// The stars and tag each image of the folder shows, by name: its
    /// catalog row's, or for an image without one the marks the file
    /// carries itself (G2). Only marked files have an entry.
    private(set) var marks: [String: Catalog.Marks] = [:] {
        didSet { cachedSelectedMarks = nil }
    }
    /// The catalog's rows by name, including an emptied row kept over a
    /// file's own marks: a row's marks win over the file's.
    private var catalogRows: [String: Catalog.Marks] = [:]
    /// Marks the files carry themselves (`xmp:Rating`, a pick), by name,
    /// for the images read so far that have any.
    private(set) var fileMarks: [String: Catalog.Marks] = [:]
    /// Images whose own marks are known, or being read, since the listing.
    private var fileMarksKnown: Set<String> = []
    /// Images to read the marks of, gathered from one layout pass.
    private var fileMarksWanted: [URL] = []
    private var fileMarksCancel = CancellationFlag()
    /// The marks read in flight; reads run one after another, so this is
    /// the last. For tests to await.
    private(set) var fileMarksWork: Task<Void, Never>?
    /// Reads the marks files carry; nil reads none (tests that don't care).
    let fileMarksCache: FileMarksCache?
    /// Finder tags by name (folders too), read after each listing.
    private(set) var finderTags: [String: [FinderTag]] = [:]
    /// Every Finder tag used in the folder, one per name, sorted: the filter menu.
    private(set) var finderTagsInFolder: [FinderTag] = []
    /// The names whose marks or Finder tags the last `.marks` change was
    /// about; nil when it was about every entry.
    private(set) var changedMarkNames: Set<String>?
    let catalog: Catalog
    /// Entries in the folder (or list) before any filter.
    var totalCount: Int { snapshot?.entries.count ?? 0 }

    var onChange: ((Changes) -> Void)?
    /// The folder's watcher saw something added, removed or renamed in it,
    /// before the reload that follows: the sidebar lists its subfolders again.
    var onFolderChangedOnDisk: ((URL) -> Void)?

    private let lister: Lister
    private let treeLister: TreeLister
    private let listLoader: ListLoader
    /// Stops the tree or list being read when the user moves on.
    private var manyCancel: CancellationFlag?
    private let isReadableFolder: FolderCheck
    private let invalidate: @MainActor (URL) -> Void
    private let watchesFolder: Bool
    private var snapshot: FolderSnapshot? {
        didSet { imageKeySet = nil }
    }
    /// The snapshot's image keys, made when a drop first asks.
    private var imageKeySet: Set<String>?
    private var visibleKeys: [String] = []
    /// Entry index by key: the file name, when every entry is a child of
    /// one folder, which survives the path spellings the file system hands
    /// back (a listing of /var/x reports /private/var/x); the path in a
    /// list from many folders (G3).
    private var indexByKey: [String: Int] = [:]
    private var generation = 0
    /// Counts what the window has shown (folders and lists), so work for
    /// one that lands after the user moved on is dropped: the generation
    /// alone also counts reloads of the same folder.
    private var sourceGeneration = 0
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
    /// The Finder tag read in flight: a whole listing's, or a refresh of a
    /// few files'. The next listing cancels either.
    private var finderTagRead: (cancel: CancellationFlag, isWholeFolder: Bool)?
    /// The Finder tag read in flight, for tests to await.
    private(set) var finderTagWork: Task<Void, Never>?
    private var catalogObserver: NSObjectProtocol?
    private var libraryObserver: NSObjectProtocol?
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
         treeLister: @escaping TreeLister = BrowserModel.listTree,
         listLoader: @escaping ListLoader = { try VirtualList.load($0, context: $1, cancel: $2, batch: $3) },
         invalidate: @escaping @MainActor (URL) -> Void = BrowserModel.invalidateCaches,
         watchesFolder: Bool = true,
         isReadableFolder: @escaping FolderCheck = BrowserModel.canOpenFolder,
         catalog: Catalog = .shared, fileMarksCache: FileMarksCache? = .shared) {
        self.sortOrder = sortOrder
        self.showHiddenFiles = showHiddenFiles
        self.lister = lister
        self.treeLister = treeLister
        self.listLoader = listLoader
        self.isReadableFolder = isReadableFolder
        self.invalidate = invalidate
        self.watchesFolder = watchesFolder
        self.catalog = catalog
        self.fileMarksCache = fileMarksCache
        // Any catalog's change names its files, so a model can listen to all
        // of them and pick out its own folder's.
        catalogObserver = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil,
                                                                 queue: .main) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            MainActor.assumeIsolated { self?.catalogChanged(urls) }
        }
        // A collection shown changes when members are added, removed or
        // found again; a smart folder is re-run only when opened.
        libraryObserver = NotificationCenter.default.addObserver(forName: Catalog.libraryDidChange, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
    }

    isolated deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        finderTagRead?.cancel.cancel()
        manyCancel?.cancel()
        filterMetadataCancel.cancel()
    }

    /// The flat view's walk, within the standard limits.
    nonisolated static func listTree(_ root: URL, _ includeHidden: Bool, _ cancel: CancellationFlag,
                                     _ batch: ([FolderEntry]) -> Void) throws -> TreeEnumerator.Result {
        try TreeEnumerator.images(under: root, includeHidden: includeHidden, isCancelled: { cancel.isCancelled },
                                  batch: batch)
    }

    static func invalidateCaches(_ url: URL) {
        AppServices.thumbnails.invalidate(url)
        AppServices.images.invalidate(url)
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The parent folder, or nil at the root of the disk or for a list.
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
        pushHistory()
        show(Location(folder: target, selection: item))
    }

    /// Shows a list instead of a folder (G3). Showing the list already
    /// shown reads it again: a smart folder is re-run whenever it is opened.
    func show(list: VirtualList) {
        if self.list != list { pushHistory() }
        show(Location(list: list))
    }

    /// Where the window is now, onto the back stack, before going elsewhere.
    private func pushHistory() {
        guard let here = currentLocation else { return }
        backStack.append(here)
        forwardStack.removeAll()
    }

    private var currentLocation: Location? {
        guard folder != nil || list != nil else { return nil }
        return Location(folder: folder, list: list, selection: lead)
    }

    func goBack() {
        guard let here = currentLocation, let previous = backStack.popLast() else { return }
        forwardStack.append(here)
        show(previous)
    }

    func goForward() {
        guard let here = currentLocation, let next = forwardStack.popLast() else { return }
        backStack.append(here)
        show(next)
    }

    /// Up one level, with the folder we came from selected, as Finder does.
    func goToEnclosingFolder() {
        guard let folder, let parent = enclosingFolder else { return }
        navigate(to: parent, selecting: folder)
    }

    private func show(_ location: Location) {
        folder = location.list == nil ? location.folder?.standardizedFileURL : nil
        list = location.list
        let item = location.selection
        sourceGeneration += 1
        manyCancel?.cancel()
        manyCancel = nil
        isTruncated = false
        filterMetadata = [:]
        filterMetadataCancel.cancel()
        filterMetadataCancel = CancellationFlag()
        snapshot = nil
        entries = []
        visibleKeys = []
        indexByKey = [:]
        imageCount = 0
        videoCount = 0
        folderCount = 0
        selection = []
        lead = nil
        marks = [:]
        catalogRows = [:]
        fileMarks = [:]
        fileMarksKnown = []
        fileMarksWanted = []
        fileMarksCancel.cancel()
        fileMarksCancel = CancellationFlag()
        finderTags = [:]
        finderTagsInFolder = []
        changedMarkNames = nil
        finderTagRead?.cancel.cancel()
        finderTagRead = nil
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

    /// Lists the folder (or list) again, keeping what is shown until the
    /// new listing arrives (a watcher reload must not flash an empty grid).
    func reload() {
        guard folder != nil || list != nil else { return }
        load()
    }

    /// Lists again and selects `items` (those of them that are in this
    /// folder) once they are listed: files just copied, moved or renamed here.
    /// A list from many folders selects those of them it still holds.
    func reload(thenSelect items: [URL]) {
        if showsManyFolders {
            guard folder != nil || list != nil else { return }
            pendingSelections = items
        } else {
            guard let folder else { return }
            pendingSelections = items.filter { Self.samePath($0.deletingLastPathComponent(), folder) }
        }
        load()
    }

    /// The flat view watches only the folder at the top of the tree, as
    /// the browser always has: watching every folder below it would keep a
    /// busy subtree reloading the grid. A list watches nothing; minivu's
    /// own moves and the catalog's notifications keep it current.
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
        if list != nil || flatView { return loadMany() }
        guard let folder else { return }
        generation += 1
        isListing = true
        let generation = self.generation
        let lister = self.lister, hidden = showHiddenFiles, order = sortOrder
        let previous = snapshot.flatMap { Self.samePath($0.folder, folder) ? $0.entries : nil } ?? []
        let parent = parentToCheck, isReadableFolder = self.isReadableFolder, catalog = self.catalog
        let fileMarksCache = self.fileMarksCache
        let needsFinderTags = marksFilter.finderTag != nil || metadataFilter.colorLabel != nil
        work = Task { [weak self] in
            let open = Perf.begin("folder.open")
            defer { open.end() }
            let (result, parentIsReadable) = await BlockingWork.run(qos: .userInitiated) {
                let result = Result { () throws -> Listing in
                    let contents = try Perf.measure("folder.list") { try Self.list(folder, hidden, with: lister) }
                    DebugMarks.seedIfRequested(folder: folder, names: Set(contents.images.map(\.name)), catalog: catalog)
                    // Files moved or renamed in Finder get their marks back
                    // (matched by file identifier) before the marks are read.
                    catalog.heal(folder: folder)
                    // One catalog read for the folder, with the listing, so a
                    // grid sorted by rating arrives in its order. Files
                    // without a row show the marks they carry, as far as the
                    // cache knows them (a stat each, no reads).
                    let rows = Perf.measure("folder.marks") { Self.marksByKey(contents.images, in: catalog) }
                    let own = Perf.measure("folder.fileMarks") {
                        fileMarksCache.map { Self.cachedFileMarks(contents.images, without: rows, in: $0) }
                    }
                    let marks = Self.shownMarks(rows: rows, files: own?.marks ?? [:])
                    let custom = order.key == .custom ? catalog.customOrder(in: folder) : []
                    let snapshot = Perf.measure("folder.sort") {
                        FolderSnapshot(contents: contents, order: order, marks: marks, customOrder: custom)
                    }
                    // A Finder tag filter hides every image until the tags
                    // are known, and the selection the listing was asked to
                    // make would be consumed against that empty grid and
                    // lost, so while one is on the tags ride along with the
                    // marks in this same hop rather than following later.
                    let tags = needsFinderTags ? Self.finderTagsByKey(snapshot.entries) : nil
                    return Listing(snapshot: snapshot, changed: Self.changedFiles(old: previous, new: snapshot.entries),
                                   marks: marks, catalogRows: rows, fileMarks: own?.marks ?? [:],
                                   fileMarksKnown: own?.known ?? [], finderTags: tags)
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

    /// Reads the flat view's tree or a list (G3), off the main thread, the
    /// grid filling in as it goes: every quarter of a second the images
    /// found so far are sorted there and shown (`showPartial`), and the
    /// marks, Finder tags and catalog changes follow with the last of them,
    /// as for a folder. Navigating away, or the next load, cancels the walk
    /// between two folders, and a result that is no longer current is
    /// dropped by its generation as a folder's is.
    ///
    /// Files moved in Finder are not healed here: healing reads each folder
    /// again, which over a tree of thousands would double the walk. Their
    /// marks come back when their folder is opened on its own.
    private func loadMany() {
        manyCancel?.cancel()
        let cancel = CancellationFlag()
        manyCancel = cancel
        generation += 1
        isListing = true
        let generation = self.generation
        let list = self.list, root = self.folder, hidden = showHiddenFiles, order = sortOrder
        let treeLister = self.treeLister, listLoader = self.listLoader, catalog = self.catalog
        let fileMarksCache = self.fileMarksCache
        let previous = snapshot?.keysByPath == true ? snapshot?.entries ?? [] : []
        let parent = list == nil ? parentToCheck : nil, isReadableFolder = self.isReadableFolder
        let needsFinderTags = marksFilter.finderTag != nil || metadataFilter.colorLabel != nil
        let context = VirtualList.Context(catalog: catalog, includeHidden: hidden,
                                          standardNames: list == nil ? [:] : ColorLabelCommand.standardNames)
        // A list has no folder; its snapshot's stands for "nowhere".
        let base = root ?? URL(fileURLWithPath: "/", isDirectory: true)
        work = Task { [weak self] in
            let open = Perf.begin("flat.open")
            defer { open.end() }
            let (result, parentIsReadable) = await BlockingWork.run(qos: .userInitiated) {
                let result = Result { () throws -> Listing in
                    var found: [FolderEntry] = []
                    var lastShown = ContinuousClock.now
                    let batch: ([FolderEntry]) -> Void = { images in
                        found += images
                        guard ContinuousClock.now - lastShown > Self.partialInterval, !cancel.isCancelled else { return }
                        lastShown = .now
                        let partial = Perf.measure("flat.partialSort") {
                            FolderSnapshot(contents: FolderContents(folder: base, subfolders: [], images: found),
                                           order: order, keysByPath: true)
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.showPartial(partial, generation: generation) }
                        }
                    }
                    let truncated: Bool
                    if let list {
                        let outcome = try listLoader(list, context, cancel, batch)
                        found = outcome.images
                        truncated = outcome.isTruncated
                    } else {
                        let walk = try treeLister(base, hidden, cancel, batch)
                        found = walk.images
                        truncated = walk.isTruncated
                    }
                    let rows = Perf.measure("folder.marks") { Self.marksByKey(found, in: catalog, byPath: true) }
                    let own = Perf.measure("folder.fileMarks") {
                        fileMarksCache.map { Self.cachedFileMarks(found, without: rows, in: $0, byPath: true) }
                    }
                    let marks = Self.shownMarks(rows: rows, files: own?.marks ?? [:])
                    let snapshot = Perf.measure("folder.sort") {
                        FolderSnapshot(contents: FolderContents(folder: base, subfolders: [], images: found),
                                       order: order, marks: marks, keysByPath: true)
                    }
                    let tags = needsFinderTags ? Self.finderTagsByKey(snapshot.entries, byPath: true) : nil
                    return Listing(snapshot: snapshot, changed: Self.changedFiles(old: previous, new: snapshot.entries),
                                   marks: marks, catalogRows: rows, fileMarks: own?.marks ?? [:],
                                   fileMarksKnown: own?.known ?? [], finderTags: tags, isTruncated: truncated)
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

    /// How often a tree or list being read shows what it has found.
    nonisolated static let partialInterval = Duration.milliseconds(250)

    /// The images found so far while a tree or list is read. Marks and
    /// Finder tags arrive with the last of them; until then the grid shows
    /// the files, in order, with what was already known.
    private func showPartial(_ partial: FolderSnapshot, generation: Int) {
        guard generation == self.generation, isListing else { return }
        let shown = Perf.begin("flat.showPartial")
        defer { shown.end() }
        snapshot = partial
        state = .loaded
        applyFilter()
        if let item = pendingSelection, entry(for: item) != nil {
            pendingSelection = nil
            select(item, notify: false)
        }
        onChange?([.entries, .selection, .state])
    }

    /// The catalog's collections or smart folders changed: a collection
    /// shown is read again (members added, removed or found elsewhere).
    private func libraryChanged() {
        guard case .collection? = list?.kind, state == .loaded else { return }
        reload()
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
            let sorted = await BlockingWork.run {
                let resort = Perf.begin("folder.resort")
                defer { resort.end() }
                let custom = order.key == .custom && !snapshot.keysByPath ? catalog.customOrder(in: snapshot.folder) : []
                return snapshot.resorted(by: order, marks: marks, customOrder: custom)
            }
            self?.finish(.success(Listing(snapshot: sorted, changed: [], marks: nil)), generation: generation)
        }
    }

    /// The catalog's rows for the images, by key (`FolderSnapshot.key`), an
    /// emptied row kept over a file's own marks included.
    nonisolated static func marksByKey(_ images: [FolderEntry], in catalog: Catalog,
                                       byPath: Bool = false) -> [String: Catalog.Marks] {
        guard !images.isEmpty else { return [:] }
        var result: [String: Catalog.Marks] = [:]
        for (url, marks) in catalog.marks(for: images.map(\.url)) {
            result[FolderSnapshot.key(of: url, byPath: byPath)] = marks
        }
        return result
    }

    /// The marks the cache already knows for images without a row: those
    /// with marks, and every image it knows about either way.
    nonisolated static func cachedFileMarks(_ images: [FolderEntry], without rows: [String: Catalog.Marks],
                                            in cache: FileMarksCache,
                                            byPath: Bool = false) -> (marks: [String: Catalog.Marks], known: Set<String>) {
        var marks: [String: Catalog.Marks] = [:], known = Set<String>()
        for image in images {
            let key = FolderSnapshot.key(of: image, byPath: byPath)
            guard rows[key] == nil, let cached = cache.cachedMarks(for: image.url) else { continue }
            known.insert(key)
            if let cached { marks[key] = cached }
        }
        return (marks, known)
    }

    /// What each image shows: its row's marks, else its own. Only marked
    /// images have an entry.
    nonisolated static func shownMarks(rows: [String: Catalog.Marks],
                                       files: [String: Catalog.Marks]) -> [String: Catalog.Marks] {
        var result = files.filter { rows[$0.key] == nil }
        for (name, marks) in rows where marks != .none { result[name] = marks }
        return result
    }

    /// Every entry's Finder tags, one extended attribute read each, for the
    /// listing to carry. Only tagged entries get an entry, as the
    /// asynchronous read's map does.
    nonisolated static func finderTagsByKey(_ entries: [FolderEntry], byPath: Bool = false) -> [String: [FinderTag]] {
        var tags: [String: [FinderTag]] = [:]
        for entry in entries {
            let found = FinderTag.read(from: entry.url)
            if !found.isEmpty { tags[FolderSnapshot.key(of: entry, byPath: byPath)] = found }
        }
        return tags
    }

    private func finish(_ result: Result<Listing, Error>, generation: Int) {
        guard generation == self.generation else { return }
        let finishing = Perf.begin("folder.finish")
        defer { finishing.end() }
        isListing = false
        switch result {
        case .success(let listing):
            listing.changed.forEach(invalidate)
            snapshot = listing.snapshot
            state = .loaded
            for url in listing.changed { filterMetadata[key(url)] = nil }
            if let marks = listing.marks {
                isTruncated = listing.isTruncated
                if marks != self.marks { changedMarkNames = nil }
                self.marks = marks
                catalogRows = listing.catalogRows
                fileMarks = listing.fileMarks
                fileMarksKnown = listing.fileMarksKnown
                if let tags = listing.finderTags {
                    // In place before the filter runs below, so the grid is
                    // never momentarily empty. A read still in flight would
                    // land after them and put older tags back, and a listing
                    // has always cancelled one.
                    finderTagRead?.cancel.cancel()
                    finderTagRead = nil
                    storeFinderTags(tags)
                } else {
                    readFinderTags()
                }
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
        if !Self.hasListedFirstFolder, state == .loaded {
            Self.hasListedFirstFolder = true
            Perf.milestone("launch.firstFolderListed")
        }
        if !catalogChangesDuringListing.isEmpty {
            let urls = catalogChangesDuringListing
            catalogChangesDuringListing = []
            catalogChanged(urls)
        }
        readEveryFileMarksIfNeeded()
        readFilterMetadataIfNeeded()
    }

    #if DEBUG
    private static var debugSelectionDone = false
    #endif

    /// The launch milestone is marked once, for the first folder shown.
    private static var hasListedFirstFolder = false

    // MARK: - Marks

    /// Reads every entry's Finder tags off the main thread: one extended
    /// attribute read each, too many for the main thread in a big folder, and
    /// never worth holding the listing back for. A newer listing cancels it.
    private func readFinderTags() {
        guard let snapshot else { return }
        readFinderTags(of: snapshot.entries.map(\.url), in: snapshot.folder, wholeFolder: true)
    }

    /// Reads the Finder tags of `urls` (files of the folder shown) again.
    ///
    /// Tagging a file in Finder changes only an extended attribute, which the
    /// folder watcher doesn't report, so the dots would stay stale until the
    /// next listing. The browser asks for its visible cells when its window
    /// becomes key (the user coming back from Finder) and for files whose
    /// marks minivu just wrote: a few dozen reads at a moment the user caused,
    /// instead of polling. Skipped while a whole-folder read is under way,
    /// which covers them.
    func refreshFinderTags(of urls: [URL]) {
        guard let snapshot, state == .loaded, !isListing, finderTagRead?.isWholeFolder != true else { return }
        let folder = snapshot.folder
        let inFolder = urls.filter(isShown)
        guard !inFolder.isEmpty else { return }
        readFinderTags(of: inFolder, in: folder, wholeFolder: false)
    }

    private func readFinderTags(of urls: [URL], in folder: URL, wholeFolder: Bool) {
        finderTagRead?.cancel.cancel()
        let cancel = CancellationFlag()
        finderTagRead = (cancel, wholeFolder)
        let byPath = snapshot?.keysByPath ?? false, source = sourceGeneration
        finderTagWork = Task { [weak self] in
            // Extended attribute reads block: on GCD (BlockingWork), with a
            // flag in place of task cancellation.
            let tags = await BlockingWork.run(qos: wholeFolder ? .utility : .userInitiated) {
                () -> [String: [FinderTag]]? in
                var tags: [String: [FinderTag]] = [:]
                for (index, url) in urls.enumerated() {
                    if index % 128 == 0, cancel.isCancelled { return nil }
                    let found = FinderTag.read(from: url)
                    if !found.isEmpty { tags[FolderSnapshot.key(of: url, byPath: byPath)] = found }
                }
                return tags
            }
            guard let self, !cancel.isCancelled else { return }
            if self.finderTagRead?.cancel === cancel { self.finderTagRead = nil }
            guard let tags, source == self.sourceGeneration else { return }
            if wholeFolder {
                self.applyFinderTags(tags)
            } else {
                var merged = self.finderTags
                for url in urls {
                    let key = FolderSnapshot.key(of: url, byPath: byPath)
                    merged[key] = tags[key]
                }
                self.applyFinderTags(merged)
            }
        }
    }

    /// Takes a read's tags into the model: the map, the folder's tags for
    /// the filter menu, and which names changed. False when they are the
    /// tags already held, so the caller can tell the views nothing happened.
    @discardableResult
    private func storeFinderTags(_ tags: [String: [FinderTag]]) -> Bool {
        guard tags != finderTags else { return false }
        var changed = Set<String>()
        for name in Set(tags.keys).union(finderTags.keys) where tags[name] != finderTags[name] { changed.insert(name) }
        finderTags = tags
        cachedSelectedLabel = nil
        var seen = Set<String>()
        finderTagsInFolder = tags.values.joined()
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        changedMarkNames = changed
        return true
    }

    private func applyFinderTags(_ tags: [String: [FinderTag]]) {
        guard storeFinderTags(tags) else { return }
        if marksFilter.finderTag != nil || metadataFilter.colorLabel != nil {
            applyFilter()
            onChange?([.marks, .entries, .selection])
        } else {
            onChange?(.marks)
        }
    }

    /// Whether the folder has an image of this name, shown or filtered out.
    /// A list from many folders (G3) has no folder to ask about.
    func containsImage(named name: String) -> Bool {
        guard snapshot?.keysByPath != true else { return false }
        return containsImage(key: name)
    }

    /// Whether the listing holds this image, shown or filtered out.
    private func containsImage(key: String) -> Bool {
        if imageKeySet == nil { imageKeySet = Set(snapshot?.imageKeys ?? []) }
        return imageKeySet?.contains(key) ?? false
    }

    /// Whether `url` is one of the files this listing holds: a child of the
    /// folder, or in a list from many folders, one of its images.
    private func isShown(_ url: URL) -> Bool {
        guard let snapshot else { return false }
        return snapshot.keysByPath ? containsImage(key: url.path)
            : Self.samePath(url.deletingLastPathComponent(), snapshot.folder)
    }

    /// What the model knows `url` by: its name, or its path in a list from
    /// many folders (G3). The grid matches `changedMarkNames` with it.
    func key(_ url: URL) -> String { FolderSnapshot.key(of: url, byPath: snapshot?.keysByPath ?? false) }
    func key(of entry: FolderEntry) -> String {
        FolderSnapshot.key(of: entry, byPath: snapshot?.keysByPath ?? false)
    }

    func marks(for url: URL) -> Catalog.Marks { marks[key(url)] ?? .none }
    func finderTags(for url: URL) -> [FinderTag] { finderTags[key(url)] ?? [] }

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
    ///
    /// Decided on the catalog's queue, after any write still queued, as the
    /// compare window does: the marks on screen may not show a change made
    /// a moment ago yet, so a quick T T would tag twice.
    func toggleTag(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let catalog = self.catalog, cache = self.fileMarksCache
        Self.catalogWrites.async {
            let rows = catalog.marks(for: urls)
            let allTagged = urls.allSatisfy { url in
                // What the grid shows: the row's marks, else the file's own
                // once read.
                let shown = rows[url] ?? ((cache?.cachedMarks(for: url) ?? nil) ?? nil)
                return shown?.isTagged == true
            }
            catalog.setTagged(!allTagged, for: urls)
        }
    }

    /// Custom Order: moves images to just before `target` (the end for nil)
    /// and stores the folder's new arrangement. Hidden images keep their
    /// places relative to the rest.
    func moveImages(_ urls: [URL], before target: URL?) {
        guard sortOrder.key == .custom, let snapshot, !snapshot.keysByPath, let folder else { return }
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
        let changing = Perf.begin("browser.catalogChanged")
        defer { changing.end() }
        if isListing { catalogChangesDuringListing += urls }
        guard let snapshot, state == .loaded else { return }
        var files: [URL] = []
        var orderChanged = false
        for url in urls {
            if !snapshot.keysByPath, Self.samePath(url, snapshot.folder) {
                orderChanged = true
            } else if isShown(url) {
                files.append(url)
            }
        }
        // A list watches no folder: a file the viewer or Compare trashed or
        // moved (the catalog names both of its paths) leaves it here.
        if list != nil {
            let gone = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !gone.isEmpty {
                removeEntries(Set(gone))
                files.removeAll { gone.contains($0) }
            }
        }
        var changed = Set<String>()
        var unread: [URL] = []
        if !files.isEmpty {
            // Marking a file is a moment the user is looking at it: its
            // Finder tags may have changed too, unseen by the watcher.
            refreshFinderTags(of: files)
            let fresh = catalog.marks(for: files)
            for url in files {
                let name = key(url)
                catalogRows[name] = fresh[url]
                // Without a row, what the file carries shows; read it if
                // that isn't known yet.
                if fresh[url] == nil, !fileMarksKnown.contains(name) { unread.append(url) }
                if updateShownMarks(of: name) { changed.insert(name) }
            }
        }
        wantFileMarks(for: unread)
        marksChanged(changed, orderChanged: orderChanged, movesSelection: true)
    }

    /// Recomputes what `name` shows from its row and its own marks; true
    /// when that changed.
    private func updateShownMarks(of name: String) -> Bool {
        let value = catalogRows[name] ?? fileMarks[name] ?? .none
        guard (marks[name] ?? .none) != value else { return false }
        marks[name] = value == .none ? nil : value
        return true
    }

    /// Redoes only what changed marks affect: the cells, the filter, or the
    /// order. `movesSelection`: a mark the user set that hides everything
    /// selected moves the selection on; marks arriving from the files don't.
    private func marksChanged(_ changed: Set<String>, orderChanged: Bool = false, movesSelection: Bool) {
        let resorts = (!changed.isEmpty && sortOrder.key == .rating) || (orderChanged && sortOrder.key == .custom)
        let refilters = !changed.isEmpty && marksFilter.isActive
        guard !changed.isEmpty || resorts else { return }
        changedMarkNames = changed

        // A mark that hides everything selected moves the selection on, as
        // the Trash does, so culling with a filter up keeps going.
        var next: URL?
        if movesSelection, refilters, !selection.isEmpty {
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

    // MARK: - Marks the files carry (G2)

    /// The grid shows these images, or is about to: the marks they carry
    /// themselves (`xmp:Rating` from Lightroom, Bridge or a camera, embedded
    /// or in a sidecar) are read, unless the catalog has a row for them,
    /// whose marks win, or they are known already. Off the main thread, at
    /// utility priority, together with the other cells of the same layout
    /// pass, in turn after reads already asked for: browsing never waits
    /// for them, and they arrive with the thumbnails.
    func wantFileMarks(for urls: [URL]) {
        guard fileMarksCache != nil, state == .loaded else { return }
        for url in urls {
            let name = key(url)
            guard catalogRows[name] == nil, !fileMarksKnown.contains(name), containsImage(key: name) else { continue }
            fileMarksKnown.insert(name)
            fileMarksWanted.append(url)
        }
        guard !fileMarksWanted.isEmpty, !fileMarksReadIsScheduled else { return }
        fileMarksReadIsScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.readWantedFileMarks() } }
    }

    private var fileMarksReadIsScheduled = false

    /// Sorting by rating and the rating and tag filters need every image's
    /// marks, so then the whole folder's are read, in the background, a
    /// chunk at a time, the order and filter following as they arrive.
    private func readEveryFileMarksIfNeeded() {
        guard state == .loaded, let snapshot else { return }
        let filter = marksFilter
        guard sortOrder.key == .rating || filter.minimumRating > 0 || filter.taggedOnly else { return }
        wantFileMarks(for: snapshot.entries.filter { !$0.isDirectory }.map(\.url))
    }

    /// Reads what was asked for, in chunks, each applied as it arrives.
    private func readWantedFileMarks() {
        fileMarksReadIsScheduled = false
        guard let cache = fileMarksCache, !fileMarksWanted.isEmpty else { return }
        let wanted = fileMarksWanted
        fileMarksWanted = []
        let cancel = fileMarksCancel
        let byPath = snapshot?.keysByPath ?? false, source = sourceGeneration
        let previous = fileMarksWork
        fileMarksWork = Task { [weak self] in
            await previous?.value
            for start in stride(from: 0, to: wanted.count, by: Self.fileMarksChunk) {
                let chunk = Array(wanted[start..<min(start + Self.fileMarksChunk, wanted.count)])
                // Header reads block: on GCD (BlockingWork), with a flag in
                // place of task cancellation.
                let read = await BlockingWork.run(qos: .utility) { () -> [String: Catalog.Marks?]? in
                    let chunkRead = Perf.begin("folder.fileMarksChunk")
                    defer { chunkRead.end() }
                    var read: [String: Catalog.Marks?] = [:]
                    for url in chunk {
                        if cancel.isCancelled { return nil }
                        read[FolderSnapshot.key(of: url, byPath: byPath)] = .some(cache.marks(for: url))
                    }
                    return read
                }
                guard let self, let read, !cancel.isCancelled, source == self.sourceGeneration else { return }
                self.applyFileMarks(read)
            }
        }
    }

    /// Images read per hop to the main actor: enough that a big folder
    /// isn't re-sorted for every few files, few enough that the first
    /// cells' stars come quickly.
    nonisolated static let fileMarksChunk = 200

    private func applyFileMarks(_ read: [String: Catalog.Marks?]) {
        var changed = Set<String>()
        for (name, value) in read {
            fileMarks[name] = value
            if updateShownMarks(of: name) { changed.insert(name) }
        }
        marksChanged(changed, movesSelection: false)
    }

    // MARK: - Metadata for the filter (G3)

    /// The metadata filter needs headers the model hasn't read: those of
    /// every image of the type it shows are read in the background, at
    /// utility priority, through the catalog's cache (a second visit reads
    /// nothing), a chunk at a time, the grid filling in as they arrive. A
    /// new folder, list or listing cancels it.
    private func readFilterMetadataIfNeeded() {
        guard metadataFilter.needsMetadata, state == .loaded, !isListing, let snapshot else { return }
        let criteria = metadataFilter
        let wanted = snapshot.entries.filter { entry in
            !entry.isDirectory && criteria.passesType(entry.url) && filterMetadata[key(of: entry)] == nil
        }
        guard !wanted.isEmpty else { return }
        filterMetadataCancel.cancel()
        let cancel = CancellationFlag()
        filterMetadataCancel = cancel
        let catalog = self.catalog, byPath = snapshot.keysByPath, source = sourceGeneration
        filterMetadataWork = Task { [weak self] in
            for start in stride(from: 0, to: wanted.count, by: Self.filterMetadataChunk) {
                let chunk = Array(wanted[start..<min(start + Self.filterMetadataChunk, wanted.count)])
                let read = await BlockingWork.run(qos: .utility) { () -> [String: FilterMetadata]? in
                    let chunkRead = Perf.begin("folder.metadataChunk")
                    defer { chunkRead.end() }
                    let found = catalog.loadFilterMetadata(for: chunk, isCancelled: { cancel.isCancelled })
                    guard !cancel.isCancelled else { return nil }
                    var byKey: [String: FilterMetadata] = [:]
                    for (url, metadata) in found { byKey[FolderSnapshot.key(of: url, byPath: byPath)] = metadata }
                    return byKey
                }
                guard let self, let read, !cancel.isCancelled, source == self.sourceGeneration else { return }
                self.filterMetadata.merge(read) { $1 }
                self.applyFilter()
                self.onChange?([.entries, .selection])
            }
        }
    }

    /// Images read per hop to the main actor, as for the files' marks.
    nonisolated static let filterMetadataChunk = 200

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
        case FolderListingError.notPermitted(let url):
            // Most often Go > Enclosing Folder past the folder the user
            // opened, or a Back to one whose access has since gone.
            "minivu doesn’t have permission to open “\(url.lastPathComponent)”. To give it access, "
                + "choose File > Open Folder… and select the folder."
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
        let filtering = Perf.begin("folder.applyFilter")
        defer { filtering.end() }
        guard let snapshot else {
            entries = []
            visibleKeys = []
            indexByKey = [:]
            imageCount = 0
            videoCount = 0
            folderCount = 0
            pruneSelection()
            return
        }
        let query = Self.searchKey(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        let marksFilter = self.marksFilter, criteria = metadataFilter
        let standardNames = criteria.colorLabel == nil ? [:] : ColorLabelCommand.standardNames
        if query.isEmpty, !marksFilter.isActive, !criteria.isActive {
            entries = snapshot.entries
            visibleKeys = snapshot.searchKeys
        } else {
            let keep = snapshot.searchKeys.indices.filter { i in
                if !query.isEmpty, !snapshot.searchKeys[i].contains(query) { return false }
                let entry = snapshot.entries[i]
                let key = snapshot.keysByPath ? entry.url.path : entry.name
                if marksFilter.isActive,
                   !marksFilter.passes(entry, marks: marks[key] ?? .none, finderTags: finderTags[key] ?? []) { return false }
                guard criteria.isActive, !entry.isDirectory else { return true }
                let label = criteria.colorLabel == nil ? ColorLabel.none
                    : ColorLabelCommand.label(of: finderTags[key] ?? [], standardNames: standardNames)
                return criteria.passes(entry.url, metadata: filterMetadata[key], label: label)
            }
            entries = keep.map { snapshot.entries[$0] }
            visibleKeys = keep.map { snapshot.searchKeys[$0] }
        }
        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        // `name` is already a String; asking each URL for its last component
        // would cost a string conversion per file on every keystroke.
        if snapshot.keysByPath {
            for (i, entry) in entries.enumerated() { index[entry.url.path] = i }
        } else {
            for (i, entry) in entries.enumerated() { index[entry.name] = i }
        }
        indexByKey = index
        folderCount = entries.prefix { $0.isDirectory }.count
        imageCount = entries.count - folderCount
        videoCount = entries.reduce(0) { $0 + ($1.kind == .video ? 1 : 0) }
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
    func index(of url: URL) -> Int? { indexByKey[key(url)] }

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

    /// What the selected images' marks have in common.
    struct SelectionMarks: Equatable {
        /// The rating every selected image has; nil when they differ or no
        /// image is selected.
        var sharedRating: Int?
        /// Whether there are selected images and every one is tagged.
        var allTagged: Bool
    }

    /// The Rating and Tag menu checkmarks' answer. Menu validation asks once
    /// per item (six ratings and the tag) on every menu update, so it is
    /// worked out once, without sorting the selection, and kept until the
    /// selection, the entries or the marks change.
    var selectedMarks: SelectionMarks {
        if let cachedSelectedMarks { return cachedSelectedMarks }
        var rating: Int?, mixed = false, allTagged = true, any = false
        for url in selection {
            guard let entry = entry(for: url), !entry.isDirectory else { continue }
            let value = marks[key(of: entry)] ?? .none
            if !any { rating = value.rating } else if rating != value.rating { mixed = true }
            allTagged = allTagged && value.isTagged
            any = true
        }
        let result = SelectionMarks(sharedRating: any && !mixed ? rating : nil, allTagged: any && allTagged)
        cachedSelectedMarks = result
        return result
    }
    private var cachedSelectedMarks: SelectionMarks?

    /// The colour label every selected image has (G4), the Label menu's
    /// checkmark; nil when they differ or no image is selected. Kept like
    /// `selectedMarks`, until the selection, the entries or the tags change.
    var selectedLabel: ColorLabel? {
        if let cachedSelectedLabel { return cachedSelectedLabel }
        let tags = selection.compactMap { url -> [FinderTag]? in
            guard let entry = entry(for: url), !entry.isDirectory else { return nil }
            return finderTags[key(of: entry)] ?? []
        }
        let result = tags.isEmpty ? nil : ColorLabelCommand.sharedLabel(tags, standardNames: ColorLabelCommand.standardNames)
        cachedSelectedLabel = .some(result)
        return result
    }
    private var cachedSelectedLabel: ColorLabel??

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
    /// than waiting for the watcher's reload to notice. A folder's entries
    /// are found by name, so only an entry at the very path given goes: a
    /// namesake in a subfolder (a duplicate trashed from Find Duplicates)
    /// leaves the shown folder's own file in place.
    /// A list of fixed files (a Duplicates group, `.files`) keeps the files
    /// minivu itself renamed or moved, here and in Back and Forward: it is
    /// read again from its paths, and would otherwise drop them.
    func followMoves(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        var moved: [String: URL] = [:]
        for move in moves { moved[move.from.standardizedFileURL.path] = move.to }
        func follow(_ list: VirtualList?) -> VirtualList? {
            guard var list, case .files(let urls) = list.kind else { return list }
            list.kind = .files(urls.map { moved[$0.standardizedFileURL.path] ?? $0 })
            return list
        }
        func follow(_ location: Location) -> Location {
            var location = location
            location.list = follow(location.list)
            return location
        }
        list = follow(list)
        backStack = backStack.map(follow)
        forwardStack = forwardStack.map(follow)
    }

    func removeEntries(_ urls: Set<URL>) {
        let matched = Set(urls.compactMap { url in entry(for: url).flatMap { Self.samePath($0.url, url) ? $0.url : nil } })
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
        guard let target = entry(for: url), let index = images.firstIndex(where: { $0.url == target.url })
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

    /// Window subtitle: "123 images, 2 videos, 4 folders".
    var subtitle: String {
        guard state == .loaded else { return "" }
        return Self.countText(images: imageCount, videos: videoCount, folders: folderCount)
    }

    /// `images` counts every file shown, `videos` those of them that are
    /// videos (G18), which are named as such rather than counted as images.
    nonisolated static func countText(images: Int, videos: Int = 0, folders: Int) -> String {
        var parts: [String] = []
        let stills = images - videos
        if stills > 0 || (videos == 0 && folders == 0) {
            parts.append(stills == 1 ? "1 image" : "\(stills.formatted()) images")
        }
        if videos > 0 { parts.append(videos == 1 ? "1 video" : "\(videos.formatted()) videos") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders.formatted()) folders") }
        return parts.joined(separator: ", ")
    }

    /// Status bar: "12 of 340 selected — 84.1 MB", or the counts when
    /// nothing is selected.
    nonisolated static func selectionText(selected: Int, total: Int, bytes: Int64, images: Int, videos: Int = 0,
                                          folders: Int) -> String {
        guard selected > 0 else { return countText(images: images, videos: videos, folders: folders) }
        let count = "\(selected.formatted()) of \(total.formatted()) selected"
        return bytes > 0 ? "\(count) — \(bytes.formatted(.byteCount(style: .file)))" : count
    }

    /// Status bar: the selection, or "12 of 340 shown" while a search or a
    /// filter hides some of the folder.
    ///
    /// A tree or list (G3) says while it is still being read, and when a
    /// walk limit stopped it, so a short list is never taken for all there is.
    var statusText: String {
        guard state == .loaded else { return state == .loading && showsManyFolders ? "Searching…" : "" }
        let text: String
        if selection.isEmpty, isFiltering {
            text = Self.shownText(shown: entries.count, total: totalCount)
        } else {
            text = Self.selectionText(selected: selection.count, total: entries.count, bytes: selectedBytes,
                                      images: imageCount, videos: videoCount, folders: folderCount)
        }
        guard showsManyFolders else { return text }
        if isListing { return text + " — searching…" }
        return isTruncated ? text + Self.truncatedNote : text
    }

    /// After the status of a tree or list that a walk limit stopped
    /// (`TreeEnumerator.Limits`: 12 levels, 20,000 images, 5,000 folders).
    nonisolated static let truncatedNote = " — limit reached, not every image is shown"

    /// A search or a marks or metadata filter is narrowing the folder.
    var isFiltering: Bool {
        marksFilter.isActive || metadataFilter.isActive || !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func shownText(shown: Int, total: Int) -> String {
        "\(shown.formatted()) of \(total.formatted()) shown"
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
