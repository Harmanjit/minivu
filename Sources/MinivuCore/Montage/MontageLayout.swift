import CoreGraphics
import Foundation

/// How a montage wallpaper arranges its photos.
public enum MontageStyle: String, CaseIterable, Codable, Sendable {
    /// Uniform cells in rows and columns; each photo fills its cell and is
    /// cropped to it.
    case grid
    /// Justified rows: every photo keeps its shape, and each row is scaled
    /// so it spans the full width, as a photo site's gallery does.
    case mosaic
    /// Prints tossed on a table: tilted, with white borders and soft
    /// shadows, overlapping a little.
    case scattered

    public var title: String {
        switch self {
        case .grid: "Grid"
        case .mosaic: "Mosaic"
        case .scattered: "Scattered"
        }
    }
}

/// One photo placed on a montage.
public struct MontageTile: Equatable, Sendable {
    /// Index of the photo in the list the layout was made for.
    public var image: Int
    /// The photo's rectangle before rotation, in canvas pixels with the
    /// origin at the top left and y growing downwards (the way a screen is
    /// read). For a scattered photo it includes the white border.
    public var frame: CGRect
    /// Clockwise turn about the frame's centre, in radians. Zero except in
    /// the scattered style.
    public var rotation: Double
    /// Width of the white border inside `frame`, in pixels. Zero except in
    /// the scattered style.
    public var border: Double

    public init(image: Int, frame: CGRect, rotation: Double = 0, border: Double = 0) {
        self.image = image
        self.frame = frame
        self.rotation = rotation
        self.border = border
    }

    /// Where the picture itself goes: the frame without its border.
    public var pictureFrame: CGRect { frame.insetBy(dx: border, dy: border) }

    /// The axis-aligned box the turned frame covers.
    public var boundingBox: CGRect {
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        let width = frame.width * c + frame.height * s
        let height = frame.width * s + frame.height * c
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }
}

/// Places photos on a canvas for a montage wallpaper. Pure geometry: no
/// pixels, no files, so each style is tested exactly.
///
/// Every layout keeps `spacing` pixels between photos and around the edge
/// of the canvas, and takes each photo's aspect ratio (width over height,
/// as oriented) so the photos can be decoded at just the size they cover.
public enum MontageLayout {
    /// The most photos one montage uses. A wallpaper of more is a texture,
    /// not photos, and decoding them would take a while for nothing.
    public static let maximumImages = 200

    /// The largest tilt of a scattered photo either way (12°).
    public static let maximumTilt = 12 * Double.pi / 180

    public static func layout(_ style: MontageStyle, aspectRatios: [Double], canvas: CGSize, spacing: Double,
                              seed: UInt64) -> [MontageTile] {
        switch style {
        case .grid: grid(aspectRatios: aspectRatios, canvas: canvas, spacing: spacing)
        case .mosaic: mosaic(aspectRatios: aspectRatios, canvas: canvas, spacing: spacing)
        case .scattered: scattered(aspectRatios: aspectRatios, canvas: canvas, spacing: spacing, seed: seed)
        }
    }

    // MARK: - Grid

    /// Columns and rows for `count` cells on `canvas`, chosen so the cells'
    /// shape is closest to `cellAspect` (the photos' typical shape, so they
    /// lose little to cropping), with as few cells left over as possible.
    public static func gridShape(count: Int, canvas: CGSize, spacing: Double, cellAspect: Double)
        -> (columns: Int, rows: Int) {
        guard count > 0, canvas.width > 0, canvas.height > 0 else { return (0, 0) }
        let target = sanitized(cellAspect)
        var best = (columns: count, rows: 1)
        var bestCost = Double.infinity
        for rows in 1...count {
            let columns = (count + rows - 1) / rows
            // Every row but the last must be full, or a smaller grid fits.
            guard (rows - 1) * columns < count else { continue }
            let cellWidth = (canvas.width - Double(columns + 1) * spacing) / Double(columns)
            let cellHeight = (canvas.height - Double(rows + 1) * spacing) / Double(rows)
            guard cellWidth > 0, cellHeight > 0 else { continue }
            let shape = abs(log((cellWidth / cellHeight) / target))
            let unused = Double(columns * rows - count) / Double(count)
            let cost = shape + unused
            if cost < bestCost {
                bestCost = cost
                best = (columns, rows)
            }
        }
        return best
    }

