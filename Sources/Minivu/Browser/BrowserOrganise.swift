import AppKit
import MinivuCore

/// Fills an Add to Collection submenu each time it opens: the catalog's
/// collections, then "New Collection…". Items carry the collection's id as
/// their `representedObject` and have no target, so the browser handles and
/// validates them like any menu command.
final class CollectionsMenu: NSObject, NSMenuDelegate {
    let catalog: Catalog

    init(catalog: Catalog = .shared) {
        self.catalog = catalog
    }

    /// A submenu that keeps its delegate alive, as `RecentDestinationsMenu` does.
    static func make(catalog: Catalog = .shared) -> NSMenu {
        let menu = NSMenu(title: "Add to Collection")
        let delegate = CollectionsMenu(catalog: catalog)
        objc_setAssociatedObject(menu, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.delegate = delegate
        delegate.fill(menu)
        return menu
    }

    nonisolated(unsafe) private static var delegateKey: UInt8 = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    /// One small catalog query, on the main thread as the menu opens.
    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let collections = catalog.collections()
        for collection in collections {
            let item = NSMenuItem(title: collection.name, action: .addToCollection, keyEquivalent: "")
            item.representedObject = NSNumber(value: collection.id)
            item.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !collections.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: "New Collection…", action: .newCollection, keyEquivalent: ""))
    }
}

/// The questions finding and organising asks, replaceable in tests: a name
/// for a new collection or smart folder, and whether to delete one.
@MainActor enum OrganisePrompts {
    /// Asks for a name on `window`; the answer is nil when cancelled. The
    /// arguments are the window, the message, the button's title and the
    /// name offered.
    static var askForName: (NSWindow, String, String, String, @escaping (String?) -> Void) -> Void = { window, message,
        button, proposed, answer in
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: proposed)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Name")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            answer(response == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
    }

    /// Asks before deleting a collection or smart folder (never any file).
    static var confirmDelete: (NSWindow, String, String, @escaping (Bool) -> Void) -> Void = { window, message,
        detail, answer in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }
}

/// Find, the flat view, the metadata filter, smart folders and collections
/// for the browser window (G3).
extension BrowserWindowController {
    // MARK: - Flat view and filters

    @objc func toggleFlatView(_ sender: Any?) {
        model.flatView.toggle()
    }

    /// The metadata conditions for what the window shows, applied when the
    /// sheet's Filter button is pressed.
    @objc func showMoreFilters(_ sender: Any?) {
        guard let window, formSheet == nil else { return }
        let form = CriteriaFormModel(model.metadataFilter)
        let sheet = FormSheet(title: "Filter", size: NSSize(width: 560, height: 640)) { sheet in
            FilterFormView(model: form,
                           onCancel: { [weak self] in self?.endFormSheet(sheet) },
                           onApply: { [weak self] in
                               self?.model.metadataFilter = form.criteria
                               self?.endFormSheet(sheet)
                           })
        }
        sheet.criteriaForm = form
        formSheet = sheet
        sheet.begin(on: window)
    }

    func endFormSheet(_ sheet: FormSheet) {
        sheet.end()
        if formSheet === sheet { formSheet = nil }
        window?.makeFirstResponder(grid.collectionView)
    }

    // MARK: - Find

    /// Edit > Find… (⌘F): where to look and what for, starting from the
    /// last search, in the folder shown (the flat view's top folder) or,
    /// for a list, where the last search looked.
    @objc func findImages(_ sender: Any?) {
        var query = lastSearch ?? SearchQuery(scope: model.folder ?? BookmarkStore.picturesFolder)
        if let folder = model.folder { query.scope = folder.standardizedFileURL.path }
        presentSearch(query, confirmTitle: "Find") { [weak self] query in self?.runSearch(query) }
    }

    /// The Find form, for a new search or a smart folder's.
    func presentSearch(_ query: SearchQuery, confirmTitle: String, then confirm: @escaping (SearchQuery) -> Void) {
        guard let window, formSheet == nil else { return }
        let form = SearchFormModel(query: query, scopes: Self.searchScopes(current: model.folder))
        let sheet = FormSheet(title: "Find Images", size: NSSize(width: 580, height: 760)) { sheet in
            SearchFormView(model: form, confirmTitle: confirmTitle,
                           onCancel: { [weak self] in self?.endFormSheet(sheet) },
                           onConfirm: { [weak self] in
                               self?.endFormSheet(sheet)
                               confirm(form.query)
                           })
        }
        sheet.searchForm = form
        formSheet = sheet
        sheet.begin(on: window)
    }

    /// The folders a search can start from: Pictures and the sidebar's
    /// folders (each a grant the user gave), and the folder shown.
    static func searchScopes(current: URL?) -> [URL] {
        var scopes = [BookmarkStore.picturesFolder] + BookmarkStore.shared.folders
        if let current, !scopes.contains(where: { BrowserModel.samePath($0, current) }) { scopes.insert(current, at: 0) }
        return scopes
    }

    /// Shows the results of `query` as a list in this window.
    func runSearch(_ query: SearchQuery) {
        lastSearch = query
        pendingViewerFile = nil
        model.show(list: VirtualList(kind: .search(query), title: Self.searchTitle(query)))
    }

    /// "Search in Pictures", or "“IMG” in Pictures" for a name search.
    nonisolated static func searchTitle(_ query: SearchQuery) -> String {
        let place = FileManager.default.displayName(atPath: query.scope)
        let name = query.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Search in \(place)" : "“\(name)” in \(place)"
    }

