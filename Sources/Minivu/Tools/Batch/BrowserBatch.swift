import AppKit
import MinivuCore
import MinivuRender

/// What the batch tools use from outside the browser window, replaceable in
/// tests: where settings are remembered, where replaced files go, and the
/// answer to "Replace the originals?".
@MainActor enum BatchTools {
    static var store = BatchStore()
    /// Moves a replaced file to the Trash (the file only: the writer moves
    /// its marks). Tests put a folder of their own here.
    static var trash: BatchFileWriter.Trasher = BatchFileWriter.systemTrash
    /// nil asks with an alert on the window.
    static var confirmReplacingOriginals: ((_ count: Int) async -> Bool)?
    static var converter: @MainActor () -> BatchConverter = { BatchConvertJob.makeConverter() }
    static var concurrency: Int?
    static var sheets = BatchSheetPresenter.system

    /// Batches under way per browser window (one started from a menu at a
    /// time: their sheets would collide; an undo or redo may queue behind).
    fileprivate static var running: [ObjectIdentifier: Int] = [:]
    /// The newest batch per window, which finishes last, for tests to await
    /// and for the next undo or redo to wait for.
    static var work: [ObjectIdentifier: Task<Void, Never>] = [:]

    fileprivate static func started(_ id: ObjectIdentifier, _ task: Task<Void, Never>) {
        work[id] = task
    }

    fileprivate static func begin(_ id: ObjectIdentifier) {
        running[id, default: 0] += 1
    }

    fileprivate static func end(_ id: ObjectIdentifier) {
        let count = (running[id] ?? 1) - 1
        running[id] = count > 0 ? count : nil
        if count <= 0 { work[id] = nil }
    }
}

/// Tools > Batch Rename… and Batch Convert… for the browser (DESIGN.md 5,
/// "Tools"). Both work on `toolImages`: the selected images, or every image
/// shown when none is selected.
extension BrowserWindowController {
    var isRunningBatch: Bool { BatchTools.running[ObjectIdentifier(self)] != nil }

    /// The batch under way in this window, for tests.
    var batchWork: Task<Void, Never>? { BatchTools.work[ObjectIdentifier(self)] }

    private func canStartBatch() -> NSWindow? {
        guard let window, window.attachedSheet == nil, !isRunningBatch, !isTransferring, !toolImages.isEmpty else {
            return nil
        }
        return window
    }

    // MARK: - Batch Rename

    /// ⇧F2: the rename sheet over the images.
    @objc func batchRename(_ sender: Any?) {
        showBatchRename()
    }

    private func showBatchRename(pattern: RenamePattern? = nil) {
        guard let window = canStartBatch() else { return NSSound.beep() }
        let model = BatchRenameModel(entries: toolImages, store: BatchTools.store)
        if let pattern { model.pattern = pattern }
        let sheet = BatchRenameSheet(model: model)
        sheet.begin(on: window) { [weak self, weak sheet] requests in
            guard let self else { return }
            let name = BatchRenameModel.actionName(count: requests.count)
            self.performBatchRename(requests, actionName: name) { _ in
                model.renamingEnded()
                sheet?.end()
            }
        }
    }

    /// The renames that one undo step covers, filled in when the work that
    /// registered it has finished (a redo registers its undo at once).
    final class BatchRenameRecord {
        var requests: [BatchRenamer.Request] = []
    }

    /// Renames off the main thread, selects the renamed files, and registers
    /// one undo step that puts every name back (and redo, the other way).
    /// Marks and Custom Order places follow the files in the catalog.
    func performBatchRename(_ requests: [BatchRenamer.Request], restoring: Bool = false, actionName: String,
                            completion: ((BatchRenamer.Outcome) -> Void)? = nil) {
        performBatchRename({ requests }, restoring: restoring, actionName: actionName, completion: completion)
    }

