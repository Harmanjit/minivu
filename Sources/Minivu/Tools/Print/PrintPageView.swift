import AppKit
import MinivuCore

/// Everything a print needs while it runs, shared by the print panel's
/// preview (drawn on the main thread) and the job itself (drawn on the
/// print operation's own thread), so it is locked rather than isolated.
nonisolated final class PrintJob: @unchecked Sendable {
    let items: [LayoutItem]
    let provider: LayoutImageProvider

    private let lock = NSLock()
    private var settings: PrintLayoutSettings
    private var paper: PrintPaper
    private var layout: PageLayout
    /// Preview cells being decoded in the background, and those that
    /// can't be, by cache key; so a redraw asks for each only once.
    private var pendingPreview: Set<String> = []
    private var failedPreview: Set<String> = []
    private var previewReady: (@MainActor @Sendable () -> Void)?

    /// Room for a couple of sheet-sized photos at 600 dpi, or a preview's
    /// worth of thumbnails many times over.
    static let cacheBudget = 192 << 20

    /// Preview decodes run here one batch at a time, four pictures at once,
    /// however fast the user steps through the panel's pages: a queue per
    /// redraw would pile up blocked threads.
    private let previewQueue = DispatchQueue(label: "minivu.print.preview", qos: .userInitiated)

    init(items: [LayoutItem], settings: PrintLayoutSettings, paper: PrintPaper,
         provider: LayoutImageProvider = LayoutImageProvider(byteBudget: PrintJob.cacheBudget)) {
        self.items = items
        self.settings = settings.validated
        self.paper = paper
        self.provider = provider
        layout = paper.layout(for: self.settings, imageCount: items.count)
    }

    /// Called on the main actor after background decodes for the preview
    /// finish, so the panel can draw its preview again.
    func onPreviewReady(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { previewReady = handler }
    }

    var currentSettings: PrintLayoutSettings { lock.withLock { settings } }
    var currentLayout: PageLayout { lock.withLock { layout } }
    var currentPaper: PrintPaper { lock.withLock { paper } }

    func update(settings newValue: PrintLayoutSettings) {
        lock.withLock {
            settings = newValue.validated
            layout = paper.layout(for: settings, imageCount: items.count)
        }
    }

    /// Lays the pictures out again for `newPaper` (the panel's paper size,
    /// orientation or printer changed) and returns the layout.
    @discardableResult
    func update(paper newPaper: PrintPaper) -> PageLayout {
        lock.withLock {
            if newPaper != paper {
                paper = newPaper
                layout = paper.layout(for: settings, imageCount: items.count)
            }
            return layout
        }
    }

    var pageCount: Int { max(1, currentLayout.pageCount(forImageCount: items.count)) }

    /// Draws `page` (from 0) for the printer, decoding its pictures at the
    /// printer's resolution. Blocks the calling thread, which is the print
    /// operation's own.
    func drawPage(_ page: Int, in context: CGContext) {
        let (layout, settings, paper) = lock.withLock { (self.layout, self.settings, self.paper) }
        LayoutRenderer.drawPage(page, items: items, layout: layout, style: settings.style,
                                pixelsPerUnit: PrintDecodePolicy.pixelsPerUnit(paper: paper, preview: false),
                                maxPixelSize: PrintDecodePolicy.maxPixelSize(preview: false), provider: provider,
                                in: context)
    }

    /// Draws `page` for the print panel's preview without waiting for a
    /// decode: pictures already decoded small are drawn, the rest leave a
    /// placeholder and are decoded in the background, after which
    /// `onPreviewReady` asks for the preview again.
    func drawPreviewPage(_ page: Int, in context: CGContext) {
        let (layout, settings, paper) = lock.withLock { (self.layout, self.settings, self.paper) }
        let style = settings.style
        let pixelsPerUnit = PrintDecodePolicy.pixelsPerUnit(paper: paper, preview: true)
        let maxPixels = PrintDecodePolicy.maxPixelSize(preview: true)
        let cells = layout.cells(onPage: page, imageCount: items.count)
        LayoutRenderer.drawChrome(layout: layout, style: style, page: page, pageCount: pageCount, in: context)

        var missing: [LayoutCell] = []
        for cell in cells {
            let item = items[cell.index]
            let key = previewKey(item, style: style)
            let info = provider.cachedInfo(for: item, needsDate: style.caption == .nameAndDate)
            if let info {
                let placement = layout.placement(for: info.pixelSize, in: cell.imageArea)
                let needed = min(max(placement.pixelsNeeded(pixelsPerUnit: pixelsPerUnit), 16), maxPixels)
                let image = provider.cachedImage(for: item, maxPixelSize: needed)
                let failed = lock.withLock { failedPreview.contains(key) }
                if image != nil || failed {
                    let caption = style.caption.lines(name: item.name, pixelSize: info.pixelSize,
                                                      date: info.dateTaken ?? item.modified)
                    LayoutRenderer.draw(.init(cell: cell, placement: placement, image: image, caption: caption),
                                        layout: layout, style: style, in: context)
                    continue
                }
            }
            let placeholder = ImagePlacement(drawRect: cell.imageArea, visibleRect: cell.imageArea, isRotated: false)
            let caption = style.caption.lines(name: item.name, pixelSize: nil, date: nil)
            LayoutRenderer.draw(.init(cell: cell, placement: placeholder, image: nil, caption: caption),
                                layout: layout, style: style, in: context)
            missing.append(cell)
        }
        schedulePreviewDecodes(missing, layout: layout, style: style, pixelsPerUnit: pixelsPerUnit, maxPixels: maxPixels)
    }

    /// For tests: returns once the preview decodes asked for so far are done.
    func previewDecodesFinished() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in previewQueue.async { done.resume() } }
    }

    private func previewKey(_ item: LayoutItem, style: LayoutPageStyle) -> String {
        item.cacheKey + (style.caption == .nameAndDate ? "+date" : "")
    }

    private func schedulePreviewDecodes(_ cells: [LayoutCell], layout: PageLayout, style: LayoutPageStyle,
                                        pixelsPerUnit: Double, maxPixels: Int) {
        let wanted = lock.withLock { () -> [LayoutCell] in
            let fresh = cells.filter { cell in
                let key = previewKey(items[cell.index], style: style)
                return !pendingPreview.contains(key) && !failedPreview.contains(key)
            }
            for cell in fresh { pendingPreview.insert(previewKey(items[cell.index], style: style)) }
            return fresh
        }
        guard !wanted.isEmpty else { return }
        previewQueue.async { [self] in
            var start = 0
            while start < wanted.count {
                let batch = Array(wanted[start..<min(start + 4, wanted.count)])
                DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                    let cell = batch[i]
                    let item = items[cell.index]
                    let prepared = LayoutRenderer.prepare(item, cell: cell, layout: layout, style: style,
                                                          pixelsPerUnit: pixelsPerUnit, maxPixelSize: maxPixels,
                                                          provider: provider)
                    let key = previewKey(item, style: style)
                    // A picture without readable facts is drawn as a
                    // placeholder too, and not asked for again.
                    let unreadable = prepared.image == nil
                        || provider.cachedInfo(for: item, needsDate: style.caption == .nameAndDate) == nil
                    lock.withLock {
                        pendingPreview.remove(key)
                        if unreadable { failedPreview.insert(key) }
                    }
                }
                start += batch.count
            }
            let handler = lock.withLock { previewReady }
            if let handler { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
        }
    }
}

