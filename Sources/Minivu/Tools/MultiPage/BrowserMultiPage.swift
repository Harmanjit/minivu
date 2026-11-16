import AppKit
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender

/// What the multi-page tools use from outside the browser window,
/// replaceable in tests: where the new file goes (a save panel by default),
/// what happens to it afterwards, and how problems are reported.
@MainActor enum MultiPageTools {
    /// nil asks with a save panel on the window.
    static var chooseDestination: ((_ name: String, _ type: UTType, _ folder: URL?) async -> URL?)?
    /// Opens a finished image strip in the viewer.
    static var showResult: (URL) -> Void = { ContactSheetExport.showResult([$0]) }
    /// nil shows an alert on the window.
    static var report: ((_ title: String, _ detail: String) -> Void)?

    static func reset() {
        chooseDestination = nil
        showResult = { ContactSheetExport.showResult([$0]) }
        report = nil
    }
}

/// Tools > Create Multi-Page File… and Image Strip… for the browser (G17),
/// on `toolStills` (videos left out) in the browser's order.
///
/// Both make one new file, chosen in a save panel (which asks before
/// replacing a file of that name). The file is made in a temporary place
/// on the destination's volume (`SafeFileWriter.temporaryFile`), page by
/// page or picture by picture with progress and Cancel, and only a whole
/// file is put in place, through `FileWriteQueue`; a cancelled or failed
/// job leaves nothing behind. They count as a batch of the window: the
/// batch commands wait until they are done.
///
/// **Image strip: saved, then opened in the viewer (decided).** The other
/// choice was to open the strip in the viewer as a new, unsaved document.
/// But every viewer document is a file: Save, Revert, the catalog's marks,
/// the info panel, the filmstrip and the external-change watcher all work
/// from its URL, so an unsaved document would need a new kind of document
/// through all of them, and a strip of 20 photos (up to 32768 px long) would
/// sit in memory only, lost on a crash, until saved. Saved first, the strip
/// is safe at full resolution, opens like any photo (shown fitted to the
/// texture limit, as any large image is), and can be edited and saved with
/// the usual non-destructive edits.
extension BrowserWindowController {
    // MARK: - Create Multi-Page File

    @objc func createMultiPageFile(_ sender: Any?) {
        guard let window = canStartBatch() else { return NSSound.beep() }
        let stills = toolStills
        guard !stills.isEmpty else { return NSSound.beep() }
        let model = MultiPageModel(entries: stills, store: BatchTools.store)
        MultiPageSheet(model: model).begin(on: window) { [weak self] settings, urls in
            guard let self else { return }
            Task {
                guard let destination = await self.chooseMultiPageDestination(name: model.suggestedName,
                                                                              type: settings.format.utType)
                else { return }
                self.runMultiPage(urls, settings: settings, to: destination)
            }
        }
    }

    /// Makes the file at `destination` from `urls` in this order, with
    /// progress and Cancel, then selects it if it is in the folder shown.
    func runMultiPage(_ urls: [URL], settings: MultiPageSettings, to destination: URL) {
        startMultiPageWork { controller in
            await controller.makeMultiPage(urls, settings: settings, to: destination)
        }
    }

    private func makeMultiPage(_ urls: [URL], settings: MultiPageSettings, to destination: URL) async {
        let pages = await BlockingWork.run { MultiPageBuilder.pages(of: urls, everyPage: settings.includesEveryPage) }
        let limit = ImageDecoder.exportDecodeLimit()
        let outcome = await produce(destination, total: pages.count, title: Self.makingTitle(destination)) { temporary, progress in
            let cancel = progress.cancellation
            return try await BlockingWork.run {
                try MultiPageBuilder.write(pages, settings: settings, to: temporary, byteLimit: limit, cancel: cancel) { done in
                    Task { @MainActor in progress.set(done: done) }
                }.map { page, error in
                    let name = page.url.lastPathComponent
                    return page.of > 1
                        ? localized(.init("\(name), page \(page.index + 1): \(SaveAlert.message(for: error))",
                                          comment: "A file name, a page number, then what went wrong with that page"))
                        : localized(.init("\(name): \(SaveAlert.message(for: error))", comment: "A file name, then what went wrong with it"))
                }
            }
        }
        guard let left = outcome else { return }
        if !left.isEmpty {
            reportMultiPage(title: localized("\(left.count) pages were left out."),
                            detail: Self.listed(left))
        }
    }

    // MARK: - Image Strip

    @objc func makeImageStrip(_ sender: Any?) {
        guard let window = canStartBatch() else { return NSSound.beep() }
        let stills = toolStills
        guard !stills.isEmpty else { return NSSound.beep() }
        let model = ImageStripModel(entries: stills, store: BatchTools.store)
        ImageStripSheet(model: model).begin(on: window) { [weak self] settings, urls in
            guard let self else { return }
            Task {
                guard let destination = await self.chooseMultiPageDestination(name: model.suggestedName,
                                                                              type: settings.options.format.utType)
                else { return }
                self.runImageStrip(urls, settings: settings, to: destination)
            }
        }
    }