    /// `requests` is read when the work starts, after any batch still under
    /// way in this window: a redo pressed while its undo still runs only
    /// learns the names to put back when that undo has finished, and two
    /// renames of the same files must never run at once.
    private func performBatchRename(_ requests: @escaping @MainActor () -> [BatchRenamer.Request], restoring: Bool,
                                    actionName: String, completion: ((BatchRenamer.Outcome) -> Void)?) {
        let id = ObjectIdentifier(self)
        let record = BatchRenameRecord()
        let done = undoRegistration(actionName) { controller in
            controller.performBatchRename({ record.requests }, restoring: !restoring, actionName: actionName,
                                          completion: nil)
        }
        let catalog = model.catalog
        let previous = BatchTools.work[id]
        BatchTools.begin(id)
        let work = Task {
            await previous?.value
            let requests = requests()
            let outcome = await BlockingWork.run {
                BatchRenamer.perform(requests, restoring: restoring, catalog: catalog)
            }
            BatchTools.end(id)
            record.requests = outcome.inverse
            for step in outcome.renamed {
                BrowserModel.invalidateCaches(step.from)
                BrowserModel.invalidateCaches(step.to)
            }
            done(!outcome.renamed.isEmpty)
            // Only the folder shown is listed again: an undo can run after
            // the user has moved on to another folder.
            let renamed = outcome.renamed.map(\.to)
            if let folder = model.folder, renamed.contains(where: { BrowserModel.samePath($0.deletingLastPathComponent(), folder) }) {
                model.reload(thenSelect: renamed)
            }
            completion?(outcome)
            reportRenameFailures(outcome.failed)
        }
        BatchTools.started(id, work)
    }

    private func reportRenameFailures(_ failures: [BatchRenamer.Failure]) {
        guard !failures.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failures.count == 1, let failure = failures.first {
            alert.messageText = "“\(failure.url.lastPathComponent)” couldn’t be renamed."
            alert.informativeText = failure.message
        } else {
            alert.messageText = "\(failures.count.formatted()) files couldn’t be renamed."
            alert.informativeText = failures.prefix(8).map { "\($0.url.lastPathComponent): \($0.message)" }
                .joined(separator: "\n") + (failures.count > 8 ? "\n…" : "")
        }
        Self.show(alert, on: window)
    }

    // MARK: - Batch Convert

    /// ⌥⌘B: the convert sheet over the images.
    @objc func batchConvert(_ sender: Any?) {
        guard let window = canStartBatch() else { return NSSound.beep() }
        let entries = toolImages
        let model = BatchConvertModel(entries: entries, store: BatchTools.store)
        let sheet = BatchConvertSheet(model: model)
        sheet.begin(on: window) { [weak self] settings in
            self?.runBatchConvert(entries, settings: settings)
        }
    }

    /// Plans the outputs, confirms replacing originals if any would be,
    /// then converts with a progress sheet and reports what didn't work.
    func runBatchConvert(_ entries: [FolderEntry], settings: BatchConvertSettings) {
        guard !isRunningBatch else { return NSSound.beep() }
        let id = ObjectIdentifier(self)
        BatchTools.begin(id)
        let work = Task {
            await convert(entries, settings: settings)
            BatchTools.end(id)
        }
        BatchTools.started(id, work)
    }

    private func convert(_ entries: [FolderEntry], settings: BatchConvertSettings) async {
        var chosen: URL?
        if case .chosenFolder(let bookmark) = settings.destination {
            guard let resolved = BatchConvertModel.resolve(bookmark) else {
                return present(message: "The destination folder can’t be found. Choose it again in Batch Convert.")
            }
            chosen = resolved
        }
        let folder = chosen
        // The chosen folder stays open to the sandbox for the whole batch.
        let accessing = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }

        let sources = entries.map { RenameSource(url: $0.url, modified: $0.modified) }
        let needsMetadata = settings.pattern?.needsImageMetadata == true
        let outputs = await BlockingWork.run {
            BatchOutputPlanner.plan(needsMetadata ? RenameSource.withImageMetadata(sources) : sources,
                                    settings: settings, folder: folder)
        }

        let originals = outputs.filter(\.replacesOriginal).count
        if originals > 0 {
            let confirmed = if let confirm = BatchTools.confirmReplacingOriginals {
                await confirm(originals)
            } else {
                await confirmReplacingOriginals(originals)
            }
            guard confirmed else { return }
        }