    func open(list: VirtualList) {
        pendingViewerFile = nil
        model.show(list: list)
    }

    // MARK: - Smart folders

    /// File > Save as Smart Folder…: the search shown, under a name, in the
    /// sidebar; it runs again whenever it is opened.
    @objc func saveAsSmartFolder(_ sender: Any?) {
        guard let window, case .search(let query)? = model.list?.kind else { return }
        let proposed = query.name.isEmpty ? "Smart Folder" : query.name
        OrganisePrompts.askForName(window, "Save the search as a smart folder named:", "Save", proposed) { [weak self] name in
            guard let self, let name else { return }
            guard let id = self.model.catalog.saveSmartFolder(named: name, query: query) else {
                return self.present(message: "The smart folder couldn’t be saved.")
            }
            self.model.show(list: VirtualList(kind: .smartFolder(id: id), title: name))
        }
    }

    // MARK: - Collections

    /// File > New Collection…: named, then holding the selected images, if
    /// any (Photos' New Album with Selection).
    @objc func newCollection(_ sender: Any?) {
        guard let window else { return }
        let images = model.selectedImageURLs
        OrganisePrompts.askForName(window, "Name the new collection:", "Create", "Untitled Collection") { [weak self] name in
            guard let self, let name else { return }
            let catalog = self.model.catalog
            BrowserModel.catalogWrites.async {
                guard let id = catalog.createCollection(named: name) else { return }
                catalog.addToCollection(id, urls: images)
            }
        }
    }

    /// Adds the selected images to the collection the item names. On the
    /// catalog's queue: recording each file's identity stats it.
    @objc func addToCollection(_ sender: Any?) {
        guard let id = Self.collectionID(of: sender) else { return }
        addToCollection(id, urls: model.selectedImageURLs)
    }

    func addToCollection(_ id: Int64, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let catalog = model.catalog
        BrowserModel.catalogWrites.async { catalog.addToCollection(id, urls: urls) }
    }

    /// Takes the selected images out of the collection shown (never out of
    /// their folders); the list follows when the catalog says so.
    @objc func removeFromCollection(_ sender: Any?) {
        guard case .collection(let id)? = model.list?.kind else { return }
        let urls = model.selectedImageURLs
        guard !urls.isEmpty else { return }
        let next = model.selectionAfterRemoving(Set(urls))
        let catalog = model.catalog
        BrowserModel.catalogWrites.async { catalog.removeFromCollection(id, urls: urls) }
        model.removeEntries(Set(urls))
        if let next, model.entry(for: next) != nil { model.select(next) }
    }

    nonisolated static func collectionID(of sender: Any?) -> Int64? {
        ((sender as? NSMenuItem)?.representedObject as? NSNumber)?.int64Value
    }

    // MARK: - The sidebar's commands

    func perform(_ command: SidebarViewController.LibraryCommand) {
        guard let window else { return }
        let catalog = model.catalog
        switch command {
        case .add(let urls, let id):
            addToCollection(id, urls: urls)
        case .editSearch(let id):
            guard let folder = catalog.smartFolder(id) else { return }
            presentSearch(folder.query, confirmTitle: "Save") { [weak self] query in
                catalog.updateSmartFolder(id, query: query)
                // Showing it: run the edited search now.
                if case .smartFolder(id)? = self?.model.list?.kind, let list = self?.model.list {
                    self?.model.show(list: list)
                }
            }
        case .rename(let list):
            OrganisePrompts.askForName(window, "Rename “\(list.title)” to:", "Rename", list.title) { [weak self] name in
                guard let name else { return }
                switch list.kind {
                case .smartFolder(let id): catalog.renameSmartFolder(id, to: name)
                case .collection(let id): catalog.renameCollection(id, to: name)
                case .search: return
                }
                if self?.model.list?.kind == list.kind {
                    self?.window?.title = name
                }
            }
        case .delete(let list):
            let isCollection = if case .collection = list.kind { true } else { false }
            let detail = isCollection ? "The images in it stay where they are." : "Only the saved search is deleted."
            OrganisePrompts.confirmDelete(window, "Delete “\(list.title)”?", detail) { [weak self] confirmed in
                guard confirmed else { return }
                switch list.kind {
                case .smartFolder(let id): catalog.deleteSmartFolder(id)
                case .collection(let id): catalog.deleteCollection(id)
                case .search: return
                }
                // The list shown has gone: back to where the window was before.
                if self?.model.list?.kind == list.kind {
                    if self?.model.canGoBack == true { self?.model.goBack() } else {
                        self?.model.navigate(to: BookmarkStore.picturesFolder)
                    }
                }
            }
        }
    }

    // MARK: - Validation

    /// Whether a finding or organising command applies now; nil for others.
    func canPerformOrganising(_ action: Selector) -> Bool? {
        let sheet = window.map(BatchTools.hasSheet(on:)) ?? false
        switch action {
        case .findImages: return !sheet
        case .toggleFlatView: return model.folder != nil
        case .showMoreFilters: return !sheet && (model.folder != nil || model.list != nil)
        case .saveAsSmartFolder:
            guard case .search? = model.list?.kind else { return false }
            return !sheet
        case .newCollection: return !sheet
        case .addToCollection: return !sheet && model.hasSelectedImages
        case .removeFromCollection:
            guard case .collection? = model.list?.kind else { return false }
            return model.hasSelectedImages
        default: return nil
        }
    }
}
