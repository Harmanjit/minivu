import AppKit
import MinivuCore

/// Ratings, tags, filters, renaming, new folders, and copying and moving
/// files, for the browser window (DESIGN.md 5).
///
/// File operations run off the main thread and register Undo with the
/// window's undo manager. NSUndoManager puts an action on the redo stack only
/// while it is undoing, so work that finishes later registers its inverse at
/// once when it is itself an undo or redo, and only after it succeeded when
/// it is a fresh action (see `undoRegistration`).
extension BrowserWindowController {
    // MARK: - Ratings and tags

    /// Image > Rating (⌃0–⌃5) and the context menu; the tag is the rating.
    @objc func setRating(_ sender: Any?) {
        guard let stars = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag else { return }
        model.setRating(stars, for: model.selectedImageURLs)
    }

    @objc func toggleTag(_ sender: Any?) {
        model.toggleTag(for: model.selectedImageURLs)
    }

    // MARK: - Filters

    /// "Show All" (tag 0) clears every filter; 1 to 5 shows images rated at
    /// least that.
    @objc func filterByRating(_ sender: Any?) {
        let minimum = (sender as? NSMenuItem)?.tag ?? 0
        if minimum <= 0 {
            model.marksFilter = MarksFilter()
        } else {
            model.marksFilter.minimumRating = min(minimum, 5)
        }
    }

    @objc func toggleTaggedFilter(_ sender: Any?) {
        model.marksFilter.taggedOnly.toggle()
    }

    /// The toolbar's Finder tag items: choosing the active tag turns it off.
    func filterByFinderTag(_ name: String?) {
        model.marksFilter.finderTag = model.marksFilter.finderTag == name ? nil : name
    }

    // MARK: - Rename

    /// F2 or the context menu: edit the name in place.
    @objc func renameItem(_ sender: Any?) {
        guard model.selection.count == 1, let lead = model.lead else { return NSSound.beep() }
        grid.beginRename(lead)
    }

    /// The inline editor finished. A name that can't be used is explained,
    /// then the editor comes back with it to correct.
    func commitRename(_ url: URL, to name: String) {
        if let problem = FileOperations.validateName(name, in: url.deletingLastPathComponent(), excluding: url) {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = problem
            alert.informativeText = "Please choose a different name."
            alert.beginSheetModal(for: window) { [weak self] _ in
                MainActor.assumeIsolated { self?.grid.beginRename(url, proposedName: name) }
            }
            return
        }
        performRename(url, to: name)
    }

