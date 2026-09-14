import Foundation

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
    /// don't make a save that is under way look superseded.
    @discardableResult
    func enqueue<Value: Sendable>(replacing urls: [URL] = [],
                                  _ work: @escaping @Sendable () async throws -> Value) -> Task<Outcome<Value>, Error> {
        counter += 1
        let number = counter
        let keys = urls.map(Self.key)
        for key in keys { newest[key] = number }
        let previous = tail
        let job = Task { () async -> Result<Value, Error> in
            await previous?.value
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        pendingCount += 1
        tail = Task {
            _ = await job.value
            pendingCount -= 1
        }
        return Task {
            let result = await job.value
            let isNewest = keys.allSatisfy { newest[$0] == number }
            for key in keys where newest[key] == number { newest[key] = nil }
            return Outcome(value: try result.get(), isNewest: isNewest)
        }
    }

    /// For tests: waits until everything queued so far has finished.
    func waitUntilIdle() async {
        await tail?.value
    }

    /// Two spellings of one file (a symbolic link, "..") are the same file.
    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
