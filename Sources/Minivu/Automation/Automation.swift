import AppKit
import MinivuCore
import MinivuRender

/// What Shortcuts can ask minivu to do (G12, DESIGN.md 5, "Automation"):
/// convert, resize, rename, rate and open. The App Intents in
/// `AutomationIntents.swift` turn the files and settings a shortcut passes
/// into a call here, and everything here is the engine the menus use
/// already: Batch Convert's planner and job, Batch Rename's planner and
/// renamer, the catalog's ratings, the app delegate's open path. There is no
/// second converter or renamer to keep in step.
///
/// **Where files go.** Convert and Resize never write beside the originals.
/// A shortcut's files come with permission to read them, not to write in
/// their folders, so the converted files are made in a folder of minivu's
/// own (`outputRoot`, inside the sandbox container) and handed back to the
/// shortcut, whose next action saves them wherever the user chose. Rename
/// has to change the folder it works in, so it works only where minivu may
/// write already: the Pictures folder and the folders in its sidebar.
///
/// **Internal storage only.** Every file on disk is checked with
/// `VolumePolicy` as it arrives (`AutomationInput`), as a folder opened in
/// the browser is: a file on an external drive, a memory card or a network
/// share fails the whole action before anything reads it.
///
/// **Nothing leaves the Mac.** The shortcut runs minivu's code in minivu's
/// own sandboxed process, which has no network entitlement. Whatever the
/// shortcut does with the files next is Shortcuts' business, not minivu's.
@MainActor enum Automation {
    nonisolated enum Failure: LocalizedError, Equatable {
        /// A file came as data only (from another app, not from a disk), and
        /// the request is about the file itself: a rename or a rating.
        case notAFileOnDisk(String)
        /// A file is on a volume `VolumePolicy` refuses: an external drive,
        /// a memory card, a network share. Nothing was done.
        case notOnInternalStorage(String)
        case unknownTokens([String])
        /// The rename plan found problems (two files getting one name, a name
        /// held by another file); nothing was renamed.
        case renameProblems([String])
        /// Folders minivu may not change (named here); nothing was renamed.
        case foldersNotWritable([String])
        /// Files minivu may not change (named here); no label was set.
        case filesNotWritable([String])
        /// Some labels couldn't be written as they ran (a file changed or
        /// its tags couldn't be read); the others were.
        case labelFailed([String])
        /// Some renames failed as they ran (a file changed or went away after
        /// the checks); the rest were done.
        case renameFailed([String])
        /// Some conversions failed; the files that converted are not handed on.
        case conversionFailed(String)
        /// ImageIO on this Mac has no encoder for the format (AVIF on a Mac
        /// without it); nothing was converted.
        case formatNotWritable(String)
        case noImages

        var errorDescription: String? {
            switch self {
            case .notAFileOnDisk(let name):
                "“\(name)” isn’t a file in a folder on this Mac, so minivu can’t rename or rate it. "
                    + "Pass files from Finder instead."
            case .notOnInternalStorage(let name):
                "“\(name)” isn’t on this Mac’s internal storage, so minivu did nothing. minivu only works with "
                    + "files on this Mac’s internal storage. Copy the photos from the external drive, memory card "
                    + "or network share to a folder on this Mac first."
            case .unknownTokens(let tokens):
                "The pattern has \(tokens.count == 1 ? "a token" : "tokens") minivu doesn’t know: "
                    + tokens.joined(separator: ", ") + ". Use {name}, {#}, {date}, {modified}, {width}, {height} or {ext}."
            case .renameProblems(let lines):
                "Nothing was renamed:\n" + Self.list(lines)
            case .foldersNotWritable(let folders):
                "Nothing was renamed. minivu can rename files only in folders it may change: Pictures and the "
                    + "folders in its sidebar (File > Add Folder to Sidebar…). It may not change:\n" + Self.list(folders)
            case .renameFailed(let lines):
                "Some files couldn’t be renamed; the others were.\n" + Self.list(lines)
            case .filesNotWritable(let names):
                "No label was set. minivu may not change "
                    + (names.count == 1 ? "this file" : "these files")
                    + " (a colour label is written into the file’s Finder tags):\n" + Self.list(names)
            case .labelFailed(let names):
                "Some files couldn’t be labelled; the others were. Their Finder tags couldn’t be read or "
                    + "written:\n" + Self.list(names)
            case .conversionFailed(let detail):
                detail
            case .formatNotWritable(let format):
                "This Mac can’t write \(format) files, so nothing was converted. Choose another format."
            case .noImages:
                "There were no images to work on."
            }
        }

        private static func list(_ lines: [String]) -> String {
            let limit = 8
            var shown = Array(lines.prefix(limit))
            if lines.count > limit { shown.append("…and \((lines.count - limit).formatted()) more.") }
            return shown.joined(separator: "\n")
        }
    }

