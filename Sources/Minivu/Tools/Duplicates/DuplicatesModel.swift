import AppKit
import MinivuCore

/// Where Tools > Find Duplicates… looks (G5).
enum DuplicateScope: String, CaseIterable, Identifiable, Sendable {
    /// The images selected in the browser.
    case selection
    /// The folder shown, without its subfolders; for a list the browser
    /// shows instead of a folder (search results, a collection), its images.
    case folder
    /// The folder shown and every folder below it, within the walk's limits.
    case folderAndSubfolders

    var id: String { rawValue }
}

/// What the browser offers the finder, gathered on the main actor when the
/// window opens.
nonisolated struct DuplicateSource: Sendable {
    var selection: [FolderEntry]
    /// The folder shown; nil while the browser shows a list.
    var folder: URL?
    /// The images of the list the browser shows instead of a folder.
    var listImages: [FolderEntry]?
    var includeHidden: Bool

    init(selection: [FolderEntry], folder: URL?, listImages: [FolderEntry]? = nil, includeHidden: Bool = false) {
        self.selection = selection
        self.folder = folder
        self.listImages = listImages
        self.includeHidden = includeHidden
    }

    /// The scopes that have something to look at.
    var scopes: [DuplicateScope] {
        var scopes: [DuplicateScope] = []
        if !selection.isEmpty { scopes.append(.selection) }
        if folder != nil || listImages != nil { scopes.append(.folder) }
        if folder != nil { scopes.append(.folderAndSubfolders) }
        return scopes
    }

    func title(of scope: DuplicateScope) -> String {
        switch scope {
        case .selection: "Selected Images (\(selection.count))"
        case .folder:
            if let folder { "“\(FileManager.default.displayName(atPath: folder.path))”" } else { "Images Shown" }
        case .folderAndSubfolders: "“\(folder.map { FileManager.default.displayName(atPath: $0.path) } ?? "")” and Subfolders"
        }
    }
}

/// One group of the results: two or more files with the same bytes, or
/// pictures that look alike.
struct DuplicateGroup: Identifiable, Equatable {
    var files: [FolderEntry]
    /// The first file's path: stable while the threshold moves, so the list
    /// keeps its place.
    var id: String { files.first?.url.path ?? "" }
}

/// The duplicate finder's state (G5): the choices, the run, the groups and
/// the files marked for the Trash. The window shows it and the controller
/// acts on it; nothing here deletes a file.
@MainActor @Observable final class DuplicatesModel {
    enum State: Equatable {
        case ready
        case running(DuplicateFinder.Progress?)
        case finished
    }

    /// What one run looks at and for.
    nonisolated struct Request: Sendable {
        var source: DuplicateSource
        var scope: DuplicateScope
        var mode: DuplicateFinder.Mode
        var maximumSimilarImages: Int
        var workers: Int
        /// Where fingerprints are cached, and thumbnails read from.
        var store: ThumbnailStore?
    }

    /// What a run found.
    nonisolated struct Outcome: Sendable {
        var mode: DuplicateFinder.Mode
        var exactGroups: [[FolderEntry]] = []
        /// The images whose prints were compared, in the index's order.
        var similarImages: [FolderEntry] = []
        var index: SimilarityIndex?
        var pixelSizes: [URL: CGSize] = [:]
        /// Images looked at.
        var scanned = 0
        /// Why not every image was compared: a walk limit, the memory limit.
        var note: String?
        var isCancelled = false
    }

    /// Runs a request: `DuplicatesModel.find` normally; tests pass their own.
    typealias Engine = @Sendable (Request, CancellationFlag, @escaping @Sendable (DuplicateFinder.Progress) -> Void) -> Outcome

    private(set) var source: DuplicateSource
    var scope: DuplicateScope
    var mode: DuplicateFinder.Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// The Vision distance under which two pictures count as alike.
    var threshold: Float = SimilarityIndex.defaultThreshold {
        didSet {
            guard threshold != oldValue else { return }
            defaults.set(Double(threshold), forKey: Self.thresholdKey)
            regroup()
        }
    }
    var keepRule: KeepRule {
        didSet { defaults.set(keepRule.rawValue, forKey: Self.keepRuleKey) }
    }

    private(set) var state: State = .ready
    private(set) var groups: [DuplicateGroup] = []
    /// Marked for the Trash by the user (or by Mark Suggested, at the user's word).
    var marked: Set<URL> = []
    /// The rows selected in the list.
    var selection: Set<URL> = []
    private(set) var pixelSizes: [URL: CGSize] = [:]
    private(set) var note: String?
    private(set) var scanned = 0
    /// The mode of the results shown, which the picker may since have left.
    private(set) var resultMode: DuplicateFinder.Mode?

