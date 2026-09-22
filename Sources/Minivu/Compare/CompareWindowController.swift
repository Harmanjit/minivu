import AppKit
import MinivuCore
import MinivuRender

/// The compare window: two to four images side by side for culling, each
/// with its rating, tag and a Trash button, zoomed and panned together.
///
/// One window at a time; asking again retargets it. `CompareModel` decides
/// what each pane shows (and is tested); `CompareImagePane` loads and draws one
/// image; this controller wires keys, toolbar and panes together and keeps
/// their views in step.
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate,
    MinivuActions {
    private(set) static var current: CompareWindowController?

    /// Opens (or retargets) the compare window.
    /// - Parameters:
    ///   - entries: the 2 to 4 images to compare (extra ones are ignored).
    ///   - allImages: the folder's images in the browser's order, where a
    ///     pane's next and previous images come from.
    static func show(entries: [FolderEntry], allImages: [FolderEntry]) {
        guard var model = CompareModel(entries: entries, allImages: allImages) else { return }
        model.arrangement = storedArrangement
        if let controller = current {
            controller.retarget(model)
            return
        }
        let controller = CompareWindowController(model: model)
        current = controller
        controller.present()
    }

    /// Where ratings and tags are read and written; tests swap in their own.
    static var catalog: Catalog = .shared

    static let frameAutosaveName = "CompareWindow"
    static let paneSpacing: CGFloat = 2
    private static let syncKey = "CompareSyncZoom"
    private static let arrangementKey = "CompareArrangement"

    private static var storedArrangement: CompareModel.Arrangement {
        CompareModel.Arrangement(rawValue: UserDefaults.standard.string(forKey: arrangementKey) ?? "") ?? .grid
    }

    private(set) var model: CompareModel
    private(set) var panes: [CompareImagePane] = []
    private let container = CompareContainerView()
    /// Zoom and pan in one pane apply to all (the toolbar's Sync).
    private(set) var isSynced: Bool {
        didSet { UserDefaults.standard.set(isSynced, forKey: Self.syncKey) }
    }
    /// One segment that stays selected while on: unlike a toggle button, a
    /// selected segment reads as "on" at a glance in the toolbar.
    private let syncControl = NSSegmentedControl()
    private let arrangementControl = NSSegmentedControl()
    private var trashing: Set<URL> = []
    private var catalogObserver: NSObjectProtocol?
    private var displaySettingsObserver: NSObjectProtocol?
    private(set) var isClosing = false

    private init(model: CompareModel) {
        self.model = model
        isSynced = UserDefaults.standard.object(forKey: Self.syncKey) as? Bool ?? true
        let window = CompareWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = "Compare"
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = container
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.onMouseDown = { [weak self] event in self?.windowMouseDown(event) }
        container.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        container.layoutHandler = { [weak self] in self?.layoutPanes() }

        buildToolbarControls()
        let toolbar = NSToolbar(identifier: "CompareToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // Ratings and tags set anywhere (the browser, the viewer, the menu)
        // show here too.
        catalogObserver = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panes.forEach { $0.refreshMarks() } }
        }
        // Show HDR, HDR RAW and RAW decoding change what these photos should
        // look like. Every pane decodes again at once, or the panes disagree:
        // the first one to be sharpened or replaced would come back under the
        // new settings while the rest kept their old textures.
        displaySettingsObserver = NotificationCenter.default.addObserver(forName: .minivuDisplaySettingsChanged,
                                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return }
                self.panes.forEach { $0.reloadForDisplaySettings() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    private func present() {
        guard let window else { return }
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.center()
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        syncPanes()
        window.makeKeyAndOrderFront(nil)
        focusCanvas()
    }

    private func retarget(_ newModel: CompareModel) {
        guard !isClosing else { return }
        var newModel = newModel
        newModel.arrangement = model.arrangement
        model = newModel
        syncPanes()
        window?.makeKeyAndOrderFront(nil)
        focusCanvas()
    }

    // MARK: - Panes

    /// Makes the pane views match the model: one per image, in order, the
    /// focused one outlined. `removed` is a pane that went, whose view goes
    /// with it (the others keep their zoom).
    private func syncPanes(removed: Int? = nil) {
        if let removed, panes.indices.contains(removed) {
            panes.remove(at: removed).stopAndRemove()
        }
        while panes.count > model.panes.count { panes.removeLast().stopAndRemove() }
        while panes.count < model.panes.count { panes.append(makePane()) }
        for (index, entry) in model.panes.enumerated() {
            let pane = panes[index]
            pane.number = index + 1
            pane.isFocused = index == model.focus
            pane.show(entry)
        }
        layoutPanes()
        updateChrome()
    }

    private func makePane() -> CompareImagePane {
        let pane = CompareImagePane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.onInteractiveViewChange = { [weak self] pane in self?.paneViewChanged(pane) }
        pane.onNewImage = { [weak self] pane in self?.paneShowedNewImage(pane) }
        pane.onNavigate = { [weak self] pane, step in self?.replace(pane, step: step) }
        pane.onRate = { [weak self] pane, rating in self?.rate(pane, rating) }
        pane.onToggleTag = { [weak self] pane in self?.toggleTag(of: pane) }
        pane.onTrash = { [weak self] pane in self?.trash(pane) }
        container.addSubview(pane)
        return pane
    }

    private func layoutPanes() {
        let frames = CompareModel.frames(count: panes.count, arrangement: model.arrangement,
                                         in: container.bounds, spacing: Self.paneSpacing)
        for (pane, frame) in zip(panes, frames) where pane.frame != frame {
            pane.frame = frame
        }
    }

    private var focusedPane: CompareImagePane? {
        panes.indices.contains(model.focus) ? panes[model.focus] : nil
    }

    private func setFocus(_ index: Int) {
        guard model.setFocus(index) else { return }
        for (i, pane) in panes.enumerated() { pane.isFocused = i == model.focus }
        focusCanvas()
    }

    private func focusCanvas() {
        guard let pane = focusedPane, let window else { return }
        if window.firstResponder !== pane.canvas { window.makeFirstResponder(pane.canvas) }
    }

    private func index(of pane: CompareImagePane) -> Int? {
        panes.firstIndex { $0 === pane }
    }

    /// A click anywhere in a pane focuses it (the canvas itself keeps the
    /// click for zooming, so this is seen at the window).
    private func windowMouseDown(_ event: NSEvent) {
        let point = container.convert(event.locationInWindow, from: nil)
        guard let index = panes.firstIndex(where: { $0.frame.contains(point) }), index != model.focus else { return }
        setFocus(index)
    }

    private func updateChrome() {
        guard let window else { return }
        let subtitle = "\(model.panes.count) images"
        if window.subtitle != subtitle { window.subtitle = subtitle }
        syncControl.setSelected(isSynced, forSegment: 0)
        arrangementControl.isEnabled = model.panes.count == 4
        arrangementControl.selectedSegment = model.arrangement == .row ? 0 : 1
    }

    // MARK: - Synchronised zoom and pan

    private func paneViewChanged(_ source: CompareImagePane) {
        guard isSynced, let view = source.relativeView() else { return }
        for pane in panes where pane !== source { pane.apply(view) }
    }

    /// A pane that loads another image while the others are zoomed in joins
    /// them, so a replaced image shows the same detail.
    private func paneShowedNewImage(_ pane: CompareImagePane) {
        guard isSynced else { return }
        let others = panes.filter { $0 !== pane && $0.canvas.image != nil }
        let source = others.first { $0.isFocused } ?? others.first
        guard let view = source?.relativeView(), !view.isFit else { return }
        pane.apply(view)
    }

    @objc func toggleSync(_ sender: Any?) {
        isSynced.toggle()
        updateChrome()
        if isSynced, let pane = focusedPane { paneViewChanged(pane) }
    }

    @objc func changeArrangement(_ sender: Any?) {
        let arrangement: CompareModel.Arrangement
        if let control = sender as? NSSegmentedControl {
            arrangement = control.selectedSegment == 0 ? .row : .grid
        } else {
            arrangement = model.arrangement == .row ? .grid : .row
        }
        model.arrangement = arrangement
        UserDefaults.standard.set(arrangement.rawValue, forKey: Self.arrangementKey)
        layoutPanes()
        updateChrome()
    }

    // MARK: - Culling

    private func replace(_ pane: CompareImagePane, step: Int) {
        guard let index = index(of: pane) else { return }
        setFocus(index)
        model.wrapAround = Preferences.shared.wrapAround
        guard model.replace(pane: index, step: step) else {
            NSSound.beep()
            return
        }
        syncPanes()
    }

    private func rate(_ pane: CompareImagePane, _ rating: Int) {
        guard let entry = pane.entry else { return }
        Self.catalog.setRating(rating, for: [entry.url])
        pane.refreshMarks()
    }

    private func toggleTag(of pane: CompareImagePane) {
        guard let entry = pane.entry else { return }
        Self.catalog.setTagged(!Self.catalog.marks(for: entry.url).isTagged, for: [entry.url])
        pane.refreshMarks()
    }

    /// Moves a pane's file to the Trash (the Finder does the move, off the
    /// main thread); the pane then shows the next image, or goes.
    private func trash(_ pane: CompareImagePane) {
        guard let entry = pane.entry, !trashing.contains(entry.url) else { return }
        trashing.insert(entry.url)
        Task { [weak self] in
            do {
                _ = try await FileWriteQueue.shared.trash([entry.url])
                self?.didTrash(entry)
            } catch {
                guard let self else { return }
                self.trashing.remove(entry.url)
                if let window = self.window, !self.isClosing {
                    let alert = NSAlert()
                    alert.messageText = "“\(entry.name)” couldn’t be moved to the Trash."
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func didTrash(_ entry: FolderEntry) {
        trashing.remove(entry.url)
        AppServices.images.invalidate(entry.url)
        AppServices.thumbnails.invalidate(entry.url)
        Self.catalog.fileRemoved(entry.url)
        guard !isClosing else { return }
        switch model.remove(entry.url) {
        case .notShown, .replaced:
            syncPanes()
        case .removedPane(let index):
            guard !model.panes.isEmpty else {
                window?.close()
                return
            }
            syncPanes(removed: index)
            focusCanvas()
        }
    }

    // MARK: - Keyboard

    /// ⌘1–⌘4 focus a pane, Tab and Shift-Tab cycle, ← → replace the focused
    /// image, 0–5 rate it, T tags it, Delete trashes it, F or Return toggles
    /// full screen and Esc closes. Bare digits rate, as in the viewer, so
    /// choosing a pane takes Command.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let key = CompareKeyCommand.command(characters: event.charactersIgnoringModifiers ?? "",
                                                  modifiers: event.modifierFlags) else { return false }
        if event.isARepeat, !key.repeats { return true }
        switch key {
        case .focus(let index): setFocus(index)
        case .cycleFocus(let backward):
            model.cycleFocus(backward: backward)
            setFocus(model.focus)
        case .replace(let step): if let pane = focusedPane { replace(pane, step: step) }
        case .rate(let rating): if let pane = focusedPane { rate(pane, rating) }
        case .toggleTag: if let pane = focusedPane { toggleTag(of: pane) }
        case .trash: if let pane = focusedPane { trash(pane) }
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .close: window?.performClose(nil)
        }
        return true
    }

    // MARK: - MinivuActions

    @objc func setRating(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let pane = focusedPane else { return }
        rate(pane, tag)
    }

    @objc func toggleTag(_ sender: Any?) {
        if let pane = focusedPane { toggleTag(of: pane) }
    }

    @objc func moveToTrash(_ sender: Any?) {
        if let pane = focusedPane { trash(pane) }
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = focusedPane?.entry?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func nextImage(_ sender: Any?) { if let pane = focusedPane { replace(pane, step: 1) } }
    @objc func previousImage(_ sender: Any?) { if let pane = focusedPane { replace(pane, step: -1) } }
    // The zoom commands act on the focused pane, and Sync carries them to the rest.
    @objc func fitToWindow(_ sender: Any?) { focusedPane?.canvas.fit() }
    @objc func actualSize(_ sender: Any?) { focusedPane?.canvas.actualSize(at: nil) }
    @objc func zoomIn(_ sender: Any?) { focusedPane?.canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { focusedPane?.canvas.zoomOut() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let entry = focusedPane?.entry
        switch menuItem.action {
        case .setRating:
            menuItem.state = entry.map { Self.catalog.marks(for: $0.url).rating == menuItem.tag } == true ? .on : .off
            return entry != nil
        case .toggleTag:
            menuItem.showTag(isTagged: entry.map { Self.catalog.marks(for: $0.url).isTagged } == true)
            return entry != nil
        case .moveToTrash: return entry.map { !trashing.contains($0.url) } ?? false
        case .revealInFinder: return entry != nil
        case .nextImage: return model.replacement(forPane: model.focus, step: 1) != nil
        case .previousImage: return model.replacement(forPane: model.focus, step: -1) != nil
        case .fitToWindow, .actualSize, .zoomIn, .zoomOut: return focusedPane?.canvas.image != nil
        default: return true
        }
    }

    // MARK: - Toolbar

    private static let syncItem = NSToolbarItem.Identifier("CompareSync")
    private static let arrangementItem = NSToolbarItem.Identifier("CompareArrangement")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.arrangementItem, Self.syncItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.syncItem:
            item.view = syncControl
            item.label = "Sync Zoom"
            item.toolTip = "Zoom and pan all images together"
        case Self.arrangementItem:
            item.view = arrangementControl
            item.label = "Layout"
            item.toolTip = "Four images in a row or a 2 × 2 grid"
        default:
            return nil
        }
        return item
    }

    /// Made before the toolbar asks for its items, which can happen as soon
    /// as the toolbar is set.
    private func buildToolbarControls() {
        syncControl.segmentCount = 1
        syncControl.trackingMode = .selectAny
        syncControl.setLabel("Sync", forSegment: 0)
        syncControl.setImage(NSImage(systemSymbolName: "link", accessibilityDescription: nil), forSegment: 0)
        syncControl.target = self
        syncControl.action = #selector(toggleSync(_:))

        arrangementControl.segmentCount = 2
        arrangementControl.trackingMode = .selectOne
        arrangementControl.setLabel("Row", forSegment: 0)
        arrangementControl.setImage(NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil),
                                    forSegment: 0)
        arrangementControl.setLabel("Grid", forSegment: 1)
        arrangementControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil),
                                    forSegment: 1)
        arrangementControl.target = self
        arrangementControl.action = #selector(changeArrangement(_:))
    }

    // MARK: - Closing

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        if let displaySettingsObserver { NotificationCenter.default.removeObserver(displaySettingsObserver) }
        for pane in panes { pane.stopAndRemove() }
        panes = []
        (window as? CompareWindow)?.onMouseDown = nil
        // Taking the canvases out of the window stops their display links,
        // which would otherwise keep them alive.
        window?.contentView = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Testing

    var paneViews: [CompareImagePane] { panes }
}

