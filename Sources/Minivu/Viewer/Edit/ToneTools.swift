import Foundation
import CoreGraphics
import Observation
import MinivuCore
import MinivuRender

/// The channel a curves or levels editor shows.
nonisolated enum ToneChannel: Int, CaseIterable, Identifiable, Sendable {
    case rgb, red, green, blue

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

// MARK: - Curves

/// Editing a curve's control points, as plain functions of the point list.
///
/// Points stay sorted by x. The two end points can move but never be
/// deleted, so a curve always spans its whole input range and dragging the
/// last interior point away still leaves a line.
nonisolated enum CurveEditing {
    /// Neighbouring points keep at least this much x apart, so one can't be
    /// dragged over another (which would silently replace it).
    static let minimumGap = 0.01
    /// How far outside the square (in unit coordinates) a point must be
    /// dragged to be removed.
    static let removalDistance = 0.08

    /// The point within `tolerance` of `location`, nearest first.
    static func hitIndex(_ points: [CurvePoint], at location: CurvePoint, tolerance: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, p) in points.enumerated() {
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (index, d) }
        }
        return best?.index
    }

    /// Adds a point, clamped to the square, between its neighbours. Returns
    /// nil (and changes nothing) when it would sit too close to one.
    static func insert(_ point: CurvePoint, into points: inout [CurvePoint]) -> Int? {
        let p = CurvePoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        let index = points.firstIndex { $0.x > p.x } ?? points.count
        if index > 0, p.x - points[index - 1].x < minimumGap { return nil }
        if index < points.count, points[index].x - p.x < minimumGap { return nil }
        points.insert(p, at: index)
        return index
    }

    /// Moves a point, its x kept between its neighbours' and y in 0...1.
    static func move(_ index: Int, to point: CurvePoint, in points: inout [CurvePoint]) {
        guard points.indices.contains(index) else { return }
        let low = index > 0 ? points[index - 1].x + minimumGap : 0
        let high = index < points.count - 1 ? points[index + 1].x - minimumGap : 1
        let x = low <= high ? min(max(point.x, low), high) : points[index].x
        points[index] = CurvePoint(x: x, y: min(max(point.y, 0), 1))
    }

    static func isEndpoint(_ index: Int, in points: [CurvePoint]) -> Bool {
        index == 0 || index == points.count - 1
    }

    /// Removes an interior point; end points stay.
    @discardableResult
    static func remove(_ index: Int, from points: inout [CurvePoint]) -> Bool {
        guard points.indices.contains(index), !isEndpoint(index, in: points) else { return false }
        points.remove(at: index)
        return true
    }

    /// Whether a drag has taken a point far enough out of the square to
    /// remove it when released.
    static func isDraggedOut(_ location: CurvePoint) -> Bool {
        location.x < -removalDistance || location.x > 1 + removalDistance
            || location.y < -removalDistance || location.y > 1 + removalDistance
    }
}

extension ToneCurves {
    subscript(channel: ToneChannel) -> [CurvePoint] {
        get {
            switch channel {
            case .rgb: master
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// An S shape on the master curve: darker shadows, brighter highlights.
    static let sCurve = ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.17),
                                            CurvePoint(x: 0.75, y: 0.83), CurvePoint(x: 1, y: 1)])
}

/// The Curves inspector's state: four curves, previewed as one operation.
@Observable final class CurvesToolState: EditToolState {
    var channel: ToneChannel = .rgb
    private(set) var curves = ToneCurves.identity
    /// The point being dragged, drawn highlighted.
    var selectedIndex: Int?
    /// Luminance and channel histograms of the image, once computed.
    var histogram: ImageHistogram?

    @ObservationIgnored private let document: EditDocument

    init(document: EditDocument) {
        self.document = document
    }

    var title: String { "Curves" }
    var hasPendingChanges: Bool { document.preview != nil }

    var points: [CurvePoint] { curves[channel] }

    func setCurves(_ curves: ToneCurves) {
        guard curves != self.curves else { return }
        self.curves = curves
        document.preview = curves.isIdentity ? nil : .curves(curves)
    }

    /// Changes the shown channel's points.
    func edit(_ body: (inout [CurvePoint]) -> Void) {
        var copy = curves
        body(&copy[channel])
        setCurves(copy)
    }

    func apply() {
        document.apply(.curves(curves))
    }

    func cancel() {
        document.preview = nil
    }

    /// All four channels back to straight lines.
    func reset() {
        selectedIndex = nil
        setCurves(.identity)
    }
}

// MARK: - Levels