        let job = BatchConvertJob(outputs: outputs, settings: settings, converter: BatchTools.converter(),
                                  trash: BatchTools.trash, catalog: model.catalog,
                                  concurrency: BatchTools.concurrency ?? BatchConvertJob.defaultConcurrency())
        let format = settings.options.format.title
        let count = entries.count == 1 ? "1 Image" : "\(entries.count.formatted()) Images"
        let sheet = BatchProgressSheet(title: "Converting \(count) to \(format)", progress: job.progress)
        let presented = window.flatMap { $0.attachedSheet == nil ? $0 : nil }
        if let presented { BatchTools.sheets.begin(sheet.window, presented) }
        let outcome = await job.run()
        if let presented { BatchTools.sheets.end(sheet.window, presented) }

        for url in outcome.written { BrowserModel.invalidateCaches(url) }
        if let current = model.folder {
            let here = outcome.written.filter { BrowserModel.samePath($0.deletingLastPathComponent(), current) }
            if !here.isEmpty { model.reload(thenSelect: here) }
        }
        if let summary = BatchConvertJob.summary(for: outcome), let window {
            let alert = NSAlert()
            alert.alertStyle = outcome.failed.isEmpty ? .informational : .warning
            alert.messageText = summary.title
            alert.informativeText = summary.detail
            Self.show(alert, on: window)
        }
    }

    private func confirmReplacingOriginals(_ count: Int) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "Replace the original with the converted file?"
            : "Replace \(count.formatted()) originals with the converted files?"
        alert.informativeText = "The converted files take the originals’ names. The originals go to the Trash."
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        // Cancel is the default: Return mustn't replace originals by accident.
        replace.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let response = await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn
    }

    private static func show(_ alert: NSAlert, on window: NSWindow) {
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Debug (snapshot harness)

    /// Debug only: the Batch Rename sheet named by date taken, which gives
    /// photos taken the same day one name, so the harness can picture a clash.
    @objc func debugBatchRenameClash(_ sender: Any?) {
        showBatchRename(pattern: RenamePattern(text: "{date}", extensionCase: .lower))
    }

    /// Debug only: the Batch Convert sheet with a resize, a turn and a name
    /// pattern chosen (settings not remembered), for the harness.
    @objc func debugBatchConvertOptions(_ sender: Any?) {
        guard let window = canStartBatch() else { return }
        // Nothing here is remembered: only Convert commits settings.
        let model = BatchConvertModel(entries: toolImages, store: BatchTools.store)
        model.format = .heic
        model.settings.resize = BatchResize(mode: .longSide, pixels: 2048, filter: .lanczos3)
        model.settings.quarterTurns = 1
        model.usesPattern = true
        model.pattern = RenamePattern(text: "Web {name} {##}", nameCase: .lower)
        BatchConvertSheet(model: model).begin(on: window) { _ in }
    }

    /// Debug only: a progress sheet part way through, without converting.
    @objc func debugBatchConvertProgress(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let progress = BatchProgress(total: 48)
        for _ in 0..<17 { progress.advance() }
        progress.currentName = toolImages.first?.name ?? "HSB_6548.NEF"
        let sheet = BatchProgressSheet(title: "Converting 48 Images to HEIC", progress: progress)
        BatchTools.sheets.begin(sheet.window, window)
    }
}

/// Shows and ends the batch tools' sheets. Tests record them instead: under
/// the test runner, with no event loop, AppKit plays each sheet's animation
/// on the main thread, a third of a second that other tests' clocks feel.
@MainActor struct BatchSheetPresenter {
    var begin: (_ sheet: NSWindow, _ parent: NSWindow) -> Void
    var end: (_ sheet: NSWindow, _ parent: NSWindow) -> Void

    static let system = BatchSheetPresenter(
        begin: { sheet, parent in parent.beginSheet(sheet, completionHandler: nil) },
        end: { sheet, parent in
            if sheet.sheetParent === parent { parent.endSheet(sheet) }
            sheet.orderOut(nil)
        })
}