    /// Makes the strip of `urls` in this order at `destination`, then opens
    /// it in the viewer.
    func runImageStrip(_ urls: [URL], settings: ImageStripSettings, to destination: URL) {
        startMultiPageWork { controller in
            await controller.makeImageStrip(urls, settings: settings, to: destination)
        }
    }

    private func makeImageStrip(_ urls: [URL], settings: ImageStripSettings, to destination: URL) async {
        let limit = ImageDecoder.exportDecodeLimit()
        let outcome = await produce(destination, total: 1, title: Self.makingTitle(destination)) { temporary, progress in
            let cancel = progress.cancellation
            return try await BlockingWork.run {
                let sizes = ImageStripRenderer.sizes(of: urls)
                let strip = try ImageStripRenderer.render(urls, sizes: sizes, settings: settings, byteLimit: limit,
                                                          cancel: cancel)
                // Transparent gaps in a format without alpha take the
                // options' background colour, which the sheet shows.
                let data = try ImageEncoder.encode(strip.image, options: settings.options, metadataSource: nil)
                try data.write(to: temporary, options: .withoutOverwriting)
                return strip.failed.map { localized("“\($0.lastPathComponent)” couldn’t be read.") }
            }
        }
        guard let left = outcome else { return }
        if !left.isEmpty {
            reportMultiPage(title: localized("\(left.count) images were left out."),
                            detail: Self.listed(left))
        }
        MultiPageTools.showResult(destination)
    }

    // MARK: - Shared

    private func chooseMultiPageDestination(name: String, type: UTType) async -> URL? {
        let startFolder = toolStartFolder
        if let choose = MultiPageTools.chooseDestination { return await choose(name, type, startFolder) }
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let startFolder { panel.directoryURL = startFolder }
        let response = await withCheckedContinuation { done in
            panel.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        // Files minivu may not use (an external volume) are refused, as
        // everywhere else.
        guard VolumePolicy.isAllowed(url.deletingLastPathComponent()) else {
            present(message: localized("minivu works only with folders on this Mac’s internal storage."))
            return nil
        }
        return url
    }

    /// Runs `work` as this window's batch (one at a time, counted so the
    /// batch commands and quitting wait for it).
    private func startMultiPageWork(_ work: @escaping @MainActor (BrowserWindowController) async -> Void) {
        guard !isRunningBatch else { return NSSound.beep() }
        let id = ObjectIdentifier(self)
        BatchTools.begin(id)
        let task = Task {
            await work(self)
            BatchTools.end(id)
        }
        BatchTools.started(id, task)
    }

    /// Makes a new file for `destination` with `make`, which writes it in
    /// full at the temporary URL it is given and returns what it left out,
    /// with a progress sheet of `total` steps; then puts it in place through
    /// the write queue and selects it in the folder shown. Nil when nothing
    /// was written (cancelled, or failed and reported).
    private func produce(_ destination: URL, total: Int, title: String,
                         make: @escaping @MainActor (URL, BatchProgress) async throws -> [String]) async -> [String]? {
        let progress = BatchProgress(total: max(total, 1))
        progress.currentName = destination.lastPathComponent
        let sheet = BatchProgressSheet(title: title, progress: progress)
        let presented = window.flatMap { BatchTools.hasSheet(on: $0) ? nil : $0 }
        if let presented { BatchTools.beginSheet(sheet.window, on: presented) }
        defer { if let presented { BatchTools.endSheet(sheet.window, on: presented) } }

        let temporary = SafeFileWriter.temporaryFile(for: destination)
        defer { if let folder = temporary.scratchFolder { try? FileManager.default.removeItem(at: folder) } }
        let left: [String]
        do {
            left = try await make(temporary.url, progress)
            guard !progress.isCancelled else { throw CancellationError() }
            let write = FileWriteQueue.shared.enqueue(replacing: [destination]) {
                try await BlockingWork.run {
                    try SafeFileWriter.place(temporary.url, at: destination)
                    OwnWrites.record(destination)
                }
            }
            _ = try await write.value.value
        } catch {
            try? FileManager.default.removeItem(at: temporary.url)
            progress.finish()
            if !(error is CancellationError) {
                reportMultiPage(title: localized(.init("“\(destination.lastPathComponent)” couldn’t be made.", comment: "%@ is a file name")),
                                detail: SaveAlert.message(for: error))
            }
            return nil
        }
        progress.finish()
        SavePresenter.didWrite(destination)
        if let folder = model.folder, BrowserModel.samePath(destination.deletingLastPathComponent(), folder) {
            model.reload(thenSelect: [destination])
        }
        return left
    }

    private func reportMultiPage(title: String, detail: String) {
        if let report = MultiPageTools.report { return report(title, detail) }
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Up to 8 lines, and how many more.
    static func listed(_ lines: [String]) -> String {
        var shown = Array(lines.prefix(8))
        if lines.count > 8 {
            shown.append(localized(.init("…and \(lines.count - 8) more.", comment: "Last line of a list of file names that was cut short")))
        }
        return shown.joined(separator: "\n")
    }

    private static func makingTitle(_ destination: URL) -> String {
        localized(.init("Making “\(destination.lastPathComponent)”…", comment: "%@ is the name of the file or folder being made"))
    }
}
