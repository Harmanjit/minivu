import Foundation
import CoreGraphics
import CoreImage
import simd

// Clone stamp, healing brush and red-eye removal (DESIGN.md 4.7): the
// operations' payloads and the Core Image graph that renders them. Brush
// work is recorded as parameters, never pixels, so it replays at any scale
// and costs the undo history a few bytes per point.

/// One clone or heal stroke, as painted.
///
/// Every position is normalised to the image at this point of the operation
/// list (top-left origin, x over the width and y over the height), and the
/// radius is a fraction of the short side, so the same stroke lands on the
/// same pixels on a screen proxy and in the saved file.
public struct RetouchStroke: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case clone, heal }

    public var mode: Mode
    /// The brush centre along the path, recorded at a spacing of at most a
    /// quarter of the radius, so the dabs overlap into a smooth stroke.
    public var points: [CGPoint]
    /// Fraction of the image's short side.
    public var radius: Double
    /// 0 fades from the centre to the rim; 1 is full coverage out to 90% of
    /// the radius (a hard brush still antialiases its edge).
    public var hardness: Double
    /// 0...1.
    public var opacity: Double
    /// Normalised vector from each destination point to the pixel it copies,
    /// fixed for the whole stroke (Photoshop's "aligned" sampling).
    public var sourceOffset: CGVector

    public static let defaultRadius = 0.02
    public static let defaultHardness = 0.5

    public init(mode: Mode, points: [CGPoint] = [], radius: Double = defaultRadius,
                hardness: Double = defaultHardness, opacity: Double = 1, sourceOffset: CGVector = .zero) {
        self.mode = mode
        self.points = points
        self.radius = radius
        self.hardness = hardness
        self.opacity = opacity
        self.sourceOffset = sourceOffset
    }

    /// Nothing painted, nothing visible, or nothing to copy from: a source
    /// on the destination itself would clone a pixel onto itself (and heal
    /// only smear its own tone), so a zero offset counts as no stroke.
    public var isIdentity: Bool {
        points.isEmpty || !(radius > 0) || !(opacity > 0)
            || !sourceOffset.dx.isFinite || !sourceOffset.dy.isFinite
            || (sourceOffset.dx == 0 && sourceOffset.dy == 0)
            || !points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, points, radius, hardness, opacity, sourceOffset
    }

    /// Missing keys take their defaults, so documents written before a field
    /// existed keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .heal
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
        hardness = try c.decodeIfPresent(Double.self, forKey: .hardness) ?? Self.defaultHardness
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        sourceOffset = try c.decodeIfPresent(CGVector.self, forKey: .sourceOffset) ?? .zero
    }
}

/// One eye to fix: a circle around the pupil.
public struct RedEyeSpot: Codable, Hashable, Sendable {
    /// Normalised, top-left origin.
    public var center: CGPoint
    /// Fraction of the image's short side.
    public var radius: Double
    /// 0...1.
    public var strength: Double

    public static let defaultRadius = 0.015

    public init(center: CGPoint = CGPoint(x: 0.5, y: 0.5), radius: Double = defaultRadius, strength: Double = 1) {
        self.center = center
        self.radius = radius
        self.strength = strength
    }

    public var isIdentity: Bool {
        !(radius > 0) || !(strength > 0) || !center.x.isFinite || !center.y.isFinite
    }

    private enum CodingKeys: String, CodingKey { case center, radius, strength }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = try c.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
    }
}

/// The numbers red-eye removal runs on, shared by the kernel and the
/// detector's check that an eye is actually red.
public enum RedEyeTuning {
    /// Redness (red over the larger of green and blue, linear light) where
    /// the pupil mask starts, and where it is full. A brown iris measures
    /// about 3 and stays out; a flash-red pupil measures 5 and up.
    public static let lowThreshold = 3.2
    public static let highThreshold = 4.8
    /// The smoothed mask is multiplied by this before clamping, so the whole
    /// pupil is corrected, not just its reddest middle.
    static let maskGain = 1.8
    /// The corrected pupil's grey, as a fraction of its green and blue.
    static let darkening = 0.85
    /// The circle's edge fades over this fraction of the radius.
    static let feather = 0.15
    /// The pupil mask is smoothed by this fraction of the radius.
    static let smoothing = 0.1