/// The view a print operation prints: one page rectangle per sheet of
/// paper, each drawn from the layout when the printing system asks.
///
/// Its drawing methods are `nonisolated`: with `canSpawnSeparateThread` the
/// print job calls them on a thread of its own while the app stays
/// responsive, and the print panel's preview calls them on the main thread.
/// They touch only the locked `PrintJob`, never the view's own state.
///
/// Pages are stacked downwards at a fixed pitch larger than any sheet, so
/// a page's rectangle never depends on the view's frame, which may not be
/// changed off the main thread.
final class PrintPageView: NSView {
    nonisolated let job: PrintJob
    /// The paper in use: the running operation's print info (which the
    /// panel changes in place), or a fixed paper in tests.
    nonisolated let paperSource: @Sendable () -> PrintPaper?
    /// Whether the drawing in progress is the panel's preview; see
    /// `PrintPageView.isPreviewDrawing`.
    nonisolated let previewTest: @Sendable () -> Bool

    /// Taller than any sheet of paper a printer takes.
    nonisolated static let pagePitch: CGFloat = 100_000

    init(job: PrintJob, paperSource: @escaping @Sendable () -> PrintPaper? = PrintPageView.currentOperationPaper,
         previewTest: @escaping @Sendable () -> Bool = PrintPageView.isPreviewDrawing) {
        self.job = job
        self.paperSource = paperSource
        self.previewTest = previewTest
        super.init(frame: NSRect(x: 0, y: 0, width: Self.pagePitch,
                                 height: Self.pagePitch * CGFloat(max(1, job.items.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    nonisolated override var isFlipped: Bool { true }

    nonisolated override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let paper = paperSource() { job.update(paper: paper) }
        range.pointee = NSRange(location: 1, length: job.pageCount)
        return true
    }

    /// `page` counts from 1, as AppKit does. The rectangle is the part of
    /// the sheet the printer can mark, in points, offset from the sheet's
    /// corner by the unprintable edge. With a view's own pagination AppKit
    /// puts each page rectangle's corner at the printable area's corner, at
    /// 100% whatever Page Setup's scale (measured by printing to PDF: a
    /// full-sheet rectangle came out shifted by the edge and cropped, and a
    /// 50% print at 100%). So the rectangle is exactly the printable area,
    /// which lands where it is on paper, and `draw` applies the scale.
    nonisolated override func rectForPage(_ page: Int) -> NSRect {
        let printable = job.currentPaper.printableSheetRect
        return printable.offsetBy(dx: 0, dy: CGFloat(max(page, 1) - 1) * Self.pagePitch)
    }

    nonisolated override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paper = job.currentPaper
        let preview = previewTest()
        let first = max(0, Int((dirtyRect.minY / Self.pagePitch).rounded(.down)))
        let last = min(job.pageCount - 1, Int((max(dirtyRect.maxY - 1, dirtyRect.minY) / Self.pagePitch).rounded(.down)))
        guard first <= last else { return }
        for page in first...last {
            context.saveGState()
            // The view is flipped: turn this sheet's rectangle into a y-up
            // space with its origin at the sheet's bottom-left corner, in
            // layout units (points at Page Setup's scale).
            context.translateBy(x: 0, y: CGFloat(page) * Self.pagePitch + paper.size.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(origin: .zero, size: paper.size))
            context.scaleBy(x: paper.scale, y: paper.scale)
            if preview {
                job.drawPreviewPage(page, in: context)
            } else {
                job.drawPage(page, in: context)
            }
            context.restoreGState()
        }
    }

    // MARK: The running operation

    /// `NSPrintOperation.current` is the operation running on the calling
    /// thread. The Swift overlay marks the class main-actor only, but the
    /// print thread must ask too, so it is looked up through the
    /// Objective-C runtime, which is what the property does anyway.
    nonisolated static func currentOperation() -> NSObject? {
        guard let type = NSClassFromString("NSPrintOperation") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("currentOperation")) else { return nil }
        return type.perform(NSSelectorFromString("currentOperation"))?.takeUnretainedValue() as? NSObject
    }

    nonisolated static let currentOperationPaper: @Sendable () -> PrintPaper? = {
        guard let info = currentOperation()?.value(forKey: "printInfo") as? NSPrintInfo else { return nil }
        return PrintPaper(printInfo: info)
    }

    /// The print panel draws its preview through a proxy graphics context
    /// of its own (`NSPrintPreviewGraphicsContext`, on the main thread),
    /// while the job draws into the printer's. AppKit offers no public
    /// flag for it, so the context's class is checked; if a later macOS
    /// renames it, the preview is simply drawn at print quality (slower,
    /// never wrong).
    nonisolated static let isPreviewDrawing: @Sendable () -> Bool = {
        guard let context = NSGraphicsContext.current else { return false }
        return NSStringFromClass(type(of: context)).contains("PrintPreview")
    }
}
