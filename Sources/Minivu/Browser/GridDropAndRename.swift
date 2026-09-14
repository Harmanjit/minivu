import AppKit
import MinivuCore

/// What dropping files at a place in the grid does.
nonisolated enum GridDropPlan: Equatable {
    /// Copy or move the files into this folder (the grid's own folder, or a
    /// folder cell).
    case transfer(files: [URL], destination: URL)
    /// Custom Order: put the files before this image (at the end for nil).
    case reorder(files: [URL], before: URL?)

    /// Decides a drop, from plain values so it can be tested without a drag.
    ///
    /// - Onto a folder cell: into that folder.
    /// - Anywhere else, files from elsewhere: into the grid's folder.
    /// - Files already in the grid's folder: a reorder when the grid is in
    ///   Custom Order and every file is an image of the folder; otherwise
    ///   nothing (they are already where they would go).
    ///
    /// - Parameters:
    ///   - entries: the visible entries, folders first.
    ///   - index: the proposed item; `on` is whether the drop is onto it
    ///     rather than into the gap before it.
    ///   - isImageInFolder: whether a name is an image of the folder, hidden
    ///     by a filter or not.
    static func decide(files: [URL], folder: URL, entries: [FolderEntry], index: Int, on: Bool, customOrder: Bool,
                       isImageInFolder: (String) -> Bool) -> GridDropPlan? {
        guard !files.isEmpty else { return nil }
        if on, entries.indices.contains(index), entries[index].isDirectory {
            let target = entries[index].url
            let movable = DropRules.movableItems(files, into: target)
            if !movable.isEmpty { return .transfer(files: movable, destination: target) }
        }
        let movable = DropRules.movableItems(files, into: folder)
        if !movable.isEmpty { return .transfer(files: movable, destination: folder) }
        guard customOrder, files.allSatisfy({ isImageInFolder($0.lastPathComponent) }) else { return nil }
        let images = entries.filter { !$0.isDirectory }
        let folders = entries.count - images.count
        let target = entries.indices.contains(max(index, folders)) ? entries[max(index, folders)].url : nil
        return .reorder(files: files, before: target)
    }
}