    /// The kernel's redness measure, for CPU checks.
    public static func redness(red: Double, green: Double, blue: Double) -> Double {
        red / max(max(green, blue), 0.005)
    }
}

/// Renders `.retouch` and `.redEye` (see `EditGraph`).
///
/// **Order.** Strokes apply in the order painted, each reading the result
/// of the ones before, so a clone over a cloned area copies the clone. The
/// graph keeps that cheap by never materialising the whole image per
/// stroke: each stroke's result is a *patch*, the size of the area its
/// brush covers, computed from the image as it was before the stroke *in
/// just the regions the stroke reads* (the destination, the source, and a
/// blur's reach around them), which is the original with the earlier
/// patches that overlap those regions pasted in. The output is the original
/// with every patch pasted in order, one pass over the image. Twenty
/// overlapping strokes cost twenty small patches, not twenty full frames.
///
/// **Scale.** Positions and offsets are normalised and radii are fractions
/// of the short side, so a proxy only needs its own pixel counts: masks are
/// rasterised at the working resolution and blur radii follow the brush.
/// Offsets are rounded to whole working pixels, so a clone copies texture
/// without resampling it soft.
enum RetouchGraph {
    static func apply(_ strokes: [RetouchStroke], to image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let shortSide = Double(min(fullSize.width, fullSize.height)) * scale
        let base = image.clampedToExtent()
        var patches: [Patch] = []
        for stroke in strokes where !stroke.isIdentity {
            guard let mask = StrokeMask.cached(stroke, extent: extent, shortSide: shortSide) else { continue }
            let offset = CGPoint(x: (stroke.sourceOffset.dx * extent.width).rounded(),
                                 y: (-stroke.sourceOffset.dy * extent.height).rounded())
            let opacity = min(max(stroke.opacity, 0), 1)
            let patch = switch stroke.mode {
            case .clone: clonePatch(mask: mask, offset: offset, opacity: opacity, base: base, patches: patches)
            case .heal: healPatch(mask: mask, offset: offset, opacity: opacity, base: base, patches: patches)
            }
            patches.append(Patch(rect: mask.rect, image: patch))
        }
        return pasted(patches, over: image)
    }

    /// Red-eye removal: inside each spot's circle, red pixels that belong
    /// to the red area around the middle become a neutral dark pupil (see
    /// `RetouchKernels` for the rules). Spots apply in order, like strokes.
    static func removeRedEye(_ spots: [RedEyeSpot], in image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let shortSide = Double(min(fullSize.width, fullSize.height)) * scale
        let base = image.clampedToExtent()
        let thresholds = CIVector(x: RedEyeTuning.lowThreshold, y: RedEyeTuning.highThreshold)
        var patches: [Patch] = []
        for spot in spots where !spot.isIdentity {
            let centre = workingPoint(spot.center, in: extent)
            let radius = max(spot.radius * shortSide, 1)
            let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
                .integral.intersection(extent)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let circle = CIVector(x: centre.x, y: centre.y, z: radius, w: RedEyeTuning.feather)
            let before = state(in: rect, base: base, patches: patches)
            let raw = RetouchKernels.redEyeMask(before, circle: circle, thresholds: thresholds, extent: rect)
            let smooth = raw.applyingGaussianBlur(sigma: max(radius * RedEyeTuning.smoothing, 0.5)).cropped(to: rect)
            let params = CIVector(x: RedEyeTuning.maskGain, y: min(spot.strength, 1), z: RedEyeTuning.darkening, w: 0)
            let fixed = RetouchKernels.redEyeFix(before, smoothMask: smooth, circle: circle, thresholds: thresholds,
                                                 params: params, extent: rect)
            patches.append(Patch(rect: rect, image: fixed))
        }
        return pasted(patches, over: image)
    }

    // MARK: - Strokes

