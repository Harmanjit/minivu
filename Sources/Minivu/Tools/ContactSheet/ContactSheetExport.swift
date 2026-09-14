import AppKit
import MinivuCore

/// Saving a contact sheet: where it goes, making it off the main thread,
/// and putting the finished files in place without ever replacing a file
/// the user didn't choose to replace.
///
/// Pages are made in a scratch folder on the destination's volume (the
/// system's item-replacement folder, which the sandbox allows even when
/// only a single file was granted by the save panel). Only when every page
/// is finished are they moved into place, through `FileWriteQueue`, so a
/// cancelled or failed sheet leaves nothing behind in the destination, and
/// memory never holds more than a page.
enum ContactSheetExport {
    enum Destination: Equatable {
        /// A PDF, or a single raster page: the file named in the save panel.
        /// The panel already asked before replacing an existing file.
        case file(URL)
        /// Several raster pages into a folder, each under its own new name.
        case folder(URL, names: [String])
    }

    /// Moves a replaced file out of the way. The Trash by default; tests
    /// pass a scratch folder.
    typealias Trasher = @Sendable (URL) throws -> Void

    nonisolated static let systemTrash: Trasher = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Makes the sheet and writes it to `destination`; returns the files
    /// written, in page order. `progress` gets (pages done, pages) on the
    /// main actor; `didWrite` is told of each file placed (tests pass their
    /// own, sparing the app's caches). Throws
    /// `ContactSheetRenderer.Failure.cancelled` if `cancel` is set before
    /// the files are placed.
    static func export(items: [LayoutItem], settings: ContactSheetSettings, header: String?, destination: Destination,
                       cancel: CancellationFlag, provider: LayoutImageProvider = LayoutImageProvider(byteBudget: 128 << 20),
                       trash: @escaping Trasher = systemTrash,
                       didWrite: @MainActor (URL) -> Void = SavePresenter.didWrite,
                       progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> [URL] {
        let settings = settings.validated
        let pageCount = settings.pageCount(imageCount: items.count)
        let finals: [URL]
        let folder: URL
        switch destination {
        case .file(let url):
            finals = [url]
            folder = url.deletingLastPathComponent()
        case .folder(let url, let names):
            finals = names.map { url.appendingPathComponent($0) }
            folder = url
        }
        guard !finals.isEmpty, pageCount > 0 else { return [] }

        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let scratch = try await BlockingWork.run { try scratchFolder(for: finals[0]) }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let report: @Sendable (Int) -> Void = { done in
            Task { @MainActor in progress(done, pageCount) }
        }
        let made: [URL] = try await BlockingWork.run {
            if settings.format == .pdf {
                let temp = scratch.appendingPathComponent(finals[0].lastPathComponent)
                try ContactSheetRenderer.writePDF(items: items, settings: settings, header: header, to: temp,
                                                  provider: provider, cancel: cancel, progress: report)
                return [temp]
            }
            let names = finals.map(\.lastPathComponent)
            return try ContactSheetRenderer.writeRasterPages(items: items, settings: settings, header: header,
                                                             names: Array(names.prefix(pageCount)), into: scratch,
                                                             provider: provider, cancel: cancel, progress: report)
        }
        guard !cancel.isCancelled else { throw ContactSheetRenderer.Failure.cancelled }

        let replacesChosenFile: Bool
        if case .file = destination { replacesChosenFile = true } else { replacesChosenFile = false }
        let pairs = Array(zip(made, finals))
        let job = FileWriteQueue.shared.enqueue(replacing: finals) {
            // Moves and trashing are blocking file-system calls: on a GCD
            // thread, not the Swift pool the queue's task runs on.
            try await BlockingWork.run { try placeAll(pairs, replacing: replacesChosenFile, trash: trash) }
        }
        let placed = try await job.value.value
        // A sheet written over a picture the browser shows must not keep
        // its old thumbnail.
        placed.forEach(didWrite)
        return placed
    }

    /// Puts every finished page in place, in order. If one can't be placed,
    /// the pages already placed by this call are removed again (they are
    /// new files, never the user's), so a failed sheet leaves nothing half
    /// done in the folder.
    nonisolated static func placeAll(_ pairs: [(URL, URL)], replacing: Bool, trash: Trasher) throws -> [URL] {
        var placed: [URL] = []
        do {
            for (temp, final) in pairs { placed.append(try place(temp, at: final, replacing: replacing, trash: trash)) }
        } catch {
            // A page that replaced a file (only a single chosen file can)
            // stays: the old one is already in the Trash.
            if !replacing { for url in placed { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
        return placed
    }

    /// Puts a finished page at `final`. A file already there is the one the
    /// save panel asked about: it goes to the Trash first (atomic replace if
    /// it can't be trashed, the user having chosen Replace). In a folder a
    /// clash can only be a file made since the names were chosen, which
    /// keeps its name; the page takes the next free one instead.
    nonisolated static func place(_ temp: URL, at final: URL, replacing: Bool, trash: Trasher) throws -> URL {
        let manager = FileManager.default
        guard replacing else {
            // Renames that never overwrite: a name taken between the check
            // and the move (by another app) moves on to the next free one.
            let folder = final.deletingLastPathComponent()
            var target = final
            for _ in 0..<20 {
                do {
                    try FileOperations.moveExclusively(temp, to: target)
                    return target
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    target = folder.appendingPathComponent(FileOperations.uniqueName(for: final.lastPathComponent,
                                                                                     in: folder))
                }
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: final.path])
        }
        guard manager.fileExists(atPath: final.path) else {
            try manager.moveItem(at: temp, to: final)
            return final
        }
        if (try? trash(final)) != nil, !manager.fileExists(atPath: final.path) {
            try manager.moveItem(at: temp, to: final)
        } else {
            try SafeFileWriter.replace(final) { slot in try manager.moveItem(at: temp, to: slot) }
        }
        return final
    }

    /// A fresh folder on `target`'s volume for pages being made.
    nonisolated static func scratchFolder(for target: URL) throws -> URL {
        let manager = FileManager.default
        if let folder = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: target.deletingLastPathComponent(), create: true) {
            return folder
        }
        let folder = manager.temporaryDirectory.appendingPathComponent("minivu-contact-sheet-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Choosing where

    /// Asks where to save, as a sheet on `window`: a save panel for one
    /// file, a folder chooser for several pages. Calls `completion` with
    /// nil when cancelled.
    static func chooseDestination(base: String, settings: ContactSheetSettings, pageCount: Int, startFolder: URL?,
                                  on window: NSWindow, completion: @escaping (Destination?) -> Void) {
        let format = settings.format
        if format == .pdf || pageCount <= 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.utType]
            panel.nameFieldStringValue = ContactSheetNaming.singleName(base: base, format: format)
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let startFolder { panel.directoryURL = startFolder }
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url.map(Destination.file) : nil)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Pages"
        panel.message = "Choose a folder for the \(pageCount) pages of “\(base)”."
        if let startFolder { panel.directoryURL = startFolder }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return completion(nil) }
            let names = ContactSheetNaming.pageNames(base: base, count: pageCount, fileExtension: format.fileExtension) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            completion(.folder(folder, names: names))
        }
    }

