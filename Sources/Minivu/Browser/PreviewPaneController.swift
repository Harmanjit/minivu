import AppKit
import Combine
import SwiftUI
import MinivuCore
import MinivuRender

/// The right-hand pane: a large preview of the selected photo on the Metal
/// canvas (with the magnifier), and its file information and EXIF below.
///
/// Arrowing through a folder changes the selection many times a second, so
/// the preview waits ~60 ms for the selection to settle before decoding,
/// cancels decodes it no longer wants, and once the photo is up prefetches
/// its neighbours at the same size so the next arrow shows instantly.
final class PreviewPaneController: NSViewController, NSSplitViewDelegate, ImageCanvasViewDelegate {
    /// What the pane describes.
    enum Content: Equatable {
        case none
        case image(FolderEntry, neighbours: [FolderEntry])
        case folder(FolderEntry)
        case multiple(count: Int, bytes: Int64)
    }

    /// The canvas was double-clicked: open the viewer on the shown photo.
    var onOpenViewer: (() -> Void)?

    /// False while the pane is collapsed: nothing is decoded for a preview
    /// nobody can see.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible {
                refresh()
            } else {
                cancelLoads()
                targetEntry = nil
                // Neighbours of a photo nobody can see aren't worth decoding.
                AppServices.images.prefetch([], pixelSize: 0)
            }
        }
    }

    static let debounce: Duration = .milliseconds(60)
    /// Share of the pane's height given to the picture, remembered when the
    /// user drags the divider.
    nonisolated static let imageFractionKey = "browserPreviewImageFraction"
    static let minimumPartHeight: CGFloat = 120

    private let split = NSSplitView()
    private let imageArea = NSView()
    private let placeholder = NSStackView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let info = NSHostingView(rootView: InfoPanelView(url: nil))
    /// Holds `info`, so the info can be hidden without the split view taking
    /// that for a collapse (which would move and save the divider).
    private let infoArea = NSView()
    /// Made on first use: creating it compiles no shaders, but it does wait
    /// for the GPU setup that launch starts in the background.
    private var canvas: ImageCanvasView?

    /// nil until the first `show`, so showing `.none` at launch isn't skipped.
    private var content: Content?
    /// The photo on the canvas, or being fetched for it.
    private var targetEntry: FolderEntry?
    private var shownEntry: FolderEntry?
    private var loadHandle: LoadHandle?
    private var refineHandle: LoadHandle?
    private var pendingLoad: Task<Void, Never>?
    private var themeSubscription: AnyCancellable?
    private var isPlacingDivider = false

    override func loadView() {
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.alignment = .center
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.alignment = .center
        placeholder.orientation = .vertical
        placeholder.spacing = 6
        placeholder.alignment = .centerX
        for view in [iconView, titleField, subtitleField] { placeholder.addArrangedSubview(view) }
        placeholder.setCustomSpacing(12, after: iconView)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        imageArea.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: imageArea.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: imageArea.leadingAnchor, constant: 16),
            titleField.widthAnchor.constraint(lessThanOrEqualTo: imageArea.widthAnchor, constant: -32),
        ])

        info.translatesAutoresizingMaskIntoConstraints = false
        infoArea.addSubview(info)
        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: infoArea.topAnchor),
            info.leadingAnchor.constraint(equalTo: infoArea.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: infoArea.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: infoArea.bottomAnchor),
        ])
        // Plain subviews, laid out by the delegate below as a proportion of
        // the height: autosaved frames would keep absolute heights, and a
        // taller window would give all its extra room to one half.
        split.addSubview(imageArea)
        split.addSubview(infoArea)

        // Under the unified toolbar the window's content runs to the top
        // edge; the pane starts below the toolbar instead.
        let container = PaneBackgroundView()
        container.wantsLayer = true
        container.onAppearanceChange = { [weak self] in self?.updateCanvasBackground() }
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        view = container

        themeSubscription = Preferences.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateCanvasBackground() }
    }

    // MARK: - Divider

    private var imageFraction: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.imageFractionKey)
        return saved > 0 && saved < 1 ? saved : 0.55
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutSplit()
    }

    private func layoutSplit() {
        let splitView = split
        let width = splitView.bounds.width
        let available = splitView.bounds.height - splitView.dividerThickness
        guard available > 0, !infoArea.isHidden else {
            // Not laid out yet, or nothing to describe (no selection, several
            // items): all to the top, so its message is centred in the pane.
            imageArea.frame = splitView.bounds
            infoArea.frame = NSRect(x: 0, y: splitView.bounds.height, width: width, height: 0)
            return
        }
        let top = clampedImageHeight((available * imageFraction).rounded(), available: available)
        // NSSplitView is flipped: the first subview is at the top.
        imageArea.frame = NSRect(x: 0, y: 0, width: width, height: top)
        infoArea.frame = NSRect(x: 0, y: top + splitView.dividerThickness, width: width, height: available - top)
    }

    private func clampedImageHeight(_ height: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 2 * Self.minimumPartHeight else { return (available / 2).rounded() }
        return min(max(height, Self.minimumPartHeight), available - Self.minimumPartHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        clampedImageHeight(proposedPosition, available: splitView.bounds.height - splitView.dividerThickness)
    }

    /// Only a drag of the divider is the user's choice; layout passes (a
    /// window resize, the info half hiding) must not overwrite it.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil, !isPlacingDivider, !infoArea.isHidden,
              NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseUp
        else { return }
        let available = split.bounds.height - split.dividerThickness
        guard available > 0 else { return }
        UserDefaults.standard.set(Double(imageArea.frame.height / available), forKey: Self.imageFractionKey)
    }

    // MARK: - Content

    func show(_ newContent: Content) {
        guard newContent != content else { return }
        content = newContent
        refresh()
    }

    /// While collapsed nothing is read or decoded (the info panel reads
    /// metadata from disk); showing the pane again refreshes it.
    private func refresh() {
        guard isViewLoaded, isVisible else { return }
        switch content ?? .none {
        case .none:
            cancelLoads()
            showPlaceholder((nil, "No Selection", ""))
            // One "No Selection" for the pane, not one per half.
            setInfoVisible(false)
        case .folder(let entry):
            cancelLoads()
            showPlaceholder((NSWorkspace.shared.icon(for: .folder), entry.name, "Folder"))
            setInfoVisible(true)
            info.rootView = InfoPanelView(url: entry.url)
        case .multiple(let count, let bytes):
            cancelLoads()
            let icon = NSImage(named: NSImage.multipleDocumentsName) ?? NSWorkspace.shared.icon(for: .image)
            showPlaceholder((icon, "\(count.formatted()) items selected",
                             bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : ""))
            setInfoVisible(false)
        case .image(let entry, let neighbours):
            setInfoVisible(true)
            info.rootView = InfoPanelView(url: entry.url)
            showImage(entry, neighbours: neighbours)
        }
    }

    private func setInfoVisible(_ visible: Bool) {
        guard infoArea.isHidden == visible else { return }
        infoArea.isHidden = !visible
        layoutSplit()
        // The divider is a layer of the split view's own, moved only when the
        // split view lays out; frames set by hand leave the old line across
        // the message.
        split.needsLayout = true
        if visible {
            // The split view still counts the half it saw hidden as
            // collapsed and draws no divider until a position is set.
            isPlacingDivider = true
            split.setPosition(imageArea.frame.height, ofDividerAt: 0)
            isPlacingDivider = false
        }
    }

    private func showPlaceholder(_ item: (icon: NSImage?, title: String, subtitle: String)?) {
        canvas?.isHidden = true
        canvas?.setImage(nil, preserveView: false)
        shownEntry = nil
        targetEntry = nil
        placeholder.isHidden = item == nil
        iconView.image = item?.icon
        iconView.isHidden = item?.icon == nil
        titleField.font = item?.icon == nil
            ? .systemFont(ofSize: 15, weight: .medium) : .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.textColor = item?.icon == nil ? .secondaryLabelColor : .labelColor
        titleField.stringValue = item?.title ?? ""
        subtitleField.stringValue = item?.subtitle ?? ""
        subtitleField.isHidden = item?.subtitle.isEmpty ?? true
    }

    // MARK: - Loading

    private func showImage(_ entry: FolderEntry, neighbours: [FolderEntry]) {
        let canvas = makeCanvasIfNeeded()
        placeholder.isHidden = true
        canvas.isHidden = false
        guard entry != targetEntry else {
            if shownEntry == entry { prefetch(neighbours) }
            return
        }
        cancelLoads()
        targetEntry = entry
        let pixelSize = previewPixelSize
        // Already decoded (by the viewer, or a prefetch): show it now.
        if let texture = AppServices.images.cache.bestTexture(url: entry.url, modified: entry.modified, page: 0,
                                                              minimumLongEdge: pixelSize) {
            display(texture, for: entry, neighbours: neighbours)
            return
        }
        pendingLoad = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self, self.targetEntry == entry else { return }
            self.loadHandle = AppServices.images.load(entry, pixelSize: pixelSize) { [weak self] result in
                guard let self, self.targetEntry == entry else { return }
                self.loadHandle = nil
                switch result {
                case .success(let texture):
                    self.display(texture, for: entry, neighbours: neighbours)
                case .failure(let error):
                    guard !(error is CancellationError) else { return }
                    self.shownEntry = nil
                    self.canvas?.setImage(nil, preserveView: false)
                }
            }
        }
    }

    private func display(_ texture: ImageTexture, for entry: FolderEntry, neighbours: [FolderEntry]) {
        canvas?.setImage(texture, preserveView: false)
        shownEntry = entry
        prefetch(neighbours)
    }

    private func prefetch(_ neighbours: [FolderEntry]) {
        guard !neighbours.isEmpty else { return }
        AppServices.images.prefetch(neighbours, pixelSize: previewPixelSize)
    }

    private func cancelLoads() {
        pendingLoad?.cancel()
        pendingLoad = nil
        loadHandle?.cancel()
        loadHandle = nil
        refineHandle?.cancel()
        refineHandle = nil
    }

    /// The canvas's long edge in pixels, which is all a fitted preview needs.
    private var previewPixelSize: Int {
        let size = canvas?.drawablePixelSize ?? .zero
        return max(256, Int(max(size.width, size.height)))
    }

    private func makeCanvasIfNeeded() -> ImageCanvasView {
        if let canvas { return canvas }
        let canvas = ImageCanvasView(frame: imageArea.bounds)
        canvas.clickAction = .none
        canvas.magnifierEnabled = true
        canvas.delegate = self
        canvas.translatesAutoresizingMaskIntoConstraints = false
        imageArea.addSubview(canvas, positioned: .below, relativeTo: placeholder)
        // A margin, so the photo sits on the pane rather than touching its edges.
        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: imageArea.topAnchor, constant: margin),
            canvas.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: margin),
            canvas.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor, constant: -margin),
            canvas.bottomAnchor.constraint(equalTo: imageArea.bottomAnchor, constant: -margin),
        ])
        imageArea.layoutSubtreeIfNeeded()
        self.canvas = canvas
        updateCanvasBackground()
        return canvas
    }

    /// The canvas paints its own surround in linear light; match it to the
    /// pane's background so the photo floats on the pane.
    private func updateCanvasBackground() {
        guard let canvas else { return }
        var level: SIMD3<Float> = .zero
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            level = Self.linearRGB(PaneBackgroundView.color)
        }
        canvas.background = level
    }

    /// sRGB colour to linear-light components, as the canvas shader wants.
    nonisolated static func linearRGB(_ color: NSColor) -> SIMD3<Float> {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .zero }
        func linear(_ c: CGFloat) -> Float {
            let v = Float(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return SIMD3(linear(srgb.redComponent), linear(srgb.greenComponent), linear(srgb.blueComponent))
    }

    /// A screen-sized decode only helps a fitted canvas whose texture is
    /// smaller than the canvas (3% slack, as the loader snaps sizes).
    nonisolated static func wantsScreenSizedRefine(fitted: Bool, textureEdge: Int, canvasEdge: Int) -> Bool {
        fitted && Double(textureEdge) < Double(canvasEdge) * 0.97
    }

    // MARK: - ImageCanvasViewDelegate

    func canvasDidDoubleClick(_ canvas: ImageCanvasView) {
        onOpenViewer?()
    }

    /// The pane grew past the texture, or the magnifier (or a wheel zoom)
    /// wants detail.
    ///
    /// The zoom mode alone can't tell these apart: the preview stays fitted
    /// while the magnifier shows. A texture that already covers the canvas
    /// can only be sharpened by the full-resolution image; asking for the
    /// screen size again would hand back the same texture and the
    /// magnifier would stay blurry.
    func canvasNeedsFullResolution(_ canvas: ImageCanvasView) {
        guard let entry = shownEntry else { return }
        refineHandle?.cancel()
        let deliver: (Result<ImageTexture, Error>) -> Void = { [weak self] result in
            guard let self, self.shownEntry == entry, case .success(let texture) = result else { return }
            self.refineHandle = nil
            self.canvas?.setImage(texture, preserveView: true)
        }
        let textureEdge = canvas.image.map { Int(max($0.textureSize.width, $0.textureSize.height)) } ?? 0
        if Self.wantsScreenSizedRefine(fitted: canvas.zoomMode == .fit, textureEdge: textureEdge,
                                       canvasEdge: previewPixelSize) {
            refineHandle = AppServices.images.load(entry, pixelSize: previewPixelSize, update: deliver)
        } else {
            refineHandle = AppServices.images.loadFullResolution(entry, update: deliver)
        }
    }
}

/// The pane's background, painted explicitly so the canvas surround can be
/// set to exactly the same colour. It also reports appearance changes
/// (Bright to Dark), which a view controller isn't told about.
private final class PaneBackgroundView: NSView {
    static let color = NSColor.windowBackgroundColor

    var onAppearanceChange: (() -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