/// Levels arithmetic the editor's handles need.
nonisolated enum LevelsMath {
    /// Input black and white never meet.
    static let minimumSpan = 2.0 / 255
    static let gammaRange = 0.1...9.99

    /// Where the midtone handle sits: the input that maps to half way, as
    /// in Photoshop. A brightening gamma above 1 moves it towards black.
    static func gammaPosition(_ channel: LevelsChannel) -> Double {
        channel.inputBlack + (channel.inputWhite - channel.inputBlack) * pow(0.5, channel.gamma)
    }

    /// The gamma that puts the midtone handle at `position`.
    static func gamma(forPosition position: Double, in channel: LevelsChannel) -> Double {
        let span = channel.inputWhite - channel.inputBlack
        guard span > 0 else { return 1 }
        let t = min(max((position - channel.inputBlack) / span, 0.001), 0.999)
        return clampGamma(Foundation.log(t) / Foundation.log(0.5))
    }

    static func clampGamma(_ gamma: Double) -> Double {
        guard gamma.isFinite else { return 1 }
        return min(max(gamma, gammaRange.lowerBound), gammaRange.upperBound)
    }

    static func setInputBlack(_ value: Double, in channel: inout LevelsChannel) {
        channel.inputBlack = min(max(value, 0), channel.inputWhite - minimumSpan)
    }

    static func setInputWhite(_ value: Double, in channel: inout LevelsChannel) {
        channel.inputWhite = max(min(value, 1), channel.inputBlack + minimumSpan)
    }

    /// Output levels may cross (white below black inverts), as in every
    /// levels dialog.
    static func setOutput(black: Double? = nil, white: Double? = nil, in channel: inout LevelsChannel) {
        if let black { channel.outputBlack = min(max(black, 0), 1) }
        if let white { channel.outputWhite = min(max(white, 0), 1) }
    }
}

extension Levels {
    subscript(channel: ToneChannel) -> LevelsChannel {
        get {
            switch channel {
            case .rgb: master
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}

/// The Levels inspector's state.
@Observable final class LevelsToolState: EditToolState {
    var channel: ToneChannel = .rgb
    private(set) var levels = Levels.identity
    var histogram: ImageHistogram?

    @ObservationIgnored private let document: EditDocument

    init(document: EditDocument) {
        self.document = document
    }

    var title: String { "Levels" }
    var hasPendingChanges: Bool { document.preview != nil }

    var current: LevelsChannel { levels[channel] }

    func edit(_ body: (inout LevelsChannel) -> Void) {
        var copy = levels
        body(&copy[channel])
        guard copy != levels else { return }
        levels = copy
        document.preview = levels.isIdentity ? nil : .levels(levels)
    }

    func apply() {
        document.apply(.levels(levels))
    }

    func cancel() {
        document.preview = nil
    }

    func reset() {
        levels = .identity
        document.preview = nil
    }
}

// MARK: - Histogram

/// 256-bin histograms of a small image, for drawing behind curves and levels.
nonisolated struct ImageHistogram: Equatable, Sendable {
    /// Each scaled so its tallest bin is 1.
    var luminance: [Float]
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    func bins(for channel: ToneChannel) -> [Float] {
        switch channel {
        case .rgb: luminance
        case .red: red
        case .green: green
        case .blue: blue
        }
    }

    /// Counts the pixels of `image` drawn into 8-bit sRGB, at most 256 px on
    /// its long edge (a thumbnail is plenty for a shape drawn 256 pt wide).
    /// The tallest bins are clipped at a high percentile so one spike (a
    /// white sky, black borders) doesn't flatten the rest.
    static func compute(from image: CGImage) -> ImageHistogram? {
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        for i in 0..<(width * height) {
            let r = Int(bytes[i * 4]), g = Int(bytes[i * 4 + 1]), b = Int(bytes[i * 4 + 2])
            counts[1][r] += 1
            counts[2][g] += 1
            counts[3][b] += 1
            // Rec. 709 weights on the encoded values: what a levels dialog shows.
            counts[0][min(255, (r * 2126 + g * 7152 + b * 722 + 5000) / 10000)] += 1
        }
        let normalized = counts.map(Self.normalize)
        return ImageHistogram(luminance: normalized[0], red: normalized[1], green: normalized[2], blue: normalized[3])
    }

    static func normalize(_ counts: [Int]) -> [Float] {
        let sorted = counts.sorted()
        // The 99th percentile bin, at least 1, is full height.
        let top = max(1, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))])
        return counts.map { min(1, Float($0) / Float(top)) }
    }
}
