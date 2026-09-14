import AppKit
import SwiftUI
import QuartzCore
import MinivuCore

/// Where the comparison looks, as plain geometry so it can be tested.
///
/// Both panes show the same region of the image at the same zoom, which
/// here means screen pixels per image pixel (so 100% is one image pixel on
/// one display pixel, as the viewer's Actual Size). Coordinates are image
/// pixels with the origin at the top left.
nonisolated struct CompareViewport: Equatable {
    static let zoomLevels = [1, 2, 4]
    /// Extra image pixels encoded beyond the visible area, so a short drag
    /// doesn't need a new encode.
    static let cropMargin = 512
    static let maximumCropSide = 2560

    let imageWidth: Int
    let imageHeight: Int
    var centre: CGPoint
    var zoom: Int

    init(imageWidth: Int, imageHeight: Int, zoom: Int = 1) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        centre = CGPoint(x: CGFloat(imageWidth) / 2, y: CGFloat(imageHeight) / 2)
        self.zoom = zoom
    }

    /// Image pixels per view point.
    func pixelsPerPoint(backingScale: CGFloat) -> CGFloat {
        backingScale / CGFloat(zoom)
    }

    /// Moves the image with the pointer: dragging right shows what is to
    /// the left. `delta` is in points, y down. The centre stays on the image.
    mutating func pan(by delta: CGSize, backingScale: CGFloat) {
        let scale = pixelsPerPoint(backingScale: backingScale)
        centre.x = min(max(centre.x - delta.width * scale, 0), CGFloat(imageWidth))
        centre.y = min(max(centre.y - delta.height * scale, 0), CGFloat(imageHeight))
    }

    /// The part of the image a pane of `viewSize` points shows (it may reach
    /// past the image's edges).
    func visibleRect(viewSize: CGSize, backingScale: CGFloat) -> CGRect {
        let scale = pixelsPerPoint(backingScale: backingScale)
        let width = viewSize.width * scale, height = viewSize.height * scale
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }

    /// Where the pixels of `crop` go in the pane, in points (y down), with
    /// the origin on a display pixel so 100% stays pixel-exact.
    func frame(of crop: CGRect, viewSize: CGSize, backingScale: CGFloat) -> CGRect {
        let points = 1 / pixelsPerPoint(backingScale: backingScale)
        func snap(_ value: CGFloat) -> CGFloat { (value * backingScale).rounded() / backingScale }
        return CGRect(x: snap(viewSize.width / 2 + (crop.minX - centre.x) * points),
                      y: snap(viewSize.height / 2 + (crop.minY - centre.y) * points),
                      width: crop.width * points, height: crop.height * points)
    }

    /// The region to encode: the visible part plus a margin, at least the
    /// estimator's 1024 px and at most 2560, on the codec's block grid.
    func crop(viewSize: CGSize, backingScale: CGFloat) -> CGRect {
        let visible = visibleRect(viewSize: viewSize, backingScale: backingScale)
        let wanted = Int(max(visible.width, visible.height).rounded(.up)) + Self.cropMargin
        let aligned = (wanted + SizeEstimator.blockAlignment - 1) / SizeEstimator.blockAlignment * SizeEstimator.blockAlignment
        let side = min(max(aligned, SizeEstimator.cropSide), Self.maximumCropSide)
        return SizeEstimator.crop(imageWidth: imageWidth, imageHeight: imageHeight, centre: centre, side: side)
    }

    /// Whether the pane shows image pixels that `crop` doesn't cover.
    func needsNewCrop(_ crop: CGRect, viewSize: CGSize, backingScale: CGFloat) -> Bool {
        let image = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let visible = visibleRect(viewSize: viewSize, backingScale: backingScale).intersection(image)
        guard !visible.isNull, !visible.isEmpty else { return false }
        return !crop.insetBy(dx: -0.5, dy: -0.5).contains(visible)
    }
}

/// One pane's pixels: part of an image and where in the image it came from.
struct CompareTile {
    let image: CGImage
    let rect: CGRect
}

