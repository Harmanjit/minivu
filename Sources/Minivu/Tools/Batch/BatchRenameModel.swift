import Foundation
import Observation
import MinivuCore

/// The state of the Batch Rename sheet: the pattern being edited and the
/// live before → after plan for it.
///
/// The plan is worked out off the main thread (`RenamePlanner` reads the
/// disk: one `lstat` per name), newest pattern wins: a plan made for a
/// pattern that has changed since is dropped. Small batches plan at once;
/// big ones wait for a short pause in typing, so each keystroke in a
/// 5000-file batch doesn't start a plan. The date taken and pixel size are
/// read from the files only when the pattern first uses them, several
/// files at a time, and kept for the life of the sheet.
@MainActor @Observable final class BatchRenameModel {
    let entries: [FolderEntry]
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let probe: BatchFileProbe

    var pattern: RenamePattern {
        didSet { if pattern != oldValue { schedulePlan() } }
    }

    /// The plan for `pattern`, once worked out.
    private(set) var plan: RenamePlan?
    /// Whether `plan` is for the current pattern.
    private(set) var isPlanCurrent = false
    private(set) var isRenaming = false

    /// Batches at least this big wait for a pause in typing before planning.
    static let debounceThreshold = 300
    static let debounce: Duration = .milliseconds(150)

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var planTask: Task<Void, Never>?
    /// Reads every file's date taken and size, once, the first time a
    /// pattern needs them; later plans wait for the same read.
    @ObservationIgnored private var metadataTask: Task<[RenameSource], Never>?
    /// For tests: the plan in flight.
    @ObservationIgnored private(set) var planWork: Task<Void, Never>?

    init(entries: [FolderEntry], store: BatchStore = BatchStore(), probe: BatchFileProbe = .system) {
        self.entries = entries
        self.store = store
        self.probe = probe
        pattern = store.renamePattern
        schedulePlan()
    }

    var sources: [RenameSource] {
        entries.map { RenameSource(url: $0.url, modified: $0.modified) }
    }

    func schedulePlan() {
        generation += 1
        isPlanCurrent = false
        let generation = self.generation
        let pattern = self.pattern
        let probe = self.probe
        let plain = sources
        if pattern.needsImageMetadata && metadataTask == nil {
            metadataTask = Task { await BlockingWork.run { RenameSource.withImageMetadata(plain) } }
        }
        let metadata = pattern.needsImageMetadata ? metadataTask : nil
        let delay = entries.count >= Self.debounceThreshold && plan != nil
        planTask?.cancel()
        let task = Task { [weak self] in
            if delay {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            let input = await metadata?.value ?? plain
            guard !Task.isCancelled else { return }
            let plan = await BlockingWork.run { RenamePlanner.plan(input, pattern: pattern, probe: probe) }
            guard let self, generation == self.generation else { return }
            self.plan = plan
            self.isPlanCurrent = true
        }
        planTask = task
        planWork = task
    }

    /// Can the Rename button be pressed.
    var canRename: Bool {
        isPlanCurrent && !isRenaming && plan?.canRename == true
    }

    /// The requests for the plan's changes, remembering the pattern.
    func beginRenaming() -> [BatchRenamer.Request]? {
        guard canRename, let plan else { return nil }
        isRenaming = true
        store.renamePattern = pattern
        return plan.changes.map { BatchRenamer.Request(url: $0.source, newName: $0.newName) }
    }

    func renamingEnded() {
        isRenaming = false
    }

    /// The line under the list: what will happen, or the first thing in the way.
    var statusText: String {
        guard let plan else { return "Checking names…" }
        if !plan.unknownTokens.isEmpty {
            let list = plan.unknownTokens.prefix(3).joined(separator: ", ")
            return plan.unknownTokens.count == 1
                ? "The pattern has an unknown token: \(list)."
                : "The pattern has unknown tokens: \(list)."
        }
        let problems = plan.problemCount
        if problems > 0 {
            let first = plan.items.first { $0.problem != nil }?.problem
            let sameKind = plan.items.lazy.filter { Self.sameKind($0.problem, first) }.count
            let files = sameKind == 1 ? "1 file" : "\(sameKind.formatted()) files"
            switch first {
            case .duplicate: return "\(files) would share a name with another file. Every file needs a name of its own."
            case .taken: return "\(files) would take the name of an item that isn’t being renamed."
            case .missing: return "\(files) can’t be found any more."
            case .invalidName(let reason): return "\(files) can’t have the new name: \(reason)"
            case nil: return ""
            }
        }
        let changes = plan.changeCount
        if changes == 0 { return "The names wouldn’t change." }
        let total = plan.items.count
        return changes == total
            ? "\(total == 1 ? "1 file" : "\(total.formatted()) files") will be renamed."
            : "\(changes.formatted()) of \(total.formatted()) files will be renamed; the others keep their names."
    }

    private nonisolated static func sameKind(_ a: RenamePlan.Problem?, _ b: RenamePlan.Problem?) -> Bool {
        switch (a, b) {
        case (.invalidName, .invalidName), (.duplicate, .duplicate), (.taken, .taken), (.missing, .missing): true
        default: false
        }
    }

    var hasProblems: Bool {
        guard let plan else { return false }
        return !plan.unknownTokens.isEmpty || plan.problemCount > 0
    }

    /// "Rename 12 Items": the sheet's title and the Undo menu's.
    nonisolated static func actionName(count: Int) -> String {
        "Rename \(count == 1 ? "1 Item" : "\(count.formatted()) Items")"
    }
}
