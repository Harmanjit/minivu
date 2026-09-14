import Foundation
import CoreGraphics
import MinivuCore
import MinivuRender

/// What the compare window shows: two to four images side by side, which
/// pane has the keyboard, and the folder they came from. Plain values, so
/// culling decisions (which image replaces which, what happens after a
/// delete) are tested without windows.
nonisolated struct CompareModel: Equatable, Sendable {
    static let paneRange = 2...4

    /// How four panes are arranged; two and three are always one row.
    enum Arrangement: String, Sendable {
        case row, grid
    }

    /// The images on screen, one per pane, left to right then top to bottom.
    private(set) var panes: [FolderEntry]
    /// The folder's images in the browser's order and filter: where a pane's
    /// next and previous images come from.
    private(set) var allImages: [FolderEntry]
    /// The pane keys, ratings and ←/→ act on.
    private(set) var focus = 0
    var arrangement: Arrangement = .grid
    var wrapAround = false

    /// At most four of `entries` (folders dropped); nil for fewer than two.
    init?(entries: [FolderEntry], allImages: [FolderEntry]) {
        var seen: Set<URL> = []
        let images = entries.filter { !$0.isDirectory && seen.insert($0.url).inserted }
        guard images.count >= Self.paneRange.lowerBound else { return nil }
        panes = Array(images.prefix(Self.paneRange.upperBound))
        self.allImages = allImages.filter { !$0.isDirectory }
    }

    var focusedEntry: FolderEntry? { panes.indices.contains(focus) ? panes[focus] : nil }

    // MARK: - Focus

    /// Focuses pane `index`; false if there is no such pane.
    @discardableResult
    mutating func setFocus(_ index: Int) -> Bool {
        guard panes.indices.contains(index) else { return false }
        focus = index
        return true
    }

    /// Tab and Shift-Tab: the next or previous pane, round and round.
    mutating func cycleFocus(backward: Bool = false) {
        guard !panes.isEmpty else { return }
        focus = (focus + (backward ? panes.count - 1 : 1)) % panes.count
    }

    // MARK: - Replacing

    /// The image `step` places from pane `index`'s image in folder order
    /// (+1 next, -1 previous), skipping images already in a pane. Wraps
    /// round the folder when `wrapAround` is set; nil when there is none.
    func replacement(forPane index: Int, step: Int) -> FolderEntry? {
        guard panes.indices.contains(index), step != 0, !allImages.isEmpty else { return nil }
        let shown = Set(panes.map(\.url))
        let count = allImages.count
        // An image the folder no longer lists (filtered out) starts from the end it is moving away from.
        let start = allImages.firstIndex { $0.url == panes[index].url } ?? (step > 0 ? -1 : count)
        let direction = step > 0 ? 1 : -1
        for k in 1...count {
            var j = start + direction * k
            if wrapAround {
                j = ((j % count) + count) % count
            } else if !(0..<count).contains(j) {
                return nil
            }
            if !shown.contains(allImages[j].url) { return allImages[j] }
        }
        return nil
    }

    /// Replaces pane `index`'s image with `replacement(forPane:step:)`.
    @discardableResult
    mutating func replace(pane index: Int, step: Int) -> Bool {
        guard let next = replacement(forPane: index, step: step) else { return false }
        panes[index] = next
        return true
    }

    // MARK: - Removing

    enum Removal: Equatable, Sendable {
        /// The file wasn't in a pane (only the folder list changed).
        case notShown
        /// The pane now shows another image.
        case replaced(pane: Int)
        /// No image was left to fill the pane, so it went.
        case removedPane(Int)
    }

    /// A file went to the Trash. Its pane shows the next image in the folder
    /// not already shown (or, at the end, the previous one); with none left
    /// the pane is removed and the focus moves to a neighbour.
    mutating func remove(_ url: URL) -> Removal {
        let position = allImages.firstIndex { $0.url == url }
        allImages.removeAll { $0.url == url }
        guard let pane = panes.firstIndex(where: { $0.url == url }) else { return .notShown }
        let shown = Set(panes.map(\.url))
        if let position {
            // After the removal, the image that followed sits at `position`.
            let after = allImages[position...].first { !shown.contains($0.url) }
            let before = allImages[..<position].last { !shown.contains($0.url) }
            if let fill = after ?? before {
                panes[pane] = fill
                return .replaced(pane: pane)
            }
        } else if let fill = allImages.first(where: { !shown.contains($0.url) }) {
            panes[pane] = fill
            return .replaced(pane: pane)
        }
        panes.remove(at: pane)
        if focus > pane || focus >= panes.count { focus = max(focus - 1, 0) }
        return .removedPane(pane)
    }

    // MARK: - Layout

    /// Columns and rows for `count` panes.
    static func grid(count: Int, arrangement: Arrangement) -> (columns: Int, rows: Int) {
        count == 4 && arrangement == .grid ? (2, 2) : (max(count, 1), 1)
    }

    /// Pane frames in `bounds` (top-left origin), in pane order, `spacing`
    /// apart, rounded to whole points so borders stay crisp.
    static func frames(count: Int, arrangement: Arrangement, in bounds: CGRect, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let (columns, rows) = grid(count: count, arrangement: arrangement)
        let width = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<count).map { i in
            let column = i % columns, row = i / columns
            let x = (bounds.minX + CGFloat(column) * (width + spacing)).rounded()
            let y = (bounds.minY + CGFloat(row) * (height + spacing)).rounded()
            let maxX = (bounds.minX + CGFloat(column) * (width + spacing) + width).rounded()
            let maxY = (bounds.minY + CGFloat(row) * (height + spacing) + height).rounded()
            return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        }
    }
}

