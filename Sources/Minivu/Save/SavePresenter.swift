import AppKit
import MinivuCore
import MinivuRender

/// Save and Save As, for the viewer (an edited image) and the browser (an
/// original to convert). The signatures are the contract both call.
enum SavePresenter {
    /// Save As, as a sheet on `window`: format, quality with a side-by-side
    /// preview and live size estimate, colour profile, metadata. `document`
    /// is nil to re-encode the original pixels. Calls `completion` on the
    /// main actor with the written file, or nil when cancelled or failed
    /// (failures are shown to the user by the presenter). On success the
    /// presenter invalidates thumbnails and textures for the written URL.
    ///
    /// Writing over the document's own file counts as saving it, so the
    /// document is marked saved then; a copy elsewhere leaves it as it was.
    static func presentSaveAs(entry: FolderEntry, document: EditDocument?, on window: NSWindow,
                              completion: @escaping (URL?) -> Void) {
        presentSaveAs(entry: entry, document: document, on: window, store: SaveOptionsStore(), completion: completion)
    }

    static func presentSaveAs(entry: FolderEntry, document: EditDocument?, on window: NSWindow,
                              store: SaveOptionsStore, completion: @escaping (URL?) -> Void) {
        let model = SaveAsModel(entry: entry, document: document, store: store)
        let panel = SaveAsPanel(model: model)
        let savedOperations = document?.operations
        panel.begin(on: window) { [weak window] url, options in
            guard let url else {
                completion(nil)
                return
            }
            store.remember(options)
            store.lastFolder = url.deletingLastPathComponent()
            let source = model.source
            let progress = window.map { SaveProgress(on: $0, title: "Saving “\(url.lastPathComponent)”…") }
            // In line with every other write, so a Save of the same file
            // asked for just before can't land after this one.
            let job = FileWriteQueue.shared.enqueue(replacing: [url]) {
                try await write(source, options: options, to: url, metadataSource: entry.url)
            }
            Task {
                do {
                    let outcome = try await job.value
                    progress?.finish()
                    didWrite(url)
                    if let document, sameFile(url, entry.url), outcome.isNewest, document.operations == savedOperations {
                        document.markSaved()
                    }
                    completion(url)
                } catch {
                    progress?.finish()
                    SaveAlert.show(error, title: "“\(url.lastPathComponent)” couldn’t be saved.", on: window)
                    completion(nil)
                }
            }
        }
    }

    /// Save (⌘S): writes the edited image over its original, in the original's
    /// format with the options last used for that format, after confirming the
    /// overwrite (with "Don't ask again"). Formats minivu can't write (camera
    /// RAW, WebP, JPEG XL, AVIF, PDF, SVG, PSD, animated files) fall back to
    /// Save As. On success calls `document.markSaved()`, invalidates caches and
    /// calls `completion(true)`.
    ///
    /// Saves run one after another (`FileWriteQueue`): ⌘S, an edit and ⌘S
    /// again write in that order, and the document is marked saved only by
    /// the last write of its file, when its operations are still the ones
    /// written.
    ///
    /// After a save the file holds the edits. The document's operations are
    /// still relative to the original it decoded, so the caller must not
    /// decode this document again from the file (`EditRenderer.release`
    /// then `prepare`): the edits would be applied a second time. To reload,
    /// start a new `EditDocument` on the saved file.
    ///
    /// `canReplace` is asked again once the overwrite is confirmed, just
    /// before writing: the file may have been changed by another application
    /// while the question was up, and then Save As opens instead.
    static func save(entry: FolderEntry, document: EditDocument, on window: NSWindow,
                     canReplace: @escaping () -> Bool = { true }, completion: @escaping (Bool) -> Void) {
        save(entry: entry, document: document, on: window, store: SaveOptionsStore(),
             preferences: .shared, canReplace: canReplace, completion: completion)
    }

    static func save(entry: FolderEntry, document: EditDocument, on window: NSWindow, store: SaveOptionsStore,
                     preferences: Preferences, canReplace: @escaping () -> Bool = { true },
                     completion: @escaping (Bool) -> Void) {
        let url = entry.url
        Task { [weak window] in
            // Reading the header is disk work: never on the main thread.
            let (info, sourceSpace) = await BlockingWork.run {
                (ImageDecoder.info(for: url), SavePolicy.sourceColorSpace(of: url))
            }
            guard let window else { return completion(false) }
            guard let format = SavePolicy.inPlaceFormat(for: url, info: info), let info else {
                presentSaveAs(entry: entry, document: document, on: window, store: store) { completion($0 != nil) }
                return
            }
            // Nothing to write: re-encoding unchanged pixels only loses quality.
            guard document.isDirty else { return completion(true) }
            let options = SavePolicy.inPlaceOptions(remembered: store.options(for: format),
                                                    sourceBitDepth: info.bitDepth)
            confirmOverwrite(of: entry, options: options, on: window, preferences: preferences) { confirmed in
                guard confirmed else { return completion(false) }
                guard canReplace() else {
                    presentSaveAs(entry: entry, document: document, on: window, store: store) { completion($0 != nil) }
                    return
                }
                let space = SavePolicy.renderColorSpace(source: sourceSpace, isHDR: info.isHDR, preferWideGamut: false)
                writeInPlace(entry: entry, document: document, options: options, colorSpace: space, on: window,
                             completion: completion)
            }
        }
    }

