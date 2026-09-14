import AppKit
import CoreText
import ImageIO
import MinivuCore

// Drawing pages of pictures with Core Graphics: shared by Print (into the
// printer's context) and Contact Sheet (into a bitmap or a PDF). Everything
// here is `nonisolated` and runs on whatever thread draws the page; a print
// job draws on a thread of its own, a contact sheet on a GCD worker.

/// One picture to lay out: a file (decoded when its page is drawn) or an
/// image already rendered (the viewer's unsaved edit).
nonisolated struct LayoutItem: @unchecked Sendable {
    enum Source {
        case file(URL, page: Int)
        case image(CGImage)
    }

    var name: String
    var source: Source
    /// Stands in for the date taken when a file has none.
    var modified: Date

    init(entry: FolderEntry, page: Int = 0) {
        name = entry.name
        source = .file(entry.url, page: page)
        modified = entry.modified
    }

    init(image: CGImage, name: String, modified: Date) {
        self.name = name
        source = .image(image)
        self.modified = modified
    }

    /// Two items are the same picture when they name the same file and page.
    var cacheKey: String {
        switch source {
        case .file(let url, let page): "\(url.path)#\(page)"
        case .image(let image): "image-\(ObjectIdentifier(image).hashValue)"
        }
    }
}

/// What a caption says under each picture.
nonisolated enum CaptionContent: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, name, nameAndDimensions, nameAndDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .name: "Name"
        case .nameAndDimensions: "Name and Dimensions"
        case .nameAndDate: "Name and Date"
        }
    }

    var lineCount: Int {
        switch self {
        case .none: 0
        case .name: 1
        case .nameAndDimensions, .nameAndDate: 2
        }
    }

    /// The space a caption takes under a cell's image: the lines plus half a
    /// line of air between the picture and the text.
    func height(fontSize: Double) -> Double {
        lineCount == 0 ? 0 : fontSize * (0.5 + 1.25 * Double(lineCount))
    }

    func lines(name: String, pixelSize: CGSize?, date: Date?) -> [String] {
        switch self {
        case .none: []
        case .name: [name]
        case .nameAndDimensions:
            [name, pixelSize.map { "\(Int($0.width.rounded())) × \(Int($0.height.rounded()))" } ?? ""]
        case .nameAndDate:
            [name, date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""]
        }
    }
}

/// How a page looks beyond its geometry.
nonisolated struct LayoutPageStyle: Sendable, Equatable {
    var background: ExportColor?
    var caption: CaptionContent = .none
    var captionFontSize: Double = 10
    /// A title across the top, in the layout's header band.
    var header: String?
    var headerFontSize: Double = 16
    /// "Page 2 of 5" in the layout's footer band.
    var showsPageNumbers = false

    /// Dark grey on light backgrounds, near-white on dark ones.
    var textColor: ExportColor {
        guard let background else { return ExportColor(red: 0.12, green: 0.12, blue: 0.12) }
        let luminance = 0.2126 * background.red + 0.7152 * background.green + 0.0722 * background.blue
        return luminance > 0.5 ? ExportColor(red: 0.12, green: 0.12, blue: 0.12) : ExportColor(red: 0.92, green: 0.92, blue: 0.92)
    }
}

/// What the renderer needs to know about a file before decoding it.
nonisolated struct LayoutImageInfo: Sendable, Equatable {
    /// Oriented, in pixels.
    var pixelSize: CGSize
    var dateTaken: Date?
}