    /// A normalised top-left point in Core Image working pixels (y up).
    static func workingPoint(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: p.x * extent.width, y: extent.height - p.y * extent.height)
    }

    private struct Patch {
        /// Whole working pixels, inside the image.
        let rect: CGRect
        let image: CIImage
    }

    /// The image as it is before the next stroke, inside `region` (which may
    /// reach past the image, where the edge repeats): the original with the
    /// overlapping patches pasted in order.
    private static func state(in region: CGRect, base: CIImage, patches: [Patch]) -> CIImage {
        var image = base.cropped(to: region)
        for patch in patches where patch.rect.intersects(region) {
            image = RetouchKernels.paste(patch.image, rect: patch.rect, over: image, extent: region)
        }
        return image
    }

    private static func pasted(_ patches: [Patch], over image: CIImage) -> CIImage {
        var result = image
        for patch in patches {
            result = RetouchKernels.paste(patch.image, rect: patch.rect, over: result, extent: image.extent)
        }
        return result
    }

    private static func clonePatch(mask: StrokeMask, offset: CGPoint, opacity: Double, base: CIImage,
                                   patches: [Patch]) -> CIImage {
        let rect = mask.rect
        let destination = state(in: rect, base: base, patches: patches)
        let source = state(in: rect.offsetBy(dx: offset.x, dy: offset.y), base: base, patches: patches)
            .transformed(by: CGAffineTransform(translationX: -offset.x, y: -offset.y))
        return RetouchKernels.clone(destination: destination, source: source, mask: mask.image, opacity: opacity,
                                    extent: rect)
    }

    /// The healing brush: texture from the source, tone and colour from the
    /// destination's surroundings, a fast stand-in for a gradient-domain
    /// (Poisson) blend that runs as a few blurs.
    ///
    /// The source is multiplied by a ratio field, the destination's
    /// surroundings over the source's, where "surroundings" is a Gaussian
    /// blur that leaves the brushed area out and renormalises
    /// (`blur(image x w) / blur(w)`), so the blemish never bleeds into its
    /// own correction (see `RetouchKernels` for the kernel). At the edge of
    /// the stroke the ratio turns the source exactly into the destination,
    /// and inside it interpolates what surrounds the stroke on every side.
    ///
    /// **Why this rather than Latent's rim ratio.** Latent scales the whole
    /// patch by one colour ratio, measured on the rims of the two circles.
    /// Measured in `RetouchHealQualityTests` against the unblemished scene
    /// (encoded 0-255 units, RMS inside the brush / worst 7 x 7 tone error):
    /// on evenly lit skin the two tie (3.8 / 7.2 against 3.7 / 7.2), on a
    /// curving HDR sky gradient too (0.73 / 1.0 against 0.73 / 1.1); across
    /// a horizon, where the brush straddles bright sky and dark hill, one
    /// ratio is wrong on both sides and the rim ratio leaves a grey blotch
    /// worse than the blemish (35 / 85, the blemish itself 22 / 54), while
    /// the ratio field rebuilds the edge (4.3 / 8.4). Dust on a horizon, a
    /// spot at the edge of a lip or a wire across a sky are ordinary heals,
    /// and a brush stroke, unlike Latent's circles, can be long enough to
    /// cross any gradient. The masked blur also needs no measuring pass.
    ///
    /// Sigma is half the brush radius (see `healSigma`): wider blurs reach
    /// further for their surroundings and follow curved gradients less
    /// closely (the sky above measured 0.80 / 1.24 with the full radius).
    private static func healPatch(mask: StrokeMask, offset: CGPoint, opacity: Double, base: CIImage,
                                  patches: [Patch]) -> CIImage {
        let rect = mask.rect
        let sigma = healSigma(radius: mask.radius, innerDistance: mask.innerDistance)
        let margin = (3 * sigma).rounded(.up) + 2
        let reach = rect.insetBy(dx: -margin, dy: -margin)
        let destination = state(in: reach, base: base, patches: patches).clampedToExtent()
        let sourceState = state(in: reach.offsetBy(dx: offset.x, dy: offset.y), base: base, patches: patches)
            .clampedToExtent()
        let toDestination = CGAffineTransform(translationX: -offset.x, y: -offset.y)
        let source = sourceState.transformed(by: toDestination)
        let weight = RetouchKernels.fillWeight(mask.image)
        func surroundings(_ image: CIImage) -> CIImage {
            RetouchKernels.weighted(image, by: weight).applyingGaussianBlur(sigma: sigma).cropped(to: rect)
        }
        return RetouchKernels.heal(destination: destination.cropped(to: rect), source: source.cropped(to: rect),
                                   sourceNumerator: surroundings(source), destinationNumerator: surroundings(destination),
                                   denominator: weight.applyingGaussianBlur(sigma: sigma).cropped(to: rect),
                                   mask: mask.image, opacity: opacity, extent: rect)
    }

    /// Sigma of the heal's blurs, in working pixels: half the brush radius,
    /// or more when the stroke covers an area deeper than one pass of the
    /// brush (a scribble), so the renormalising weights in its middle stay
    /// well above zero (at least about 0.05 for any shape).
    static func healSigma(radius: Double, innerDistance: Double) -> Double {
        max(0.5 * radius, 0.6 * innerDistance, 0.5)
    }
}