    /// Renames off the main thread, then lists the folder with the file
    /// selected under its new name. Undo renames it back.
    func performRename(_ url: URL, to name: String) {
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        let oldName = url.lastPathComponent
        let done = undoRegistration("Rename") { $0.performRename(renamed, to: oldName) }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileOperations.rename(url, to: name) }
            }.value
            switch result {
            case .success(let newURL):
                BrowserModel.invalidateCaches(url)
                done(true)
                if let folder = model.folder, BrowserModel.samePath(folder, newURL.deletingLastPathComponent()) {
                    model.reload(thenSelect: [newURL])
                }
            case .failure(let error):
                done(false)
                present(error)
            }
        }
    }

    // MARK: - New folder

    /// ⇧⌘N: "untitled folder" in the folder shown, then its name to edit.
    @objc func newFolder(_ sender: Any?) {
        guard let folder = model.folder, model.state == .loaded else { return NSSound.beep() }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileOperations.createFolder(in: folder) }
            }.value
            switch result {
            case .success(let url):
                undoRegistrar("New Folder")(true, { $0.trashItems([url], actionName: "New Folder") })
                pendingRename = url
                model.reload(thenSelect: [url])
            case .failure(let error):
                present(error)
            }
        }
    }

    // MARK: - Copy To and Move To

    @objc func copyToFolder(_ sender: Any?) {
        transferSelection(move: false, sender: sender)
    }

    @objc func moveToFolder(_ sender: Any?) {
        transferSelection(move: true, sender: sender)
    }

    /// A recent folder from the submenu goes straight there; otherwise an
    /// open panel asks where.
    private func transferSelection(move: Bool, sender: Any?) {
        let files = model.selectedEntries.map(\.url)
        guard !files.isEmpty, let window else { return NSSound.beep() }
        if let folder = (sender as? NSMenuItem)?.representedObject as? URL {
            RecentDestinations.shared.add(folder)
            transfer(files, to: folder, move: move)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move" : "Copy"
        panel.message = "Choose a folder to \(move ? "move" : "copy") \(FileTransfer.itemsText(files.count)) to."
        panel.directoryURL = RecentDestinations.shared.folders.first ?? model.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let folder = panel.url else { return }
                guard VolumePolicy.isAllowed(folder) else {
                    self.present(message: BrowserModel.message(for: FolderListingError.notAllowed(folder)))
                    return
                }
                RecentDestinations.shared.add(folder)
                self.transfer(files, to: folder, move: move)
            }
        }
    }

    // MARK: - Transfers

    /// Copies or moves files into `destination` (a drop, Copy To or Move
    /// To), then shows the result: arrivals in this folder are selected,
    /// files that left it make way for the next one.
    func transfer(_ files: [URL], to destination: URL, move: Bool) {
        guard !files.isEmpty else { return }
        guard !isTransferring else { return NSSound.beep() }
        guard VolumePolicy.isAllowed(destination) else {
            return present(message: BrowserModel.message(for: FolderListingError.notAllowed(destination)))
        }
        isTransferring = true
        let request = FileTransfer.Request(files: files, destination: destination, isMove: move)
        let next = move ? model.selectionAfterRemoving(Set(files)) : nil
        let resolver = transferConflictResolver
        transferWork = Task {
            let outcome = await FileTransfer.run(request, window: window, resolver: resolver)
            isTransferring = false
            if move { outcome.transfers.forEach { BrowserModel.invalidateCaches($0.from) } }
            outcome.replaced.forEach(BrowserModel.invalidateCaches)
            if !outcome.transfers.isEmpty {
                let pairs = outcome.transfers
                let name = Self.transferActionName(count: pairs.count, isMove: move)
                undoRegistrar(name)(true, { controller in
                    if move {
                        controller.moveExactly(Self.reversed(pairs), actionName: name)
                    } else {
                        controller.trashItems(pairs.map(\.to), actionName: name, redo: pairs)
                    }
                })
            }
            showTransferred(outcome.transfers, isMove: move, thenSelect: next)
            FileTransfer.reportFailures(outcome, on: window)
        }
    }

    /// "Move 3 Items", "Copy 1 Item": the Undo and Redo titles.
    nonisolated static func transferActionName(count: Int, isMove: Bool) -> String {
        "\(isMove ? "Move" : "Copy") \(count == 1 ? "1 Item" : "\(count.formatted()) Items")"
    }

    nonisolated static func reversed(_ pairs: [FileOperations.Transfer]) -> [FileOperations.Transfer] {
        pairs.map { FileOperations.Transfer(from: $0.to, to: $0.from) }
    }

    private func showTransferred(_ pairs: [FileOperations.Transfer], isMove: Bool, thenSelect next: URL?) {
        guard let folder = model.folder, !pairs.isEmpty else { return }
        let inFolder = { (url: URL) in BrowserModel.samePath(url.deletingLastPathComponent(), folder) }
        let arrived = pairs.map(\.to).filter(inFolder)
        let left = isMove ? pairs.map(\.from).filter(inFolder) : []
        if !arrived.isEmpty {
            model.reload(thenSelect: arrived)
        } else if !left.isEmpty {
            model.removeEntries(Set(left))
            if let next, model.entry(for: next) != nil { model.select(next) }
            model.reload()
        }
        // A folder moved or copied changes the sidebar's tree; rows not
        // listed yet cost nothing.
        sidebarFolderChanged(Array(Set(pairs.map { $0.to.deletingLastPathComponent() }
                                       + pairs.map { $0.from.deletingLastPathComponent() })))
    }

    /// Undo and Redo of a move: each file back to exactly where it was.
    func moveExactly(_ pairs: [FileOperations.Transfer], actionName: String) {
        let done = undoRegistration(actionName) { $0.moveExactly(Self.reversed(pairs), actionName: actionName) }
        Task {
            let moved = await Task.detached(priority: .userInitiated) {
                pairs.filter { Self.moveFile($0.from, exactlyTo: $0.to) }
            }.value
            moved.forEach { BrowserModel.invalidateCaches($0.from) }
            done(!moved.isEmpty)
            showTransferred(moved, isMove: true, thenSelect: nil)
            if moved.count < pairs.count { present(message: "Some items couldn’t be put back.") }
        }
    }

    /// Redo of a copy: the same files copied again to the same names.
    func copyExactly(_ pairs: [FileOperations.Transfer], actionName: String) {
        let done = undoRegistration(actionName) { $0.trashItems(pairs.map(\.to), actionName: actionName, redo: pairs) }
        Task {
            let copied = await Task.detached(priority: .userInitiated) {
                pairs.filter { Self.copyFile($0.from, exactlyTo: $0.to) }
            }.value
            done(!copied.isEmpty)
            showTransferred(copied, isMove: false, thenSelect: nil)
        }
    }

    /// Undo of a copy or a new folder: what was made goes to the Trash,
    /// where it can still be recovered. `redo` makes the copies again.
    func trashItems(_ urls: [URL], actionName: String, redo: [FileOperations.Transfer]? = nil) {
        let done = undoRegistration(actionName) { controller in
            if let redo {
                controller.copyExactly(redo, actionName: actionName)
            } else {
                controller.recreateFolders(urls, actionName: actionName)
            }
        }
        Task {
            let trashed = (try? await NSWorkspace.shared.recycle(urls)).map { Array($0.keys) } ?? []
            trashed.forEach(BrowserModel.invalidateCaches)
            done(!trashed.isEmpty)
            model.removeEntries(Set(trashed))
            model.reload()
        }
    }

    /// Redo of New Folder.
    func recreateFolders(_ urls: [URL], actionName: String) {
        let done = undoRegistration(actionName) { $0.trashItems(urls, actionName: actionName) }
        Task {
            let made = await Task.detached(priority: .userInitiated) {
                urls.filter { (try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)) != nil }
            }.value
            done(!made.isEmpty)
            model.reload(thenSelect: made)
        }
    }

    /// Moves a file to exactly `to`, name included (a Keep Both copy named
    /// "photo 2.jpg" goes back as "photo.jpg"). Refuses to overwrite.
    nonisolated static func moveFile(_ from: URL, exactlyTo to: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: to.path) else { return false }
        let result = FileOperations.move([from], to: to.deletingLastPathComponent(), conflict: .skip)
        guard let moved = result.completed.first?.to else { return false }
        guard moved.lastPathComponent != to.lastPathComponent else { return true }
        return (try? FileOperations.rename(moved, to: to.lastPathComponent)) != nil
    }

    nonisolated static func copyFile(_ from: URL, exactlyTo to: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: to.path) else { return false }
        let result = FileOperations.copy([from], to: to.deletingLastPathComponent(), conflict: .keepBoth)
        guard let copied = result.completed.first?.to else { return false }
        guard copied.lastPathComponent != to.lastPathComponent else { return true }
        return (try? FileOperations.rename(copied, to: to.lastPathComponent)) != nil
    }

    // MARK: - Undo

    /// Registers `inverse` under `actionName` at the right moment: now, when
    /// this is running as an undo or redo (so it lands on the other stack),
    /// or when the returned function is called with true, for a fresh action
    /// that has just succeeded.
    func undoRegistration(_ actionName: String,
                          _ inverse: @escaping @MainActor (BrowserWindowController) -> Void) -> (Bool) -> Void {
        let register = undoRegistrar(actionName)
        guard let manager = window?.undoManager, manager.isUndoing || manager.isRedoing else {
            return { succeeded in register(succeeded, inverse) }
        }
        register(true, inverse)
        return { _ in }
    }

    /// The registration step alone: call with true and the inverse to file it.
    func undoRegistrar(_ actionName: String)
        -> (Bool, @escaping @MainActor (BrowserWindowController) -> Void) -> Void {
        { [weak self] succeeded, inverse in
            guard succeeded, let self, let manager = self.window?.undoManager else { return }
            manager.registerUndo(withTarget: self, handler: inverse)
            manager.setActionName(actionName)
        }
    }

    // MARK: - Alerts

    func present(_ error: Error) {
        guard let window else { return }
        if window.attachedSheet == nil {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    func present(message: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Validation

    /// Whether a management command applies now; nil for other commands.
    func canPerformManagement(_ action: Selector) -> Bool? {
        let sheet = window?.attachedSheet != nil
        switch action {
        case .setRating, .toggleTag:
            return model.hasSelectedImages
        case .filterByRating, .toggleTaggedFilter:
            return model.folder != nil
        case .renameItem:
            return !sheet && model.selection.count == 1 && grid.renameEditor == nil
        case .newFolder:
            return !sheet && model.state == .loaded
        case .copyToFolder, .moveToFolder:
            return !sheet && !model.selection.isEmpty && !isTransferring
        default:
            return nil
        }
    }

    /// Checkmarks: the filter in force, and the rating and tag the whole
    /// selection shares.
    func updateManagementState(_ menuItem: NSMenuItem) {
        switch menuItem.action {
        case .filterByRating:
            let filter = model.marksFilter
            menuItem.state = (menuItem.tag == 0 ? !filter.isActive : filter.minimumRating == menuItem.tag) ? .on : .off
        case .toggleTaggedFilter:
            menuItem.state = model.marksFilter.taggedOnly ? .on : .off
        case .setRating:
            let urls = model.selectedImageURLs
            menuItem.state = !urls.isEmpty && urls.allSatisfy({ model.marks(for: $0).rating == menuItem.tag }) ? .on : .off
        case .toggleTag:
            let urls = model.selectedImageURLs
            menuItem.state = !urls.isEmpty && urls.allSatisfy({ model.marks(for: $0).isTagged }) ? .on : .off
        default:
            break
        }
    }
}
