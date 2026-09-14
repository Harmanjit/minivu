import Foundation
import CoreGraphics

/// Space kept clear around a page's content, in the page's own units
/// (points for a printed page, pixels for a contact sheet).
public struct LayoutInsets: Sendable, Hashable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(all value: Double) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    public static let zero = LayoutInsets(all: 0)
}

/// How an image meets its cell: whole with space around it, or covering
/// the cell with the overflow cropped away.
public enum LayoutScaling: String, Sendable, Codable, CaseIterable {
    case fit, fill
}

/// One cell of a page: the image with `index` in the whole list goes in it.
public struct LayoutCell: Sendable, Equatable {
    public var index: Int
    /// The whole cell, caption included.
    public var frame: CGRect
    /// The part of the cell the image may use: the frame less the caption.
    public var imageArea: CGRect
    /// Below the image; nil when captions take no space.
    public var captionRect: CGRect?

    public init(index: Int, frame: CGRect, imageArea: CGRect, captionRect: CGRect?) {
        self.index = index
        self.frame = frame
        self.imageArea = imageArea
        self.captionRect = captionRect
    }
}

/// Where one image lands in its cell.
public struct ImagePlacement: Sendable, Equatable {
    /// The rectangle the whole image covers once scaled (and turned, when
    /// `isRotated`). With `.fill` it is larger than `visibleRect` and centred
    /// on it, so an equal amount is cropped from either side.
    public var drawRect: CGRect
    /// What shows: the image itself with `.fit`, the image area with `.fill`.
    public var visibleRect: CGRect
    /// The image is drawn turned a quarter clockwise, because it covers its
    /// cell better that way (see `PageLayout.autoRotate`).
    public var isRotated: Bool

    public init(drawRect: CGRect, visibleRect: CGRect, isRotated: Bool) {
        self.drawRect = drawRect
        self.visibleRect = visibleRect
        self.isRotated = isRotated
    }

    /// The pixels the image needs along its long edge to be drawn at
    /// `pixelsPerUnit` (a printer's dots per point, 1 for a pixel page).
    public func pixelsNeeded(pixelsPerUnit: Double) -> Int {
        Int((max(drawRect.width, drawRect.height) * pixelsPerUnit).rounded(.up))
    }
}

/// The geometry of a page of pictures: a grid of cells inside margins, with
/// room for captions under each image and an optional header and footer.
/// Used by Print (in points) and Contact Sheet (in pixels).
///
/// Pure values and arithmetic, so every rule (pagination, fit and fill,
/// auto-rotate, centring) is unit tested without a printer or a file.
///
/// Coordinates have their origin at the page's top-left corner with y
/// growing downwards, the order a page is read in. Core Graphics contexts
/// have y growing upwards; `flipped(_:pageHeight:)` converts a rectangle.
public struct PageLayout: Sendable, Equatable {
    public var pageSize: CGSize
    public var margins: LayoutInsets
    /// At least 1.
    public var columns: Int
    /// nil means "auto": as many rows as the images need, so they all fit
    /// on one page.
    public var rows: Int?
    /// Between cells, across and down.
    public var spacing: Double
    /// Taken from the bottom of every cell for its caption; 0 for none.
    public var captionHeight: Double
    /// A band below the top margin for a title; 0 for none.
    public var headerHeight: Double
    /// A band above the bottom margin for "Page 1 of 3"; 0 for none.
    public var footerHeight: Double
    public var scaling: LayoutScaling
    /// Turns an image 90° when that makes it cover more of its cell: a
    /// landscape photo in a tall cell prints larger on its side. The
    /// covered share of the cell is the same measure for fit (less empty
    /// space) and fill (less cropped away).
    public var autoRotate: Bool
    /// A page holding fewer images than it has cells (the last one) centres
    /// them: the used rows vertically, and a short last row horizontally.
    /// Otherwise cells fill from the top-left, as in a contact sheet.
    public var centersPartialPages: Bool

    public init(pageSize: CGSize, margins: LayoutInsets = .zero, columns: Int = 1, rows: Int? = 1,
                spacing: Double = 0, captionHeight: Double = 0, headerHeight: Double = 0, footerHeight: Double = 0,
                scaling: LayoutScaling = .fit, autoRotate: Bool = false, centersPartialPages: Bool = false) {
        self.pageSize = pageSize
        self.margins = margins
        self.columns = columns
        self.rows = rows
        self.spacing = spacing
        self.captionHeight = captionHeight
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.scaling = scaling
        self.autoRotate = autoRotate
        self.centersPartialPages = centersPartialPages
    }

    // MARK: - Images per page

    /// The images-per-page choices Print offers.
    public static let imagesPerPageChoices = [1, 2, 4, 6, 9, 12, 20, 30]

    /// Columns and rows for `count` images on a page of `pageSize`: an exact
    /// grid whose cells are closest to square, so both portrait and
    /// landscape photos use them well. On a portrait page 2 is 1×2, 6 is
    /// 2×3, 12 is 3×4, 20 is 4×5 and 30 is 5×6; a landscape page turns them.
    public static func grid(imagesPerPage count: Int, pageSize: CGSize) -> (columns: Int, rows: Int) {
        let count = max(1, count)
        let aspect = pageSize.height > 0 ? Double(pageSize.width / pageSize.height) : 1
        var best: (columns: Int, rows: Int, score: Double) = (count, 1, .infinity)
        for columns in 1...count where count % columns == 0 {
            let rows = count / columns
            let cellAspect = aspect * Double(rows) / Double(columns)
            let score = abs(log(max(cellAspect, 1e-9)))
            if score < best.score - 1e-9 { best = (columns, rows, score) }
        }
        return (best.columns, best.rows)
    }

    // MARK: - Pagination