/// FastStone's "compare image quality": the original beside the result of
/// encoding it with the options chosen in Save As.
///
/// Light on purpose. Only the region on screen (plus a margin) is cropped
/// and encoded, a few milliseconds per change, so the quality slider
/// updates the right-hand pane live; the file size shown with it comes from
/// Save As's full encode. The crop is re-encoded 100 ms after the last
/// change, and again when panning reaches its edge.
@MainActor @Observable final class QualityCompareModel {
    let save: SaveAsModel
    var zoom = 1 {
        didSet {
            guard zoom != oldValue else { return }
            viewport?.zoom = zoom
            refreshIfNeeded()
        }
    }
    private(set) var viewport: CompareViewport?
    private(set) var original: CompareTile?
    private(set) var encoded: CompareTile?
    private(set) var isEncoding = false
    /// Uncompressed size of the full rendered image.
    private(set) var imageBytes: Int64?
    private(set) var error: String?

    /// Pane size in points and the screen's scale, reported by the panes.
    @ObservationIgnored var paneSize = CGSize(width: 500, height: 500)
    @ObservationIgnored var backingScale: CGFloat = 2

    static let debounce: Duration = .milliseconds(100)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(save: SaveAsModel) {
        self.save = save
    }

    /// Call when the options change: re-encodes after a short pause.
    func optionsChanged() {
        refresh(debounced: true)
    }

    func pan(by delta: CGSize) {
        guard var viewport else { return }
        viewport.pan(by: delta, backingScale: backingScale)
        self.viewport = viewport
        refreshIfNeeded()
    }

    func paneResized(to size: CGSize, backingScale: CGFloat) {
        guard size != paneSize || backingScale != self.backingScale else { return }
        paneSize = size
        self.backingScale = backingScale
        refreshIfNeeded()
    }

    /// A new crop only when the panes show pixels outside the current one.
    private func refreshIfNeeded() {
        guard let viewport, let original else {
            refresh(debounced: false)
            return
        }
        if viewport.needsNewCrop(original.rect, viewSize: paneSize, backingScale: backingScale) {
            refresh(debounced: false)
        }
    }

    func refresh(debounced: Bool) {
        generation += 1
        let generation = self.generation
        task?.cancel()
        task = Task { [weak self] in
            if debounced { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled, let self else { return }
            await self.render(generation: generation)
        }
    }

    private func render(generation: Int) async {
        let options = save.options
        let image: CGImage
        do {
            image = try await save.source.image(for: options)
        } catch {
            guard generation == self.generation else { return }
            self.error = SaveAlert.message(for: error)
            return
        }
        guard generation == self.generation else { return }
        self.error = nil
        if viewport?.imageWidth != image.width || viewport?.imageHeight != image.height {
            viewport = CompareViewport(imageWidth: image.width, imageHeight: image.height, zoom: zoom)
        }
        imageBytes = Int64(image.bytesPerRow * image.height)
        guard let viewport else { return }
        let rect = viewport.crop(viewSize: paneSize, backingScale: backingScale)
        guard let cropped = image.cropping(to: rect) else { return }
        // The original side is just the crop, so it follows a drag at once.
        original = CompareTile(image: cropped, rect: rect)

        isEncoding = true
        let result = await BlockingWork.run { () -> CGImage? in
            var cropOptions = options
            cropOptions.keepMetadata = false
            guard let data = try? ImageEncoder.encode(cropped, options: cropOptions, metadataSource: nil) else { return nil }
            return ImageEncoder.decodePreview(data)
        }
        guard generation == self.generation else { return }
        isEncoding = false
        encoded = result.map { CompareTile(image: $0, rect: rect) }
    }
}

/// The comparison window. A separate window rather than a sheet on the save
/// panel, which would be too small for two panes at 100%; it closes with
/// the panel.
final class QualityCompareWindowController: NSWindowController {
    let model: QualityCompareModel

