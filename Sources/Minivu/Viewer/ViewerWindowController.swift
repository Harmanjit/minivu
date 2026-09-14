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
    private var infoTask: Task<Void, Never>?

    /// One page of one image.
    private struct Shown: Equatable {
        var entry: FolderEntry
        var page: Int
    }

    /// The image and page whose pixels are on the canvas. It lags the model
    /// while a decode is on its way.
    private var displayed: Shown?
    private var current: Shown? { model.current.map { Shown(entry: $0, page: model.page) } }
    /// Plays the current image when it is animated; nil otherwise.
    private var player: AnimationPlayer?
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

        // An animation stops its clock while its window can't be seen:
        // minimised, hidden, behind another window or on another Space.
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)

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
        updateAnimationVisibility()
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

    /// Shows `model.current` after a move to another image.
    private func showCurrent() {
        guard let entry = model.current else { return }
        loadCurrentPage()
        entryDidChange(entry)
    }

    /// Shows the model's image and page: from the cache within this event if
    /// possible, otherwise as soon as it is decoded. On its own for a page
    /// turn, which is still the same file.
    private func loadCurrentPage() {
        guard let shown = current else { return }
        cancelLoads()
        let pixelSize = canvasPixelSize
        let entry = shown.entry
        if let texture = AppServices.images.cache.bestTexture(url: entry.url, modified: entry.modified,
                                                              page: shown.page, minimumLongEdge: pixelSize) {
            display(texture, of: shown, preserveView: false)
        } else {
            schedulePlaceholder(for: shown)
            loadHandle = AppServices.images.load(entry, page: shown.page, pixelSize: pixelSize) { [weak self] result in
                self?.loadFinished(result, shown: shown)
            }
        }
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
    private func schedulePlaceholder(for shown: Shown) {
        let entry = shown.entry
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current == shown, self.displayed != shown,
                  let texture = AppServices.images.cache.anyTexture(url: entry.url, modified: entry.modified,
                                                                    page: shown.page)
            else { return }
            self.display(texture, of: shown, preserveView: false, prefetch: false)
        }
        placeholderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.placeholderDelay, execute: work)
    }

    private func loadFinished(_ result: Result<ImageTexture, Error>, shown: Shown) {
        guard current == shown, !isClosing else { return }
        let entry = shown.entry
        placeholderWork?.cancel()
        switch result {
        case .success(let texture):
            // Replacing a stand-in of the same page keeps any zoom the user
            // started on it.
            display(texture, of: shown, preserveView: displayed == shown)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            canvas.setImage(nil, preserveView: false)
            displayed = shown
            errorLabel.stringValue = "minivu can’t display “\(entry.name)”."
            errorLabel.isHidden = false
            updateChrome()
        }
    }

    private func display(_ texture: ImageTexture, of shown: Shown, preserveView: Bool, prefetch: Bool = true) {
        errorLabel.isHidden = true
        canvas.setImage(texture, preserveView: preserveView)
        displayed = shown
        updateChrome()
        if prefetch { prefetchAhead() }
    }

    /// The next page of a document, then the neighbouring images.
    private func prefetchAhead() {
        AppServices.images.prefetch(pages: model.prefetchPages, pixelSize: canvasPixelSize)
    }

    /// The navigation happened: update everything that says which image this is.
    private func entryDidChange(_ entry: FolderEntry) {
        if displayed?.entry != entry { errorLabel.isHidden = true }
        filmstrip.setCurrent(model.index)
        // The info panel reads metadata only while it can be seen.
        if infoHost.superview?.isHidden == false { infoHost.rootView = InfoPanelView(url: entry.url) }
        stopAnimation()
        readExposure(for: entry)
        readStructure(of: entry)
        updateChrome()
        hud.flash()
    }

    // MARK: - Pages and animation

    /// Whether a file's header is worth reading for pages or frames. Only
    /// these formats can have either, so flipping through JPEGs and raw
    /// files costs no extra reads.
    nonisolated static func mayHavePagesOrFrames(_ entry: FolderEntry) -> Bool {
        switch entry.kind {
        case .pdf: true
        case .raster: ["tif", "tiff", "gif", "png", "apng", "webp", "heic", "heif", "hif", "avif"]
            .contains(entry.url.pathExtension.lowercased())
        default: false
        }
    }

    /// Reads how many pages the image has and whether it animates, off the
    /// main thread (a header read, like the exposure line).
    private func readStructure(of entry: FolderEntry) {
        infoTask?.cancel()
        infoTask = nil
        guard Self.mayHavePagesOrFrames(entry) else { return }
        let url = entry.url
        infoTask = Task { [weak self] in
            let info = await Task.detached(priority: .userInitiated) { ImageDecoder.info(for: url) }.value
            guard !Task.isCancelled, let self, !self.isClosing, self.model.current == entry, let info else { return }
            self.structureArrived(info, for: entry)
        }
    }

    private func structureArrived(_ info: ImageInfo, for entry: FolderEntry) {
        model.setPageCount(info.documentPageCount, for: entry)
        if info.isAnimated { startAnimation(of: entry, imageSize: info.pixelSize) }
        updateChrome()
        // Now that a next page is known to exist, it's worth decoding.
        if model.isMultiPage, displayed == current { prefetchAhead() }
    }

    /// Moves to another page of the current image and shows it fitted.
    private func turnPage(_ turn: (inout ViewerModel) -> Bool) {
        guard turn(&model) else {
            hud.flash()   // the first or last page: say so rather than do nothing
            return
        }
        loadCurrentPage()
        updateChrome()
        hud.flash()
    }

    /// Page Down or Page Up: pages while there are any, then images.
    private func pageStep(_ step: (inout ViewerModel) -> ViewerModel.PageStep) {
        model.wrapAround = Preferences.shared.wrapAround
        switch step(&model) {
        case .page:
            loadCurrentPage()
            updateChrome()
            hud.flash()
        case .image:
            showCurrent()
        case .none:
            hud.flash()
        }
    }

    /// The still image (the first frame) is already on its way through the
    /// loader, so it shows as quickly as any photo; the player takes over
    /// once its first frame is decoded.
    private func startAnimation(of entry: FolderEntry, imageSize: CGSize) {
        stopAnimation()
        let player = AnimationPlayer(url: entry.url, pixelSize: animationPixelSize(for: imageSize))
        player.onFrame = { [weak self] texture in self?.showFrame(texture, of: entry) }
        player.onStateChange = { [weak self] in self?.updateChrome() }
        self.player = player
        updateAnimationVisibility()
    }

    private func stopAnimation() {
        player?.stop()
        player = nil
    }

    /// Each frame replaces the texture with zoom and pan kept, as a sharper
    /// texture would. A still load still pending would put the first frame
    /// back over the animation, so it is cancelled.
    private func showFrame(_ texture: ImageTexture, of entry: FolderEntry) {
        guard model.current == entry, !isClosing, let player else { return }
        let shown = Shown(entry: entry, page: 0)
        cancelLoads()
        if displayed == shown {
            errorLabel.isHidden = true   // the still decode may have failed where the player didn't
            canvas.setImage(texture, preserveView: true)
            // The HUD names the frame only while paused.
            if !player.isPlaying { updateChrome() }
        } else {
            // The animation beat the still decode.
            display(texture, of: shown, preserveView: false)
        }
    }

    /// Frames are decoded at the size the animation is shown at when fitted,
    /// not the canvas's long edge: every frame is a decode, and anything
    /// larger would only be sampled down again. Zooming in asks for more
    /// (`canvasNeedsFullResolution`).
    private func animationPixelSize(for imageSize: CGSize) -> Int {
        let view = canvas.drawablePixelSize
        guard view.width > 0, view.height > 0, imageSize.width > 0, imageSize.height > 0 else { return canvasPixelSize }
        let scale = min(view.width / imageSize.width, view.height / imageSize.height)
        return Int((max(imageSize.width, imageSize.height) * scale).rounded(.up))
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        updateAnimationVisibility()
    }

    private func updateAnimationVisibility() {
        guard let player else { return }
        player.isSuspended = !(window?.occlusionState.contains(.visible) ?? false)
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
        let shown = displayed == current && canvas.image != nil
        if let window {
            if window.title != entry.name { window.title = entry.name }
            let subtitle = isFullScreen ? "" : model.subtitleText
            if window.subtitle != subtitle { window.subtitle = subtitle }
        }
        let zoom = shown ? canvas.zoomPercent : nil
        var part = model.pageHUDText
        if let player, !player.isPlaying, player.frameCount > 0 {
            part = "Frame \(player.currentFrame + 1) / \(player.frameCount)"
        }
        hud.update(name: entry.name, position: model.positionText, part: part,
                   pixelSize: shown ? canvas.image?.imageSize : nil, zoomPercent: zoom,
                   exposure: exposure?.url == entry.url ? exposure?.text : nil)
        model.wrapAround = Preferences.shared.wrapAround
        let pages = model.isMultiPage
            ? ViewerControlBar.Pages(text: model.pageText, canGoPrevious: model.canGoPreviousPage,
                                     canGoNext: model.canGoNextPage)
            : nil
        controlBar.update(zoomPercent: zoom, canGoPrevious: model.canGoPrevious, canGoNext: model.canGoNext,
                          isFullScreen: isFullScreen, infoShown: flyouts.isPinned(.right),
                          pages: pages, isPlaying: player?.isPlaying)
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
        guard let shown = current, displayed == shown else { return }
        if let player, let imageSize = player.imageSize {
            // An animation sharpens by decoding its next frames larger. The
            // canvas asks again with every frame until they arrive; the
            // player ignores a size it already has. Fitted frames that
            // already cover the fitted size are being magnified by the
            // magnifier, which only full size helps.
            let fitted = animationPixelSize(for: imageSize)
            let frameEdge = canvas.image.map { Int(max($0.textureSize.width, $0.textureSize.height)) } ?? 0
            let full = canvas.zoomMode != .fit || Double(frameEdge) >= Double(fitted) * 0.97
            player.setPixelSize(full ? TextureUploader.maximumDimension : fitted)
            return
        }
        sharpenHandle?.cancel()
        let deliver: (Result<ImageTexture, Error>) -> Void = { [weak self] result in
            guard let self, case .success(let texture) = result, self.current == shown else { return }
            self.canvas.setImage(texture, preserveView: true)
            self.updateChrome()
        }
        if Self.wantsScreenSizedSharpening(fitted: canvas.zoomMode == .fit, kind: shown.entry.kind,
                                           imageLongEdge: canvas.image.map { max($0.imageSize.width, $0.imageSize.height) } ?? 0,
                                           canvasLongEdge: canvasPixelSize) {
            // The window outgrew the texture, or a stand-in is up: a
            // screen-sized decode is enough, and joins one already running.
            sharpenHandle = AppServices.images.load(shown.entry, page: shown.page, pixelSize: canvasPixelSize,
                                                    update: deliver)
        } else {
            sharpenHandle = AppServices.images.loadFullResolution(shown.entry, page: shown.page, update: deliver)
        }
    }

    /// Whether a screen-sized load can sharpen the canvas, or it takes full
    /// resolution.
    ///
    /// Zoomed in, only full resolution helps. Fitted, a photo only needs the
    /// canvas's size. A vector smaller than the canvas is the exception: the
    /// loader and cache treat a texture as big as the image's actual size as
    /// covering any screen request, so a screen-sized load would hand back
    /// the blurry texture already showing (a small SVG enlarged to fit). Its
    /// full-resolution render is small anyway, at most 4096 px.
    nonisolated static func wantsScreenSizedSharpening(fitted: Bool, kind: ImageKind?, imageLongEdge: CGFloat,
                                                       canvasLongEdge: Int) -> Bool {
        guard fitted else { return false }
        guard kind == .pdf || kind == .svg else { return true }
        return imageLongEdge >= CGFloat(canvasLongEdge)
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
        case .nextPage: nextPage(nil)
        case .previousPage: previousPage(nil)
        case .pageForward: pageStep { $0.pageForward() }
        case .pageBackward: pageStep { $0.pageBackward() }
        case .togglePlayback: togglePlayback(nil)
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

    /// Pages of a PDF or multi-page TIFF. Not in MinivuActions: only the
    /// viewer has pages, and the control bar and the snapshot harness
    /// (`MINIVU_ACTIONS=nextPage:`) reach these through the responder chain.
    @objc func nextPage(_ sender: Any?) { turnPage { $0.nextPage() } }
    @objc func previousPage(_ sender: Any?) { turnPage { $0.previousPage() } }

    /// Plays or pauses an animated image; P and the control bar's button.
    @objc func togglePlayback(_ sender: Any?) {
        guard let player else { return }
        player.togglePlayback()   // its state change updates the chrome
        hud.flash()
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

    // MARK: - Testing

    /// The page on screen and the page count, for tests.
    var pageState: (page: Int, count: Int) { (model.page, model.pageCount) }
    /// The current image's player, for tests.
    var animationPlayer: AnimationPlayer? { player }

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
        stopAnimation()
        summaryTask?.cancel()
        infoTask?.cancel()
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