    /// Opens what was written in the viewer: the PDF or picture, or the
    /// pages in order.
    static func showResult(_ urls: [URL]) {
        let entries = urls.compactMap(FolderEntry.init(url:))
        guard !entries.isEmpty else { return }
        ViewerWindowController.show(images: entries, index: 0, fullScreen: false, onClose: { _ in })
    }
}

/// A sheet with a progress bar and Cancel, shown while a contact sheet is
/// made; only after a moment, so a quick one-page sheet doesn't flash it.
final class ContactSheetProgress {
    private weak var parent: NSWindow?
    private var sheet: NSWindow?
    private let bar = NSProgressIndicator()
    private let detail = NSTextField(labelWithString: "")
    private var pending: Task<Void, Never>?
    let cancel = CancellationFlag()

    init(on parent: NSWindow, title: String, pageCount: Int, delay: Duration) {
        self.parent = parent
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(pageCount, 1))
        detail.stringValue = pageCount > 1 ? "Page 1 of \(pageCount)" : ""
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.show(title)
        }
    }

    func update(done: Int, of total: Int) {
        bar.doubleValue = Double(done)
        if total > 1 { detail.stringValue = "Page \(min(done + 1, total)) of \(total)" }
    }

    private func show(_ title: String) {
        guard let parent, parent.isVisible, parent.attachedSheet == nil else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bar.style = .bar
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        button.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [detail, NSView(), button])
        row.orientation = .horizontal
        let stack = NSStackView(views: [label, bar, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        row.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = stack
        sheet = window
        parent.beginSheet(window)
    }

    @objc private func cancelPressed() {
        cancel.cancel()
        detail.stringValue = "Cancelling…"
    }

    func finish() {
        pending?.cancel()
        pending = nil
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
    }
}