    /// Where converted files are made before the shortcut takes them. Each
    /// run gets a folder of its own, so two shortcuts at once never number
    /// each other's files; runs older than a day are removed when the next
    /// one starts (Shortcuts normally removes the files itself as soon as it
    /// is done with them). Tests put a folder of their own here.
    static var outputRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Automation", isDirectory: true)
    /// The catalog ratings go to. Tests use one in memory.
    static var catalog: Catalog = .shared

    /// How old a run folder may get before the next run removes it.
    nonisolated static let outputLifetime: TimeInterval = 24 * 3600

    /// Everything as the app starts, for tests.
    static func reset() {
        outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Automation", isDirectory: true)
        catalog = .shared
    }

    // MARK: - Convert and resize

    /// Converts `sources` with `settings` into a new run folder and returns
    /// the converted files in the order of `sources`. Names are kept, with
    /// the new format's extension; two files of one name (from different
    /// folders) are numbered, as Batch Convert numbers them.
    ///
    /// All or nothing: if any file fails, the error names it and the files
    /// that did convert are removed, so a shortcut never carries on with
    /// part of what it was given and no warning.
    static func convert(_ sources: [URL], settings: BatchConvertSettings) async throws -> [URL] {
        guard settings.options.format.isWritable else { throw Failure.formatNotWritable(settings.options.format.title) }
        return try await convert(sources.map { ($0, settings) })
    }

    /// Resize: each file keeps its own format where minivu can write it
    /// (otherwise JPEG, a camera RAW for instance), at that format's
    /// remembered-default quality.
    static func resize(_ sources: [URL], resize: BatchResize, removeLocation: Bool) async throws -> [URL] {
        try await convert(sources.map { source in
            var options = ExportOptions.defaults(for: ExportFormat.format(for: source) ?? .jpeg)
            options.removeLocation = removeLocation
            return (source, BatchConvertSettings(options: options, resize: resize))
        })
    }

    /// The settings for Convert Images: a format, a quality, an optional long
    /// side (never enlarging) and Remove location. Everything else is Batch
    /// Convert's default: metadata kept, the original's colour profile.
    nonisolated static func convertSettings(format: ExportFormat, quality: Int, longSide: Int?,
                                            removeLocation: Bool) -> BatchConvertSettings {
        var options = ExportOptions.defaults(for: format)
        options.quality = Double(min(max(quality, 1), 100)) / 100
        options.removeLocation = removeLocation
        var settings = BatchConvertSettings(options: options)
        if let longSide {
            settings.resize = BatchResize(mode: .longSide, pixels: min(max(longSide, 1), BatchResize.maximumSide))
        }
        return settings
    }

