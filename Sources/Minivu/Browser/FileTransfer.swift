import AppKit
import MinivuCore

/// Copies or moves files for the browser, the way Finder does: name clashes
/// are settled up front (Replace, Keep Both or Skip, optionally for all),
/// the files go off the main thread one at a time so the job can be
/// cancelled between them, and a progress sheet appears for a big job
/// (more than 20 files) or a slow one (still running after half a second).
final class FileTransfer {
    struct Request {
        var files: [URL]
        var destination: URL
        var isMove: Bool
    }

    struct Outcome {
        var request: Request
        var transfers: [FileOperations.Transfer] = []
        /// Destinations whose old file was replaced.
        var replaced: [URL] = []
        /// The replaced items, now in the Trash: from where they were to
        /// where the Trash put them, so Undo can bring them back.
        var trashed: [FileOperations.Transfer] = []
        var skipped: [URL] = []
        var failed: [(url: URL, message: String)] = []
        var wasCancelled = false
    }

    /// The answer to one name clash, and whether it goes for the rest.
    struct Resolution: Equatable {
        var policy: FileOperations.ConflictPolicy
        var applyToAll: Bool
    }

    /// Asks about one clash: the file, and how many clashes are left
    /// including it. Tests answer without an alert.
    typealias ConflictResolver = @MainActor (_ file: URL, _ remaining: Int) async -> Resolution
    /// Puts an item in the Trash and says where it went (nil: nothing was
    /// there). Tests keep their files out of the user's Trash.
    typealias Trasher = @Sendable (URL) -> Result<URL?, Error>

    static let progressThreshold = 20
    static let progressDelay: Duration = .milliseconds(500)

    /// Runs `request`, asking about clashes with `resolver` (an alert on
    /// `window` when nil) and showing progress on `window`.
    static func run(_ request: Request, window: NSWindow?, resolver: ConflictResolver? = nil,
                    trash: @escaping Trasher = TransferChecks.trash) async -> Outcome {
        var outcome = Outcome(request: request)
        let destination = request.destination
        let isMove = request.isMove

        // What the paths alone can't show: files already in the destination
        // under another spelling of its path (a symbolic link, other case),
        // a folder going into itself, a clash that holds the file itself.
        let preflight = await BlockingWork.run {
            TransferChecks.preflight(request.files, into: destination)
        }
        let files = preflight.files
        let clashing = preflight.clashing
        outcome.failed = preflight.failed

        // Settle every clash before anything moves.
        var plan: [(url: URL, policy: FileOperations.ConflictPolicy)] = []
        var forAll: FileOperations.ConflictPolicy?
        var remaining = clashing.count
        for file in files {
            guard clashing.contains(file) else {
                plan.append((file, .keepBoth))
                continue
            }
            let policy: FileOperations.ConflictPolicy
            if let forAll {
                policy = forAll
            } else {
                let answer = await (resolver ?? { file, remaining in
                    await askAboutConflict(file, remaining: remaining, isMove: request.isMove, window: window)
                })(file, remaining)
                policy = answer.policy
                if answer.applyToAll { forAll = policy }
            }
            remaining -= 1
            if policy == .skip { outcome.skipped.append(file) } else { plan.append((file, policy)) }
        }
        guard !plan.isEmpty else { return outcome }

        let progress = TransferProgress(total: plan.count)
        var sheet: TransferProgressSheet?
        let showSheet = { @MainActor in
            guard sheet == nil, let window, window.attachedSheet == nil, !progress.isFinished else { return }
            let made = TransferProgressSheet(title: progressTitle(count: plan.count, isMove: request.isMove,
                                                                  destination: destination), progress: progress)
            sheet = made
            window.beginSheet(made)
        }
        if plan.count > progressThreshold { showSheet() }
        let delayed = Task { @MainActor in
            try? await Task.sleep(for: progressDelay)
            if !Task.isCancelled { showSheet() }
        }
        progress.onUpdate = { done in
            DispatchQueue.main.async { MainActor.assumeIsolated { sheet?.update(done: done) } }
        }

        let items = plan
        let (result, trashed) = await BlockingWork.run {
            () -> (FileOperations.Result, [FileOperations.Transfer]) in
            var merged = FileOperations.Result()
            var trashed: [FileOperations.Transfer] = []
            for item in items {
                if progress.isCancelled {
                    merged.wasCancelled = true
                    break
                }
                var policy = item.policy
                if policy == .replace {
                    // The old item goes to the Trash rather than away for
                    // good, so Replace can be undone; one that can't be
                    // trashed stays, and the file isn't transferred.
                    let existing = destination.appendingPathComponent(item.url.lastPathComponent)
                    switch trash(existing) {
                    case .success(let place):
                        if let place { trashed.append(FileOperations.Transfer(from: existing, to: place)) }
                        // Something turning up there meanwhile is kept too.
                        policy = .keepBoth
                    case .failure(let error):
                        merged.failed.append((item.url, error.localizedDescription))
                        progress.advance()
                        continue
                    }
                }
                let one = isMove
                    ? FileOperations.move([item.url], to: destination, conflict: policy)
                    : FileOperations.copy([item.url], to: destination, conflict: policy)
                merged.completed += one.completed
                merged.skipped += one.skipped
                merged.failed += one.failed
                progress.advance()
            }
            return (merged, trashed)
        }
        progress.finish()
        delayed.cancel()
        if let sheet, let window { window.endSheet(sheet) }

        let replacing = Set(plan.filter { $0.policy == .replace }.map(\.url))
        outcome.transfers = result.completed
        outcome.replaced = result.completed.filter { replacing.contains($0.from) }.map(\.to)
        outcome.trashed = trashed
        outcome.skipped += result.skipped
        outcome.failed += result.failed
        outcome.wasCancelled = result.wasCancelled
        return outcome
    }