    public func rowCount(forImageCount count: Int) -> Int {
        max(1, rows ?? (max(count, 1) + safeColumns - 1) / safeColumns)
    }

    public func cellsPerPage(forImageCount count: Int) -> Int {
        safeColumns * rowCount(forImageCount: count)
    }

    /// 0 for no images.
    public func pageCount(forImageCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        let perPage = cellsPerPage(forImageCount: count)
        return (count + perPage - 1) / perPage
    }

    /// Which images go on `page` (from 0); empty past the last page.
    public func indices(onPage page: Int, imageCount count: Int) -> Range<Int> {
        let perPage = cellsPerPage(forImageCount: count)
        let start = min(max(page, 0) * perPage, count)
        return start..<min(start + perPage, count)
    }

    // MARK: - Areas

    /// The page less its margins.
    public var printableRect: CGRect {
        CGRect(x: margins.left, y: margins.top,
               width: max(0, pageSize.width - margins.left - margins.right),
               height: max(0, pageSize.height - margins.top - margins.bottom))
    }

    /// Where the cells go: the printable rect less the header and footer.
    public var contentRect: CGRect {
        let printable = printableRect
        let header = min(headerHeight, printable.height)
        let footer = min(footerHeight, printable.height - header)
        return CGRect(x: printable.minX, y: printable.minY + header, width: printable.width,
                      height: max(0, printable.height - header - footer))
    }

    public var headerRect: CGRect? {
        guard headerHeight > 0 else { return nil }
        let printable = printableRect
        return CGRect(x: printable.minX, y: printable.minY, width: printable.width,
                      height: min(headerHeight, printable.height))
    }

    public var footerRect: CGRect? {
        guard footerHeight > 0 else { return nil }
        let content = contentRect
        let printable = printableRect
        return CGRect(x: printable.minX, y: content.maxY, width: printable.width,
                      height: max(0, printable.maxY - content.maxY))
    }

    /// Every cell is this size, whichever page it is on.
    public func cellSize(forImageCount count: Int) -> CGSize {
        let content = contentRect
        let rows = rowCount(forImageCount: count)
        let width = (content.width - spacing * Double(safeColumns - 1)) / Double(safeColumns)
        let height = (content.height - spacing * Double(rows - 1)) / Double(rows)
        return CGSize(width: max(0, width), height: max(0, height))
    }

    /// The cells holding images on `page`, in reading order.
    public func cells(onPage page: Int, imageCount count: Int) -> [LayoutCell] {
        let range = indices(onPage: page, imageCount: count)
        guard !range.isEmpty else { return [] }
        let content = contentRect
        let size = cellSize(forImageCount: count)
        let capacity = cellsPerPage(forImageCount: count)
        let onPage = range.count
        let strideX = size.width + spacing, strideY = size.height + spacing

        var offsetY = 0.0
        let usedRows = (onPage + safeColumns - 1) / safeColumns
        if centersPartialPages, onPage < capacity {
            let usedHeight = Double(usedRows) * size.height + Double(usedRows - 1) * spacing
            offsetY = max(0, (content.height - usedHeight) / 2)
        }
        let lastRowCount = onPage - (usedRows - 1) * safeColumns

        return range.enumerated().map { position, index in
            let row = position / safeColumns
            let column = position % safeColumns
            var offsetX = 0.0
            if centersPartialPages, onPage < capacity, row == usedRows - 1, lastRowCount < safeColumns {
                offsetX = Double(safeColumns - lastRowCount) * strideX / 2
            }
            let frame = CGRect(x: content.minX + offsetX + Double(column) * strideX,
                               y: content.minY + offsetY + Double(row) * strideY,
                               width: size.width, height: size.height)
            let caption = min(captionHeight, frame.height)
            let imageArea = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - caption)
            let captionRect = captionHeight > 0
                ? CGRect(x: frame.minX, y: imageArea.maxY, width: frame.width, height: caption) : nil
            return LayoutCell(index: index, frame: frame, imageArea: imageArea, captionRect: captionRect)
        }
    }

    // MARK: - Images

    /// Where an image of `imageSize` (oriented, any unit: only its shape
    /// matters) goes in `area`, centred.
    public func placement(for imageSize: CGSize, in area: CGRect) -> ImagePlacement {
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else {
            let point = CGRect(x: area.midX, y: area.midY, width: 0, height: 0)
            return ImagePlacement(drawRect: point, visibleRect: point, isRotated: false)
        }
        var size = imageSize
        let turned = CGSize(width: imageSize.height, height: imageSize.width)
        // A clear margin, so a square image (or rounding) never turns.
        let rotated = autoRotate && Self.coverage(of: turned, in: area.size) > Self.coverage(of: size, in: area.size) + 1e-6
        if rotated { size = turned }
        let scaleX = area.width / size.width, scaleY = area.height / size.height
        let scale = scaling == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let width = size.width * scale, height = size.height * scale
        let draw = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        return ImagePlacement(drawRect: draw, visibleRect: scaling == .fit ? draw : area, isRotated: rotated)
    }

    /// The share of a cell of `cell` size an image of `image` shape covers
    /// when fitted, which is also the share of the image kept when it fills
    /// the cell: the ratio of the narrower aspect to the wider.
    static func coverage(of image: CGSize, in cell: CGSize) -> Double {
        let imageAspect = image.width / image.height
        let cellAspect = cell.width / cell.height
        return min(imageAspect, cellAspect) / max(imageAspect, cellAspect)
    }

    /// `rect` in a coordinate system with y growing upwards from the
    /// page's bottom edge (Core Graphics, PDF), or back again.
    public static func flipped(_ rect: CGRect, pageHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private var safeColumns: Int { max(1, columns) }
}