    /// Files with their own settings, all into one run folder: Resize gives
    /// each file its own format. Files sharing settings convert as one batch
    /// (two at a time, one camera RAW at a time, as Batch Convert does).
    private static func convert(_ work: [(source: URL, settings: BatchConvertSettings)]) async throws -> [URL] {
        guard !work.isEmpty else { throw Failure.noImages }
        let root = outputRoot
        let folder = try await BlockingWork.run { try makeRunFolder(in: root) }
        var groups: [(settings: BatchConvertSettings, indices: [Int])] = []
        for (index, item) in work.enumerated() {
            var settings = item.settings
            // Into a folder of minivu's own under the original names, so
            // nothing there is ever replaced: a clash is numbered.
            settings.destination = .besideOriginals
            settings.naming = .keep
            settings.existingFiles = .keepBoth
            if let group = groups.firstIndex(where: { $0.settings == settings }) {
                groups[group].indices.append(index)
            } else {
                groups.append((settings, [index]))
            }
        }

        var results = [URL?](repeating: nil, count: work.count)
        var failures = BatchConvertJob.Outcome()
        for group in groups {
            let sources = group.indices.map { RenameSource(url: work[$0].source) }
            let settings = group.settings
            // The folder is new and minivu's alone, so the plan only ever
            // writes or numbers; nothing in it can be replaced.
            let outputs = await BlockingWork.run { BatchOutputPlanner.plan(sources, settings: settings, folder: folder) }
            let job = BatchConvertJob(outputs: outputs, settings: settings, converter: BatchTools.converter(),
                                      trash: { url in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) },
                                      catalog: catalog,
                                      concurrency: BatchTools.concurrency ?? BatchConvertJob.defaultConcurrency())
            let outcome = await job.run()
            failures.failed += outcome.failed
            failures.skipped += outcome.skipped
            // (`failures.written` stays empty: on any failure none are
            // handed on, and the summary says no files were converted.)
            // In batch order; with no failure, one output per source.
            if outcome.written.count == group.indices.count {
                for (index, url) in zip(group.indices, outcome.written) { results[index] = url }
            }
        }
        if let summary = BatchConvertJob.summary(for: failures) {
            try? FileManager.default.removeItem(at: folder)
            throw Failure.conversionFailed(summary.title + "\n\n" + summary.detail)
        }
        return results.compactMap { $0 }
    }

    /// A new, empty folder for one run in `root` (`outputRoot`), after
    /// clearing out runs old enough that no shortcut can still want them.
    /// Blocking: off the main thread.
    nonisolated static func makeRunFolder(in root: URL, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let runs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for run in runs {
            guard let created = try? run.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  now.timeIntervalSince(created) > outputLifetime else { continue }
            try? fileManager.removeItem(at: run)
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    // MARK: - Rename

    /// Renames `sources` in place with Batch Rename's pattern (tokens, then
    /// the counter from `counterStart`), checked first as the sheet checks
    /// it: unknown tokens or any problem and nothing is renamed. Then every
    /// folder a file is renamed in must be one minivu may change, or nothing
    /// is renamed: a shortcut passing photos from Pictures and the Desktop
    /// would otherwise rename the first and fail on the second, leaving a
    /// half-renamed set with gaps in its counter and no undo. Returns the
    /// files under their new names, in order. Ratings follow in the catalog.
    ///
    /// What is left to fail as the files move is a file that changes or goes
    /// away after these checks, which `renameFailed` names.
    static func rename(_ sources: [URL], pattern: RenamePattern) async throws -> [URL] {
        guard !sources.isEmpty else { throw Failure.noImages }
        let plan = await BlockingWork.run {
            let renameSources = sources.map { RenameSource(url: $0).withFileDates() }
            return RenamePlanner.plan(pattern.needsImageMetadata ? RenameSource.withImageMetadata(renameSources)
                                                                 : renameSources, pattern: pattern)
        }
        guard plan.unknownTokens.isEmpty else { throw Failure.unknownTokens(plan.unknownTokens) }
        let problems = plan.items.compactMap { item in item.problem.map { "\(item.source.lastPathComponent): \($0.message)" } }
        guard problems.isEmpty else { throw Failure.renameProblems(problems) }
        let requests = plan.changes.map { BatchRenamer.Request(url: $0.source, newName: $0.newName) }
        guard !requests.isEmpty else { return sources }
        let closed = await BlockingWork.run { unwritableFolders(requests.map(\.url)) }
        guard closed.isEmpty else { throw Failure.foldersNotWritable(closed.map(\.path)) }

        let outcome = await BatchTools.renameWithoutWindow(requests, catalog: catalog)
        for step in outcome.renamed {
            BrowserModel.invalidateCaches(step.from)
            BrowserModel.invalidateCaches(step.to)
        }
        guard outcome.failed.isEmpty else {
            throw Failure.renameFailed(outcome.failed.map { "\($0.url.lastPathComponent): \($0.message)" })
        }
        // One step per request, from its original name to its final one.
        let renamed = Dictionary(outcome.renamed.map { ($0.from.standardizedFileURL.path, $0.to) }) { first, _ in first }
        return sources.map { renamed[$0.standardizedFileURL.path] ?? $0 }
    }

    /// The folders of `files` that minivu may not change, each once, in the
    /// order first met. Asked of the file system with access(2), which the
    /// sandbox answers too: the Pictures folder and the sidebar's folders
    /// (whose bookmarks are open for the session) are writable, a folder
    /// minivu was only given single files in is not. Blocking.
    nonisolated static func unwritableFolders(_ files: [URL]) -> [URL] {
        var seen = Set<String>(), closed: [URL] = []
        for file in files {
            let folder = file.deletingLastPathComponent().standardizedFileURL
            guard seen.insert(folder.path).inserted else { continue }
            if !FileManager.default.isWritableFile(atPath: folder.path) { closed.append(folder) }
        }
        return closed
    }

    // MARK: - Rating

    /// Gives `urls` `rating` stars (0 clears them), through the queue every
    /// catalog write takes, and returns once it is written: the shortcut's
    /// next action, or quitting, sees it done. Windows showing the files
    /// update from the catalog's change notice.
    static func setRating(_ rating: Int, for urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let catalog = self.catalog
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            BrowserModel.catalogWrites.async {
                catalog.setRating(rating, for: urls)
                done.resume()
            }
        }
    }

    // MARK: - Colour label

    /// Gives `urls` the colour label `label` (`.none` removes it): the file's
    /// standard Finder colour tag, written exactly as Image > Label writes it
    /// (`ColorLabelCommand.write`: in line behind other writes of the files,
    /// other tags kept, the XMP copy when ratings are written into files).
    /// Returns once written.
    ///
    /// A label lives in the file, not the catalog, so unlike a rating it
    /// needs permission to change each file. All or nothing up front: if
    /// minivu may not change any one of them (`unwritableFiles`), nothing is
    /// labelled. What can still fail is a file whose tags can't be read or
    /// that changes as it is written; those are named and the rest keep
    /// their label.
    static func setColorLabel(_ label: ColorLabel, for urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let closed = await BlockingWork.run { unwritableFiles(urls) }
        guard closed.isEmpty else { throw Failure.filesNotWritable(closed.map(\.lastPathComponent)) }
        let result = await ColorLabelCommand.write(label, for: urls)
        guard result.failed.isEmpty else { throw Failure.labelFailed(result.failed.map(\.lastPathComponent)) }
    }

    /// The files of `urls` minivu may not change, asked with access(2) as
    /// `unwritableFolders` asks of folders: the sandbox answers too, so a
    /// file a shortcut passed for reading only is caught here. Blocking.
    nonisolated static func unwritableFiles(_ urls: [URL]) -> [URL] {
        urls.filter { !FileManager.default.isWritableFile(atPath: $0.path) }
    }

    // MARK: - Open

    /// Opens files or a folder in minivu, as a double-click in Finder does
    /// (`AppDelegate.application(_:open:)`): the last image opens in the
    /// viewer with its folder in the browser, a folder in the browser.
    static func open(_ urls: [URL]) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.application(NSApp, open: urls)
        NSApp.activate()
    }
}

extension RenameSource {
    /// The modification date from the file system, which `{modified}` and
    /// the date fallback use. Blocking: off the main thread.
    nonisolated func withFileDates() -> RenameSource {
        var copy = self
        if copy.modified == nil {
            copy.modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return copy
    }
}