/// A stroke's coverage, rasterised on the CPU into a small 8-bit mask.
///
/// The brush is a soft round dab repeated along the path and combined by
/// maximum; with the path sampled densely that is exactly a round-capped
/// line whose coverage falls off with the distance from the path, which is
/// what is computed, segment by segment, over only the pixels each segment
/// can reach. The mask is never finer than 24 pixels per radius: coverage
/// is smooth across the brush (even a hard brush fades over its outer
/// tenth), so a large brush on a large export is drawn at a fraction of
/// the resolution and magnified with bilinear sampling, and the work stays
/// proportional to the stroke's length in radii, not to its pixels.
///
/// Masks are cached by stroke and working size (`cached`): while painting,
/// every render repeats the strokes before the new one, and the preview and
/// full-resolution lanes repeat each other's.
struct StrokeMask: @unchecked Sendable {
    /// Coverage in the red channel, 0 outside; working pixels, y up.
    let image: CIImage
    /// Whole working pixels, inside the image: where coverage can be above 0.
    let rect: CGRect
    /// The brush radius in working pixels.
    let radius: Double
    /// Working pixels per mask pixel.
    let step: Double
    /// How far the deepest covered point is from uncovered pixels, in
    /// working pixels (about 3/4 of the radius for a single pass).
    let innerDistance: Double

    /// Mask pixels per radius, at most.
    static let maximumRadius = 24.0

    /// The mask for `stroke` on a working image of `extent` whose short side
    /// is `shortSide` working pixels (as a fraction of the full size, which
    /// can differ from the extent's own by rounding).
    static func cached(_ stroke: RetouchStroke, extent: CGRect, shortSide: Double) -> StrokeMask? {
        let key = CacheKey(stroke: stroke, extent: extent, shortSide: shortSide)
        if let hit = cache.value(for: key) { return hit }
        let points = stroke.points.map { RetouchGraph.workingPoint($0, in: extent) }
        let mask = StrokeMask(points: points, radius: stroke.radius * shortSide, hardness: stroke.hardness,
                              bounds: extent)
        cache.insert(mask, for: key)
        return mask
    }

    private struct CacheKey: Hashable {
        let stroke: RetouchStroke
        let extent: CGRect
        let shortSide: Double
    }

    /// A few dozen recent masks. Each is a few kilobytes to a megabyte.
    private static let cache = MaskCache<CacheKey>(limit: 64)

