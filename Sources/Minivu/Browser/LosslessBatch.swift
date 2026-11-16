import Foundation
import MinivuCore

/// Rotating and flipping a selection of files without re-encoding them
/// (DESIGN.md 4.7, "Lossless actions"): which files can be, doing it, and
/// what to tell the user about the rest. No views, so it can be tested.
nonisolated enum LosslessBatch {
    struct Outcome: Equatable, Sendable {
        /// Files whose orientation changed.
        var transformed: [URL] = []
        /// Files that can't change without re-encoding: RAW, GIF, BMP, and
        /// files whose contents turned out not to match their extension.
        var skipped: [URL] = []
        /// Files that could have been transformed but weren't, with the reason.
        var failed: [Failure] = []
    }

    struct Failure: Equatable, Sendable {
        var url: URL
        var reason: String
    }

    /// How many files transform at once. The work is mostly reading and
    /// writing whole files, so more would only queue up at the disk.
    static let concurrency = 4

    /// Splits a selection into files to transform and files to skip.
    /// Folders are neither: they are simply not part of it.
    static func partition(_ entries: [FolderEntry]) -> (applicable: [URL], skipped: [URL]) {
        var applicable: [URL] = [], skipped: [URL] = []
        for entry in entries where !entry.isDirectory {
            if isApplicable(entry) { applicable.append(entry.url) } else { skipped.append(entry.url) }
        }
        return (applicable, skipped)
    }

    /// Cheap enough for menu validation: by kind and extension only.
    static func isApplicable(_ entry: FolderEntry) -> Bool {
        !entry.isDirectory && entry.kind != .raw && LosslessTransform.canApply(to: entry.url)
    }

    /// Transforms every file, a few at a time. Each transform blocks its
    /// thread on file I/O, so it runs through `BlockingWork` (GCD), never
    /// on the main actor or a cooperative thread. A file
    /// found not to be transformable on closer look (a camera raw renamed
    /// .tif, a GIF named .jpg) counts as skipped. `apply` is for tests.
    static func run(_ kind: LosslessTransform.Kind, on urls: [URL], skipped: [URL] = [],
                    apply: @escaping @Sendable (LosslessTransform.Kind, URL) throws -> Void = LosslessTransform.apply) async -> Outcome {
        var outcome = Outcome(skipped: skipped)
        await withTaskGroup(of: (URL, Result<Void, Error>).self) { group in
            var pending = urls[...]
            func startNext() {
                guard let url = pending.popFirst() else { return }
                group.addTask { (url, await BlockingWork.run { Result { try apply(kind, url) } }) }
            }
            for _ in 0..<concurrency { startNext() }
            for await (url, result) in group {
                switch result {
                case .success:
                    outcome.transformed.append(url)
                case .failure(LosslessTransform.Error.unsupportedFormat):
                    outcome.skipped.append(url)
                case .failure(let error):
                    outcome.failed.append(Failure(url: url, reason: reason(for: error)))
                }
                startNext()
            }
        }
        // Finishing order is arbitrary; report in the order given.
        let order = Dictionary(urls.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        outcome.transformed.sort { order[$0, default: 0] < order[$1, default: 0] }
        outcome.failed.sort { order[$0.url, default: 0] < order[$1.url, default: 0] }
        return outcome
    }

    static func reason(for error: Error) -> String {
        switch error {
        case LosslessTransform.Error.unreadable: localized("The file couldn’t be read.")
        case LosslessTransform.Error.copyFailed(let detail):
            localized(.init("The file couldn’t be rewritten (\(detail)).", comment: "%@ is a technical detail in English"))
        default: error.localizedDescription
        }
    }

    /// The alert after a batch, or nil when every file was transformed.
    static func message(for outcome: Outcome, kind: LosslessTransform.Kind) -> (title: String, detail: String)? {
        guard !outcome.skipped.isEmpty || !outcome.failed.isEmpty else { return nil }
        let rotates = switch kind {
        case .rotateClockwise, .rotateCounterclockwise, .rotate180: true
        case .flipHorizontal, .flipVertical: false
        }
        var lines: [String] = []
        if !outcome.skipped.isEmpty {
            let count = outcome.skipped.count, types = typeList(outcome.skipped)
            lines.append(rotates
                ? localized(.init("\(count) files can’t be rotated without re-encoding (\(types)).", comment: "%@ lists file types"))
                : localized(.init("\(count) files can’t be flipped without re-encoding (\(types)).", comment: "%@ lists file types")))
        }
        if let first = outcome.failed.first {
            let count = outcome.failed.count, name = first.url.lastPathComponent, reason = first.reason
            let line = switch (count == 1, rotates) {
            case (true, true): localized(.init("“\(name)” couldn’t be rotated: \(reason)", comment: "A file name, then the reason"))
            case (true, false): localized(.init("“\(name)” couldn’t be flipped: \(reason)", comment: "A file name, then the reason"))
            case (false, true): localized(.init("\(count) files couldn’t be rotated: \(reason)", comment: "%@ is the first file's reason"))
            case (false, false): localized(.init("\(count) files couldn’t be flipped: \(reason)", comment: "%@ is the first file's reason"))
            }
            lines.append(line)
        }
        let done = outcome.transformed.count
        let title = switch (done == 0, rotates) {
        case (true, true): localized("No files were rotated.")
        case (true, false): localized("No files were flipped.")
        case (false, true): localized("\(done) files were rotated.")
        case (false, false): localized("\(done) files were flipped.")
        }
        return (title, lines.joined(separator: "\n\n"))
    }

    /// "RAW, GIF, BMP, …": the kinds of file skipped, most common first, at
    /// most three named. Every camera raw format is just "RAW".
    static func typeList(_ urls: [URL]) -> String {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, url) in urls.enumerated() {
            let name = ImageFormats.kind(of: url) == .raw ? "RAW" : url.pathExtension.uppercased()
            let key = name.isEmpty ? localized(.init("no extension", comment: "In a list of file types: a file with no extension")) : name
            counts[key, default: 0] += 1
            if firstSeen[key] == nil { firstSeen[key] = index }
        }
        let names = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]! }
        return listText(names, limit: 3)
    }
}

/// Runs lossless batches one after another, and after any other write to
/// an image (see `FileWriteQueue`). Two quick ⌘R presses on the same photos
/// must turn them twice: run side by side, both would read the old
/// orientation and one turn would be lost.
@MainActor final class LosslessQueue {
    static let shared = LosslessQueue()

    /// Transforms `urls` after any write already queued, then calls `done`
    /// on the main actor.
    func enqueue(_ kind: LosslessTransform.Kind, urls: [URL], skipped: [URL],
                 done: @escaping (LosslessBatch.Outcome) -> Void) {
        // The work never throws, and only the orientation changes, so no
        // save under way is superseded by it.
        let job = FileWriteQueue.shared.enqueue(touching: urls) {
            await LosslessBatch.run(kind, on: urls, skipped: skipped)
        }
        Task {
            guard let outcome = try? await job.value else { return }
            done(outcome.value)
        }
    }

    /// For tests: waits until everything queued so far has finished.
    func waitUntilIdle() async {
        await FileWriteQueue.shared.waitUntilIdle()
    }
}
