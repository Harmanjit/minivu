import Foundation

/// Carries out a batch of renames in an order that works, including swaps
/// ("a.jpg" ↔ "b.jpg"), chains ("1" → "2" → "3") and renames that change
/// only letter case on a case-insensitive volume.
///
/// Synchronous file-system work: call it off the main thread. Each rename
/// is an exclusive `rename(2)` (never overwriting), and marks follow the
/// files in the catalog: every step (temporary names included) is recorded
/// in order and applied in one catalog transaction when the renames are
/// done, with one `Catalog.didChange`.
///
/// **Order.** A file whose new name is still held by another file of the
/// batch waits until that file has moved away; the moment a name is freed,
/// the file waiting for it goes. Only a cycle (a swap, or a longer ring)
/// can't be ordered: one of its files steps aside to a hidden temporary
/// name first, which frees its old name for the rest of the ring, and takes
/// its new name last. Temporary names are used for cycles only, so a crash
/// part way leaves at most one hidden file per ring.
///
/// Undo is the same operation with every pair turned around (`restoring`,
/// which puts back names without judging them as new names).
public enum BatchRenamer {
    public struct Request: Hashable, Sendable {
        public var url: URL
        public var newName: String

        public init(url: URL, newName: String) {
            self.url = url
            self.newName = newName
        }
    }

    public struct Step: Hashable, Sendable {
        public var from: URL
        public var to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public struct Failure: Hashable, Sendable {
        public var url: URL
        public var message: String
    }

    public struct Outcome: Sendable {
        /// Completed renames, in the order they were requested.
        public var renamed: [Step] = []
        public var failed: [Failure] = []

        /// The requests that undo this outcome.
        public var inverse: [Request] {
            renamed.map { Request(url: $0.to, newName: $0.from.lastPathComponent) }
        }
    }

    /// - Parameters:
    ///   - restoring: the names are old names being put back (undo), so they
    ///     are only checked to be free, as `FileOperations.undoRename` does.
    public static func perform(_ requests: [Request], restoring: Bool = false, catalog: Catalog = .shared,
                               probe: BatchFileProbe = .system) -> Outcome {
        var outcome = Outcome()
        // The catalog follows every step, in order, once the renames are done.
        var moves: [(from: URL, to: URL)] = []
        func moved(_ from: URL, _ to: URL) { moves.append((from, to)) }
        // No healing of the folders until the marks have followed.
        catalog.pauseHealing()
        defer {
            catalog.filesMoved(moves)
            catalog.resumeHealing()
        }
        var results: [Step?] = Array(repeating: nil, count: requests.count)
        var failures: [Failure?] = Array(repeating: nil, count: requests.count)

        var caseSensitivity: [String: Bool] = [:]
        func key(_ url: URL, name: String? = nil) -> String {
            let folder = url.deletingLastPathComponent()
            let path = folder.standardizedFileURL.path
            let sensitive = caseSensitivity[path] ?? {
                let value = probe.isCaseSensitive(folder)
                caseSensitivity[path] = value
                return value
            }()
            return BatchNameKey.key(folder: folder, name: name ?? url.lastPathComponent, caseSensitive: sensitive)
        }

        // Where each pending file is now, which pending file holds each name,
        // and which files wait for a name to be freed.
        var current = requests.map(\.url)
        var pending = Set<Int>()
        var holder: [String: Int] = [:]
        var waiting: [String: [Int]] = [:]
        let targets = requests.map { key($0.url, name: $0.newName) }
        for (i, request) in requests.enumerated() where request.newName != request.url.lastPathComponent {
            pending.insert(i)
            holder[key(request.url)] = i
        }
        var ready: [Int] = []
        for i in pending.sorted() {
            // A case-only rename waits for nobody: the name it "takes" is its own.
            if let other = holder[targets[i]], other != i {
                waiting[targets[i], default: []].append(i)
            } else {
                ready.append(i)
            }
        }
        var readyIndex = 0

        /// The name is no longer held by `i`: whoever waited for it may go.
        /// A file that failed keeps its name, and is released with
        /// `holds: true` so the waiting files try, and are refused, rather
        /// than wait forever.
        func release(_ nameKey: String, from i: Int, holds: Bool = false) {
            guard holder[nameKey] == i else { return }
            if !holds { holder[nameKey] = nil }
            for next in waiting.removeValue(forKey: nameKey) ?? [] where pending.contains(next) { ready.append(next) }
        }

        while !pending.isEmpty {
            if readyIndex == ready.count {
                // Everything left waits on something. Following who waits on
                // whom from any file ends in a ring (a swap or longer); one
                // file of the ring steps aside under a temporary name.
                guard var i = pending.min() else { break }
                var seen: Set<Int> = []
                var inRing = false
                while let next = holder[targets[i]], next != i, pending.contains(next) {
                    seen.insert(i)
                    i = next
                    if seen.contains(i) { inRing = true; break }
                }
                guard inRing, current[i] == requests[i].url else {
                    ready.append(i)   // not in a ring after all: let it try
                    continue
                }
                let from = current[i]
                let temporary = from.deletingLastPathComponent()
                    .appendingPathComponent(".minivu-rename-\(UUID().uuidString)")
                do {
                    try FileOperations.moveExclusively(from, to: temporary)
                    moved(from, temporary)
                    current[i] = temporary
                    release(key(from), from: i)
                } catch {
                    pending.remove(i)
                    failures[i] = Failure(url: requests[i].url, message: error.localizedDescription)
                    release(key(from), from: i, holds: true)
                }
                continue
            }
            let i = ready[readyIndex]
            readyIndex += 1
            guard pending.contains(i) else { continue }
            if let other = holder[targets[i]], other != i, pending.contains(other) {
                // Became ready early (a ring was broken elsewhere); wait again.
                waiting[targets[i], default: []].append(i)
                continue
            }
            pending.remove(i)
            let request = requests[i]
            let from = current[i]
            let wasTemporary = from != request.url
            do {
                let renamed: URL
                if wasTemporary || restoring {
                    renamed = try FileOperations.undoRename(from, to: request.url.deletingLastPathComponent()
                        .appendingPathComponent(request.newName), moved: moved)
                } else {
                    renamed = try FileOperations.rename(from, to: request.newName, moved: moved)
                }
                // (The catalog followed original → temporary → new, which
                // also keeps the file's place in its folder's Custom Order.)
                results[i] = Step(from: request.url, to: renamed)
                current[i] = renamed
                if !wasTemporary { release(key(from), from: i) }
            } catch {
                var message = error.localizedDescription
                if wasTemporary {
                    // Back under its own name if that is still free, else a
                    // numbered one: never left hidden.
                    let folder = from.deletingLastPathComponent()
                    let name = BatchNameKey.uniqueName(for: request.url.lastPathComponent, in: folder, probe: probe) { _ in false }
                    let back = folder.appendingPathComponent(name)
                    if (try? FileOperations.moveExclusively(from, to: back)) != nil {
                        moved(from, back)
                        if name != request.url.lastPathComponent { message += " It is now named “\(name)”." }
                    }
                } else {
                    release(key(from), from: i, holds: true)
                }
                failures[i] = Failure(url: request.url, message: message)
            }
        }
        outcome.renamed = results.compactMap { $0 }
        outcome.failed = failures.compactMap { $0 }
        return outcome
    }
}