    // MARK: - Alerts

    private static func askAboutConflict(_ file: URL, remaining: Int, isMove: Bool, window: NSWindow?) async -> Resolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(file.lastPathComponent)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re \(isMove ? "moving" : "copying")?"
        // Keep Both is the default: the choice that loses nothing.
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        let skip = alert.addButton(withTitle: "Skip")
        skip.keyEquivalent = "\u{1b}"
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to All"
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let policy: FileOperations.ConflictPolicy = switch response {
        case .alertFirstButtonReturn: .keepBoth
        case .alertSecondButtonReturn: .replace
        default: .skip
        }
        return Resolution(policy: policy, applyToAll: alert.suppressionButton?.state == .on)
    }

    /// "Moving 120 items to “Trip”".
    nonisolated static func progressTitle(count: Int, isMove: Bool, destination: URL) -> String {
        "\(isMove ? "Moving" : "Copying") \(itemsText(count)) to “\(destination.lastPathComponent)”"
    }

    /// "1 item", "3 items".
    nonisolated static func itemsText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    /// Tells the user what couldn't be copied or moved, if anything.
    static func reportFailures(_ outcome: Outcome, on window: NSWindow?) {
        guard !outcome.failed.isEmpty else { return }
        let alert = NSAlert()
        let verb = outcome.request.isMove ? "moved" : "copied"
        if outcome.failed.count == 1, let failure = outcome.failed.first {
            alert.messageText = "“\(failure.url.lastPathComponent)” couldn’t be \(verb)."
            alert.informativeText = failure.message
        } else {
            alert.messageText = "\(itemsText(outcome.failed.count).capitalizedFirst) couldn’t be \(verb)."
            let names = outcome.failed.prefix(8).map(\.url.lastPathComponent)
            alert.informativeText = names.joined(separator: ", ") + (outcome.failed.count > 8 ? "…" : "")
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// How far a transfer has got, shared between the worker and the sheet.
nonisolated final class TransferProgress: @unchecked Sendable {
    let total: Int
    private let lock = NSLock()
    private var done = 0
    private var cancelled = false
    private var finished = false
    /// Called on the worker after each file with the count done. Set before
    /// the work starts.
    var onUpdate: (@Sendable (Int) -> Void)?

    init(total: Int) { self.total = total }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { finished } }
    func cancel() { lock.withLock { cancelled = true } }
    func finish() { lock.withLock { finished = true } }

    func advance() {
        let (count, report) = lock.withLock { () -> (Int, Bool) in
            done += 1
            // At most about a hundred updates, however many files.
            let step = max(1, total / 100)
            return (done, done % step == 0 || done == total)
        }
        if report { onUpdate?(count) }
    }
}

/// The sheet for a long transfer: what is happening, a bar and Cancel.
final class TransferProgressSheet: NSWindow {
    private let bar = NSProgressIndicator()
    private let progress: TransferProgress

    init(title: String, progress: TransferProgress) {
        self.progress = progress
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled],
                   backing: .buffered, defer: false)
        // Owned by Swift; AppKit releasing it too on close would crash.
        isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(progress.total)
        bar.style = .bar
        let cancel = NSButton(title: "Cancel", target: nil, action: #selector(cancelTransfer(_:)))
        cancel.target = self
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel])
        let stack = NSStackView(views: [label, bar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(14, after: bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        contentView = stack
    }

    func update(done: Int) {
        bar.doubleValue = Double(done)
    }

    @objc private func cancelTransfer(_ sender: Any?) {
        progress.cancel()
    }
}

/// File-system checks that keep a transfer from destroying what it moves.
///
/// Paths can't answer these: the same folder has many spellings (through a
/// symbolic link, `/tmp` and `/private/tmp`, another letter case on a
/// case-insensitive volume), so items are compared by file identity.
nonisolated enum TransferChecks {
    struct Preflight {
        /// The files to transfer, in order.
        var files: [URL] = []
        /// Those whose name is taken in the destination.
        var clashing: Set<URL> = []
        /// Files refused outright, with the reason.
        var failed: [(url: URL, message: String)] = []
    }

    /// Sorts `urls` for a transfer into `destination`: files already there
    /// are left out (there is nothing to do), a folder into itself or a
    /// folder inside it is refused, and so is a clash with an item that
    /// contains the file (Replace would delete the file with it).
    static func preflight(_ urls: [URL], into destination: URL) -> Preflight {
        var result = Preflight()
        guard let destinationID = identity(destination) else {
            result.failed = urls.map { ($0, "The destination folder can’t be found.") }
            return result
        }
        var parentIDs: [String: NSObject?] = [:]
        for url in urls {
            let parent = url.deletingLastPathComponent()
            let parentID = parentIDs[parent.path] ?? {
                let id = identity(parent)
                parentIDs[parent.path] = id
                return id
            }()
            if parentID?.isEqual(destinationID) == true { continue }
            if isDirectory(url), isSameOrInside(destination, url) {
                result.failed.append((url, "A folder can’t be put inside itself."))
                continue
            }
            let existing = destination.appendingPathComponent(url.lastPathComponent)
            guard exists(existing) else {
                result.files.append(url)
                continue
            }
            if isSameOrInside(url, existing) {
                result.failed.append((url, "“\(existing.lastPathComponent)” can’t be replaced by an item inside it."))
                continue
            }
            result.files.append(url)
            result.clashing.insert(url)
        }
        return result
    }

    /// The file system's identity for the item at `url`, following symbolic
    /// links in the path; nil when there is nothing there.
    static func identity(_ url: URL) -> NSObject? {
        var resolved = url.resolvingSymlinksInPath()
        resolved.removeAllCachedResourceValues()
        return (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    /// Whether `inner` is `outer` or lies somewhere inside it.
    static func isSameOrInside(_ inner: URL, _ outer: URL) -> Bool {
        guard let outerID = identity(outer) else { return false }
        var url = inner.resolvingSymlinksInPath()
        while true {
            if identity(url)?.isEqual(outerID) == true { return true }
            guard url.pathComponents.count > 1 else { return false }
            url = url.deletingLastPathComponent()
        }
    }

    /// Anything at `url`, a broken symbolic link included.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// A real folder: a symbolic link to one moves as the link.
    static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Moves `url` to the Trash, its marks with it; returns where it went
    /// (nil when nothing was there any more).
    static func trash(_ url: URL) -> Result<URL?, Error> {
        trash(url, using: moveToTrash)
    }

    /// `trash(_:)` with another way of putting the item away (tests use a
    /// folder of their own, not the user's Trash).
    static func trash(_ url: URL, using putAway: (URL) throws -> URL?) -> Result<URL?, Error> {
        guard exists(url) else { return .success(nil) }
        do {
            guard let place = try putAway(url) else { return .success(nil) }
            Catalog.shared.fileMoved(from: url, to: place)
            return .success(place)
        } catch {
            return .failure(error)
        }
    }

    static func moveToTrash(_ url: URL) throws -> URL? {
        var place: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &place)
        return place as URL?
    }
}
