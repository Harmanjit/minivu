import AppKit
import Combine
import SwiftUI
import MinivuCore
import MinivuRender

/// The image viewer (DESIGN.md 5): one image at a time, windowed or true full
/// screen, with fly-out panels at the edges.
///
/// The controller is glue. `ViewerModel` decides which image comes next,
/// `ImageCanvasView` draws and handles the mouse, `ImageLoader` decodes, and
/// `FlyoutController` slides the panels. What's left here is turning a
/// navigation into the right load, and the responder-chain commands.
///
/// Flipping must feel instant, which comes down to three rules:
/// - a texture already cached at this size is shown in the same event;
/// - otherwise the previous image stays up until the new one arrives (no
///   black flash), with any lower-resolution copy standing in after 150 ms;
/// - once shown, the neighbours in the direction of travel start decoding.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, MinivuActions,
    ImageCanvasViewDelegate {
    /// The viewer on screen, if any. minivu shows one viewer at a time.
    private(set) static var current: ViewerWindowController?

    /// Opens (or retargets) the viewer on `images[index]`.
    /// - Parameters:
    ///   - images: the folder's images in the browser's current order and filter.
    ///   - fullScreen: borderless full screen rather than a window.
    ///   - onClose: called with the image showing when the viewer closes, so
    ///     the browser can select it.
    static func show(images: [FolderEntry], index: Int, fullScreen: Bool,
                     onClose: @escaping (FolderEntry?) -> Void) {
        guard !images.isEmpty else {
            // Nothing to show. A viewer already open closes too, or the
            // caller would think it had gone while it stays on screen.
            if let viewer = current {
                viewer.onClose = onClose
                viewer.closeViewer(reportsCurrent: false)
            } else {
                onClose(nil)
            }
            return
        }
        if let viewer = current {
            viewer.retarget(images: images, index: index, fullScreen: fullScreen, onClose: onClose)
            return
        }
        let viewer = ViewerWindowController(images: images, index: index, onClose: onClose)
        current = viewer
        viewer.present(fullScreen: fullScreen)
    }

    /// How long a missing texture may keep the previous image up before a
    /// lower-resolution copy (if one is cached) stands in.
    static let placeholderDelay: TimeInterval = 0.15
    /// Pointer stillness before the cursor hides in full screen.
    static let cursorHideDelay: TimeInterval = 2
    static let frameAutosaveName = "ViewerWindow"
    static let infoPanelWidth: CGFloat = 320
    static let hudMargin: CGFloat = 16

    private var model: ViewerModel
    private var onClose: (FolderEntry?) -> Void

    private let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let container: ViewerContainerView
    private let hud = ViewerHUD()
    private var hudTop: NSLayoutConstraint?
    private var hudLeading: NSLayoutConstraint?
    private let errorLabel = NSTextField(labelWithString: "")
    private let flyouts: FlyoutController
    private let filmstrip = FilmstripView()
    private let controlBar = ViewerControlBar()
    private let infoHost = NSHostingView(rootView: InfoPanelView(url: nil))

    /// One window of each kind, made on first use; the content moves between them.
    private var fullScreenWindow: ViewerWindow?
    private var windowedWindow: ViewerWindow?
    private(set) var isFullScreen = false

    /// The screen-sized load for the image being navigated to.
    private var loadHandle: LoadHandle?
    /// A sharper texture for the image on screen (zoomed in, or a window
    /// grown past its texture).
    private var sharpenHandle: LoadHandle?
    private var placeholderWork: DispatchWorkItem?
    private var cursorWork: DispatchWorkItem?
    /// When the pointer last moved, in system uptime.
    private var lastPointerMove: TimeInterval = 0
    private var backgroundSubscription: AnyCancellable?
    private var summaryTask: Task<Void, Never>?
    /// The image whose pixels are on the canvas. It lags `model.current`
    /// while a decode is on its way.
    private var displayedEntry: FolderEntry?
    /// The HUD's exposure line, and which file it belongs to.
    private var exposure: (url: URL, text: String?)?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    /// Files the Finder is moving to the Trash right now.
    private var trashing: Set<URL> = []
    private var isClosing = false

    private init(images: [FolderEntry], index: Int, onClose: @escaping (FolderEntry?) -> Void) {
        model = ViewerModel(images: images, index: index, wrapAround: Preferences.shared.wrapAround)
        self.onClose = onClose
        container = ViewerContainerView(canvas: canvas)
        flyouts = FlyoutController(container: container)
        super.init(window: nil)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: - Content

    private func buildContent() {
        canvas.delegate = self
        container.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        container.layoutHandler = { [weak self] area in self?.layoutOverlays(in: area) }

        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)

        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)

        filmstrip.onSelect = { [weak self] index in self?.navigate { $0.move(to: index) } }
        filmstrip.setImages(model.images, current: model.index)
        // A hosting view tries to size its container to the SwiftUI content;
        // here the panel decides the size.
        infoHost.sizingOptions = []
        infoHost.frame = NSRect(x: 0, y: 0, width: Self.infoPanelWidth, height: 600)

        // Added after the HUD, so panels slide over it.
        flyouts.add(panel(filmstrip, edge: .top), edge: .top, thickness: FilmstripView.height)
        flyouts.add(panel(controlBar, edge: .bottom), edge: .bottom, thickness: ViewerControlBar.height)
        flyouts.add(panel(ViewerToolsPanel(), edge: .left), edge: .left, thickness: ViewerToolsPanel.width)
        flyouts.add(panel(infoHost, edge: .right), edge: .right, thickness: Self.infoPanelWidth)
        flyouts.onPointerMoved = { [weak self] in self?.pointerMoved() }
        flyouts.onVisibilityChange = { [weak self] edge, visible in self?.panelVisibilityChanged(edge, visible) }

        let hudTop = hud.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.hudMargin)
        let hudLeading = hud.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.hudMargin)
        self.hudTop = hudTop
        self.hudLeading = hudLeading
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            hudLeading,
            hudTop,
        ])

        // The surround can change in Settings while the viewer is open; the
        // window's own colour (title bar, camera strip) must follow the canvas.
        backgroundSubscription = Preferences.shared.$viewerBackground
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] background in
                guard let self, let window = self.window else { return }
                self.applyBackground(background, to: window)
            }
    }

    private func panel(_ content: NSView, edge: FlyoutEdge) -> FlyoutPanelView {
        let panel = FlyoutPanelView(edge: edge)
        // Start at the content's own size, never zero: a collection view
        // laid out at zero height complains its items don't fit.
        panel.frame = content.frame
        content.frame = panel.bounds
        content.autoresizingMask = [.width, .height]
        panel.addSubview(content)
        return panel
    }

    /// The HUD sits below the title bar or camera housing, and beside any
    /// panel pinned open, which would otherwise cover it; panels share the
    /// canvas's area. In full screen the rest of the screen still reaches
    /// the panels' edges (see `FlyoutGeometry.edge`).
    private func layoutOverlays(in area: CGRect) {
        let top = container.bounds.height - area.maxY + Self.hudMargin
            + (flyouts.isPinned(.top) ? FilmstripView.height : 0)
        let leading = Self.hudMargin + (flyouts.isPinned(.left) ? ViewerToolsPanel.width : 0)
        if hudTop?.constant != top { hudTop?.constant = top }
        if hudLeading?.constant != leading { hudLeading?.constant = leading }
        flyouts.layout(in: area, reach: isFullScreen ? container.bounds : nil)
    }

    /// A panel was pinned or unpinned: the HUD moves with it.
    private func pinsChanged() {
        container.needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FlyoutController.animationDuration
            context.allowsImplicitAnimation = true
            container.layoutSubtreeIfNeeded()
        }
        updateChrome()
    }

    // MARK: - Showing and retargeting

    private func present(fullScreen: Bool) {
        setFullScreen(fullScreen)
        showCurrent()
    }

    private func retarget(images: [FolderEntry], index: Int, fullScreen: Bool,
                          onClose: @escaping (FolderEntry?) -> Void) {
        self.onClose = onClose
        model.replace(images: images, index: index)
        filmstrip.setImages(model.images, current: model.index)
        if fullScreen != isFullScreen { setFullScreen(fullScreen) }
        window?.makeKeyAndOrderFront(nil)
        showCurrent()
    }

    // MARK: - Full screen and windowed

    /// Moves the one content view into the other window. The canvas keeps its
    /// zoom mode and the image point at its centre; only its size changes.
    private func setFullScreen(_ fullScreen: Bool) {
        let previous = window as? ViewerWindow
        let screen = previous?.screen ?? Self.preferredScreen()
        let target = fullScreen ? makeFullScreenWindow(on: screen) : makeWindowedWindow(on: screen)
        guard target !== previous else { return }
        isFullScreen = fullScreen

        previous?.contentView = NSView()
        target.contentView = container
        applyBackground(Preferences.shared.viewerBackground, to: target)
        window = target
        target.delegate = self
        container.layoutSubtreeIfNeeded()
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(canvas)
        previous?.orderOut(nil)

        cursorWork?.cancel()
        cursorWork = nil
        if fullScreen {
            pointerMoved()
        } else {
            restorePresentationOptions()
        }
        updateChrome()
    }

    /// The display the user is working on: the browser's, else the one under
    /// the pointer.
    private static func preferredScreen() -> NSScreen? {
        if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func makeFullScreenWindow(on screen: NSScreen?) -> ViewerWindow {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let window = fullScreenWindow {
            window.setFrame(frame, display: false)
            return window
        }
        let window = ViewerWindow(style: .fullScreen, frame: frame)
        // Content rects of borderless windows can be adjusted on creation;
        // the frame must be exactly the screen's.
        window.setFrame(frame, display: false)
        window.onMouseDown = { [weak self] event in self?.windowMouseDown(event) }
        fullScreenWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        return window
    }

    private func makeWindowedWindow(on screen: NSScreen?) -> ViewerWindow {
        if let window = windowedWindow { return window }
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: (visible.width * 0.75).rounded(), height: (visible.height * 0.8).rounded())
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let window = ViewerWindow(style: .windowed, frame: frame)
        window.setFrame(frame, display: false)
        // A saved frame wins over the default when there is one.
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.onMouseDown = { [weak self] event in self?.windowMouseDown(event) }
        windowedWindow = window
        return window
    }

    /// A resolution change or a display unplugged: keep covering the screen.
    @objc private func screensChanged() {
        guard isFullScreen, let window = fullScreenWindow else { return }
        if let frame = (window.screen ?? NSScreen.main)?.frame, window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }

    /// The surround behind the image becomes the window's own colour, so the
    /// title bar strip (and a notched display's camera strip) match the
    /// canvas. Dark surrounds get dark window chrome whatever the app theme:
    /// light title text on a black title bar, not black on black.
    private func applyBackground(_ background: Preferences.ViewerBackground, to window: NSWindow) {
        let level = Double(background.linearLevel)
        let srgb = level <= 0.0031308 ? 12.92 * level : 1.055 * pow(level, 1 / 2.4) - 0.055
        window.backgroundColor = NSColor(srgbRed: srgb, green: srgb, blue: srgb, alpha: 1)
        window.appearance = isFullScreen || srgb < 0.5 ? NSAppearance(named: .darkAqua) : nil
    }

    // MARK: - Presentation options

    /// The menu bar and Dock get out of the way while the full-screen window
    /// is key, and come back whenever it isn't: switching to another app
    /// mustn't leave the user without a menu bar. The Dock is hidden outright
    /// rather than auto-hidden, because an auto-hidden Dock slides up over the
    /// bottom control bar whenever the pointer reaches for it.
    private func applyPresentationOptions() {
        if savedPresentationOptions == nil { savedPresentationOptions = NSApp.presentationOptions }
        NSApp.presentationOptions = [.autoHideMenuBar, .hideDock]
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions else { return }
        savedPresentationOptions = nil
        NSApp.presentationOptions = saved
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if isFullScreen, notification.object as? NSWindow === fullScreenWindow { applyPresentationOptions() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === fullScreenWindow { restorePresentationOptions() }
    }

    // MARK: - Pointer

    /// A movement only notes the time. Pointer events arrive over a hundred
    /// times a second, and a work item made and cancelled for each would
    /// pile up in the main queue; one pending item is enough.
    private func pointerMoved() {
        lastPointerMove = ProcessInfo.processInfo.systemUptime
        guard isFullScreen, cursorWork == nil else { return }
        scheduleCursorHide(after: Self.cursorHideDelay)
    }

    /// A single delayed work item, not a repeating timer: when it comes due
    /// it checks how long the pointer has really been still, and if it moved
    /// in the meantime, waits out the rest. A still pointer costs nothing.
    private func scheduleCursorHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cursorWork = nil
            guard self.isFullScreen else { return }
            let still = ProcessInfo.processInfo.systemUptime - self.lastPointerMove
            if still < Self.cursorHideDelay {
                self.scheduleCursorHide(after: Self.cursorHideDelay - still)
            } else if !self.flyouts.hasTransientPanelOpen, self.window?.isKeyWindow == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        cursorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A press on the image (not in a panel) belongs to the canvas: clicks,
    /// drags and the magnifier all want a clear view.
    private func windowMouseDown(_ event: NSEvent) {
        guard let contentView = window?.contentView, let superview = contentView.superview else { return }
        if contentView.hitTest(superview.convert(event.locationInWindow, from: nil)) === canvas {
            flyouts.hideTransientPanels()
        }
    }

    // MARK: - Loading

    /// Long edge of the canvas in pixels: the size to decode for.
    private var canvasPixelSize: Int {
        let size = canvas.drawablePixelSize
        let edge = Int(max(size.width, size.height))
        if edge > 0 { return edge }
        guard let screen = window?.screen ?? NSScreen.main else { return 2560 }
        return Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
    }

    /// Shows `model.current`: from the cache within this event if possible,
    /// otherwise as soon as it is decoded.
    private func showCurrent() {
        guard let entry = model.current else { return }
        cancelLoads()
        let pixelSize = canvasPixelSize
        let cache = AppServices.images.cache
        if let texture = cache.bestTexture(url: entry.url, modified: entry.modified, page: 0,
                                           minimumLongEdge: pixelSize) {
            display(texture, of: entry, preserveView: false)
        } else {
            schedulePlaceholder(for: entry)
            loadHandle = AppServices.images.load(entry, pixelSize: pixelSize) { [weak self] result in
                self?.loadFinished(result, entry: entry)
            }
        }
        entryDidChange(entry)
    }

    private func cancelLoads() {
        loadHandle?.cancel()
        loadHandle = nil
        sharpenHandle?.cancel()
        sharpenHandle = nil
        placeholderWork?.cancel()
        placeholderWork = nil
    }

    /// After 150 ms without the real texture, any cached copy of the new image
    /// (the browser's preview, say) beats showing the previous photo.
    private func schedulePlaceholder(for entry: FolderEntry) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.current == entry, self.displayedEntry != entry,
                  let texture = AppServices.images.cache.anyTexture(url: entry.url, modified: entry.modified, page: 0)
            else { return }
            self.display(texture, of: entry, preserveView: false, prefetch: false)
        }
        placeholderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.placeholderDelay, execute: work)
    }

    private func loadFinished(_ result: Result<ImageTexture, Error>, entry: FolderEntry) {
        guard model.current == entry, !isClosing else { return }
        placeholderWork?.cancel()
        switch result {
        case .success(let texture):
            // Replacing a stand-in of the same image keeps any zoom the user
            // started on it.
            display(texture, of: entry, preserveView: displayedEntry == entry)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            canvas.setImage(nil, preserveView: false)
            displayedEntry = entry
            errorLabel.stringValue = "minivu can’t display “\(entry.name)”."
            errorLabel.isHidden = false
            updateChrome()
        }
    }

    private func display(_ texture: ImageTexture, of entry: FolderEntry, preserveView: Bool, prefetch: Bool = true) {
        errorLabel.isHidden = true
        canvas.setImage(texture, preserveView: preserveView)
        displayedEntry = entry
        updateChrome()
        if prefetch { AppServices.images.prefetch(model.prefetchList, pixelSize: canvasPixelSize) }
    }

    /// The navigation happened: update everything that says which image this is.
    private func entryDidChange(_ entry: FolderEntry) {
        if displayedEntry != entry { errorLabel.isHidden = true }
        filmstrip.setCurrent(model.index)
        // The info panel reads metadata only while it can be seen.
        if infoHost.superview?.isHidden == false { infoHost.rootView = InfoPanelView(url: entry.url) }
        readExposure(for: entry)
        updateChrome()
        hud.flash()
    }

    /// The exposure line is in the file's EXIF: a few milliseconds of disk
    /// reading, so it happens off the main thread and arrives a moment later.
    private func readExposure(for entry: FolderEntry) {
        summaryTask?.cancel()
        guard exposure?.url != entry.url else { return }
        exposure = nil
        guard entry.kind == .raster || entry.kind == .raw else { return }
        let url = entry.url
        summaryTask = Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) { MetadataReader.summary(for: url) }.value
            guard !Task.isCancelled, let self, self.model.current?.url == url else { return }
            self.exposure = (url, summary.exposure)
            self.updateChrome()
        }
    }

    /// Title, HUD and control bar, from the current state. Runs on every zoom
    /// step of a pinch, so the window title is only touched when it changes
    /// (setting it redraws the title bar).
    private func updateChrome() {
        guard let entry = model.current else { return }
        let shown = displayedEntry == entry && canvas.image != nil
        if let window {
            if window.title != entry.name { window.title = entry.name }
            let subtitle = isFullScreen ? "" : model.subtitleText
            if window.subtitle != subtitle { window.subtitle = subtitle }
        }
        let zoom = shown ? canvas.zoomPercent : nil
        hud.update(name: entry.name, position: model.positionText,
                   pixelSize: shown ? canvas.image?.imageSize : nil, zoomPercent: zoom,
                   exposure: exposure?.url == entry.url ? exposure?.text : nil)
        model.wrapAround = Preferences.shared.wrapAround
        controlBar.update(zoomPercent: zoom, canGoPrevious: model.canGoPrevious, canGoNext: model.canGoNext,
                          isFullScreen: isFullScreen, infoShown: flyouts.isPinned(.right))
    }

    // MARK: - ImageCanvasViewDelegate

    func canvasRequestsNavigation(_ canvas: ImageCanvasView, offset: Int) {
        navigate { $0.move(by: offset) }
    }

    func canvasDidChangeZoom(_ canvas: ImageCanvasView) {
        updateChrome()
        // Resizing the window changes a fitted zoom continuously; the HUD
        // would only flicker.
        if !canvas.inLiveResize { hud.flash() }
    }

    func canvasNeedsFullResolution(_ canvas: ImageCanvasView) {
        guard let entry = model.current, displayedEntry == entry else { return }
        sharpenHandle?.cancel()
        let deliver: (Result<ImageTexture, Error>) -> Void = { [weak self] result in
            guard let self, case .success(let texture) = result, self.model.current == entry else { return }
            self.canvas.setImage(texture, preserveView: true)
            self.updateChrome()
        }
        if canvas.zoomMode == .fit {
            // The window outgrew the texture, or a stand-in is up: a
            // screen-sized decode is enough, and joins one already running.
            sharpenHandle = AppServices.images.load(entry, pixelSize: canvasPixelSize, update: deliver)
        } else {
            sharpenHandle = AppServices.images.loadFullResolution(entry, update: deliver)
        }
    }

    /// FastStone's double-click: back to the browser. (The canvas has already
    /// undone the zoom toggle of the pair's first click.)
    func canvasDidDoubleClick(_ canvas: ImageCanvasView) {
        closeViewer()
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let zoomedIn = canvas.image.map {
            CanvasInteraction.imageExceedsView(canvas.transform, imageSize: $0.imageSize,
                                               viewSize: canvas.drawablePixelSize)
        } ?? false
        guard let command = ViewerKeyCommand.command(characters: event.charactersIgnoringModifiers ?? "",
                                                     modifiers: event.modifierFlags, zoomedIn: zoomedIn)
        else { return false }
        // Swallowed rather than passed on, which would beep.
        if event.isARepeat, !command.repeats { return true }
        switch command {
        case .next: nextImage(nil)
        case .previous: previousImage(nil)
        case .first: firstImage(nil)
        case .last: lastImage(nil)
        case .pan(let x, let y):
            // The content moves opposite to where the user wants to look.
            let step = ViewerKeyCommand.panFraction
            canvas.pan(byPoints: CGSize(width: -CGFloat(x) * step * canvas.bounds.width,
                                        height: -CGFloat(y) * step * canvas.bounds.height))
        case .toggleFullScreen: toggleFullScreenViewer(nil)
        case .close: exitViewer(nil)
        case .zoomIn: zoomIn(nil)
        case .zoomOut: zoomOut(nil)
        case .actualSize: actualSize(nil)
        case .fit: fitToWindow(nil)
        case .toggleHUD: hud.setPinned(!hud.isPinned)
        case .toggleFilmstrip:
            flyouts.togglePinned(.top)
            pinsChanged()
        case .rating: break   // phase 5; taken so the key doesn't beep
        }
        return true
    }

    // MARK: - MinivuActions

    @objc func nextImage(_ sender: Any?) { navigate { $0.next() } }
    @objc func previousImage(_ sender: Any?) { navigate { $0.previous() } }
    @objc func firstImage(_ sender: Any?) { navigate { $0.first() } }
    @objc func lastImage(_ sender: Any?) { navigate { $0.last() } }

    /// Moves, then loads if the image changed. At either end of the folder
    /// the HUD flashes "120 / 120" instead, so the key press isn't silent.
    private func navigate(_ move: (inout ViewerModel) -> Bool) {
        model.wrapAround = Preferences.shared.wrapAround
        guard move(&model) else {
            hud.flash()
            return
        }
        showCurrent()
    }

    @objc func fitToWindow(_ sender: Any?) { canvas.fit() }
    @objc func actualSize(_ sender: Any?) { canvas.actualSize(at: nil) }
    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }

    @objc func toggleFullScreenViewer(_ sender: Any?) {
        setFullScreen(!isFullScreen)
    }

    @objc func exitViewer(_ sender: Any?) {
        closeViewer()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let entry = model.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// Moves the image to the Trash, then shows the next one (or the previous,
    /// if it was last), or closes the viewer when none are left.
    @objc func moveToTrash(_ sender: Any?) {
        guard let entry = model.current, !trashing.contains(entry.url) else { return }
        trashing.insert(entry.url)
        Task { [weak self] in
            do {
                // The Finder does the move, off the main thread.
                _ = try await NSWorkspace.shared.recycle([entry.url])
                self?.didTrash(entry)
            } catch {
                self?.trashing.remove(entry.url)
                self?.presentTrashError(error, for: entry)
            }
        }
    }

    private func didTrash(_ entry: FolderEntry) {
        trashing.remove(entry.url)
        AppServices.images.invalidate(entry.url)
        AppServices.thumbnails.invalidate(entry.url)
        guard !isClosing else { return }
        // The user may have moved on while the Finder worked.
        let wasCurrent = model.current == entry
        guard model.remove(entry) else {
            closeViewer()
            return
        }
        filmstrip.setImages(model.images, current: model.index)
        if wasCurrent { showCurrent() } else { updateChrome() }
    }

    private func presentTrashError(_ error: Error, for entry: FolderEntry) {
        guard let window, !isClosing else { return }
        let alert = NSAlert()
        alert.messageText = "“\(entry.name)” couldn’t be moved to the Trash."
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    /// The control bar's info button: pins the info panel open, or unpins it.
    @objc func toggleInfoPanel(_ sender: Any?) {
        flyouts.togglePinned(.right)
        pinsChanged()
    }

    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugShowAllPanels:`):
    /// pins every panel and the HUD open so one picture shows them all. No
    /// menu item or key sends it, and it changes nothing but what's shown.
    @objc func debugShowAllPanels(_ sender: Any?) {
        for edge in FlyoutEdge.allCases where !flyouts.isPinned(edge) {
            flyouts.setPinned(true, edge: edge, animated: false)
        }
        hud.setPinned(true)
        pinsChanged()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        model.wrapAround = Preferences.shared.wrapAround
        switch menuItem.action {
        case .nextImage: return model.canGoNext
        case .previousImage: return model.canGoPrevious
        case .firstImage: return model.index > 0
        case .lastImage: return model.index < model.count - 1
        case .fitToWindow, .actualSize, .zoomIn, .zoomOut: return canvas.image != nil
        case .revealInFinder: return model.current != nil
        case .moveToTrash: return model.current.map { !trashing.contains($0.url) } ?? false
        case .toggleFullScreenViewer:
            menuItem.state = isFullScreen ? .on : .off
            return true
        case ViewerControlBar.toggleInfoAction:
            menuItem.state = flyouts.isPinned(.right) ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Panels

    private func panelVisibilityChanged(_ edge: FlyoutEdge, _ visible: Bool) {
        switch edge {
        case .top:
            filmstrip.setActive(visible)
        case .right:
            if visible { infoHost.rootView = InfoPanelView(url: model.current?.url) }
            updateChrome()
        case .bottom, .left:
            break
        }
        // A click inside a panel may have taken the keyboard; give it back to
        // the canvas so the arrow keys keep flipping images.
        if !visible, let window, let responder = window.firstResponder as? NSView, responder !== canvas {
            window.makeFirstResponder(canvas)
        }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeViewer()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closeViewer()
    }

    /// Esc, ⌘W, the close button or a double-click: stop all work, put the
    /// menu bar back, and tell the browser which image to select.
    /// `reportsCurrent` is false when the browser has nothing left to show,
    /// so there is no image for it to select.
    private func closeViewer(reportsCurrent: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        // Clearing the canvas below reports a zoom change; nothing should
        // update (or schedule a HUD fade) on the way out.
        canvas.delegate = nil
        cancelLoads()
        summaryTask?.cancel()
        cursorWork?.cancel()
        backgroundSubscription = nil
        hud.cancelFade()
        filmstrip.setActive(false)
        AppServices.images.prefetch([], pixelSize: 0)
        restorePresentationOptions()
        NotificationCenter.default.removeObserver(self)

        let entry = reportsCurrent ? model.current : nil
        canvas.setImage(nil, preserveView: false)
        for window in [fullScreenWindow, windowedWindow].compactMap({ $0 }) {
            window.delegate = nil
            window.onMouseDown = nil
            // Taking the canvas out of its window stops its display link,
            // which would otherwise keep the canvas and renderer alive.
            window.contentView = nil
            window.close()
        }
        window = nil
        if Self.current === self { Self.current = nil }
        onClose(entry)
    }
}