/// One pane's zoom and pan in terms another pane can use: zoom relative to
/// fitting the image, and the view's centre as a fraction of the image. Two
/// photos of different sizes then show the same part of the scene at the
/// same size relative to their panes, which is what comparing needs.
nonisolated struct RelativeView: Equatable, Sendable {
    /// Fitted (and following the pane as it resizes).
    var isFit: Bool
    /// Zoom divided by the fitted zoom; 1 when fitted.
    var zoomFactor: CGFloat
    /// The image point at the view's centre, 0...1 on each axis.
    var center: CGPoint

    static let fit = RelativeView(isFit: true, zoomFactor: 1, center: CGPoint(x: 0.5, y: 0.5))

    init(isFit: Bool, zoomFactor: CGFloat, center: CGPoint) {
        self.isFit = isFit
        self.zoomFactor = zoomFactor
        self.center = center
    }

    /// `enlargeSmall` is the "enlarge small images" setting, which decides
    /// what fitting means for an image smaller than its pane.
    init(transform: ViewportTransform, isFit: Bool, imageSize: CGSize, viewSize: CGSize, enlargeSmall: Bool) {
        guard !isFit, imageSize.width > 0, imageSize.height > 0 else {
            self = .fit
            return
        }
        let fitted = ViewportTransform.bestFit(imageSize: imageSize, viewSize: viewSize, enlargeSmall: enlargeSmall).zoom
        self.init(isFit: false, zoomFactor: fitted > 0 ? transform.zoom / fitted : 1,
                  center: CGPoint(x: transform.center.x / imageSize.width, y: transform.center.y / imageSize.height))
    }

    /// The same view of an image of `imageSize` in a view of `viewSize`.
    func transform(imageSize: CGSize, viewSize: CGSize, enlargeSmall: Bool) -> ViewportTransform {
        let fitted = ViewportTransform.bestFit(imageSize: imageSize, viewSize: viewSize, enlargeSmall: enlargeSmall)
        guard !isFit else { return fitted }
        return ViewportTransform(zoom: fitted.zoom * zoomFactor,
                                 center: CGPoint(x: center.x * imageSize.width, y: center.y * imageSize.height))
    }
}
