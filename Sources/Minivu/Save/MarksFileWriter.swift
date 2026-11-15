import AppKit
import MinivuCore
import os

nonisolated private let marksLog = Logger(subsystem: "com.minivu.app", category: "marks")

/// Writes ratings, the tag and colour labels into the image files as XMP,
/// as well as keeping them in the catalog, while Settings > General >
/// "Write ratings into files (XMP)" is on (G2). Off, nothing is written.
///
/// **Coalesced.** Changes are collected per file and written once they
/// have been quiet for `delay`: pressing 1 2 3 4 5 quickly writes the file
/// once, with five stars, and T T writes nothing new. Each file gets the
/// last value of each mark that was changed in minivu, and nothing else:
/// pressing T writes the tag and leaves the file's rating alone, so a
/// rating set in Lightroom since minivu last rated the file is not
/// overwritten by the catalog's older one.
///
/// **How.** Through the write queue (metadata only, `touching:`, so moving
/// the file waits for it and a save under way isn't superseded), off the
/// main thread, one file at a time, by `MetadataWriter`: embedded in JPEG,
/// HEIC, PNG and TIFF, which it rewrites without re-encoding, and in an
/// XMP sidecar for camera raws and every other format. The mapping is
/// `MarksXMP`'s. A file that already says what would be written is left
/// alone, and a file gone before its turn is skipped.
///
/// A failure is told once a session (the first), then only logged: a key
/// press that rates a photo in a read-only folder shouldn't raise an alert
/// every time. The marks stay in the catalog either way.
@MainActor final class MarksFileWriter {
    static let shared = MarksFileWriter()

    /// What a file should say: nil leaves that part as the file has it.
    nonisolated struct Change: Equatable, Sendable {
        var url: URL
        var rating: Int?
        var tagged: Bool?
        var label: ColorLabel?

        var edit: MetadataEdit { MetadataEdit(rating: rating, tagged: tagged, colorLabel: label) }
    }

    /// Whether the setting is on, asked as each change arrives.
    var isEnabled: () -> Bool = { Preferences.shared.writeMarksToFiles }
    /// How long changes must be quiet before they are written.
    var delay: Duration = .milliseconds(800)
    /// The writer; tests count its calls.
    var apply: @Sendable (MetadataEdit, URL) throws -> MetadataWriter.Outcome = MetadataWriter.apply
    /// Tells the user about failures; tests collect them instead.
    var reportFailures: @MainActor ([MetadataBatch.Failure]) -> Void = { MarksFileWriter.alertOnce($0) }

    private var pending: [String: Change] = [:]
    /// Files in the order they were first changed, for the write order.
    private var order: [String] = []
    private var timer: Task<Void, Never>?
    /// The last batch written, for tests and quitting to await.
    private(set) var writing: Task<Void, Never>?

    /// Changes not yet handed to the write queue.
    var pendingCount: Int { pending.count }

    /// The catalog committed a new rating or tag (`field`) for these files
    /// (`CatalogFileMirror`). Only that mark is written.
    func marksChanged(_ field: Catalog.MarkField, _ marks: [URL: Catalog.Marks], of urls: [URL]) {
        guard isEnabled(), !urls.isEmpty else { return }
        for url in urls {
            let new = marks[url] ?? .none
            note(url) { change in
                switch field {
                case .rating: change.rating = new.rating
                case .tagged: change.tagged = new.isTagged
                }
            }
        }
        schedule()
    }

    /// A Label command set `label` on these files' Finder tags.
    func labelChanged(_ label: ColorLabel, of urls: [URL]) {
        guard isEnabled(), !urls.isEmpty else { return }
        for url in urls { note(url) { $0.label = label } }
        schedule()
    }

    private func note(_ url: URL, _ change: (inout Change) -> Void) {
        let key = FileWriteQueue.key(url)
        if pending[key] == nil {
            pending[key] = Change(url: url)
            order.append(key)
        }
        change(&pending[key]!)
    }

