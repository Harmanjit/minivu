import AppKit
import MinivuCore
import MinivuRender

/// One image in the compare window: a header naming it, the canvas, and a
/// footer with its rating, tag and a Trash button.
///
/// The pane loads its own image at its own drawable size through
/// `AppServices.images` (so a texture the browser or viewer already made is
/// reused), and a sharper one when the canvas asks, as the viewer does. The
/// window controller decides what it shows and keeps panes in step.
final class CompareImagePane: NSView, ImageCanvasViewDelegate {
    static let headerHeight: CGFloat = 42
    static let footerHeight: CGFloat = 30
    static let focusBorderWidth: CGFloat = 2
    static let minimumWidthForZoomLabel: CGFloat = 210

    let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    private(set) var entry: FolderEntry?

    /// The user zoomed or panned this pane.
    var onInteractiveViewChange: ((CompareImagePane) -> Void)?
    /// A different image (not a sharper copy) reached the canvas.
    var onNewImage: ((CompareImagePane) -> Void)?
    /// The wheel asked for the next (+1) or previous (-1) image.
    var onNavigate: ((CompareImagePane, Int) -> Void)?
    var onRate: ((CompareImagePane, Int) -> Void)?
    var onToggleTag: ((CompareImagePane) -> Void)?
    var onTrash: ((CompareImagePane) -> Void)?

    var isFocused = false {
        didSet { if isFocused != oldValue { updateBorder() } }
    }

    /// 1-based, shown as a badge so ⌘1–⌘4 are discoverable.
    var number = 1 {
        didSet { numberLabel.stringValue = "\(number)" }
    }

    private let header = NSView()
    private let footer = NSView()
    private let border = FocusBorderView()
    private let numberLabel = NSTextField(labelWithString: "1")
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let exposureLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var starButtons: [NSButton] = []
    private let tagButton = NSButton()
    private let trashButton = NSButton()

    private var loadHandle: LoadHandle?
    private var sharpenHandle: LoadHandle?
    private var summaryTask: Task<Void, Never>?
    /// The entry whose texture is on the canvas (it lags `entry` while loading).
    private var displayedEntry: FolderEntry?
    /// Set when an image was asked for before the pane had a size.
    private var needsLoad = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The surround is the viewer's dark background, whatever the theme.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        buildHeader()
        buildFooter()
        canvas.delegate = self
        canvas.clickAction = .toggleZoom
        canvas.magnifierEnabled = true
        addSubview(canvas)

        errorLabel.font = .systemFont(ofSize: 13, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        addSubview(errorLabel)

        // Drawn over everything (see `FocusBorderView`).
        border.wantsLayer = true
        border.layer?.borderWidth = Self.focusBorderWidth
        addSubview(border)
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isFlipped: Bool { true }

    /// Header, canvas and footer are placed by hand in `layout`, which a
    /// frame change alone doesn't always schedule.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let b = bounds
        header.frame = CGRect(x: 0, y: 0, width: b.width, height: Self.headerHeight)
        footer.frame = CGRect(x: 0, y: b.height - Self.footerHeight, width: b.width, height: Self.footerHeight)
        let canvasFrame = CGRect(x: 0, y: Self.headerHeight, width: b.width,
                                 height: max(b.height - Self.headerHeight - Self.footerHeight, 1))
        if canvas.frame != canvasFrame { canvas.frame = canvasFrame }
        errorLabel.sizeToFit()
        errorLabel.frame.origin = CGPoint(x: ((b.width - errorLabel.frame.width) / 2).rounded(),
                                          y: (canvasFrame.midY - errorLabel.frame.height / 2).rounded())
        border.frame = b
        // Four panes in a row in a small window leave no room for the zoom
        // readout beside the stars, tag and trash; it goes first.
        zoomLabel.isHidden = b.width < Self.minimumWidthForZoomLabel
        if needsLoad, canvasFitSize.width >= 1, canvasFitSize.height >= 1 { load() }
    }

