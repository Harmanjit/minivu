import Foundation
import MinivuCore

/// Writing one Edit Metadata change to a selection of files (G1): which
/// files can take it, writing them one after another, and what to tell the
/// user afterwards. No views, so it can be tested.
nonisolated enum MetadataBatch {
    struct Failure: Equatable, Sendable {
        var url: URL
        var reason: String
    }

    struct Outcome: Equatable, Sendable {
        /// Images rewritten in place: their date and size changed.
        var rewritten: [URL] = []
        /// Images whose XMP sidecar was written; the image itself is unchanged.
        var sidecars: [URL] = []
        /// Files no metadata can be written for (PDF, SVG).
        var skipped: [URL] = []
        var failed: [Failure] = []
        /// Camera raws that keep a location of their own after Remove
        /// location, which minivu doesn't modify.
        var locationLeft: [URL] = []
        /// Files a date shift found no date taken in.
        var noDate: [URL] = []
        var wasCancelled = false

        /// Every file whose metadata changed, in batch order.
        var updated: [URL] { rewritten + sidecars }
    }

    /// Splits a selection into files to write and files to skip.
    static func partition(_ urls: [URL]) -> (writable: [URL], skipped: [URL]) {
        var writable: [URL] = [], skipped: [URL] = []
        for url in urls {
            if MetadataWriter.method(for: url) == .unsupported { skipped.append(url) } else { writable.append(url) }
        }
        return (writable, skipped)
    }

    /// The files a write of `urls` touches, for the write queue: each image,
    /// and the sidecar of those written to one, so that moving or renaming
    /// either waits for the write.
    static func touchedFiles(_ urls: [URL]) -> [URL] {
        urls + urls.filter { MetadataWriter.method(for: $0) == .sidecar }.map(MetadataSidecar.url(for:))
    }

    /// Writes `edit` to each file in turn, each atomically, so Cancel
    /// (`isCancelled`, asked before each file) leaves only whole files: the
    /// ones written have the change and the rest don't. One at a time: a
    /// metadata write is a few milliseconds of disk work, and in turn the
    /// order of the report and of Cancel is the order of the files.
    /// `starting` is told of each file as it starts, `finished` as it ends.
    /// `apply` is for tests.
    static func run(_ edit: MetadataEdit, on urls: [URL], skipped: [URL] = [],
                    isCancelled: @escaping @Sendable () async -> Bool = { false },
                    starting: @escaping @Sendable (URL) async -> Void = { _ in },
                    finished: @escaping @Sendable () async -> Void = {},
                    apply: @escaping @Sendable (MetadataEdit, URL) throws -> MetadataWriter.Outcome
                        = MetadataWriter.apply) async -> Outcome {
        var outcome = Outcome(skipped: skipped)
        for url in urls {
            if await isCancelled() {
                outcome.wasCancelled = true
                break
            }
            await starting(url)
            let result = await BlockingWork.run { Result { try apply(edit, url) } }
            switch result {
            case .success(let written):
                if written.usedSidecar { outcome.sidecars.append(url) } else { outcome.rewritten.append(url) }
                if written.locationLeftInFile { outcome.locationLeft.append(url) }
                if written.hadNoDateToShift { outcome.noDate.append(url) }
            case .failure(MetadataWriter.Error.unsupported):
                outcome.skipped.append(url)
            case .failure(let error):
                outcome.failed.append(Failure(url: url, reason: error.localizedDescription))
            }
            await finished()
        }
        return outcome
    }

    /// The alert after a batch, or nil when every file took the change and
    /// there is nothing to add. Lists up to 8 files per kind, as Batch
    /// Convert's summary does.
    static func summary(for outcome: Outcome) -> (title: String, detail: String)? {
        let notes = !outcome.locationLeft.isEmpty || !outcome.noDate.isEmpty
        guard !outcome.failed.isEmpty || !outcome.skipped.isEmpty || notes else { return nil }
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count.formatted()) files" }
        func list(_ lines: [String]) -> String {
            let limit = 8
            var shown = Array(lines.prefix(limit))
            if lines.count > limit { shown.append("…and \((lines.count - limit).formatted()) more.") }
            return shown.joined(separator: "\n")
        }
        let updated = outcome.updated.count
        let title = !outcome.failed.isEmpty
            ? "\(files(outcome.failed.count).capitalizedFirst) couldn’t be updated."
            : !outcome.skipped.isEmpty
                ? "\(files(outcome.skipped.count).capitalizedFirst) \(outcome.skipped.count == 1 ? "was" : "were") skipped."
                : updated == 1 ? "The metadata was updated." : "The metadata of \(updated.formatted()) files was updated."
        var parts: [String] = []
        parts.append(updated == 0 ? "No files were updated." : "\(files(updated).capitalizedFirst) updated.")
        if !outcome.failed.isEmpty {
            parts.append(list(outcome.failed.map { "\($0.url.lastPathComponent): \($0.reason)" }))
        }
        if !outcome.skipped.isEmpty {
            parts.append("Metadata can’t be written for these files:\n"
                + list(outcome.skipped.map(\.lastPathComponent)))
        }
        if !outcome.locationLeft.isEmpty {
            parts.append("The location was removed from the XMP sidecar, but stays in "
                + "\(outcome.locationLeft.count == 1 ? "this camera raw file" : "these camera raw files"), "
                + "which minivu never modifies:\n" + list(outcome.locationLeft.map(\.lastPathComponent)))
        }
        if !outcome.noDate.isEmpty {
            parts.append("\(outcome.noDate.count == 1 ? "This file has" : "These files have") no date taken to shift:\n"
                + list(outcome.noDate.map(\.lastPathComponent)))
        }
        return (title, parts.joined(separator: "\n\n"))
    }
}