    private var outcome: Outcome?
    /// Trashed since the run: left out however the threshold moves.
    private var removed: Set<URL> = []
    private var cancel: CancellationFlag?
    private var generation = 0
    private let engine: Engine
    private let store: ThumbnailStore?
    /// Where the mode, threshold and keep rule are remembered.
    @ObservationIgnored private let defaults: UserDefaults

    static let modeKey = "DuplicatesMode"
    static let thresholdKey = "DuplicatesThreshold"
    static let keepRuleKey = "DuplicatesKeepRule"

    /// - Parameter store: the thumbnail database, where fingerprints are
    ///   cached; tests pass one in memory.
    init(source: DuplicateSource, store: ThumbnailStore? = AppServices.thumbnailStore,
         defaults: UserDefaults = .standard, engine: @escaping Engine = DuplicatesModel.find) {
        self.source = source
        self.store = store
        self.engine = engine
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(DuplicateFinder.Mode.init(rawValue:)) ?? .exact
        keepRule = defaults.string(forKey: Self.keepRuleKey).flatMap(KeepRule.init(rawValue:)) ?? .highestResolution
        if let stored = defaults.object(forKey: Self.thresholdKey) as? Double {
            threshold = min(max(Float(stored), SimilarityIndex.thresholdRange.lowerBound),
                            SimilarityIndex.thresholdRange.upperBound)
        }
        scope = source.scopes.first ?? .folder
    }

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// Points the window at what the browser shows now. A run under way is
    /// left alone; the next Find uses the new source.
    func retarget(_ source: DuplicateSource) {
        self.source = source
        if !source.scopes.contains(scope) { scope = source.scopes.first ?? .folder }
    }

    // MARK: - Running

    func start() {
        guard !isRunning, source.scopes.contains(scope) else { return }
        cancel?.cancel()
        let flag = CancellationFlag()
        cancel = flag
        generation += 1
        let run = generation
        let request = Request(source: source, scope: scope, mode: mode,
                              maximumSimilarImages: DuplicateFinder.maximumSimilarImages(),
                              workers: DuplicateFinder.analysisWorkers(), store: store)
        state = .running(nil)
        groups = []
        marked = []
        selection = []
        note = nil
        removed = []
        let relay = ProgressRelay { [weak self] progress in
            guard let self, self.generation == run, self.isRunning else { return }
            self.state = .running(progress)
        }
        let engine = self.engine
        Task {
            let outcome = await BlockingWork.run(qos: .userInitiated) { engine(request, flag, relay.report) }
            guard self.generation == run else { return }
            self.show(outcome)
        }
    }

    /// Stops the run; what it found so far is shown.
    func stop() {
        cancel?.cancel()
    }

    /// The window is closing: nothing more is shown.
    func abandon() {
        cancel?.cancel()
        generation += 1
    }

    private func show(_ outcome: Outcome) {
        self.outcome = outcome
        resultMode = outcome.mode
        pixelSizes = outcome.pixelSizes
        scanned = outcome.scanned
        note = outcome.isCancelled ? "Stopped before the end: only the images compared so far are grouped." : outcome.note
        state = .finished
        regroup()
    }

    /// The groups at the current threshold, without trashed files.
    func regroup() {
        guard let outcome else { return }
        let found: [[FolderEntry]] = switch outcome.mode {
        case .exact: outcome.exactGroups
        case .similar:
            outcome.index?.groups(threshold: threshold).map { $0.map { outcome.similarImages[$0] } } ?? []
        }
        groups = found.map { $0.filter { !removed.contains($0.url) } }.filter { $0.count > 1 }
            .map { DuplicateGroup(files: $0) }
        let shown = Set(groups.flatMap { $0.files.map(\.url) })
        marked.formIntersection(shown)
        selection.formIntersection(shown)
    }

    // MARK: - Marks

    /// The file the keep rule suggests keeping in `group`.
    func keeper(of group: DuplicateGroup) -> URL? {
        keepRule.keeper(of: group.files, pixelSizes: pixelSizes)?.url
    }

    /// Marks every file but each group's suggested keeper, replacing the
    /// marks there were. Never marks a whole group.
    func markSuggested() {
        marked = Set(groups.flatMap { group -> [URL] in
            let keep = keeper(of: group)
            return group.files.map(\.url).filter { $0 != keep }
        })
    }

    func clearMarks() {
        marked = []
    }

    func setMarked(_ url: URL, _ isMarked: Bool) {
        if isMarked { marked.insert(url) } else { marked.remove(url) }
    }

