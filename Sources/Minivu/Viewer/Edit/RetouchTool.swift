import Foundation
import CoreGraphics
import Observation
import MinivuRender

/// A tool whose own steps (brush strokes, circles) Edit > Undo takes back
/// one at a time while it is open, before the viewer's undo of committed
/// edits, which would close the tool and drop everything in it.
protocol EditToolSteps: EditToolState {
    /// The step Undo would take back ("Stroke"), or nil when there is none.
    var undoStepTitle: String? { get }
    var redoStepTitle: String? { get }
    func undoStep() -> Bool
    func redoStep() -> Bool
}

/// Where a clone or heal stroke copies from.
nonisolated enum RetouchSource: Equatable, Sendable {
    /// Nothing chosen yet: painting needs an Option-click first.
    case unset
    /// Option-clicked here (normalised); the next stroke takes its offset
    /// from its own first point.
    case pending(CGPoint)
    /// Strokes copy from this far away (normalised), wherever they start:
    /// Photoshop's "aligned" sampling.
    case aligned(CGVector)

    /// Where the source is while the brush is at `brush` (normalised).
    func sourcePoint(forBrushAt brush: CGPoint?) -> CGPoint? {
        switch self {
        case .unset: nil
        case .pending(let point): point
        case .aligned(let offset): brush.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        }
    }
}

/// The clone stamp and healing brush: brush settings, the strokes painted
/// so far and where they copy from.
///
/// Strokes preview on the document as one `.retouch` operation as each is
/// finished, so every render shows them all; Apply commits that operation
/// (one undo step for everything painted), Cancel drops it. While the tool
/// is open ⌘Z takes back the last stroke (and ⇧⌘Z brings it back), with
/// the source as it was before that stroke.
@Observable final class RetouchToolState: EditToolSteps {
    let mode: RetouchStroke.Mode
    /// The image being painted, in full-resolution pixels.
    let imageSize: CGSize

    /// Brush diameter in full-resolution pixels.
    private(set) var brushSize: Double
    /// 0...1.
    private(set) var hardness = RetouchStroke.defaultHardness
    /// 0...1.
    private(set) var opacity = 1.0
    private(set) var strokes: [RetouchStroke] = []
    private(set) var source: RetouchSource = .unset
    /// Painting was tried before a source was chosen.
    private(set) var needsSourceHint = false
    /// The stroke being dragged, not yet on the document.
    @ObservationIgnored private(set) var liveStroke: RetouchStroke?
    /// Strokes finished whose render may not be on screen yet: the overlay
    /// goes on drawing them as it drew the live stroke until one is, or a
    /// stroke would vanish at mouse-up for the 20-40 ms its render takes.
    @ObservationIgnored private var strokesAwaitingRender: [RetouchStroke] = []

    /// For the overlay, which isn't SwiftUI: strokes, the source or the
    /// brush changed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let document: EditDocument
    /// The source before each stroke, for undo.
    @ObservationIgnored private var sourcesBefore: [RetouchSource] = []
    @ObservationIgnored private var redoStack: [(stroke: RetouchStroke, sourceBefore: RetouchSource)] = []
    @ObservationIgnored private var liveSourceBefore: RetouchSource = .unset

    /// Recorded points are at most this fraction of the radius apart, under
    /// the quarter that `RetouchStroke` promises.
    static let spacing = 0.2

    init(mode: RetouchStroke.Mode, document: EditDocument, imageSize: CGSize) {
        self.mode = mode
        self.document = document
        self.imageSize = imageSize
        brushSize = Self.defaultBrushSize(for: imageSize)
    }

    var title: String { mode == .clone ? "Clone Stamp" : "Healing Brush" }
    var hasPendingChanges: Bool { !strokes.isEmpty }
    var canRedoStroke: Bool { !redoStack.isEmpty }

    // MARK: - Brush

    var shortSide: Double { max(1, Double(min(imageSize.width, imageSize.height))) }

    /// Radius as a fraction of the short side, as strokes store it.
    var radiusFraction: Double { brushSize / 2 / shortSide }

    /// 3% of the short side: a blemish on a portrait, a speck of dust at
    /// full view.
    static func defaultBrushSize(for size: CGSize) -> Double {
        max(10, (Double(min(size.width, size.height)) * 0.03).rounded())
    }

    var brushSizeRange: ClosedRange<Double> { 2...max(20, (shortSide / 2).rounded()) }

    func setBrushSize(_ size: Double) {
        guard size.isFinite else { return }
        let clamped = min(max(size.rounded(), brushSizeRange.lowerBound), brushSizeRange.upperBound)
        guard clamped != brushSize else { return }
        brushSize = clamped
        onChange?()
    }

    /// [ and ]: a fifth smaller or a quarter larger, so a few presses cover
    /// any range and one step back undoes one step forward.
    func stepBrushSize(larger: Bool) {
        let next = larger ? brushSize * 1.25 : brushSize / 1.25
        setBrushSize(larger ? max(next, brushSize + 1) : min(next, brushSize - 1))
    }

