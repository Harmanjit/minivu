import AppKit

/// Every write minivu makes to an image file (Save, Save As, a JPEG
/// comment, a lossless rotate) runs through here, one at a time, in the
/// order it was asked for.
///
/// Why one queue: two writes to the same file side by side can land in
/// either order. ⌘S, another edit, ⌘S again on a large image could let the
/// older render finish last and overwrite the newer one while the document
/// believes the newer one is on disk. A rotate and a comment each read the
/// file, change it and write it back, so run together one change is lost.
/// Writes are quick next to the time it takes to ask for another, so
/// running them in series costs nothing noticeable.
///
/// Moving a file away (the Trash, a rename, a move) waits here for the
/// writes queued for it: a save still in line would otherwise land after,
/// its atomic replace making a new file at the old path, and the moved file
/// would miss the save.
@MainActor final class FileWriteQueue {
    static let shared = FileWriteQueue()

    private var tail: Task<Void, Never>?
    private var counter = 0
    /// Writes queued or running. Quitting while this is above zero would
    /// cut a save or a batch rotate short (each file is still whole, but
    /// the user's last save wouldn't be on disk), so termination should
    /// wait for `waitUntilIdle`.
    private(set) var pendingCount = 0
    /// The newest pixel-replacing write asked for, per file.
    private var newest: [String: Int] = [:]
    /// The last write queued for each file, until it finishes.
    private var lastWrite: [String: (number: Int, finished: Task<Void, Never>)] = [:]

    /// The result of a write, and whether it is still the newest write of
    /// new pixels asked for its file. A save that isn't may have been
    /// overwritten already, so it mustn't mark its document saved.
    struct Outcome<Value: Sendable>: Sendable {
        var value: Value
        var isNewest: Bool
    }

    /// Queues `work` behind everything queued before it; its place in line
    /// is taken now, synchronously, so writes run in the order they were
    /// asked for even if their callers' tasks start in another order.
    /// `replacing` names the files whose pixels the work rewrites (a save);
    /// metadata-only writes (a comment, an orientation) pass none, so they
    /// don't make a save that is under way look superseded; they name the
    /// files they rewrite as `touching`, so moving those waits for them.
    @discardableResult
    func enqueue<Value: Sendable>(replacing urls: [URL] = [], touching others: [URL] = [],
                                  _ work: @escaping @Sendable () async throws -> Value) -> Task<Outcome<Value>, Error> {
        counter += 1
        let number = counter
        let keys = urls.map(Self.key)
        for key in keys { newest[key] = number }
        let written = Set(keys + others.map(Self.key))
        let previous = tail
        let job = Task { () async -> Result<Value, Error> in
            await previous?.value
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        pendingCount += 1
        let finished = Task {
            _ = await job.value
            pendingCount -= 1
            for key in written where lastWrite[key]?.number == number { lastWrite[key] = nil }
        }
        tail = finished
        for key in written { lastWrite[key] = (number, finished) }
        return Task {
            let result = await job.value
            let isNewest = keys.allSatisfy { newest[$0] == number }
            for key in keys where newest[key] == number { newest[key] = nil }
            return Outcome(value: try result.get(), isNewest: isNewest)
        }
    }

    /// Waits, without blocking, for the writes queued so far to `urls` or
    /// to files inside them (a folder), before they move.
    func waitForWrites(to urls: [URL]) async {
        let pending = lastWrite.filter { Self.path($0.key, isIn: urls) }
        for write in pending.values { await write.finished.value }
    }

    /// Puts items in the Trash once the writes queued for them are done,
    /// returning where each went.
    func trash(_ urls: [URL]) async throws -> [URL: URL] {
        await waitForWrites(to: urls)
        return try await putInTrash(urls)
    }

    /// How `trash` puts items away; tests use a folder of their own.
    var putInTrash: @MainActor ([URL]) async throws -> [URL: URL] = { try await NSWorkspace.shared.recycle($0) }

    /// For tests: waits until everything queued so far has finished.
    func waitUntilIdle() async {
        await tail?.value
    }

    /// Two spellings of one file (a symbolic link, "..") are the same file.
    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `path` (a `key`) is one of `urls` or inside one of them.
    nonisolated static func path(_ path: String, isIn urls: [URL]) -> Bool {
        urls.map(key).contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
