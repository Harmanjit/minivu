import Foundation

/// A control point of a tone curve, both coordinates 0...1.
///
/// Curves and levels work on encoded values (Display P3's sRGB-shaped
/// transfer curve), not linear light: that is the scale on which 0.5 looks
/// like a middle grey, which is what a user dragging a point expects.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The Curves dialog's four curves.
///
/// Each channel curve is applied first and the master curve to its result
/// (the order GIMP uses), so a master S-curve adds contrast on top of a
/// colour correction rather than distorting it.
public struct ToneCurves: Codable, Hashable, Sendable {
    public var master: [CurvePoint]
    public var red: [CurvePoint]
    public var green: [CurvePoint]
    public var blue: [CurvePoint]

    public static let diagonal = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    public static let identity = ToneCurves(master: diagonal, red: diagonal, green: diagonal, blue: diagonal)

    public init(master: [CurvePoint] = diagonal, red: [CurvePoint] = diagonal,
                green: [CurvePoint] = diagonal, blue: [CurvePoint] = diagonal) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Every curve has no points, or has points only on the diagonal from
    /// corner to corner, which the monotone interpolation turns into the
    /// diagonal itself. (Diagonal points that stop short of a corner clip:
    /// the curve is flat beyond its last point.)
    public var isIdentity: Bool {
        [master, red, green, blue].allSatisfy(Self.isDiagonal)
    }

    static func isDiagonal(_ points: [CurvePoint]) -> Bool {
        guard !points.isEmpty else { return true }
        let xs = points.map { min(max($0.x, 0), 1) }
        return points.allSatisfy { abs($0.x - $0.y) < 1e-9 } && xs.min() == 0 && xs.max() == 1
    }

    /// `size` evenly spaced samples of each curve over 0...1, in the order
    /// master, red, green, blue. For drawing the curves in the dialog; the
    /// renderer bakes its own combined table (`toneTable`).
    public func lookupTable(size: Int) -> [[Float]] {
        let n = max(size, 2)
        return [master, red, green, blue].map { points in
            let curve = MonotoneCurve(points)
            return (0..<n).map { Float(curve.value(at: Double($0) / Double(n - 1))) }
        }
    }

    /// One table per colour channel of master(channel(x)), what the tone
    /// kernel applies.
    func toneTable(size: Int = ToneTable.defaultSize) -> ToneTable {
        // Diagonal curves are skipped rather than evaluated: usually only the
        // master or only a channel has been touched.
        let m = Self.isDiagonal(master) ? nil : MonotoneCurve(master)
        let channels = [red, green, blue].map { Self.isDiagonal($0) ? nil : MonotoneCurve($0) }
        return ToneTable(size: size) { channel, x in
            let v = channels[channel]?.value(at: x) ?? x
            return m?.value(at: v) ?? v
        }
    }
}

/// Monotone cubic interpolation (Fritsch and Carlson, 1980) through a
/// curve's points.
///
/// A plain cubic spline overshoots: pull one point up and the curve bulges
/// above 1 or dips back down beside it, which on an image shows as tones
/// reversing. Fritsch-Carlson limits each point's tangent so that between
/// two points the curve never goes beyond them, while staying smooth
/// (continuous first derivative). Outside the first and last points the
/// curve is flat, so moving an end point inward clips, as in any editor.
struct MonotoneCurve {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var tangents: [Double] = []

    init(_ points: [CurvePoint]) {
        // Sorted, clamped to the unit square, one point per x (the last wins,
        // so a point dragged onto another replaces it).
        var byX: [Double: Double] = [:]
        for p in points where p.x.isFinite && p.y.isFinite {
            byX[min(max(p.x, 0), 1)] = min(max(p.y, 0), 1)
        }
        let sorted = byX.sorted { $0.key < $1.key }
        xs = sorted.map(\.key)
        ys = sorted.map(\.value)
        guard xs.count >= 2 else { return }

        let n = xs.count
        var secants = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            secants[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k])
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = secants[0]
        m[n - 1] = secants[n - 2]
        for k in 1..<(n - 1) {
            // A point where the curve turns (secants of opposite sign) is a
            // local extremum: a flat tangent keeps both sides from overshooting.
            m[k] = secants[k - 1] * secants[k] <= 0 ? 0 : (secants[k - 1] + secants[k]) / 2
        }
        for k in 0..<(n - 1) {
            let d = secants[k]
            if d == 0 {
                m[k] = 0
                m[k + 1] = 0
                continue
            }
            // Tangents against the segment's direction (possible only where an
            // earlier flat segment zeroed one) would overshoot: flatten them.
            let a = max(m[k] / d, 0), b = max(m[k + 1] / d, 0)
            m[k] = a * d
            m[k + 1] = b * d
            // Inside the circle of radius 3 the Hermite segment is monotone.
            let r = a * a + b * b
            if r > 9 {
                let tau = 3 / r.squareRoot()
                m[k] = tau * a * d
                m[k + 1] = tau * b * d
            }
        }
        tangents = m
    }

    func value(at x: Double) -> Double {
        guard let first = xs.first else { return x }             // no points: identity
        guard xs.count >= 2 else { return ys[0] }                // one point: constant
        if x <= first { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        // Few points (a dialog has at most a dozen), so a linear scan is as
        // fast as a binary search and simpler.
        var k = 0
        while k < xs.count - 2 && x > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[k] + h10 * h * tangents[k] + h01 * ys[k + 1] + h11 * h * tangents[k + 1]
    }
}

