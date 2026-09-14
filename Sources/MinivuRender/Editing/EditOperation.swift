import Foundation
import CoreGraphics

/// The eleven resampling filters of the Resize dialog (DESIGN.md 4.7).
///
/// Each is a 1D kernel evaluated separably by `ResampleKernel`. They differ
/// in how wide they reach (`support`, in source pixels at 1:1) and in the
/// trade they make between sharpness, ringing and aliasing: Box is blocky
/// with no overshoot, B-Spline is soft with none either, Catmull-Rom and
/// the Lanczos pair are sharp and ring a little around hard edges.
public enum ResampleFilter: String, Codable, CaseIterable, Sendable {
    case box, triangle, hermite, bell, bSpline, mitchell, catmullRom, cosine, quadratic, lanczos3, lanczos8

    public var title: String {
        switch self {
        case .box: "Box"
        case .triangle: "Triangle (Bilinear)"
        case .hermite: "Hermite"
        case .bell: "Bell"
        case .bSpline: "B-Spline"
        case .mitchell: "Mitchell"
        case .catmullRom: "Catmull-Rom"
        case .cosine: "Cosine"
        case .quadratic: "Quadratic"
        case .lanczos3: "Lanczos 3"
        case .lanczos8: "Lanczos 8"
        }
    }

    /// Radius of the kernel in source pixels when not downscaling. Outside
    /// it the weight is zero, so it decides how many taps the shader reads.
    public var support: Double {
        switch self {
        case .box: 0.5
        case .triangle, .hermite, .cosine: 1
        case .bell, .quadratic: 1.5
        case .bSpline, .mitchell, .catmullRom: 2
        case .lanczos3: 3
        case .lanczos8: 8
        }
    }

    /// The number Resample.metal's `filterWeight` switches on. Stored
    /// explicitly rather than derived from `allCases` so reordering the
    /// cases can't silently change which shader function runs.
    var shaderID: UInt32 {
        switch self {
        case .box: 0
        case .triangle: 1
        case .hermite: 2
        case .bell: 3
        case .bSpline: 4
        case .mitchell: 5
        case .catmullRom: 6
        case .cosine: 7
        case .quadratic: 8
        case .lanczos3: 9
        case .lanczos8: 10
        }
    }

    /// The kernel's weight at distance `x` (in filter units), in Swift. The
    /// shader has its own copy (Resample.metal); this one lets tests build
    /// CPU references and check each filter's shape.
    public func weight(_ x: Double) -> Double {
        let t = abs(x)
        switch self {
        case .box:
            return t <= 0.5 ? 1 : 0
        case .triangle:
            return max(0, 1 - t)
        case .hermite:
            return t < 1 ? (2 * t - 3) * t * t + 1 : 0
        case .bell:
            // The quadratic B-spline (a box convolved with itself twice):
            // smooth and never negative, so a little soft.
            if t < 0.5 { return 0.75 - t * t }
            if t < 1.5 { return 0.5 * (t - 1.5) * (t - 1.5) }
            return 0
        case .bSpline:
            return Self.cubic(t, b: 1, c: 0)
        case .mitchell:
            return Self.cubic(t, b: 1.0 / 3, c: 1.0 / 3)
        case .catmullRom:
            return Self.cubic(t, b: 0, c: 0.5)
        case .cosine:
            return t < 1 ? (cos(.pi * t) + 1) / 2 : 0
        case .quadratic:
            // Dodgson's interpolating quadratic: same reach as Bell, but it
            // passes through the original samples (weight 1 at 0, 0 at 1),
            // so it is sharper, at the cost of a small negative lobe.
            if t < 0.5 { return 1 - 2 * t * t }
            if t < 1.5 { return (t - 1) * (t - 1.5) }
            return 0
        case .lanczos3:
            return t < 3 ? Self.sinc(t) * Self.sinc(t / 3) : 0
        case .lanczos8:
            return t < 8 ? Self.sinc(t) * Self.sinc(t / 8) : 0
        }
    }