    func setHardness(_ value: Double) {
        hardness = value.isFinite ? min(max(value, 0), 1) : RetouchStroke.defaultHardness
        onChange?()
    }

    func setOpacity(_ value: Double) {
        opacity = value.isFinite ? min(max(value, 0.01), 1) : 1
        onChange?()
    }

    // MARK: - Painting

    /// Option-click: the next stroke copies from here.
    func setSource(_ point: CGPoint) {
        source = .pending(point)
        needsSourceHint = false
        onChange?()
    }

    /// Starts a stroke at `point` (normalised); false when there is nothing
    /// to copy from yet.
    @discardableResult
    func beginStroke(at point: CGPoint) -> Bool {
        let offset: CGVector
        switch source {
        case .unset:
            needsSourceHint = true
            onChange?()
            return false
        case .pending(let origin):
            offset = CGVector(dx: origin.x - point.x, dy: origin.y - point.y)
        case .aligned(let aligned):
            offset = aligned
        }
        liveSourceBefore = source
        liveStroke = RetouchStroke(mode: mode, points: [point], radius: radiusFraction, hardness: hardness,
                                   opacity: opacity, sourceOffset: offset)
        onChange?()
        return true
    }

    /// The pointer moved to `point` while painting: points along the way,
    /// no further apart than `spacing` of the radius.
    func continueStroke(to point: CGPoint) {
        guard var stroke = liveStroke, let last = stroke.points.last else { return }
        let spacing = max(0.5, Self.spacing * brushSize / 2)
        let added = Self.interpolated(from: last, to: point, spacing: spacing, imageSize: imageSize)
        guard !added.isEmpty else { return }
        stroke.points += added
        liveStroke = stroke
        onChange?()
    }

    /// The mouse went up: the stroke joins the others and the preview.
    func endStroke(at point: CGPoint? = nil) {
        guard var stroke = liveStroke else { return }
        if let point, let last = stroke.points.last, last != point {
            stroke.points += Self.interpolated(from: last, to: point, spacing: max(0.5, Self.spacing * brushSize / 2),
                                               imageSize: imageSize, includingShortLast: true)
        }
        liveStroke = nil
        if !stroke.isIdentity {
            strokes.append(stroke)
            strokesAwaitingRender.append(stroke)
            sourcesBefore.append(liveSourceBefore)
            source = .aligned(stroke.sourceOffset)
            redoStack.removeAll()
            updatePreview()
        }
        onChange?()
    }

    var undoStepTitle: String? { strokes.isEmpty ? nil : "Stroke" }
    var redoStepTitle: String? { redoStack.isEmpty ? nil : "Stroke" }
    func undoStep() -> Bool { undoStroke() }
    func redoStep() -> Bool { redoStroke() }

    /// ⌘Z while the tool is open; false when there is no stroke to take back.
    @discardableResult
    func undoStroke() -> Bool {
        guard let stroke = strokes.popLast() else { return false }
        strokesAwaitingRender.removeAll { $0 == stroke }
        let before = sourcesBefore.popLast() ?? .unset
        redoStack.append((stroke, before))
        source = before
        updatePreview()
        onChange?()
        return true
    }

    @discardableResult
    func redoStroke() -> Bool {
        guard let (stroke, before) = redoStack.popLast() else { return false }
        strokes.append(stroke)
        sourcesBefore.append(before)
        source = .aligned(stroke.sourceOffset)
        updatePreview()
        onChange?()
        return true
    }

    /// Finished strokes that no render on screen shows yet, for the overlay
    /// to draw; forgets those that one does.
    func strokesNotYetRendered() -> [RetouchStroke] {
        guard !strokesAwaitingRender.isEmpty else { return [] }
        strokesAwaitingRender = Self.unrendered(strokesAwaitingRender, shown: document.deliveredOperations)
        return strokesAwaitingRender
    }

    /// `strokes` less those in the retouch step that `operations` (what is
    /// on screen) ends with.
    nonisolated static func unrendered(_ strokes: [RetouchStroke], shown operations: [EditOperation]?) -> [RetouchStroke] {
        guard case .retouch(let shown)? = operations?.last else { return strokes }
        return strokes.filter { !shown.contains($0) }
    }