    /// - Parameters:
    ///   - points: the path in working pixels, y up.
    ///   - bounds: the image extent; the mask is clipped to it.
    init?(points: [CGPoint], radius: Double, hardness: Double, bounds: CGRect) {
        guard !points.isEmpty, radius.isFinite else { return nil }
        let r = max(radius, 0.5)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let reach = CGRect(x: minX - r, y: minY - r, width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
        let rect = reach.integral.intersection(bounds.integral)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }

        let step = max(1, r / Self.maximumRadius)
        let width = Int((rect.width / step).rounded(.up)), height = Int((rect.height / step).rounded(.up))
        let top = rect.minY + Double(height) * step
        let rm = r / step
        let inner = rm * min(max(hardness.isFinite ? hardness : 0.5, 0), 1) * 0.9
        // Mask coordinates: x from the left, y down from the top row. Points
        // are recorded every quarter radius, so neighbouring segments cover
        // nearly the same pixels; dropping the points a straight line through
        // their neighbours passes within a tenth of the brush's soft edge
        // (at most a quarter pixel) changes no coverage anyone could see and
        // does several times less work.
        let tolerance = min(0.25, 0.1 * max(rm - inner, 0.01))
        let kept = Self.simplified(points.map { SIMD2(($0.x - rect.minX) / step, (top - $0.y) / step) },
                                   tolerance: tolerance)
        let xs = kept.map(\.x), ys = kept.map(\.y)

        var coverage = [UInt8](repeating: 0, count: width * height)
        coverage.withUnsafeMutableBufferPointer { buffer in
            Self.rasterise(xs: xs, ys: ys, radius: rm, inner: inner, into: buffer.baseAddress!, width: width,
                           height: height)
        }

        self.rect = rect
        self.radius = r
        self.step = step
        innerDistance = Self.deepestDistance(coverage, width: width, height: height, radius: rm) * step
        let data = coverage.withUnsafeBufferPointer { Data(buffer: $0) }
        image = CIImage(bitmapData: data, bytesPerRow: width, size: CGSize(width: width, height: height),
                        format: .L8, colorSpace: nil)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: step, y: step).concatenating(
                CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            .cropped(to: rect)
    }

    /// Coverage of the round-capped path through (`xs`, `ys`), maxed into
    /// `buffer`. Plain scalar arithmetic in `while` loops over raw memory:
    /// this is the one loop of the retouch graph that runs per pixel on the
    /// CPU, and written this way it stays quick even in a debug build.
    private static func rasterise(xs: [Double], ys: [Double], radius rm: Double, inner: Double,
                                  into buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        let rm2 = rm * rm, inner2 = inner * inner
        let feather = rm - inner
        let segments = xs.count > 1 ? xs.count - 1 : 1
        var index = 0
        while index < segments {
            let next = index + 1 < xs.count ? index + 1 : index
            let ax = xs[index], ay = ys[index]
            let abx = xs[next] - ax, aby = ys[next] - ay
            index += 1
            let length2 = abx * abx + aby * aby
            let inverse = length2 > 0 ? 1 / length2 : 0
            let x0 = Swift.max(0, Int((Swift.min(ax, ax + abx) - rm).rounded(.down)))
            let x1 = Swift.min(width - 1, Int((Swift.max(ax, ax + abx) + rm).rounded(.up)))
            var y = Swift.max(0, Int((Swift.min(ay, ay + aby) - rm).rounded(.down)))
            let y1 = Swift.min(height - 1, Int((Swift.max(ay, ay + aby) + rm).rounded(.up)))
            guard x0 <= x1 else { continue }
            while y <= y1 {
                let dy = Double(y) + 0.5 - ay
                let dyAlong = dy * aby
                var pointer = buffer + (y * width + x0)
                var dx = Double(x0) + 0.5 - ax
                var x = x0
                while x <= x1 {
                    var t = (dx * abx + dyAlong) * inverse
                    t = t < 0 ? 0 : (t > 1 ? 1 : t)
                    let ex = dx - t * abx, ey = dy - t * aby
                    let d2 = ex * ex + ey * ey
                    if d2 < rm2 {
                        var value: UInt8 = 255
                        if d2 > inner2 {
                            var u = (d2.squareRoot() - inner) / feather
                            u = u > 1 ? 1 : u
                            value = UInt8((1 - u * u * (3 - 2 * u)) * 255 + 0.5)
                        }
                        if value > pointer.pointee { pointer.pointee = value }
                    }
                    pointer += 1
                    dx += 1
                    x += 1
                }
                y += 1
            }
        }
    }