private extension CompareImagePane {
    func stopAndRemove() {
        stop()
        removeFromSuperview()
    }
}

/// What a key press means in the compare window, as a table tests can read.
nonisolated enum CompareKeyCommand: Equatable {
    case focus(Int)
    case cycleFocus(backward: Bool)
    /// ← and →: the previous or next image in the focused pane.
    case replace(Int)
    case rate(Int)
    case toggleTag
    case trash
    case toggleFullScreen
    case close

    var repeats: Bool {
        if case .replace = self { return true }
        return false
    }

    static func command(characters: String, modifiers: NSEvent.ModifierFlags) -> CompareKeyCommand? {
        let shortcut = modifiers.intersection([.command, .control, .option])
        guard let scalar = characters.unicodeScalars.first else { return nil }
        if shortcut == .command {
            switch characters {
            case "1", "2", "3", "4": return .focus(Int(characters)! - 1)
            default: break
            }
            // ⌘⌫ normally reaches Move to Trash in the menu first; this is
            // for when the menu doesn't take it.
            if Int(scalar.value) == NSDeleteCharacter || Int(scalar.value) == NSBackspaceCharacter { return .trash }
            return nil
        }
        guard shortcut.isEmpty else { return nil }
        switch Int(scalar.value) {
        case NSTabCharacter: return .cycleFocus(backward: modifiers.contains(.shift))
        case NSBackTabCharacter: return .cycleFocus(backward: true)
        case NSLeftArrowFunctionKey: return .replace(-1)
        case NSRightArrowFunctionKey: return .replace(1)
        case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey: return .trash
        case NSCarriageReturnCharacter, NSEnterCharacter: return .toggleFullScreen
        case 0x1B: return .close
        default: break
        }
        switch characters.lowercased() {
        case "0", "1", "2", "3", "4", "5": return .rate(Int(characters)!)
        case "t": return .toggleTag
        case "f": return .toggleFullScreen
        default: return nil
        }
    }
}

/// The compare window's content: the panes, and the first chance at keys
/// the focused canvas passes up.
final class CompareContainerView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?
    var layoutHandler: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutHandler?()
    }
}

/// Reports mouse presses before any view handles them, so a click on a
/// canvas (which keeps it for zooming) still focuses its pane.
final class CompareWindow: NSWindow {
    var onMouseDown: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?(event) }
        super.sendEvent(event)
    }
}