    private static func writeInPlace(entry: FolderEntry, document: EditDocument, options: ExportOptions,
                                     colorSpace: CGColorSpace, on window: NSWindow,
                                     completion: @escaping (Bool) -> Void) {
        let snapshot = document.snapshot()
        let savedOperations = snapshot.operations
        let renderer = EditRenderer.shared
        let url = entry.url
        let progress = SaveProgress(on: window, title: "Saving “\(entry.name)”…")
        let job = FileWriteQueue.shared.enqueue(replacing: [url]) {
            try await writeInPlace(snapshot, colorSpace: colorSpace, options: options, to: url, renderer: renderer)
        }
        Task { [weak window] in
            do {
                let outcome = try await job.value
                progress.finish()
                didWrite(url)
                // Only what was written counts as saved: an edit made while
                // the save ran leaves the document dirty, and so does a
                // newer write of the file still queued behind this one.
                if outcome.isNewest, document.operations == savedOperations { document.markSaved() }
                completion(true)
            } catch {
                progress.finish()
                SaveAlert.show(error, title: "“\(entry.name)” couldn’t be saved.", on: window)
                completion(false)
            }
        }
    }

    /// The Save As write: the panel's render for `options`, encoded in the background.
    static func write(_ source: SaveImageSource, options: ExportOptions, to url: URL, metadataSource: URL) async throws {
        let image = try await source.image(for: options)
        try await BlockingWork.run {
            try ImageEncoder.write(image, to: url, options: options, metadataSource: metadataSource)
        }
    }

    /// The Save write: the committed operations rendered at full resolution
    /// and written over `url`. The metadata is read from the original while
    /// the new file is written beside it, before it replaces it.
    nonisolated static func writeInPlace(_ snapshot: EditDocument.Snapshot, colorSpace: CGColorSpace,
                                         options: ExportOptions, to url: URL, renderer: EditRenderer) async throws {
        let bits = options.format.supports16Bit && options.sixteenBit ? 16 : 8
        let image = try await renderer.renderForExport(snapshot, colorSpace: colorSpace, bitsPerComponent: bits)
        // Encoding and the file write block: on GCD (BlockingWork).
        try await BlockingWork.run { try ImageEncoder.write(image, to: url, options: options, metadataSource: url) }
    }

    /// "Replace the original?", unless the user ticked "Don't ask again" once.
    private static func confirmOverwrite(of entry: FolderEntry, options: ExportOptions, on window: NSWindow,
                                         preferences: Preferences, then: @escaping (Bool) -> Void) {
        guard preferences.confirmOverwriteOnSave else { return then(true) }
        let alert = NSAlert()
        alert.messageText = "Replace the original “\(entry.name)”?"
        alert.informativeText = SavePolicy.overwriteDetail(options)
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { response in
            let confirmed = response == .alertFirstButtonReturn
            if confirmed, alert.suppressionButton?.state == .on {
                preferences.confirmOverwriteOnSave = false
            }
            then(confirmed)
        }
    }

    /// After any write minivu made: the browser's thumbnails and the
    /// viewer's textures of that file show the old picture. A file also
    /// open in an external editor is watched; the watcher takes this write's
    /// date and size as its own, so it doesn't report minivu's save back as
    /// another application's (a second reload, or a needless question).
    static func didWrite(_ url: URL) {
        AppServices.thumbnails.invalidate(url)
        AppServices.images.invalidate(url)
        ExternalEditWatcher.shared.noteOwnWrite(url)
    }

    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The JPEG comment editor.
enum CommentEditor {
    /// Edits the COM comment of a JPEG. Calls `completion(true)` after writing.
    static func present(for url: URL, on window: NSWindow, completion: @escaping (Bool) -> Void) {
        Task { [weak window] in
            let text = await BlockingWork.run { JPEGComment.read(from: url) ?? "" }
            guard let window else { return completion(false) }
            CommentEditorSheet(url: url, comment: text).begin(on: window, completion: completion)
        }
    }
}