    /// Ramer-Douglas-Peucker: the fewest points whose polyline stays within
    /// `tolerance` of every original point.
    static func simplified(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges = [(0, points.count - 1)]
        let tolerance2 = tolerance * tolerance
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], ab = points[last] - a
            let length2 = simd_length_squared(ab)
            var worst = 0.0, index = first
            for i in (first + 1)..<last {
                let ap = points[i] - a
                let t = length2 > 0 ? min(max(simd_dot(ap, ab) / length2, 0), 1) : 0
                let d2 = simd_length_squared(ap - t * ab)
                if d2 > worst { worst = d2; index = i }
            }
            if worst > tolerance2 {
                keep[index] = true
                ranges.append((first, index))
                ranges.append((index, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The largest distance from a pixel at least half covered to the
    /// nearest pixel that isn't (or the mask's edge), in mask pixels: a
    /// two-pass chamfer distance transform, within a few percent of the
    /// Euclidean distance. Measured on a grid a few times coarser than the
    /// mask when the brush is large, keeping at least six cells per radius:
    /// the answer only picks a blur radius.
    static func deepestDistance(_ coverage: [UInt8], width: Int, height: Int, radius: Double = 0) -> Double {
        let cell = Swift.max(1, Int(radius / 6))
        let gw = (width + cell - 1) / cell, gh = (height + cell - 1) / cell
        // One cell of uncovered border all round, so neighbours need no checks.
        let w = gw + 2, h = gh + 2
        var grid = [Float](repeating: 0, count: w * h)
        let diagonal = Float(2).squareRoot()
        var deepest: Float = 0
        grid.withUnsafeMutableBufferPointer { g in
            let d = g.baseAddress!
            coverage.withUnsafeBufferPointer { c in
                // A cell counts as covered only when all of it is.
                var y = 0
                while y < gh {
                    var x = 0
                    while x < gw {
                        var covered = true
                        var yy = y * cell
                        let yEnd = Swift.min((y + 1) * cell, height), xEnd = Swift.min((x + 1) * cell, width)
                        while covered && yy < yEnd {
                            var xx = x * cell
                            while xx < xEnd { if c[yy * width + xx] < 128 { covered = false; break }; xx += 1 }
                            yy += 1
                        }
                        if covered { d[(y + 1) * w + x + 1] = .greatestFiniteMagnitude }
                        x += 1
                    }
                    y += 1
                }
            }
            @inline(__always) func lower(_ a: Float, _ b: Float) -> Float { a < b ? a : b }
            var k = w + 1
            while k < w * (h - 1) - 1 {
                if d[k] > 0 {
                    d[k] = lower(lower(d[k], d[k - 1] + 1), lower(lower(d[k - w] + 1, d[k - w - 1] + diagonal),
                                                                  d[k - w + 1] + diagonal))
                }
                k += 1
            }
            k = w * (h - 1) - 2
            while k > w {
                if d[k] > 0 {
                    let v = lower(lower(d[k], d[k + 1] + 1), lower(lower(d[k + w] + 1, d[k + w + 1] + diagonal),
                                                                    d[k + w - 1] + diagonal))
                    d[k] = v
                    if v > deepest { deepest = v }
                }
                k -= 1
            }
        }
        return Double(deepest) * Double(cell)
    }
}

/// A small cache of masks, oldest dropped first, bounded by bytes as well
/// as count (a long stroke on a large export can be a megabyte). Safe to use
/// from the render threads (`@unchecked Sendable`: every access holds the
/// lock).
final class MaskCache<Key: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: (mask: StrokeMask?, bytes: Int)] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int, byteLimit: Int = 32 << 20) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    /// The cached result, which may itself be "no mask"; nil when not cached.
    func value(for key: Key) -> StrokeMask?? {
        lock.lock(); defer { lock.unlock() }
        return values[key].map { $0.mask }
    }

    func insert(_ mask: StrokeMask?, for key: Key) {
        let size = mask.map { Int($0.image.extent.width * $0.image.extent.height / ($0.step * $0.step)) } ?? 0
        lock.lock(); defer { lock.unlock() }
        if let old = values.updateValue((mask, size), forKey: key) {
            bytes -= old.bytes
        } else {
            order.append(key)
        }
        bytes += size
        while order.count > limit || (bytes > byteLimit && order.count > 1) {
            if let evicted = values.removeValue(forKey: order.removeFirst()) { bytes -= evicted.bytes }
        }
    }
}