    init(model saveModel: SaveAsModel) {
        model = QualityCompareModel(save: saveModel)
        let hosting = NSHostingController(rootView: QualityCompareView(model: model))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        // After the content: the hosting controller brings its own (empty) title.
        window.title = "Compare Quality"
        window.subtitle = saveModel.entry.name
        window.setContentSize(NSSize(width: 1160, height: 720))
        window.center()
        super.init(window: window)
        model.refresh(debounced: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Image > Zoom In, Zoom Out and Actual Size step through 100/200/400%
    // while this window is in front.

    @objc func zoomIn(_ sender: Any?) {
        model.zoom = CompareViewport.zoomLevels.first { $0 > model.zoom } ?? model.zoom
    }

    @objc func zoomOut(_ sender: Any?) {
        model.zoom = CompareViewport.zoomLevels.last { $0 < model.zoom } ?? model.zoom
    }

    @objc func actualSize(_ sender: Any?) {
        model.zoom = 1
    }
}

struct QualityCompareView: View {
    @Bindable var model: QualityCompareModel

    var body: some View {
        let save = model.save
        HStack(spacing: 0) {
            pane(title: "Original",
                 detail: model.imageBytes.map { "\(SaveSizeText.memory($0)) in memory" } ?? "",
                 tile: model.original, isBusy: false)
            Divider()
            pane(title: save.formatDescription, detail: save.sizeText, tile: model.encoded,
                 isBusy: model.isEncoding || save.isEstimating)
        }
        .overlay {
            if let error = model.error {
                Text(error).foregroundStyle(.secondary).padding()
            }
        }
        .onChange(of: save.options) { model.optionsChanged() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Zoom", selection: $model.zoom) {
                    ForEach(CompareViewport.zoomLevels, id: \.self) { level in
                        Text("\(level * 100)%").tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .help("Zoom both sides (⌘= and ⌘-)")
            }
            if save.options.format.supportsQuality {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Text("Quality")
                            .foregroundStyle(.secondary)
                        Slider(value: Bindable(save).qualityPercent, in: 1...100)
                            .accessibilityLabel("Quality")
                            .frame(width: 180)
                        Text("\(Int(save.qualityPercent))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func pane(title: String, detail: String, tile: CompareTile?, isBusy: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if !detail.isEmpty {
                    Text("— \(detail)").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider()
            ComparePane(tile: tile, viewport: model.viewport, model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One side: a layer showing a tile, dragged to pan both sides.
private struct ComparePane: NSViewRepresentable {
    let tile: CompareTile?
    let viewport: CompareViewport?
    let model: QualityCompareModel

    func makeNSView(context: Context) -> ComparePaneView {
        let view = ComparePaneView()
        view.onPan = { [model] delta in model.pan(by: delta) }
        view.onResize = { [model] size, scale in model.paneResized(to: size, backingScale: scale) }
        return view
    }

    func updateNSView(_ view: ComparePaneView, context: Context) {
        view.show(tile, viewport: viewport)
    }
}

/// Draws with a plain `CALayer` whose contents are the tile's CGImage:
/// Core Animation scales it on the GPU, and nearest-neighbour magnification
/// keeps each pixel a crisp square at 200% and 400%, which is what makes
/// compression artefacts visible.
final class ComparePaneView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onResize: ((CGSize, CGFloat) -> Void)?

    private let imageLayer = CALayer()
    private var tile: CompareTile?
    private var viewport: CompareViewport?
    private var lastDrag: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .linear
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ tile: CompareTile?, viewport: CompareViewport?) {
        let imageChanged = tile?.image !== self.tile?.image
        self.tile = tile
        self.viewport = viewport
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if imageChanged { imageLayer.contents = tile?.image }
        placeImage()
        CATransaction.commit()
    }

    private func placeImage() {
        guard let tile, let viewport else {
            imageLayer.isHidden = true
            return
        }
        imageLayer.isHidden = false
        imageLayer.frame = viewport.frame(of: tile.rect, viewSize: bounds.size, backingScale: backingScale)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeImage()
        CATransaction.commit()
        onResize?(bounds.size, backingScale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?(bounds.size, backingScale)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        lastDrag = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let point = event.locationInWindow
        lastDrag = point
        // Window coordinates run up; the pane's delta runs down.
        onPan?(CGSize(width: point.x - last.x, height: last.y - point.y))
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        NSCursor.pop()
    }
}