    /// Uniform cells. Cells left over after the last photo repeat the photos
    /// from the start, since a wallpaper with holes looks unfinished.
    public static func grid(aspectRatios: [Double], canvas: CGSize, spacing: Double) -> [MontageTile] {
        let count = aspectRatios.count
        let (columns, rows) = gridShape(count: count, canvas: canvas, spacing: spacing,
                                        cellAspect: median(aspectRatios))
        guard columns > 0, rows > 0 else { return [] }
        let cellWidth = (canvas.width - Double(columns + 1) * spacing) / Double(columns)
        let cellHeight = (canvas.height - Double(rows + 1) * spacing) / Double(rows)
        var tiles: [MontageTile] = []
        tiles.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let frame = CGRect(x: spacing + Double(column) * (cellWidth + spacing),
                                   y: spacing + Double(row) * (cellHeight + spacing),
                                   width: cellWidth, height: cellHeight)
                tiles.append(MontageTile(image: tiles.count % count, frame: frame))
            }
        }
        return tiles
    }

    // MARK: - Mosaic

    /// Justified rows. Each row is scaled so its photos, at their own
    /// shapes, span exactly the width between the margins; the number of
    /// rows is the one whose total height comes closest to the canvas.
    ///
    /// Those rows rarely add up to the canvas's height exactly (a few
    /// percent over or under), and a wallpaper with bands of background at
    /// the top and bottom looks unfinished. So every row's height is then
    /// scaled by one factor that makes the block fill the height between the
    /// margins exactly. Widths don't change, so each cell is a little taller
    /// or shorter than its photo and the photo fills it, cropped (as grid
    /// cells are) by the same few percent in every cell.
    ///
    /// A few wide photos can't reach the bottom of a screen at any row count
    /// (a row of one 3:2 photo is already two thirds of a 16:10 screen's
    /// height), so when the rows fall more than a tenth short the photos
    /// repeat from the first, up to once each, as the grid's leftover cells
    /// do, until the rows fill the height.
    ///
    /// Rows are found greedily for each candidate row height (a photo joins
    /// a row while that brings the row's width closer to the target), which
    /// is O(n²) over all candidates, a few milliseconds for 200 photos.
    public static func mosaic(aspectRatios: [Double], canvas: CGSize, spacing: Double) -> [MontageTile] {
        let photos = aspectRatios.map(sanitized)
        let count = photos.count
        let width = canvas.width - 2 * spacing
        guard count > 0, width > 0, canvas.height > 0 else { return [] }

        var aspects = photos
        var best = justifiedRows(aspects, canvas: canvas, width: width, spacing: spacing)
        if best.total < canvas.height * 0.9 {
            var extended = photos
            for repeated in 0..<count {
                extended.append(photos[repeated])
                let candidate = justifiedRows(extended, canvas: canvas, width: width, spacing: spacing)
                if abs(candidate.total - canvas.height) < abs(best.total - canvas.height) {
                    best = candidate
                    aspects = extended
                }
                if abs(best.total - canvas.height) < canvas.height * 0.02 { break }
            }
        }

        // Each row's height at which its photos keep their shapes.
        let natural = best.rows.map { rowHeight(aspects[$0], width: width, spacing: spacing) }
        // Fill the height exactly. Only when there is height to fill: with
        // spacing so wide that the gaps alone take the canvas, the rows stay
        // as they are, centred.
        let available = canvas.height - Double(best.rows.count + 1) * spacing
        let naturalTotal = natural.reduce(0, +)
        let fills = available > 0 && naturalTotal > 0
        let scale = fills ? available / naturalTotal : 1
        var y = fills ? spacing : (canvas.height - best.total) / 2 + spacing
        var tiles: [MontageTile] = []
        tiles.reserveCapacity(aspects.count)
        for (row, rowNatural) in zip(best.rows, natural) {
            let height = rowNatural * scale
            var x = spacing
            for index in row {
                // Widths come from the natural height, so the row spans the
                // margins; the last photo takes what is left, so rounding
                // never leaves the row a hair short.
                let photoWidth = index == row.upperBound - 1 ? canvas.width - spacing - x : aspects[index] * rowNatural
                tiles.append(MontageTile(image: index % count,
                                         frame: CGRect(x: x, y: y, width: photoWidth, height: height)))
                x += photoWidth + spacing
            }
            y += height + spacing
        }
        return tiles
    }

    /// The rows of `aspects` whose total height (spacing included) comes
    /// closest to the canvas's.
    static func justifiedRows(_ aspects: [Double], canvas: CGSize, width: Double, spacing: Double)
        -> (rows: [Range<Int>], total: Double) {
        let totalHeight = { (rows: [Range<Int>]) in
            rows.reduce(spacing) { $0 + rowHeight(aspects[$1], width: width, spacing: spacing) + spacing }
        }
        var best: (rows: [Range<Int>], total: Double) = ([0..<aspects.count], totalHeight([0..<aspects.count]))
        for rowCount in 1...aspects.count {
            let targetHeight = (canvas.height - Double(rowCount + 1) * spacing) / Double(rowCount)
            guard targetHeight > 0 else { break }
            let rows = partition(aspects, rowHeight: targetHeight, width: width, spacing: spacing)
            let total = totalHeight(rows)
            if abs(total - canvas.height) < abs(best.total - canvas.height) { best = (rows, total) }
        }
        return best
    }

    /// The height at which photos of these shapes, with spacing between
    /// them, fill `width`.
    static func rowHeight(_ aspects: ArraySlice<Double>, width: Double, spacing: Double) -> Double {
        let gaps = Double(max(aspects.count - 1, 0)) * spacing
        return max(width - gaps, 1) / aspects.reduce(0, +)
    }

    /// Greedy rows for one target height. A last row much taller than the
    /// target (a lone photo stretched across the width) joins the row above.
    static func partition(_ aspects: [Double], rowHeight target: Double, width: Double, spacing: Double) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var sum = 0.0
        for index in aspects.indices {
            let without = sum * target + Double(max(index - start - 1, 0)) * spacing
            let with = (sum + aspects[index]) * target + Double(index - start) * spacing
            if index > start, with > width, abs(with - width) > abs(without - width) {
                rows.append(start..<index)
                start = index
                sum = 0
            }
            sum += aspects[index]
        }
        rows.append(start..<aspects.count)
        if rows.count > 1, let last = rows.last,
           rowHeight(aspects[last], width: width, spacing: spacing) > 1.5 * target {
            rows.removeLast()
            let previous = rows.removeLast()
            rows.append(previous.lowerBound..<last.upperBound)
        }
        return rows
    }

    // MARK: - Scattered

    /// Tilted prints on a jittered grid: each photo sits near the centre of
    /// its own cell (so the canvas is covered evenly), a little larger than
    /// the cell (so neighbours overlap), turned up to 12° either way, and
    /// kept wholly inside the margins. The cells, jitter, tilts and drawing
    /// order all come from `seed`: the same seed gives the same wallpaper,
    /// and Shuffle simply picks another.
    public static func scattered(aspectRatios: [Double], canvas: CGSize, spacing: Double,
                                 seed: UInt64) -> [MontageTile] {
        let aspects = aspectRatios.map(sanitized)
        let count = aspects.count
        // Checked before making the rectangle: CGRect reports a negative
        // width as positive.
        guard count > 0, canvas.width > 2 * spacing, canvas.height > 2 * spacing else { return [] }
        let inner = CGRect(x: spacing, y: spacing, width: canvas.width - 2 * spacing, height: canvas.height - 2 * spacing)
        var random = SplitMix64(seed: seed)
        let rows = gridShape(count: count, canvas: canvas, spacing: 0, cellAspect: median(aspects)).rows
        guard rows > 0 else { return [] }
        // Every row is filled edge to edge: the photos are shared out over
        // the rows (a row takes one more where they don't divide evenly), so
        // no cell is left empty and no corner shows bare background.
        let perRow = rowCounts(count: count, rows: rows, random: &random)
        var cells: [(row: Int, column: Int, columns: Int)] = []
        for (row, columnsInRow) in perRow.enumerated() {
            for column in 0..<columnsInRow { cells.append((row, column, columnsInRow)) }
        }
        cells = random.shuffled(cells)
        let cellHeight = inner.height / Double(rows)
        let overlap = count == 1 ? 0.8 : 1.3

        var tiles: [MontageTile] = []
        tiles.reserveCapacity(count)
        for index in 0..<count {
            let (row, column, columnsInRow) = cells[index]
            let cellWidth = inner.width / Double(columnsInRow)
            let aspect = aspects[index]
            // The print's longer side is set from the cell; the border is a
            // fixed share of its shorter side, as on a real print.
            let boxWidth = cellWidth * overlap, boxHeight = cellHeight * overlap
            let border = max(2, 0.04 * min(boxWidth, boxHeight))
            let pictureWidth = min(boxWidth - 2 * border, (boxHeight - 2 * border) * aspect)
            guard pictureWidth > 0 else { continue }
            let pictureHeight = pictureWidth / aspect
            var width = pictureWidth + 2 * border
            var height = pictureHeight + 2 * border
            let rotation = (random.nextUnit() * 2 - 1) * maximumTilt
            // A print too big to fit the margins once turned is shrunk.
            let c = abs(cos(rotation)), s = abs(sin(rotation))
            let fit = min(1, inner.width / (width * c + height * s), inner.height / (width * s + height * c))
            width *= fit
            height *= fit
            let halfX = (width * c + height * s) / 2, halfY = (width * s + height * c) / 2
            var centreX = inner.minX + (Double(column) + 0.5) * cellWidth + (random.nextUnit() - 0.5) * 0.4 * cellWidth
            var centreY = inner.minY + (Double(row) + 0.5) * cellHeight + (random.nextUnit() - 0.5) * 0.4 * cellHeight
            centreX = min(max(centreX, inner.minX + halfX), inner.maxX - halfX)
            centreY = min(max(centreY, inner.minY + halfY), inner.maxY - halfY)
            tiles.append(MontageTile(image: index,
                                     frame: CGRect(x: centreX - width / 2, y: centreY - height / 2,
                                                   width: width, height: height),
                                     rotation: rotation, border: border * fit))
        }
        // Drawn in a random order, so no corner is always on top.
        return random.shuffled(tiles)
    }

    /// Photos per row for the scattered style: `count` shared over `rows`,
    /// the rows that take one extra chosen at random.
    static func rowCounts(count: Int, rows: Int, random: inout SplitMix64) -> [Int] {
        guard rows > 0 else { return [] }
        var counts = Array(repeating: count / rows, count: rows)
        for row in random.shuffled(Array(0..<rows)).prefix(count % rows) { counts[row] += 1 }
        return counts
    }

    // MARK: - Helpers

    /// The decode size each photo needs: the long edge, in pixels, at which
    /// it covers the largest picture frame it is given (grid cells crop, so
    /// the photo must cover the cell in both directions).
    public static func neededLongEdges(_ tiles: [MontageTile], aspectRatios: [Double]) -> [Int: Int] {
        var needed: [Int: Int] = [:]
        for tile in tiles where aspectRatios.indices.contains(tile.image) {
            let aspect = sanitized(aspectRatios[tile.image])
            let frame = tile.pictureFrame
            guard frame.width > 0, frame.height > 0 else { continue }
            // Scale that makes a photo of this shape cover the frame.
            let coverHeight = max(frame.height, frame.width / aspect)
            let longEdge = Int((max(coverHeight * aspect, coverHeight)).rounded(.up))
            needed[tile.image] = max(needed[tile.image] ?? 0, longEdge)
        }
        return needed
    }

    /// Where a photo of `aspect` is drawn so it covers `frame`, centred, with
    /// the overflow cropped by the frame.
    public static func aspectFill(_ aspect: Double, in frame: CGRect) -> CGRect {
        let aspect = sanitized(aspect)
        var width = frame.width, height = frame.width / aspect
        if height < frame.height {
            height = frame.height
            width = height * aspect
        }
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// A usable aspect ratio: an unreadable photo (0, NaN) counts as 3:2.
    static func sanitized(_ aspect: Double) -> Double {
        aspect.isFinite && aspect > 0 ? min(max(aspect, 0.05), 20) : 1.5
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 1.5 }
        let sorted = values.map(sanitized).sorted()
        return sorted[sorted.count / 2]
    }
}

/// A small, fast, seedable random number generator (Vigna's SplitMix64),
/// so a scattered montage is the same on every run for the same seed.
/// `SystemRandomNumberGenerator` can't be seeded.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Fisher–Yates, driven only by this generator (the standard library's
    /// `shuffled(using:)` may change its algorithm between releases).
    mutating func shuffled<T>(_ values: [T]) -> [T] {
        var result = values
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
    }
}