    /// Mitchell and Netravali's two-parameter cubic family. B = 1, C = 0 is
    /// the cubic B-spline; B = 0, C = 1/2 is Catmull-Rom; B = C = 1/3 is the
    /// compromise they recommended.
    static func cubic(_ t: Double, b: Double, c: Double) -> Double {
        if t < 1 {
            return ((12 - 9 * b - 6 * c) * t * t * t + (-18 + 12 * b + 6 * c) * t * t + (6 - 2 * b)) / 6
        }
        if t < 2 {
            return ((-b - 6 * c) * t * t * t + (6 * b + 30 * c) * t * t + (-12 * b - 48 * c) * t + (8 * b + 24 * c)) / 6
        }
        return 0
    }

    static func sinc(_ x: Double) -> Double {
        x < 1e-8 ? 1 : sin(.pi * x) / (.pi * x)
    }
}

/// One step of an edit (DESIGN.md 4.7).
///
/// Plain values, so the undo history is just an array and a document can be
/// saved, compared and replayed. Every length is in full-resolution pixels
/// and every position is normalised, so `EditGraph` can render the same list
/// on a screen-sized proxy by scaling lengths (a 10 px blur is a 2.5 px blur
/// on a quarter-size proxy) while positions need no change at all.
///
/// Tone and colour amounts are unitless, 0 meaning "no change"; what each
/// end of a range does is documented on `EditGraph`'s implementation of it.
public enum EditOperation: Codable, Hashable, Sendable {
    /// Exact output size in pixels.
    case resize(width: Int, height: Int, filter: ResampleFilter)
    /// Clockwise quarter turns, 1...3.
    case rotate90(turns: Int)
    /// Clockwise by an arbitrary angle. The corners are transparent, or with
    /// `autoCrop` the result is cropped to the largest upright rectangle
    /// that lies entirely inside the turned image.
    case rotate(degrees: Double, autoCrop: Bool)
    /// Mirror left to right (`horizontal`) or top to bottom.
    case flip(horizontal: Bool)
    /// Normalised 0...1 rectangle of the image as it is at this point in
    /// the list, top-left origin.
    case crop(CGRect)
    /// Unsharp mask. `amount` is the strength (0 none, 1 strong, up to 5);
    /// `radius` is in full-resolution pixels.
    case sharpen(amount: Double, radius: Double)
    /// Gaussian blur, radius in full-resolution pixels. The image's own edge
    /// pixels are repeated outward, so edges don't fade and the size stays.
    case blur(radius: Double)
    /// -1...1 each, except `gamma` 0.1...5 where 1 is no change and larger
    /// brightens the midtones.
    case lighting(brightness: Double, contrast: Double, gamma: Double, shadows: Double, highlights: Double)
    /// `hue` in degrees -180...180; the rest -1...1.
    case colors(hue: Double, saturation: Double, lightness: Double, temperature: Double, tint: Double)
    /// -1...1 per channel.
    case rgbAdjust(red: Double, green: Double, blue: Double)
    case curves(ToneCurves)
    case levels(Levels)
    case grayscale
    /// 0...1.
    case sepia(intensity: Double)
    case negative

    // Phase 6. Each payload type and its rendering live with their feature:
    // Effects.swift (EffectsGraph), Annotations.swift (AnnotationGraph),
    // Retouch.swift (RetouchGraph).
    case dropShadow(DropShadow)
    case frame(FrameStyle)
    case bumpMap(BumpMap)
    case sketch(Sketch)
    case oilPaint(OilPaint)
    case lens(LensEffect)
    /// Vector objects (text, lines, arrows, shapes, callouts) drawn on top.
    case annotations([Annotation])
    /// Clone stamp and healing brush strokes, in the order painted.
    case retouch([RetouchStroke])
    case redEye([RedEyeSpot])