/// Decodes pictures at the size a cell needs and keeps the last few, so a
/// print preview drawn again (a setting changed) or a page drawn for the
/// preview and then for the printer doesn't decode them twice.
///
/// Bounded by bytes, least recently used first out: a page of 30 small
/// cells and a page of one large photo both fit, a 1000-image job never
/// holds more than the budget. Thread-safe; decodes run outside the lock.
nonisolated final class LayoutImageProvider: @unchecked Sendable {
    /// (file, page, long edge wanted) → the image and whether it is the
    /// file's full resolution (so a larger request can't do better).
    typealias Decode = @Sendable (URL, Int, Int) -> (image: CGImage, isFullResolution: Bool)?
    typealias Describe = @Sendable (URL, _ needsDate: Bool) -> LayoutImageInfo?

    private struct Entry {
        var image: CGImage
        var isFullResolution: Bool
        var bytes: Int
        var lastUse: UInt64
    }

    let byteBudget: Int
    private let decode: Decode
    private let describe: Describe
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var infos: [String: LayoutImageInfo] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    init(byteBudget: Int = 256 << 20, decode: @escaping Decode = LayoutImageProvider.decodeFile,
         describe: @escaping Describe = LayoutImageProvider.describeFile) {
        self.byteBudget = byteBudget
        self.decode = decode
        self.describe = describe
    }

    /// The picture's size (and date when asked), read from the header once.
    func info(for item: LayoutItem, needsDate: Bool) -> LayoutImageInfo? {
        switch item.source {
        case .image(let image):
            return LayoutImageInfo(pixelSize: CGSize(width: image.width, height: image.height), dateTaken: nil)
        case .file(let url, _):
            let key = item.cacheKey + (needsDate ? "+date" : "")
            if let known = lock.withLock({ infos[key] }) { return known }
            guard let info = describe(url, needsDate) else { return nil }
            lock.withLock { infos[key] = info }
            return info
        }
    }

    /// The header facts if they have been read, without reading them.
    func cachedInfo(for item: LayoutItem, needsDate: Bool) -> LayoutImageInfo? {
        switch item.source {
        case .image: info(for: item, needsDate: needsDate)
        case .file: lock.withLock { infos[item.cacheKey + (needsDate ? "+date" : "")] }
        }
    }

    /// A decoded picture good for `maxPixelSize` if one is cached; never decodes.
    func cachedImage(for item: LayoutItem, maxPixelSize: Int) -> CGImage? {
        cached(key: item.cacheKey, wanted: max(1, maxPixelSize))
    }

    /// The picture with at least `maxPixelSize` pixels on its long edge (or
    /// all it has), from the cache when a large enough one is there.
    func image(for item: LayoutItem, maxPixelSize: Int) -> CGImage? {
        let wanted = max(1, maxPixelSize)
        let key = item.cacheKey
        if let cached = cached(key: key, wanted: wanted) { return cached }

        let made: (image: CGImage, isFullResolution: Bool)?
        switch item.source {
        case .file(let url, let page):
            made = decode(url, page, wanted)
        case .image(let image):
            made = Self.downscale(image, maxPixelSize: wanted).map { ($0, max(image.width, image.height) <= wanted) }
        }
        guard let made else { return nil }
        store(made.image, isFullResolution: made.isFullResolution, key: key)
        return made.image
    }

    private func cached(key: String, wanted: Int) -> CGImage? {
        lock.withLock { () -> CGImage? in
            guard var entry = entries[key] else { return nil }
            let longEdge = max(entry.image.width, entry.image.height)
            // Up to twice the size wanted is fine (Core Graphics filters it
            // down when drawing); larger wastes the preview's time.
            guard entry.isFullResolution || Double(longEdge) >= Double(wanted) * 0.97, longEdge <= wanted * 2
            else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.image
        }
    }

    private func store(_ image: CGImage, isFullResolution: Bool, key: String) {
        let cost = image.bytesPerRow * image.height
        lock.withLock {
            if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
            // An image larger than the whole budget is used once, not kept.
            guard cost <= byteBudget else { return }
            clock += 1
            entries[key] = Entry(image: image, isFullResolution: isFullResolution, bytes: cost, lastUse: clock)
            bytes += cost
            while bytes > byteBudget, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries.removeValue(forKey: oldest.key)
                bytes -= oldest.value.bytes
            }
        }
    }

    var cachedBytes: Int { lock.withLock { bytes } }
    var cachedCount: Int { lock.withLock { entries.count } }

    // MARK: Default decoding

    /// Small sizes take ImageIO's thumbnail route (embedded previews, the
    /// fast HEIC path); larger ones the display decode, which snaps to the
    /// JPEG decoder's cheap fractions. HDR pictures come back as SDR: paper
    /// and 8-bit files have no headroom.
    static let decodeFile: Decode = { url, page, maxPixelSize in
        if maxPixelSize <= 512, page == 0, let thumbnail = ImageDecoder.thumbnail(for: url, maxPixelSize: maxPixelSize) {
            return (thumbnail, max(thumbnail.width, thumbnail.height) < maxPixelSize)
        }
        guard let decoded = try? ImageDecoder.decode(url, maxPixelSize: maxPixelSize, page: page, allowHDR: false)
        else { return nil }
        let image = decoded.image
        return (image, decoded.isFullResolution || max(image.width, image.height) < maxPixelSize)
    }

    static let describeFile: Describe = { url, needsDate in
        guard let info = ImageDecoder.info(for: url) else { return nil }
        let date = needsDate ? MetadataReader.summary(for: url).dateTaken : nil
        return LayoutImageInfo(pixelSize: info.pixelSize, dateTaken: date)
    }

    /// `image` no larger than `maxPixelSize` on its long edge, in its own
    /// colour space when an 8-bit context takes it (else Display P3).
    static func downscale(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        var space = image.colorSpace ?? p3
        if space.model != .rgb || CGColorSpaceUsesITUR_2100TF(space) || CGColorSpaceUsesExtendedRange(space) { space = p3 }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Carries a finished CGImage across an `await`.
nonisolated struct CGImageBox: @unchecked Sendable {
    let image: CGImage
}

/// A flag a long job checks between steps; set from any thread.
nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Draws pages. The context's user space is the page in layout units with
/// y growing upwards from the bottom-left corner, as Core Graphics has it;
/// callers set the transform (a printer's flipped view, a PDF's points).
nonisolated enum LayoutRenderer {
    /// A cell with its picture decoded, ready to draw.
    struct PreparedCell: @unchecked Sendable {
        var cell: LayoutCell
        var placement: ImagePlacement
        var image: CGImage?
        var caption: [String]
    }

    /// Decodes what one cell needs. `pixelsPerUnit` turns layout units into
    /// device pixels (a printer's dots per point, 1 for a pixel page, less
    /// than 1 for a preview); the decode is capped at `maxPixelSize`.
    static func prepare(_ item: LayoutItem, cell: LayoutCell, layout: PageLayout, style: LayoutPageStyle,
                        pixelsPerUnit: Double, maxPixelSize: Int, provider: LayoutImageProvider) -> PreparedCell {
        let info = provider.info(for: item, needsDate: style.caption == .nameAndDate)
        let size = info?.pixelSize ?? cell.imageArea.size
        let placement = layout.placement(for: size, in: cell.imageArea)
        let needed = min(max(placement.pixelsNeeded(pixelsPerUnit: pixelsPerUnit), 16), maxPixelSize)
        let image = placement.drawRect.isEmpty ? nil : provider.image(for: item, maxPixelSize: needed)
        let caption = style.caption.lines(name: item.name, pixelSize: info?.pixelSize,
                                          date: info?.dateTaken ?? item.modified)
        return PreparedCell(cell: cell, placement: placement, image: image, caption: caption)
    }

    /// Background, header and footer.
    static func drawChrome(layout: PageLayout, style: LayoutPageStyle, page: Int, pageCount: Int, in context: CGContext) {
        let height = layout.pageSize.height
        if let background = style.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(origin: .zero, size: layout.pageSize))
        }
        let color = style.textColor.cgColor
        if let header = style.header, !header.isEmpty, let rect = layout.headerRect {
            drawLine(header, font: font(size: style.headerFontSize, bold: true), color: color,
                     in: rect, pageHeight: height, context: context)
        }
        if style.showsPageNumbers, let rect = layout.footerRect {
            drawLine("Page \(page + 1) of \(max(pageCount, 1))", font: font(size: style.captionFontSize, bold: false),
                     color: color, in: rect, pageHeight: height, context: context)
        }
    }

    static func draw(_ prepared: PreparedCell, layout: PageLayout, style: LayoutPageStyle, in context: CGContext) {
        let height = layout.pageSize.height
        if let image = prepared.image {
            drawImage(image, placement: prepared.placement, pageHeight: height, in: context)
        } else if !prepared.placement.visibleRect.isEmpty {
            // A picture that couldn't be decoded leaves a quiet grey box, so
            // the grid still reads and the caption still names the file.
            context.setFillColor(CGColor(gray: 0.5, alpha: 0.15))
            context.fill(PageLayout.flipped(prepared.cell.imageArea, pageHeight: height))
        }
        guard let rect = prepared.cell.captionRect, !prepared.caption.isEmpty else { return }
        let size = style.captionFontSize
        let color = style.textColor.cgColor
        let top = rect.minY + size * 0.5
        for (number, line) in prepared.caption.enumerated() where !line.isEmpty {
            let lineRect = CGRect(x: rect.minX, y: top + Double(number) * size * 1.25, width: rect.width, height: size * 1.25)
            let lineColor = number == 0 ? color : color.copy(alpha: 0.65) ?? color
            drawLine(line, font: font(size: number == 0 ? size : size * 0.9, bold: false), color: lineColor,
                     in: lineRect, pageHeight: height, context: context)
        }
    }

    /// Draws a whole page synchronously, decoding four cells at a time: the
    /// print view's path, and the contact sheet's on its worker thread.
    /// Stops early (leaving the page unfinished) once `cancel` is set.
    /// `embed`, when given, turns each decoded picture into the image
    /// drawn, on the decoding threads (a PDF stores them as JPEG).
    static func drawPage(_ page: Int, items: [LayoutItem], layout: PageLayout, style: LayoutPageStyle,
                         pixelsPerUnit: Double, maxPixelSize: Int, provider: LayoutImageProvider,
                         cancel: CancellationFlag? = nil, embed: (@Sendable (CGImage) -> CGImage)? = nil,
                         in context: CGContext) {
        let pageCount = layout.pageCount(forImageCount: items.count)
        drawChrome(layout: layout, style: style, page: page, pageCount: pageCount, in: context)
        let cells = layout.cells(onPage: page, imageCount: items.count)
        var start = 0
        while start < cells.count, cancel?.isCancelled != true {
            let batch = Array(cells[start..<min(start + 4, cells.count)])
            let results = PreparedBox(count: batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                let cell = batch[i]
                var prepared = prepare(items[cell.index], cell: cell, layout: layout, style: style,
                                       pixelsPerUnit: pixelsPerUnit, maxPixelSize: maxPixelSize, provider: provider)
                if let embed, let image = prepared.image { prepared.image = embed(image) }
                results.set(i, prepared)
            }
            for prepared in results.values { draw(prepared, layout: layout, style: style, in: context) }
            start += batch.count
        }
    }

    // MARK: Primitives

    /// `placement` is in layout coordinates (top-left origin).
    static func drawImage(_ image: CGImage, placement: ImagePlacement, pageHeight: Double, in context: CGContext) {
        let visible = PageLayout.flipped(placement.visibleRect, pageHeight: pageHeight)
        let rect = PageLayout.flipped(placement.drawRect, pageHeight: pageHeight)
        context.saveGState()
        context.clip(to: visible)
        context.interpolationQuality = .high
        if placement.isRotated {
            // A quarter turn clockwise about the rectangle's centre: the
            // picture's top ends up facing right.
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -.pi / 2)
            context.draw(image, in: CGRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width))
        } else {
            context.draw(image, in: rect)
        }
        context.restoreGState()
    }

    static func font(size: Double, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, max(size, 1), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, max(size, 1), nil)
    }

    /// One line of text centred in `rect` (layout coordinates), shortened in
    /// the middle with an ellipsis when too wide, as Finder shortens names.
    static func drawLine(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, pageHeight: Double,
                         context: CGContext) {
        guard rect.width > 1, rect.height > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(full, rect.width, .middle, token) ?? token
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let flipped = PageLayout.flipped(rect, pageHeight: pageHeight)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: flipped.midX - width / 2,
                                       y: flipped.minY + (flipped.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Results written by `concurrentPerform` workers, each to its own slot.
nonisolated private final class PreparedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [LayoutRenderer.PreparedCell?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: LayoutRenderer.PreparedCell) { lock.withLock { slots[index] = value } }
    var values: [LayoutRenderer.PreparedCell] { lock.withLock { slots.compactMap { $0 } } }
}