    /// The marked files in list order.
    var markedFiles: [FolderEntry] {
        groups.flatMap { $0.files.filter { marked.contains($0.url) } }
    }

    /// Groups every one of whose files is marked: trashing them keeps no copy.
    var wholeGroupsMarked: Int {
        groups.filter { $0.files.allSatisfy { marked.contains($0.url) } }.count
    }

    /// The selected rows in list order.
    var selectedFiles: [FolderEntry] {
        groups.flatMap { $0.files.filter { selection.contains($0.url) } }
    }

    var allFiles: [FolderEntry] { groups.flatMap(\.files) }

    /// Files gone to the Trash leave the groups (a group left with one
    /// file leaves the list) and stay out whatever the threshold.
    func didTrash(_ urls: Set<URL>) {
        removed.formUnion(urls)
        marked.subtract(urls)
        regroup()
    }

    // MARK: - The search itself

    /// Lists what the request covers and finds its groups. Blocking: the
    /// model runs it on a GCD thread.
    nonisolated static func find(_ request: Request, cancel: CancellationFlag,
                                 progress: @escaping @Sendable (DuplicateFinder.Progress) -> Void) -> Outcome {
        var outcome = Outcome(mode: request.mode)
        var images: [FolderEntry]
        let source = request.source
        switch request.scope {
        case .selection:
            images = source.selection
        case .folder, .folderAndSubfolders:
            if let folder = source.folder {
                let limits = request.scope == .folder
                    ? TreeEnumerator.Limits(maximumDepth: 0, maximumImages: TreeEnumerator.Limits.standard.maximumImages,
                                            maximumFolders: 1)
                    : .standard
                guard let walk = try? TreeEnumerator.images(under: folder, includeHidden: source.includeHidden,
                                                            limits: limits, isCancelled: { cancel.isCancelled })
                else { return outcome }
                images = walk.images
                if walk.isTruncated { outcome.note = "A folder limit was reached: not every image was compared." }
            } else {
                images = source.listImages ?? []
            }
        }
        images = images.filter { !$0.isDirectory }
        outcome.scanned = images.count
        let store = request.store
        defer { store?.pruneFingerprints() }
        switch request.mode {
        case .exact:
            outcome.exactGroups = DuplicateFinder.exactGroups(in: images, cache: store,
                                                              isCancelled: { cancel.isCancelled }, progress: progress)
            outcome.pixelSizes = DuplicateFinder.pixelSizes(of: outcome.exactGroups.flatMap { $0 })
        case .similar:
            if images.count > request.maximumSimilarImages {
                images = Array(images.prefix(request.maximumSimilarImages))
                outcome.note = "Only the first \(request.maximumSimilarImages.formatted()) images were compared, "
                    + "to keep memory in hand."
            }
            let prints = DuplicateFinder.featurePrints(for: images, store: store, workers: request.workers,
                                                       isCancelled: { cancel.isCancelled }, progress: progress)
            let compared = images.filter { prints[$0.url] != nil }
            let index = SimilarityIndex(prints: compared.map { prints[$0.url]! },
                                        maximumDistance: SimilarityIndex.thresholdRange.upperBound,
                                        isCancelled: { cancel.isCancelled }) { done, total in
                progress(DuplicateFinder.Progress(phase: .grouping, done: done, total: total))
            }
            outcome.similarImages = compared
            outcome.index = index
            // Sizes of the images in any pair: every one that some threshold can show.
            let paired = Set(index.pairs.flatMap { [$0.first, $0.second] })
            outcome.pixelSizes = DuplicateFinder.pixelSizes(of: paired.sorted().map { compared[$0] })
        }
        outcome.isCancelled = cancel.isCancelled
        return outcome
    }
}

/// Hands a background run's progress to the main actor without flooding
/// it: a report is posted when the phase changes, at the end, or each
/// hundredth of the way, and only the newest waiting report is shown.
nonisolated final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last: DuplicateFinder.Progress?
    private let show: @MainActor (DuplicateFinder.Progress) -> Void

    init(show: @escaping @MainActor (DuplicateFinder.Progress) -> Void) {
        self.show = show
    }

    func report(_ progress: DuplicateFinder.Progress) {
        let post = lock.withLock { () -> Bool in
            let step = max(1, progress.total / 100)
            let due = last?.phase != progress.phase || progress.done >= progress.total
                || progress.done - (last?.done ?? 0) >= step
            if due { last = progress }
            return due
        }
        guard post else { return }
        let show = self.show
        DispatchQueue.main.async { MainActor.assumeIsolated { show(progress) } }
    }
}