    private func updateBorder() {
        border.layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.clear).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()   // the accent colour is dynamic
    }

    private func buildHeader() {
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        addSubview(header)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .center
        numberLabel.wantsLayer = true
        numberLabel.layer?.cornerRadius = 4
        numberLabel.layer?.borderWidth = 1
        numberLabel.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        // In a narrow pane (four in a row) the name, which says which photo
        // this is, keeps its room and the size details give way.
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        exposureLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        exposureLabel.textColor = .secondaryLabelColor
        exposureLabel.lineBreakMode = .byTruncatingTail
        exposureLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [numberLabel, nameLabel, detailLabel, exposureLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
        }
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            numberLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 7),
            nameLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            detailLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            exposureLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            exposureLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -10),
            exposureLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
        ])
    }

    private func buildFooter() {
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        addSubview(footer)

        for stars in 1...5 {
            let button = symbolButton("star", action: #selector(starClicked(_:)))
            button.tag = stars
            button.toolTip = stars == 1 ? "Rate 1 star (click again to clear)" : "Rate \(stars) stars (click again to clear)"
            starButtons.append(button)
        }
        tagButton.target = self
        configure(tagButton, symbol: "checkmark.circle", action: #selector(tagClicked(_:)))
        tagButton.toolTip = "Tag (T)"
        configure(trashButton, symbol: "trash", action: #selector(trashClicked(_:)))
        trashButton.toolTip = "Move to Trash (⌫)"
        trashButton.setAccessibilityLabel("Move to Trash")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor

        let stars = NSStackView(views: starButtons)
        stars.spacing = 1
        let trailing = NSStackView(views: [zoomLabel, tagButton, trashButton])
        trailing.spacing = 10
        for view in [stars, trailing] {
            view.orientation = .horizontal
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stars.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            stars.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: stars.trailingAnchor, constant: 8),
        ])
    }

    private func symbolButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, symbol: symbol, action: action)
        return button
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        // Clicking a footer control must leave the keyboard with the canvas.
        button.refusesFirstResponder = true
    }

    // MARK: - Showing an image

    /// Shows `entry`, from the texture cache at once if it has one this
    /// large, otherwise as soon as it is decoded.
    func show(_ entry: FolderEntry) {
        guard entry != self.entry else { return }
        self.entry = entry
        cancelLoads()
        summaryTask?.cancel()
        errorLabel.isHidden = true
        nameLabel.stringValue = entry.name
        nameLabel.toolTip = entry.url.path
        detailLabel.stringValue = Self.fileSizeText(entry.fileSize)
        exposureLabel.stringValue = " "
        refreshMarks()
        readSummary(of: entry)
        load()
    }

    /// The canvas in pixels: screen-sized decodes are for the image fitted
    /// into it, which in a pane beside others is often much less than its
    /// long edge.
    private var canvasFitSize: CGSize { canvas.drawablePixelSize }

    private func load() {
        guard let entry else { return }
        let fitSize = canvasFitSize
        guard fitSize.width >= 1, fitSize.height >= 1, window != nil else {
            needsLoad = true
            return
        }
        needsLoad = false
        let cache = AppServices.images.cache
        if let hit = cache.bestTexture(url: entry.url, modified: entry.modified, page: 0, fitting: fitSize) {
            display(hit, of: entry)
            return
        }
        if displayedEntry != entry {
            // Any smaller copy beats the previous image under the new name.
            if let stand = cache.anyTexture(url: entry.url, modified: entry.modified, page: 0) {
                display(stand, of: entry)
            } else {
                displayedEntry = nil
                canvas.setImage(nil, preserveView: false)
                updateZoom()
            }
        }
        loadHandle = AppServices.images.load(entry, fitting: fitSize) { [weak self] result in
            self?.loadFinished(result, entry: entry)
        }
    }

    private func loadFinished(_ result: Result<ImageTexture, Error>, entry: FolderEntry) {
        guard entry == self.entry else { return }
        loadHandle = nil
        switch result {
        case .success(let texture):
            display(texture, of: entry)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            displayedEntry = entry
            canvas.setImage(nil, preserveView: false)
            errorLabel.stringValue = "minivu can’t display “\(entry.name)”."
            errorLabel.isHidden = false
            needsLayout = true
            updateZoom()
        }
    }

    /// A sharper texture of the image on screen keeps its zoom and pan; a
    /// different image starts fitted and tells the controller, which may
    /// give it the other panes' view.
    private func display(_ texture: ImageTexture, of entry: FolderEntry) {
        let sameImage = displayedEntry == entry && canvas.image?.imageSize == texture.imageSize
        displayedEntry = entry
        errorLabel.isHidden = true
        canvas.setImage(texture, preserveView: sameImage)
        updateZoom()
        if !sameImage { onNewImage?(self) }
    }

    func cancelLoads() {
        loadHandle?.cancel()
        loadHandle = nil
        sharpenHandle?.cancel()
        sharpenHandle = nil
    }

    /// Decodes this pane's image again because Show HDR, HDR RAW or RAW
    /// decoding changed.
    ///
    /// `displayedEntry` is deliberately left as it is. Clearing it would send
    /// `load` down its different-image branch, and since the loader has just
    /// emptied its cache nothing would be found there, so the pane would go
    /// black and lose its zoom until the decode landed. Left alone, the
    /// texture already on screen stays up until the new one replaces it, and
    /// the zoom is kept while the size is unchanged, which is what the viewer
    /// and the browser's preview pane already do.
    func reloadForDisplaySettings() {
        guard entry != nil else { return }
        cancelLoads()
        load()
    }

    /// Stops all work; the pane is about to go.
    func stop() {
        cancelLoads()
        summaryTask?.cancel()
        canvas.delegate = nil
        canvas.setImage(nil, preserveView: false)
    }

    /// Pixel size and exposure come from the file's headers: a few
    /// milliseconds of disk, so off the main thread.
    private func readSummary(of entry: FolderEntry) {
        let url = entry.url
        summaryTask = Task { [weak self] in
            let summary = await BlockingWork.run { MetadataReader.summary(for: url) }
            guard !Task.isCancelled, let self, self.entry?.url == url else { return }
            var parts: [String] = []
            if let size = summary.pixelSize { parts.append("\(Int(size.width)) × \(Int(size.height))") }
            parts.append(Self.fileSizeText(summary.fileSize))
            self.detailLabel.stringValue = parts.joined(separator: "  ·  ")
            let exposure = [summary.exposure, summary.camera].compactMap { $0 }.first
            self.exposureLabel.stringValue = exposure ?? summary.formatName
        }
    }

    /// "131 kB", as the browser's status bar and info panel write sizes.
    static func fileSizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    // MARK: - Rating and tag

    /// Reads the rating and tag from the catalog (one in-memory lookup).
    func refreshMarks() {
        let marks = entry.map { CompareWindowController.catalog.marks(for: $0.url) } ?? .none
        // The browser's and viewer's stars and tag mark, in the same colours.
        for button in starButtons {
            let filled = button.tag <= marks.rating
            let label = button.tag == 1 ? "Rate 1 star" : "Rate \(button.tag) stars"
            button.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: label)
            button.contentTintColor = filled ? StarRatingView.filledColor : .tertiaryLabelColor
        }
        tagButton.image = NSImage(systemSymbolName: marks.isTagged ? "checkmark.circle.fill" : "checkmark.circle",
                                  accessibilityDescription: marks.isTagged ? "Tagged" : "Not Tagged")
        tagButton.contentTintColor = marks.isTagged ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func starClicked(_ sender: NSButton) {
        guard let entry else { return }
        // Clicking the rating already set clears it, as in Photos and Lightroom.
        let current = CompareWindowController.catalog.marks(for: entry.url).rating
        onRate?(self, current == sender.tag ? 0 : sender.tag)
    }

    @objc private func tagClicked(_ sender: NSButton) { onToggleTag?(self) }
    @objc private func trashClicked(_ sender: NSButton) { onTrash?(self) }

    // MARK: - Synchronised view

    /// This pane's view, for the others to copy; nil without an image.
    func relativeView() -> RelativeView? {
        guard let image = canvas.image else { return nil }
        return RelativeView(transform: canvas.transform, isFit: canvas.zoomMode == .fit, imageSize: image.imageSize,
                            viewSize: canvas.drawablePixelSize, enlargeSmall: Preferences.shared.enlargeSmallImages)
    }

    /// Takes another pane's view without reporting it back.
    func apply(_ view: RelativeView) {
        guard let image = canvas.image else { return }
        let transform = view.transform(imageSize: image.imageSize, viewSize: canvas.drawablePixelSize,
                                       enlargeSmall: Preferences.shared.enlargeSmallImages)
        let mode: ImageCanvasView.ZoomMode = view.isFit ? .fit : abs(transform.zoom - 1) < 1e-6 ? .actualSize : .custom
        canvas.applyView(transform, mode: mode)
    }

    private func updateZoom() {
        zoomLabel.stringValue = canvas.image == nil ? "" : "\(Int(canvas.zoomPercent.rounded()))%"
    }

    // MARK: - ImageCanvasViewDelegate

    func canvasDidChangeZoom(_ canvas: ImageCanvasView) {
        updateZoom()
    }

    func canvasDidChangeViewInteractively(_ canvas: ImageCanvasView) {
        onInteractiveViewChange?(self)
    }

    func canvasRequestsNavigation(_ canvas: ImageCanvasView, offset: Int) {
        onNavigate?(self, offset)
    }

    /// As in the viewer: a screen-sized load while a fitted pane has outgrown
    /// its texture, full resolution when zoomed in or under the magnifier.
    func canvasNeedsFullResolution(_ canvas: ImageCanvasView) {
        guard let entry, displayedEntry == entry, let image = canvas.image else { return }
        sharpenHandle?.cancel()
        sharpenHandle = nil
        let deliver: (Result<ImageTexture, Error>) -> Void = { [weak self] result in
            guard let self, case .success(let texture) = result, self.entry == entry else { return }
            self.display(texture, of: entry)
        }
        let fitSize = canvasFitSize
        let handle: LoadHandle
        // Compared with the image's fitted size, not the pane's long edge: a
        // fitted texture under the magnifier must go to full resolution.
        if ViewerWindowController.wantsScreenSizedSharpening(
            fitted: canvas.zoomMode == .fit, kind: entry.kind,
            imageLongEdge: max(image.imageSize.width, image.imageSize.height),
            textureLongEdge: max(image.textureSize.width, image.textureSize.height),
            canvasLongEdge: ImageDecoder.fittedLongEdge(imageSize: image.imageSize, in: fitSize)) {
            handle = AppServices.images.load(entry, fitting: fitSize, update: deliver)
        } else {
            handle = AppServices.images.loadFullResolution(entry, update: deliver)
        }
        // A cache hit delivered inside the call may already have asked again.
        if sharpenHandle == nil { sharpenHandle = handle }
    }
}

/// The focused pane's accent outline, drawn above the header, canvas and
/// footer but never taking a click from them.
private final class FocusBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