/// The outline shown round the grid while a drop would land in its folder.
final class DropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }

    /// A highlight, never a target: drags and clicks go to the grid beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension GridViewController {
    // MARK: - Drop

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func plan(for info: NSDraggingInfo, index: Int, on: Bool) -> GridDropPlan? {
        guard let folder = model.folder, model.state == .loaded, renameEditor == nil else { return nil }
        return GridDropPlan.decide(files: Self.fileURLs(from: info.draggingPasteboard), folder: folder,
                                   entries: model.entries, index: index, on: on,
                                   customOrder: model.sortOrder.key == .custom,
                                   isImageInFolder: { [model] in model.containsImage(named: $0) })
    }

    /// Copy or move by Finder's rules, the volume answer kept for the drag.
    private func operation(for info: NSDraggingInfo, files: [URL], destination: URL) -> NSDragOperation {
        guard VolumePolicy.isAllowed(destination), let first = files.first else { return [] }
        if dropVolumeCache.sequence != info.draggingSequenceNumber {
            dropVolumeCache = (info.draggingSequenceNumber, [:])
        }
        let key = destination.path
        let same = dropVolumeCache.answers[key] ?? DropRules.sameVolume(first, destination)
        dropVolumeCache.answers[key] = same
        return DropRules.operation(sourceMask: info.draggingSourceOperationMask, sameVolume: same)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
        -> NSDragOperation {
        let index = proposedDropIndexPath.pointee.item
        guard let plan = plan(for: draggingInfo, index: index, on: proposedDropOperation.pointee == .on) else {
            dropHighlight.isHidden = true
            return []
        }
        switch plan {
        case .reorder:
            // A gap between items shows where they will go; never before the folders.
            dropHighlight.isHidden = true
            proposedDropOperation.pointee = .before
            let firstImage = model.folderCount
            if index < firstImage { proposedDropIndexPath.pointee = IndexPath(item: firstImage, section: 0) as NSIndexPath }
            return .move
        case .transfer(let files, let destination):
            let operation = operation(for: draggingInfo, files: files, destination: destination)
            let intoGridFolder = model.folder.map { BrowserModel.samePath($0, destination) } ?? false
            dropHighlight.isHidden = operation.isEmpty || !intoGridFolder
            if intoGridFolder, let firstImage = model.entries.firstIndex(where: { !$0.isDirectory }) {
                // Onto an image, which draws nothing: no gap indicator, which
                // would promise a place in the order, and no folder lit up.
                let entries = model.entries
                let target = entries.indices.contains(index) && !entries[index].isDirectory ? index : firstImage
                proposedDropOperation.pointee = .on
                proposedDropIndexPath.pointee = IndexPath(item: target, section: 0) as NSIndexPath
            }
            return operation
        }
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        dropHighlight.isHidden = true
        guard let plan = plan(for: draggingInfo, index: indexPath.item, on: dropOperation == .on) else { return false }
        switch plan {
        case .reorder(let files, let before):
            model.moveImages(files, before: before)
        case .transfer(let files, let destination):
            let operation = operation(for: draggingInfo, files: files, destination: destination)
            guard !operation.isEmpty else { return false }
            onDropFiles?(files, destination, operation.contains(.move))
        }
        return true
    }

    // MARK: - Rename

    /// Edits `url`'s name in place, the name without its extension selected
    /// (Finder's convention). `proposedName` puts back a name the user typed
    /// that couldn't be used, to correct it.
    func beginRename(_ url: URL, proposedName: String? = nil) {
        renameEditor?.cancel()
        guard let index = model.index(of: url), let window = view.window else { return }
        let entry = model.entries[index]
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        let name = thumbnailLayout.nameFrame.offsetBy(dx: item.minX, dy: item.minY)
        // Wider than a small cell, so a long name has room, but inside the grid.
        let width = min(max(item.width - 4, 160), collectionView.bounds.width - 8)
        let x = min(max(item.midX - width / 2, 4), collectionView.bounds.width - width - 4)
        let frame = CGRect(x: x.rounded(), y: name.minY - 3, width: width.rounded(), height: name.height + 6)

        let editor = InlineRenameEditor(url: entry.url, originalName: entry.name)
        editor.onCommit = { [weak self] url, newName in self?.onRename?(url, newName) }
        editor.onEnd = { [weak self, weak editor] in
            guard let self, self.renameEditor === editor else { return }
            self.renameEditor = nil
            self.view.window?.makeFirstResponder(self.collectionView)
        }
        renameEditor = editor
        editor.begin(in: collectionView, frame: frame, window: window, text: proposedName ?? entry.name,
                     selectingBaseName: !entry.isDirectory)
    }
}

/// Finder-style renaming: a text field over an item's name. Return (or Tab,
/// or clicking elsewhere) commits, Esc cancels. The field lives in the
/// collection view, not the cell, so it scrolls with the item and survives
/// the cell being recycled or the grid reloading.
final class InlineRenameEditor: NSObject, NSTextFieldDelegate {
    let url: URL
    let originalName: String
    let field = NSTextField(string: "")
    var onCommit: ((URL, String) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var isFinished = false

    init(url: URL, originalName: String) {
        self.url = url
        self.originalName = originalName
        super.init()
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel("Name")
    }

    func begin(in view: NSView, frame: CGRect, window: NSWindow, text: String, selectingBaseName: Bool) {
        field.stringValue = text
        field.frame = frame
        view.addSubview(field)
        window.makeFirstResponder(field)
        let base = selectingBaseName ? (text as NSString).deletingPathExtension : text
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    /// Focus went elsewhere (a click on another item): that commits, as in Finder.
    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    func commit() {
        guard !isFinished else { return }
        let name = field.stringValue
        finish()
        if name != originalName { onCommit?(url, name) }
    }

    func cancel() {
        guard !isFinished else { return }
        finish()
    }

    /// Marked finished before the field goes: removing the first responder
    /// ends its editing, which calls back into `commit`.
    private func finish() {
        isFinished = true
        field.removeFromSuperview()
        onEnd?()
    }
}
