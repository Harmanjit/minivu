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
                viewer.endSheetForClosingFromOutside()
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

    private(set) var model: ViewerModel
    private var onClose: (FolderEntry?) -> Void

    let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let container: ViewerContainerView
    let hud = ViewerHUD()
    private var hudTop: NSLayoutConstraint?
    private var hudLeading: NSLayoutConstraint?
    let errorLabel = NSTextField(labelWithString: "")
    let flyouts: FlyoutController
    private let filmstrip = FilmstripView()
    private let controlBar = ViewerControlBar()
    let toolsPanel = ViewerToolsPanel()
    private let infoHost = NSHostingView(rootView: InfoPanelView(url: nil))
    /// The histogram and colour count, above the info panel on the right.
    let histogramPanel = HistogramPanelController()

    // Editing (ViewerEditing.swift).
    /// The edit of the image on screen; nil until the user first edits it.
    var editSession: EditSession?
    /// The tool whose inspector the tools panel shows.
    var activeTool: OpenEditTool?
    /// The open tool pinned the tools panel (rather than the user), so it
    /// unpins when the tool closes.
    var toolPinnedPanel = false
    /// Counts tool openings, so a tool waiting for a decode (crop, resize)
    /// doesn't open after the user has asked for another.
    var toolRequest = 0
    /// What the HUD last said about the edit, so it flashes only on news.
    var editChromeSignature: String?
    /// The image whose pages and frames have been read (or that can't have
    /// any). Editing waits for it, since an animation can't be edited.
    private(set) var structureRead: FolderEntry?

    /// One window of each kind, made on first use; the content moves between them.
    private var fullScreenWindow: ViewerWindow?
    private var windowedWindow: ViewerWindow?
    private(set) var isFullScreen = false
    /// The display the full-screen window covers. Kept by id rather than read
    /// from the window, so a display that goes away is noticed, and the
    /// window moved, even while AppKit still reports it on its old frame.
    private(set) var fullScreenDisplayID: UInt32?

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
    struct Shown: Equatable {
        var entry: FolderEntry
        var page: Int
    }

    /// The image and page whose pixels are on the canvas. It lags the model
    /// while a decode is on its way.
    var displayed: Shown?
    var current: Shown? { model.current.map { Shown(entry: $0, page: model.page) } }
    /// Plays the current image when it is animated; nil otherwise.
    private(set) var player: AnimationPlayer?
    /// The HUD's exposure line, and which file it belongs to.
    private var exposure: (url: URL, text: String?)?
    /// Files the Finder is moving to the Trash right now.
    private var trashing: Set<URL> = []
    private(set) var isClosing = false
    /// The current image's rating and tag, read once per image rather than
    /// on every zoom step that updates the HUD.
    private var shownMarks: (url: URL, marks: Catalog.Marks)?
    /// Rating and tag writes sent from here that haven't landed yet.
    private var pendingMarkWrites = 0

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
        flyouts.add(panel(toolsPanel, edge: .left), edge: .left, thickness: ViewerToolsPanel.width)
        flyouts.add(panel(histogramPanel.makePanel(with: infoHost, width: Self.infoPanelWidth), edge: .right),
                    edge: .right, thickness: Self.infoPanelWidth)
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
        // Show HDR, HDR RAW and RAW decoding change what the photo on screen
        // should look like. `closeViewer` removes both observers.
        NotificationCenter.default.addObserver(self, selector: #selector(displaySettingsChanged(_:)),
                                               name: .minivuDisplaySettingsChanged, object: nil)
        // Ratings and tags set here, in the browser or anywhere else.
        NotificationCenter.default.addObserver(self, selector: #selector(catalogDidChange(_:)),
                                               name: Catalog.didChange, object: nil)
        // A display connected, disconnected or rearranged, or its resolution
        // changed: the full-screen window keeps covering its display.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

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
        let leading = Self.hudMargin + (flyouts.isPinned(.left) ? flyouts.thickness(.left) : 0)
        if hudTop?.constant != top { hudTop?.constant = top }
        if hudLeading?.constant != leading { hudLeading?.constant = leading }
        flyouts.layout(in: area, reach: isFullScreen ? container.bounds : nil)
    }

    /// A panel was pinned or unpinned: the HUD moves with it, and a pinned
    /// tools panel takes its width from the canvas (see
    /// `ViewerContainerView.canvasLeadingInset`).
    func pinsChanged() {
        container.canvasLeadingInset = flyouts.isPinned(.left) ? flyouts.thickness(.left) : 0
        container.needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            // Reduce Motion: the canvas and HUD move over at once.
            let still = flyouts.reducesMotion()
            context.duration = still ? 0 : FlyoutController.animationDuration
            context.allowsImplicitAnimation = !still
            container.layoutSubtreeIfNeeded()
        }
        updateChrome()
    }

    // MARK: - Showing and retargeting

    private func present(fullScreen: Bool) {
        setFullScreen(fullScreen)
        showCurrent()
    }

    /// Unsaved edits are dealt with first; if the user cancels, the viewer
    /// stays on its image and the browser's new request is dropped.
    private func retarget(images: [FolderEntry], index: Int, fullScreen: Bool,
                          onClose: @escaping (FolderEntry?) -> Void) {
        resolveUnsavedEdits { [weak self] in
            self?.performRetarget(images: images, index: index, fullScreen: fullScreen, onClose: onClose)
        }
    }

    private func performRetarget(images: [FolderEntry], index: Int, fullScreen: Bool,
                                 onClose: @escaping (FolderEntry?) -> Void) {
        guard !isClosing else { return }
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
    ///
    /// Full screen goes to the display Settings > Viewer chooses (see
    /// `DisplayPlacement.fullScreenDisplay`), starting from the viewer's own
    /// display when a window goes full screen, or the browser's when the
    /// viewer opens.
    private func setFullScreen(_ fullScreen: Bool) {
        let previous = window as? ViewerWindow
        let current = previous.flatMap(Displays.provider.display(of:)) ?? Displays.originDisplay()
        let target = fullScreen ? makeFullScreenWindow(on: Displays.fullScreenDisplay(current: current))
                                : makeWindowedWindow(on: current)
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
            FullScreenPresentation.shared.release(self)
        }
        updateAnimationVisibility()
        updateChrome()
    }

    private func makeFullScreenWindow(on display: DisplayInfo?) -> ViewerWindow {
        fullScreenDisplayID = display?.id
        let frame = display?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let window = fullScreenWindow {
            window.setFrame(frame, display: false)
            return window
        }
        let window = ViewerWindow(style: .fullScreen, frame: frame)
        // Content rects of borderless windows can be adjusted on creation;
        // the frame must be exactly the screen's.
        window.setFrame(frame, display: false)
        window.onMouseDown = { [weak self] event in self?.windowMouseDown(event) }
        window.editUndoTarget = self
        fullScreenWindow = window
        return window
    }

    private func makeWindowedWindow(on display: DisplayInfo?) -> ViewerWindow {
        if let window = windowedWindow { return window }
        let visible = display?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: (visible.width * 0.75).rounded(), height: (visible.height * 0.8).rounded())
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let window = ViewerWindow(style: .windowed, frame: frame)
        window.setFrame(frame, display: false)
        // A saved frame wins over the default when there is one.
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.onMouseDown = { [weak self] event in self?.windowMouseDown(event) }
        window.editUndoTarget = self
        windowedWindow = window
        return window
    }

    /// A resolution change: keep covering the display. Its display unplugged:
    /// move to one that is left, chosen as when the viewer opens, rather than
    /// stay where no display shows it. Posted for every step of an EDR
    /// headroom change too, when nothing here changes.
    @objc private func screensChanged() {
        guard !isClosing, isFullScreen, let window = fullScreenWindow else { return }
        let displays = Displays.provider.displays
        guard !displays.isEmpty else { return }   // the last display went; wait for one to come
        let display = displays.first { $0.id == fullScreenDisplayID } ?? Displays.fullScreenDisplay(current: nil)
        guard let display else { return }
        place(window, on: display)
    }

    /// Puts the full-screen window over `display`. The container lays out
    /// again even when the frame is the same, for a camera housing's inset.
    private func place(_ window: ViewerWindow, on display: DisplayInfo) {
        fullScreenDisplayID = display.id
        if window.frame != display.frame { window.setFrame(display.frame, display: true) }
        container.needsLayout = true
    }

    /// Window > Move to Next Display (⌃⌥⌘→): full screen covers the next
    /// display, left to right; a window keeps its place on the new display's
    /// usable area.
    @objc func moveToNextDisplay(_ sender: Any?) {
        guard !isClosing, let window else { return }
        let provider = Displays.provider
        let displays = provider.displays
        let current = isFullScreen ? displays.first { $0.id == fullScreenDisplayID } ?? provider.display(of: window)
                                   : provider.display(of: window)
        guard displays.count > 1, let next = DisplayPlacement.next(after: current, in: displays),
              next.id != current?.id else { return }
        if isFullScreen, let fullScreenWindow {
            place(fullScreenWindow, on: next)
        } else {
            window.setFrame(DisplayPlacement.movedFrame(window.frame, from: current, to: next), display: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The surround behind the image becomes the window's own colour, so the
    /// title bar strip matches the canvas. Dark surrounds get dark window
    /// chrome whatever the app theme: light title text on a black title bar,
    /// not black on black.
    ///
    /// In full screen the window is black whatever the surround: on a notched
    /// display its colour is the camera housing strip, which is black around
    /// the camera like the menu bar of any full-screen app.
    private func applyBackground(_ background: Preferences.ViewerBackground, to window: NSWindow) {
        let level = Double(background.linearLevel)
        let srgb = level <= 0.0031308 ? 12.92 * level : 1.055 * pow(level, 1 / 2.4) - 0.055
        window.backgroundColor = isFullScreen ? .black : NSColor(srgbRed: srgb, green: srgb, blue: srgb, alpha: 1)
        window.appearance = isFullScreen || srgb < 0.5 ? NSAppearance(named: .darkAqua) : nil
    }

    // MARK: - Presentation options

    /// The menu bar and Dock get out of the way while the full-screen window
    /// is key, and come back whenever it isn't: switching to another app, or
    /// to the browser on another display, mustn't leave the user without a
    /// menu bar. `FullScreenPresentation` shares this with the slideshow.
    func windowDidBecomeKey(_ notification: Notification) {
        if isFullScreen, notification.object as? NSWindow === fullScreenWindow {
            FullScreenPresentation.shared.hide(for: self)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === fullScreenWindow { FullScreenPresentation.shared.release(self) }
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
        let hit = contentView.hitTest(superview.convert(event.locationInWindow, from: nil))
        // The crop overlay takes the image's presses while cropping.
        if hit === canvas || (hit != nil && hit === container.canvasOverlay) {
            flyouts.hideTransientPanels()
        }
    }

    // MARK: - Loading

    /// Long edge of the canvas in pixels.
    var canvasPixelSize: Int {
        let size = canvasFitSize
        return Int(max(size.width, size.height))
    }

    /// The canvas in pixels, or before it has a size a square of the
    /// screen's long edge: screen-sized decodes are for the image fitted
    /// into it, which for most photos is less than the long edge.
    var canvasFitSize: CGSize {
        let size = canvas.drawablePixelSize
        if size.width >= 1, size.height >= 1 { return size }
        let provider = Displays.provider
        let edge = (window.flatMap(provider.display(of:)) ?? provider.mainDisplay)?.pixelLongEdge ?? 2560
        return CGSize(width: edge, height: edge)
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
    ///
    /// `reloading` is for the page already on screen, decoded again: it
    /// keeps its zoom and pan if the new texture is of the same size.
    func loadCurrentPage(reloading: Bool = false) {
        guard let shown = current else { return }
        cancelLoads()
        let fitSize = canvasFitSize
        let entry = shown.entry
        if let texture = AppServices.images.cache.bestTexture(url: entry.url, modified: entry.modified,
                                                              page: shown.page, fitting: fitSize) {
            display(texture, of: shown, preserveView: reloading && keepsView(for: texture, of: shown))
        } else {
            schedulePlaceholder(for: shown)
            loadHandle = AppServices.images.load(entry, page: shown.page, fitting: fitSize) { [weak self] result in
                self?.loadFinished(result, shown: shown)
            }
        }
    }

    func cancelLoads() {
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
        // An edited render is on screen; the file's own pixels would undo it.
        guard editSession?.hasDisplayedEdit != true else { return }
        let entry = shown.entry
        placeholderWork?.cancel()
        switch result {
        case .success(let texture):
            // Replacing a stand-in of the same page, or the page decoded
            // under old display settings, keeps any zoom the user set.
            display(texture, of: shown, preserveView: keepsView(for: texture, of: shown))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            displayed = shown
            canvas.setImage(nil, preserveView: false)
            errorLabel.stringValue = "minivu can’t display “\(entry.name)”."
            errorLabel.isHidden = false
            updateChrome()
        }
    }

    /// `displayed` is set before the canvas gets the texture: the canvas may
    /// ask for a sharper one from inside `setImage` (the magnifier is up, or
    /// the texture is smaller than the fitted view), and it asks only once
    /// per texture, so a request that found the old image still "displayed"
    /// would be lost for good.
    private func display(_ texture: ImageTexture, of shown: Shown, preserveView: Bool, prefetch: Bool = true) {
        errorLabel.isHidden = true
        displayed = shown
        canvas.setImage(texture, preserveView: preserveView)
        updateChrome()
        if prefetch { prefetchAhead() }
    }

    /// Whether a new texture can take over the view of the one on the canvas:
    /// only for the same page and image size, or the zoom and pan would land
    /// somewhere else in the picture.
    private func keepsView(for texture: ImageTexture, of shown: Shown) -> Bool {
        displayed == shown && canvas.image?.imageSize == texture.imageSize
    }

    /// Show HDR, HDR RAW or RAW decoding changed. The loader has already
    /// emptied its cache, since textures made under the old settings look
    /// wrong, so the page decodes again. It stays on screen meanwhile (the
    /// placeholder only stands in for a different page), and the
    /// neighbours are prefetched again once the new texture is up.
    @objc private func displaySettingsChanged(_ notification: Notification) {
        guard !isClosing, let shown = current else { return }
        if let session = editSession {
            // The original decodes again under the new settings; an edited
            // render on screen is replaced by a new one, not by the file.
            session.reload()
            if session.hasDisplayedEdit {
                prefetchAhead()
                return
            }
        }
        if player != nil, displayed == shown {
            // An animation's frames come from its player, which decodes
            // them in SDR whatever the settings; only the neighbours change.
            prefetchAhead()
            return
        }
        loadCurrentPage(reloading: true)
    }

    /// The next page of a document, then the neighbouring images.
    private func prefetchAhead() {
        AppServices.images.prefetch(pages: model.prefetchPages, fitting: canvasFitSize)
    }

    /// The navigation happened: update everything that says which image this is.
    private func entryDidChange(_ entry: FolderEntry) {
        if displayed?.entry != entry { errorLabel.isHidden = true }
        structureRead = Self.mayHavePagesOrFrames(entry) ? nil : entry
        filmstrip.setCurrent(model.index)
        // The info panel reads metadata only while it can be seen.
        if !infoHost.isHiddenOrHasHiddenAncestor { infoHost.rootView = InfoPanelView(url: entry.url) }
        histogramPanel.setEntry(entry)
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
            let info = await BlockingWork.run { ImageDecoder.info(for: url) }
            guard !Task.isCancelled, let self, !self.isClosing, self.model.current == entry else { return }
            self.structureRead = entry
            guard let info else {
                self.updateChrome()
                return
            }
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

    /// Moves to another page of the current image and shows it fitted. An
    /// edit belongs to one page, so unsaved edits are dealt with first.
    private func turnPage(_ turn: @escaping (inout ViewerModel) -> Bool) {
        var probe = model
        guard turn(&probe) else {
            hud.flash()   // the first or last page: say so rather than do nothing
            return
        }
        resolveUnsavedEdits { [weak self] in
            guard let self, !self.isClosing else { return }
            guard turn(&self.model) else {
                self.hud.flash()
                return
            }
            self.loadCurrentPage()
            self.updateChrome()
            self.hud.flash()
        }
    }

    /// Page Down or Page Up: pages while there are any, then images.
    private func pageStep(_ step: @escaping (inout ViewerModel) -> ViewerModel.PageStep) {
        model.wrapAround = Preferences.shared.wrapAround
        var probe = model
        guard step(&probe) != .none else {
            hud.flash()
            return
        }
        resolveUnsavedEdits { [weak self] in
            guard let self, !self.isClosing else { return }
            self.model.wrapAround = Preferences.shared.wrapAround
            switch step(&self.model) {
            case .page:
                self.loadCurrentPage()
                self.updateChrome()
                self.hud.flash()
            case .image:
                self.showCurrent()
            case .none:
                self.hud.flash()
            }
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
            let summary = await BlockingWork.run { MetadataReader.summary(for: url) }
            guard !Task.isCancelled, let self, self.model.current?.url == url else { return }
            self.exposure = (url, summary.exposure)
            self.updateChrome()
        }
    }

    /// Title, HUD and control bar, from the current state. Runs on every zoom
    /// step of a pinch, so the window title is only touched when it changes
    /// (setting it redraws the title bar).
    func updateChrome() {
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
        let document = editSession?.document
        let dirty = document?.isDirty == true
        if let window, window.isDocumentEdited != dirty { window.isDocumentEdited = dirty }
        hud.update(name: entry.name, position: model.positionText, part: part,
                   pixelSize: shown ? canvas.image?.imageSize : nil, zoomPercent: zoom,
                   exposure: exposure?.url == entry.url ? exposure?.text : nil,
                   edited: dirty ? (document?.undoTitle ?? "") : nil, marks: marks(for: entry))
        model.wrapAround = Preferences.shared.wrapAround
        let pages = model.isMultiPage
            ? ViewerControlBar.Pages(text: model.pageText, canGoPrevious: model.canGoPreviousPage,
                                     canGoNext: model.canGoNextPage)
            : nil
        let canEdit = canEditCurrent
        controlBar.update(zoomPercent: zoom, canGoPrevious: model.canGoPrevious, canGoNext: model.canGoNext,
                          isFullScreen: isFullScreen, infoShown: flyouts.isPinned(.right),
                          pages: pages, isPlaying: player?.isPlaying, canEdit: canEdit,
                          toolsShown: flyouts.isPinned(.left))
        toolsPanel.updateAvailability { [unowned self] action in
            canEdit ? (validateEditAction(action) ?? false) : false
        }
    }

    // MARK: - ImageCanvasViewDelegate

    func canvasRequestsNavigation(_ canvas: ImageCanvasView, offset: Int) {
        navigate { $0.move(by: offset) }
    }

    func canvasDidChangeZoom(_ canvas: ImageCanvasView) {
        updateChrome()
        // Resizing the window changes a fitted zoom continuously; the HUD
        // would only flicker.
        if !canvas.inLiveResize {
            hud.flash()
            shrinkAnimationFramesIfFitted()
        }
    }

    /// Back at fit after zooming in, an animation returns to fitted-size
    /// frames. Full-size frames would cost a larger decode on every frame for
    /// as long as it plays, and frame textures have no mipmaps, so shrinking
    /// them on the GPU would shimmer. Only when they are well over the fitted
    /// size, so a window resized a little doesn't make every frame decode again.
    private func shrinkAnimationFramesIfFitted() {
        guard canvas.zoomMode == .fit, let player, let imageSize = player.imageSize,
              let texture = canvas.image else { return }
        let fitted = animationPixelSize(for: imageSize)
        if Double(max(texture.textureSize.width, texture.textureSize.height)) > Double(fitted) * 1.25 {
            player.setPixelSize(fitted)
        }
    }

    func canvasNeedsFullResolution(_ canvas: ImageCanvasView) {
        guard let shown = current, displayed == shown else { return }
        if editSession?.hasDisplayedEdit == true {
            sharpenEditedImage()
            return
        }
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
        sharpenHandle = nil
        let deliver: (Result<ImageTexture, Error>) -> Void = { [weak self] result in
            guard let self, case .success(let texture) = result, self.current == shown,
                  self.editSession?.hasDisplayedEdit != true else { return }
            self.canvas.setImage(texture, preserveView: true)
            self.updateChrome()
        }
        let image = canvas.image
        let fitSize = canvasFitSize
        let handle: LoadHandle
        if Self.wantsScreenSizedSharpening(fitted: canvas.zoomMode == .fit, kind: shown.entry.kind,
                                           imageLongEdge: image.map { max($0.imageSize.width, $0.imageSize.height) } ?? 0,
                                           textureLongEdge: image.map { max($0.textureSize.width, $0.textureSize.height) } ?? 0,
                                           canvasLongEdge: ImageDecoder.fittedLongEdge(imageSize: image?.imageSize ?? .zero,
                                                                                       in: fitSize)) {
            // The window outgrew the texture (a fitted image's size, which
            // grows too when a resize turns the window's long axis), or a
            // stand-in is up: a screen-sized decode is enough, and joins one
            // already running.
            handle = AppServices.images.load(shown.entry, page: shown.page, fitting: fitSize, update: deliver)
        } else {
            handle = AppServices.images.loadFullResolution(shown.entry, page: shown.page, update: deliver)
        }
        // A cache hit is delivered inside the call above, and the texture it
        // hands the canvas may ask for more at once (a screen-sized one under
        // the magnifier). That request's handle is the one to keep.
        if sharpenHandle == nil { sharpenHandle = handle }
    }

    /// Whether a screen-sized load can sharpen the canvas, or it takes full
    /// resolution.
    ///
    /// Zoomed in, only full resolution helps. Fitted, a screen-sized load
    /// helps only while the texture is smaller than the canvas (the window
    /// grew, or a stand-in is up). A texture that already covers the canvas
    /// is being magnified by the magnifier: asking for the screen size again
    /// would hand back that same texture, and the loupe would stay blurry.
    ///
    /// A vector smaller than the canvas always takes full resolution: the
    /// loader and cache treat a texture as big as the image's actual size as
    /// covering any screen request, so a screen-sized load would hand back
    /// the blurry texture already showing (a small SVG enlarged to fit). Its
    /// full-resolution render is small anyway, at most 4096 px.
    nonisolated static func wantsScreenSizedSharpening(fitted: Bool, kind: ImageKind?, imageLongEdge: CGFloat,
                                                       textureLongEdge: CGFloat, canvasLongEdge: Int) -> Bool {
        guard fitted, textureLongEdge < CGFloat(canvasLongEdge) * 0.97 else { return false }
        guard kind == .pdf || kind == .svg else { return true }
        return imageLongEdge >= CGFloat(canvasLongEdge)
    }

    /// FastStone's double-click: back to the browser. (The canvas has already
    /// undone the zoom toggle of the pair's first click.)
    func canvasDidDoubleClick(_ canvas: ImageCanvasView) {
        exitViewer(nil)
    }

    func canvasDidChangeImage(_ canvas: ImageCanvasView) {
        histogramPanel.show(canvas.image, interval: player?.isPlaying == true
            ? HistogramPanelController.animationInterval : HistogramPanelController.minimumInterval)
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let zoomedIn = canvas.image.map {
            CanvasInteraction.imageExceedsView(canvas.transform, imageSize: $0.imageSize,
                                               viewSize: canvas.drawablePixelSize)
        } ?? false
        if handleToolKey(event) { return true }
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
        case .rating(let stars): rate(stars)
        case .toggleTag: toggleTag(nil)
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
    /// Unsaved edits are dealt with before moving, and only when a move
    /// would happen.
    private func navigate(_ move: @escaping (inout ViewerModel) -> Bool) {
        model.wrapAround = Preferences.shared.wrapAround
        var probe = model
        guard move(&probe) else {
            hud.flash()
            return
        }
        resolveUnsavedEdits { [weak self] in
            guard let self, !self.isClosing else { return }
            self.model.wrapAround = Preferences.shared.wrapAround
            guard move(&self.model) else {
                self.hud.flash()
                return
            }
            self.showCurrent()
        }
    }

    /// Pages of a PDF or multi-page TIFF, from the Go menu, the control bar
    /// and the snapshot harness (`MINIVU_ACTIONS=nextPage:`). Only the viewer
    /// has pages, so the menu items are disabled in the browser.
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

    /// Esc, ⌘W, the close button and a double-click, after unsaved edits are
    /// dealt with.
    @objc func exitViewer(_ sender: Any?) {
        resolveUnsavedEdits { [weak self] in self?.closeViewer() }
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
        // Its edits went to the Trash with it.
        if wasCurrent || editSession?.document.entry == entry { endEditSession() }
        guard model.remove(entry) else {
            endSheetForClosingFromOutside()
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

    // MARK: - Rating and tag

    /// Image > Rating (⌃0–⌃5); the bare digits come through `handleKey`.
    @objc func setRating(_ sender: Any?) {
        guard let stars = (sender as? NSMenuItem)?.tag else { return }
        rate(stars)
    }

    /// T, ` and ⌘T.
    @objc func toggleTag(_ sender: Any?) {
        guard let entry = model.current else { return }
        var marks = marks(for: entry)
        marks.isTagged.toggle()
        let tagged = marks.isTagged
        showMarks(marks, for: entry)
        writeMarks { Catalog.shared.setTagged(tagged, for: [entry.url]) }
    }

    private func rate(_ stars: Int) {
        guard let entry = model.current else { return }
        var marks = marks(for: entry)
        marks.rating = min(max(stars, 0), 5)
        showMarks(marks, for: entry)
        writeMarks { Catalog.shared.setRating(stars, for: [entry.url]) }
    }

    /// Writes on the catalog's queue, counting writes not yet landed: until
    /// the last has, the HUD keeps what the keys set rather than reading back
    /// a catalog that has only some of them (a quick T T would flash tagged).
    private func writeMarks(_ write: @escaping @Sendable () -> Void) {
        pendingMarkWrites += 1
        BrowserModel.catalogWrites.async { [weak self] in
            write()
            // Queued after the catalog's own change notice, so it runs after it.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pendingMarkWrites -= 1 } }
        }
    }

    /// Shown before the write lands, so a second quick press toggles from
    /// what the first one set.
    private func showMarks(_ marks: Catalog.Marks, for entry: FolderEntry) {
        shownMarks = (entry.url, marks)
        updateChrome()
        hud.flash()
    }

    private func marks(for entry: FolderEntry) -> Catalog.Marks {
        if let shownMarks, shownMarks.url == entry.url { return shownMarks.marks }
        let marks = Catalog.shared.marks(for: entry.url)
        shownMarks = (entry.url, marks)
        return marks
    }

    /// The HUD shows the new stars at once, flashing up so a key press in
    /// full screen is answered even with the HUD faded.
    @objc private func catalogDidChange(_ notification: Notification) {
        guard !isClosing, pendingMarkWrites == 0, let entry = model.current, let urls = notification.object as? [URL],
              urls.contains(where: { $0.standardizedFileURL.path == entry.url.standardizedFileURL.path }) else { return }
        shownMarks = nil
        updateChrome()
        hud.flash()
    }

    /// The control bar's info button: pins the info panel open, or unpins it.
    @objc func toggleInfoPanel(_ sender: Any?) {
        flyouts.togglePinned(.right)
        pinsChanged()
    }

    /// The histogram sits at the top of the info panel, so this pins or
    /// unpins that panel.
    @objc func toggleHistogram(_ sender: Any?) {
        toggleInfoPanel(sender)
    }

    /// Counts the colours of the image on screen, opening the panel that
    /// shows the answer if it isn't out.
    @objc func countColors(_ sender: Any?) {
        guard model.current != nil else { return }
        if !flyouts.isOpen(.right) {
            flyouts.setPinned(true, edge: .right)
            pinsChanged()
        }
        histogramPanel.countColors()
    }

    #if DEBUG
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
    #endif

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        model.wrapAround = Preferences.shared.wrapAround
        if let enabled = validateEditAction(menuItem.action) { return enabled }
        if let enabled = validateToolAction(menuItem.action) { return enabled }
        switch menuItem.action {
        case .nextImage: return model.canGoNext
        case .previousImage: return model.canGoPrevious
        case .firstImage: return model.index > 0
        case .lastImage: return model.index < model.count - 1
        case .nextPage: return model.canGoNextPage
        case .previousPage: return model.canGoPreviousPage
        case .togglePlayback:
            menuItem.showPlayback(isPlaying: player?.isPlaying == true)
            return player != nil
        case .fitToWindow, .actualSize, .zoomIn, .zoomOut: return canvas.image != nil
        case .revealInFinder: return model.current != nil
        case .moveToTrash:
            // ⌘⌫ typed in a drawn text box, an inspector's field or a sheet
            // (Resize, the comment editor, Save As) deletes text; it must not
            // trash the photo being edited.
            return model.current.map { !trashing.contains($0.url) } ?? false
                && !TextKeys.belongToText(in: window) && window?.attachedSheet == nil
        case .setRating, .toggleTag:
            let marks = model.current.map(marks(for:))
            menuItem.state = marks?.rating == menuItem.tag ? .on : .off
            if menuItem.action == .toggleTag { menuItem.showTag(isTagged: marks?.isTagged == true) }
            return marks != nil
        case .toggleFullScreenViewer:
            menuItem.state = isFullScreen ? .on : .off
            return true
        case .moveToNextDisplay: return Displays.provider.displays.count > 1
        case ViewerControlBar.toggleInfoAction, .toggleHistogram:
            menuItem.state = flyouts.isPinned(.right) ? .on : .off
            return true
        case .countColors: return model.current != nil
        case ViewerControlBar.toggleToolsAction:
            menuItem.state = flyouts.isPinned(.left) ? .on : .off
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
            histogramPanel.setActive(visible)
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
        exitViewer(nil)
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
    /// The texture on the canvas, for tests.
    var canvasTexture: ImageTexture? { canvas.image }
    /// The canvas itself, so tests can press on it.
    var canvasView: ImageCanvasView { canvas }

    /// Esc, ⌘W, the close button or a double-click: stop all work, put the
    /// menu bar back, and tell the browser which image to select.
    /// `reportsCurrent` is false when the browser has nothing left to show,
    /// so there is no image for it to select.
    /// The viewer is about to close for a reason outside the window (its last
    /// image went to the Trash, the browser has nothing left to show). A
    /// sheet still up (Resize, an alert, a save panel) would be left hanging
    /// off a closed window, so it ends first; an alert's handler then finds
    /// its session gone and does nothing. Not part of `closeViewer`, which
    /// also runs inside an alert's own handler (Don't Save), while AppKit
    /// still has that alert attached.
    private func endSheetForClosingFromOutside() {
        guard !isClosing, let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
    }

    private func closeViewer(reportsCurrent: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        // Unsaved edits were dealt with by the caller where that was possible
        // (a browser with nothing left to show, or a window closing for good,
        // can't wait for an answer).
        endEditSession()
        // Clearing the canvas below reports a zoom change; nothing should
        // update (or schedule a HUD fade) on the way out.
        canvas.delegate = nil
        cancelLoads()
        stopAnimation()
        summaryTask?.cancel()
        infoTask?.cancel()
        histogramPanel.stop()
        cursorWork?.cancel()
        backgroundSubscription = nil
        hud.cancelFade()
        filmstrip.setActive(false)
        AppServices.images.prefetch([], pixelSize: 0)
        FullScreenPresentation.shared.release(self)
        NotificationCenter.default.removeObserver(self)

        let entry = reportsCurrent ? model.current : nil
        canvas.setImage(nil, preserveView: false)
        for window in [fullScreenWindow, windowedWindow].compactMap({ $0 }) {
            window.delegate = nil
            window.onMouseDown = nil
            window.editUndoTarget = nil
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