    /// Points from `last` (excluded) towards `point`, evenly spaced at most
    /// `spacing` full-resolution pixels apart, ending exactly at `point`
    /// once it is at least `spacing` away (or at all, with
    /// `includingShortLast`). Normalised in, normalised out.
    nonisolated static func interpolated(from last: CGPoint, to point: CGPoint, spacing: Double, imageSize: CGSize,
                                         includingShortLast: Bool = false) -> [CGPoint] {
        let dx = (point.x - last.x) * imageSize.width, dy = (point.y - last.y) * imageSize.height
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance.isFinite, spacing > 0, distance >= spacing || (includingShortLast && distance > 0) else {
            return []
        }
        let count = max(1, Int((distance / spacing).rounded(.up)))
        return (1...count).map { i in
            let t = Double(i) / Double(count)
            return CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t)
        }
    }

    // MARK: - EditToolState

    func apply() {
        liveStroke = nil
        strokesAwaitingRender = []
        if strokes.isEmpty {
            document.preview = nil
        } else {
            document.apply(.retouch(strokes))
        }
    }

    func cancel() {
        liveStroke = nil
        strokesAwaitingRender = []
        document.preview = nil
    }

    /// Takes back every stroke; the source goes back to where the first
    /// stroke found it.
    func reset() {
        guard !strokes.isEmpty || liveStroke != nil else { return }
        if let first = sourcesBefore.first { source = first }
        strokes = []
        sourcesBefore = []
        redoStack = []
        liveStroke = nil
        strokesAwaitingRender = []
        updatePreview()
        onChange?()
    }

    private func updatePreview() {
        document.preview = strokes.isEmpty ? nil : .retouch(strokes)
    }
}

/// The red-eye tool: circles over pupils, each with a strength.
@Observable final class RedEyeToolState: EditToolSteps {
    enum Detection: Equatable {
        case idle, running
        /// How many red eyes the last run added.
        case found(Int)
        /// Faces were looked for and no red eye was found.
        case none
        case failed
    }

    /// The image, in full-resolution pixels.
    let imageSize: CGSize
    private(set) var spots: [RedEyeSpot] = []
    var selection: Int?
    var detection: Detection = .idle

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let document: EditDocument

    init(document: EditDocument, imageSize: CGSize) {
        self.document = document
        self.imageSize = imageSize
    }

    var title: String { "Red-Eye Removal" }
    var hasPendingChanges: Bool { !spots.isEmpty }

    var shortSide: Double { max(1, Double(min(imageSize.width, imageSize.height))) }

    /// A circle's smallest radius, as a fraction of the short side: 3 pixels.
    var minimumRadius: Double { 3 / shortSide }

    func addSpot(center: CGPoint, radius: Double) {
        spots.append(RedEyeSpot(center: center, radius: max(radius, minimumRadius)))
        selection = spots.count - 1
        changed()
    }

    func moveSpot(_ index: Int, to center: CGPoint) {
        guard spots.indices.contains(index) else { return }
        spots[index].center = center
        changed()
    }

    func setStrength(_ index: Int, _ strength: Double) {
        guard spots.indices.contains(index), strength.isFinite else { return }
        spots[index].strength = min(max(strength, 0), 1)
        changed()
    }

    func removeSpot(_ index: Int) {
        guard spots.indices.contains(index) else { return }
        spots.remove(at: index)
        if let selected = selection {
            selection = selected == index ? nil : (selected > index ? selected - 1 : selected)
        }
        changed()
    }

    var undoStepTitle: String? { spots.isEmpty ? nil : "Red-Eye Circle" }
    var redoStepTitle: String? { nil }
    func undoStep() -> Bool { removeLastSpot() }
    func redoStep() -> Bool { false }

    /// ⌘Z while the tool is open.
    @discardableResult
    func removeLastSpot() -> Bool {
        guard !spots.isEmpty else { return false }
        removeSpot(spots.count - 1)
        return true
    }

    /// Adds detected spots that aren't already covered by one of the user's;
    /// returns how many were added.
    @discardableResult
    func addDetected(_ found: [RedEyeSpot]) -> Int {
        var added = 0
        for spot in found {
            let covered = spots.contains { existing in
                let dx = (existing.center.x - spot.center.x) * imageSize.width
                let dy = (existing.center.y - spot.center.y) * imageSize.height
                return (dx * dx + dy * dy).squareRoot() < max(existing.radius, spot.radius) * shortSide
            }
            guard !covered else { continue }
            spots.append(spot)
            added += 1
        }
        detection = added > 0 ? .found(added) : .none
        if added > 0 { changed() }
        return added
    }

    /// The spot whose circle contains `point` (normalised), topmost first.
    func spot(at point: CGPoint, slop: Double = 0) -> Int? {
        spots.indices.reversed().first { index in
            let spot = spots[index]
            let dx = (spot.center.x - point.x) * imageSize.width, dy = (spot.center.y - point.y) * imageSize.height
            return (dx * dx + dy * dy).squareRoot() <= spot.radius * shortSide + slop
        }
    }

    func apply() {
        if spots.isEmpty {
            document.preview = nil
        } else {
            document.apply(.redEye(spots))
        }
    }

    func cancel() {
        document.preview = nil
    }

    func reset() {
        spots = []
        selection = nil
        detection = .idle
        changed()
    }

    private func changed() {
        document.preview = spots.isEmpty ? nil : .redEye(spots)
        onChange?()
    }
}