    /// Starts the quiet period again.
    private func schedule() {
        timer?.cancel()
        let delay = self.delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Hands every pending change to the write queue now: when the quiet
    /// period ends, and before quitting.
    func flush() {
        timer?.cancel()
        timer = nil
        let changes = order.compactMap { pending[$0] }
        pending = [:]
        order = []
        guard !changes.isEmpty else { return }
        let apply = self.apply
        let urls = changes.map(\.url)
        let job = FileWriteQueue.shared.enqueue(touching: MetadataBatch.touchedFiles(urls)) {
            await BlockingWork.run { Self.write(changes, apply: apply) }
        }
        writing = Task { [weak self] in
            let outcome = (try? await job.value)?.value ?? MetadataBatch.Outcome()
            // Minivu's own write, not another application's change.
            for url in outcome.rewritten { ExternalEditWatcher.shared.noteOwnWrite(url) }
            MetadataRevisions.shared.noteChange(outcome.updated)
            ViewerWindowController.current?.metadataDidChange(outcome.rewritten)
            if !outcome.failed.isEmpty { self?.reportFailures(outcome.failed) }
        }
    }

    /// Before quitting: waits for the rating and tag changes still on
    /// `queue` (the catalog's), then for the main-queue blocks that bring
    /// them here (`CatalogFileMirror`), and hands everything pending to the
    /// write queue. A plain `flush()` would miss a change the catalog is
    /// still making, say while it reads a few hundred sidecars first.
    func flush(after queue: DispatchQueue) async {
        // The catalog posts each change to the main queue as it commits it,
        // so a main-queue block posted once `queue` has drained comes after
        // them all.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { done.resume() } }
        }
        flush()
    }

    /// For tests: writes what is pending now and waits for it.
    func flushAndWait() async {
        flush()
        await writing?.value
    }

    /// Writes each change in turn. Disk work, on the write queue.
    nonisolated static func write(_ changes: [Change],
                                  apply: (MetadataEdit, URL) throws -> MetadataWriter.Outcome) -> MetadataBatch.Outcome {
        var outcome = MetadataBatch.Outcome()
        for change in changes {
            let url = change.url
            guard FileManager.default.fileExists(atPath: url.path) else {
                outcome.skipped.append(url)
                continue
            }
            let edit = change.edit
            let fields = MetadataFields.read(from: url)
            guard edit.applied(to: fields) != fields else {
                outcome.skipped.append(url)
                continue
            }
            do {
                let written = try apply(edit, url)
                if written.usedSidecar { outcome.sidecars.append(url) } else { outcome.rewritten.append(url) }
                FileMarksCache.shared.forget(url)
            } catch MetadataWriter.Error.unsupported {
                outcome.skipped.append(url)
            } catch {
                marksLog.error("Writing marks into \(url.lastPathComponent, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                outcome.failed.append(MetadataBatch.Failure(url: url, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    private static var hasAlerted = false

    /// The first failure of the session, as a sheet on the main window.
    static func alertOnce(_ failures: [MetadataBatch.Failure]) {
        guard !hasAlerted, let first = failures.first,
              let window = NSApp.mainWindow ?? NSApp.keyWindow, window.attachedSheet == nil else { return }
        hasAlerted = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "The rating couldn’t be written into “\(first.url.lastPathComponent)”."
            : "Ratings couldn’t be written into \(failures.count.formatted()) files."
        alert.informativeText = first.reason + " The ratings are kept in minivu all the same. "
            + "Later failures in this session aren’t reported."
        alert.beginSheetModal(for: window)
    }
}

/// The catalog's hook into `MarksFileWriter`: each committed rating or tag
/// change, passed to the main actor in the order the catalog made them.
nonisolated final class CatalogFileMirror: CatalogMirror {
    private let writer: MarksFileWriter

    init(writer: MarksFileWriter) {
        self.writer = writer
    }

    func catalog(_ catalog: Catalog, didChange field: Catalog.MarkField, marks: [URL: Catalog.Marks], of urls: [URL]) {
        let writer = self.writer
        // In order (a main-queue block, not a Task), so 1 then 5 can't land
        // as 5 then 1.
        DispatchQueue.main.async { MainActor.assumeIsolated { writer.marksChanged(field, marks, of: urls) } }
    }
}