    /// For the Edit menu's "Undo Crop" and the history list.
    public var title: String {
        switch self {
        case .resize: "Resize"
        case .rotate90(let turns):
            switch Self.normalizedTurns(turns) {
            case 1: "Rotate Right"
            case 3: "Rotate Left"
            default: "Rotate 180°"
            }
        case .rotate: "Rotate"
        case .flip(let horizontal): horizontal ? "Flip Horizontal" : "Flip Vertical"
        case .crop: "Crop"
        case .sharpen: "Sharpen"
        case .blur: "Blur"
        case .lighting: "Lighting"
        case .colors: "Colors"
        case .rgbAdjust: "RGB Adjust"
        case .curves: "Curves"
        case .levels: "Levels"
        case .grayscale: "Grayscale"
        case .sepia: "Sepia"
        case .negative: "Negative"
        case .dropShadow: "Drop Shadow"
        case .frame: "Frame"
        case .bumpMap: "Bump Map"
        case .sketch: "Sketch"
        case .oilPaint: "Oil Painting"
        case .lens: "Lens"
        case .annotations: "Drawing"
        case .retouch(let strokes):
            strokes.allSatisfy { $0.mode == .clone } ? "Clone Stamp" : "Healing Brush"
        case .redEye: "Red-Eye Removal"
        }
    }

    /// True when applying the operation would change nothing, so the
    /// document doesn't record it (a dialog confirmed with every slider at
    /// zero) and the graph skips it. Operations that can't be carried out
    /// (a resize to zero pixels, an empty crop) count as identity too:
    /// ignoring them is the only sensible way to "apply" them.
    public var isIdentity: Bool {
        switch self {
        case .resize(let width, let height, _):
            return width <= 0 || height <= 0
        case .rotate90(let turns):
            return Self.normalizedTurns(turns) == 0
        case .rotate(let degrees, _):
            return !degrees.isFinite || degrees.truncatingRemainder(dividingBy: 360) == 0
        case .flip:
            return false
        case .crop(let rect):
            // Every component finite: a NaN origin would otherwise pass the
            // checks below and trap when converted to whole pixels.
            let r = rect.standardized
            let valid = [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite)
            let clipped = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return !valid || clipped.isNull || clipped.width <= 0 || clipped.height <= 0
                || (r.minX <= 0 && r.minY <= 0 && r.maxX >= 1 && r.maxY >= 1)
        case .sharpen(let amount, let radius):
            return !(amount > 0) || !(radius > 0)
        case .blur(let radius):
            return !(radius > 0)
        case .lighting(let brightness, let contrast, let gamma, let shadows, let highlights):
            return brightness == 0 && contrast == 0 && gamma == 1 && shadows == 0 && highlights == 0
        case .colors(let hue, let saturation, let lightness, let temperature, let tint):
            return hue.truncatingRemainder(dividingBy: 360) == 0 && saturation == 0 && lightness == 0
                && temperature == 0 && tint == 0
        case .rgbAdjust(let red, let green, let blue):
            return red == 0 && green == 0 && blue == 0
        case .curves(let curves):
            return curves.isIdentity
        case .levels(let levels):
            return levels.isIdentity
        case .grayscale, .negative:
            return false
        case .sepia(let intensity):
            return !(intensity > 0)
        case .dropShadow(let v): return v.isIdentity
        case .frame(let v): return v.isIdentity
        case .bumpMap(let v): return v.isIdentity
        case .sketch(let v): return v.isIdentity
        case .oilPaint(let v): return v.isIdentity
        case .lens(let v): return v.isIdentity
        case .annotations(let objects): return objects.isEmpty
        case .retouch(let strokes): return strokes.allSatisfy(\.isIdentity)
        case .redEye(let spots): return spots.isEmpty
        }
    }

    /// True for operations that move pixels or change the size, which the
    /// canvas needs to know to keep zoom and crop overlays meaningful.
    public var changesGeometry: Bool {
        switch self {
        // A shadow and an outer frame add margins around the image.
        case .resize, .rotate90, .rotate, .flip, .crop, .dropShadow, .frame: true
        default: false
        }
    }

    /// 0...3 for any whole number of clockwise quarter turns.
    static func normalizedTurns(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }
}