/// One channel of the Levels dialog, all values on the encoded 0...1 scale.
public struct LevelsChannel: Codable, Hashable, Sendable {
    public var inputBlack: Double
    public var inputWhite: Double
    /// Midtone exponent: 1 is none, larger brightens (Photoshop's convention).
    public var gamma: Double
    public var outputBlack: Double
    public var outputWhite: Double

    public static let identity = LevelsChannel(inputBlack: 0, inputWhite: 1, gamma: 1, outputBlack: 0, outputWhite: 1)

    public init(inputBlack: Double, inputWhite: Double, gamma: Double, outputBlack: Double, outputWhite: Double) {
        self.inputBlack = inputBlack
        self.inputWhite = inputWhite
        self.gamma = gamma
        self.outputBlack = outputBlack
        self.outputWhite = outputWhite
    }

    /// Stretch [inputBlack, inputWhite] to 0...1, clipping what lies outside
    /// (that is what the black and white sliders are for), bend it by gamma,
    /// then fit it into [outputBlack, outputWhite].
    public func map(_ x: Double) -> Double {
        let range = inputWhite - inputBlack
        var t = range > 1e-6 ? (x - inputBlack) / range : (x >= inputBlack ? 1 : 0)
        t = min(max(t, 0), 1)
        let g = gamma.isFinite && gamma > 0 ? gamma : 1
        if g != 1 { t = pow(t, 1 / g) }
        return outputBlack + t * (outputWhite - outputBlack)
    }
}

/// The Levels dialog: a composite channel and one per colour. As with
/// curves, the colour channel applies first and the master to its result.
public struct Levels: Codable, Hashable, Sendable {
    public var master: LevelsChannel
    public var red: LevelsChannel
    public var green: LevelsChannel
    public var blue: LevelsChannel

    public static let identity = Levels(master: .identity, red: .identity, green: .identity, blue: .identity)

    public init(master: LevelsChannel = .identity, red: LevelsChannel = .identity,
                green: LevelsChannel = .identity, blue: LevelsChannel = .identity) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var isIdentity: Bool { self == .identity }

    func toneTable(size: Int = ToneTable.defaultSize) -> ToneTable {
        let channels = [red, green, blue]
        return ToneTable(size: size) { channel, x in master.map(channels[channel].map(x)) }
    }
}

/// A per-channel tone function sampled for the GPU: what curves and levels
/// both compile to, so one kernel applies either.
///
/// The table covers encoded values 0...1. Extended-range pixels lie outside
/// that (HDR highlights above 1, wide-gamut colours below 0), and clamping
/// them would flatten every HDR highlight to white, so the kernel continues
/// the function in a straight line with the slope of its end segment. A
/// function that ends flat (a white point pulled in, which clips) therefore
/// still clips HDR highlights, and one that ends at slope 1 (the usual case)
/// keeps them. Slopes are never negative: an inverted curve holds
/// out-of-range values at its end value instead of sending them far below
/// black, where they would upset every operation after it.
struct ToneTable: Equatable {
    /// 4096 entries: linear interpolation between them is within 1e-4 of the
    /// exact function above encoded 0.002 (measured for levels gammas from
    /// 0.1 to 5; curves are smoother still). Below that (linear values
    /// under 0.00016, which no screen shows apart from black) a strong
    /// gamma's near-vertical start is cut short.
    static let defaultSize = 4096

    let size: Int
    /// RGBA float quadruples, `size` of them (alpha is unused, set to 1).
    let rgba: [Float]
    let lowValue: SIMD3<Float>
    let highValue: SIMD3<Float>
    let lowSlope: SIMD3<Float>
    let highSlope: SIMD3<Float>

    init(size: Int, function: (_ channel: Int, _ x: Double) -> Double) {
        let n = max(size, 2)
        self.size = n
        var rgba = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            for c in 0..<3 { rgba[i * 4 + c] = Float(function(c, x)) }
        }
        self.rgba = rgba
        var lowValue = SIMD3<Float>(), highValue = SIMD3<Float>()
        var lowSlope = SIMD3<Float>(), highSlope = SIMD3<Float>()
        let step = Float(n - 1)
        for c in 0..<3 {
            lowValue[c] = rgba[c]
            highValue[c] = rgba[(n - 1) * 4 + c]
            lowSlope[c] = max(0, (rgba[4 + c] - rgba[c]) * step)
            highSlope[c] = max(0, (rgba[(n - 1) * 4 + c] - rgba[(n - 2) * 4 + c]) * step)
        }
        self.lowValue = lowValue
        self.highValue = highValue
        self.lowSlope = lowSlope
        self.highSlope = highSlope
    }

    /// What the kernel computes for one encoded channel value, on the CPU,
    /// for tests.
    func apply(_ e: Float, channel c: Int) -> Float {
        if e < 0 { return lowValue[c] + e * lowSlope[c] }
        if e > 1 { return highValue[c] + (e - 1) * highSlope[c] }
        let p = e * Float(size - 1)
        let i = min(Int(p), size - 2)
        let f = p - Float(i)
        return rgba[i * 4 + c] * (1 - f) + rgba[(i + 1) * 4 + c] * f
    }
}
