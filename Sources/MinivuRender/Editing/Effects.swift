import Foundation
import CoreGraphics
import CoreImage

// The Phase 6 special effects (DESIGN.md 4.7): drop shadow, frame, bump
// map, sketch, oil painting and lens. Payloads are plain values; lengths are
// fractions of the image's short side or full-resolution pixels, and
// positions are normalised, so `EffectsGraph` renders a proxy that matches
// the saved file. Every field decodes with its default when missing, so
// documents saved before a field existed keep loading.

/// An sRGB colour with alpha, 0...1.
public struct EditColor: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = EditColor(red: 0, green: 0, blue: 0)
    public static let white = EditColor(red: 1, green: 1, blue: 1)

    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.effectsValue(.red, default: 0)
        green = try c.effectsValue(.green, default: 0)
        blue = try c.effectsValue(.blue, default: 0)
        alpha = try c.effectsValue(.alpha, default: 1)
    }

    /// Premultiplied components in the edit graph's working space (extended
    /// linear Display P3), converted by ColorSync. Components outside 0...1
    /// are kept (extended sRGB) rather than clipped; alpha is held to 0...1.
    var working: SIMD4<Float> {
        let a = Float(EffectsMath.clamp(alpha, 0...1))
        let components = [red, green, blue].map { CGFloat($0.isFinite ? $0 : 0) } + [1]
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let color = CGColor(colorSpace: space, components: components),
              let converted = color.converted(to: EditRenderer.workingSpace, intent: .relativeColorimetric, options: nil),
              let c = converted.components, c.count >= 3 else {
            return SIMD4(Float(red) * a, Float(green) * a, Float(blue) * a, a)
        }
        return SIMD4(Float(c[0]) * a, Float(c[1]) * a, Float(c[2]) * a, a)
    }

    /// An infinite image of the colour. Its components are given in the
    /// working space, so Core Image converts nothing.
    var image: CIImage {
        let w = working
        let unpremultiplied = w.w > 0 ? SIMD3(w.x, w.y, w.z) / w.w : .zero
        let color = CIColor(red: CGFloat(unpremultiplied.x), green: CGFloat(unpremultiplied.y),
                            blue: CGFloat(unpremultiplied.z), alpha: CGFloat(w.w), colorSpace: EditRenderer.workingSpace)
        return color.map { CIImage(color: $0) } ?? .clear
    }

    /// Premultiplied working-space components, for a kernel argument.
    var vector: CIVector {
        let w = working
        return CIVector(x: CGFloat(w.x), y: CGFloat(w.y), z: CGFloat(w.z), w: CGFloat(w.w))
    }
}

// MARK: - Drop shadow

/// A shadow behind the photo on a grown canvas.
///
/// Lengths are fractions of the photo's short side, so a shadow looks the
/// same on a 2 MP and a 50 MP photo and on the proxy. The canvas grows by
/// the shadow's reach (its offset plus three blur radii, where a Gaussian
/// has faded to a thousandth) plus `margin` on every side, so the blurred
/// edge is never clipped.
public struct DropShadow: Codable, Hashable, Sendable {
    /// Rightward and downward offset, -0.1...0.1 of the short side.
    public var offsetX = 0.02
    public var offsetY = 0.02
    /// Gaussian standard deviation, 0...0.1 of the short side.
    public var blur = 0.02
    /// 0...1.
    public var opacity = 0.6
    public var color = EditColor.black
    /// The grown canvas. Alpha 0 is transparent, which only formats with
    /// alpha keep (others flatten it when saving).
    public var background = EditColor.white
    /// Space beyond the shadow's reach on every side, 0...0.2 of the short side.
    public var margin = 0.02
    /// The photo's corner radius, 0...0.25 of the short side.
    public var cornerRadius = 0.0

    public static let offsetRange = -0.1...0.1
    public static let blurRange = 0.0...0.1
    public static let marginRange = 0.0...0.2
    public static let cornerRadiusRange = 0.0...0.25

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case offsetX, offsetY, blur, opacity, color, background, margin, cornerRadius
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DropShadow()
        offsetX = try c.effectsValue(.offsetX, default: d.offsetX)
        offsetY = try c.effectsValue(.offsetY, default: d.offsetY)
        blur = try c.effectsValue(.blur, default: d.blur)
        opacity = try c.effectsValue(.opacity, default: d.opacity)
        color = try c.effectsValue(.color, default: d.color)
        background = try c.effectsValue(.background, default: d.background)
        margin = try c.effectsValue(.margin, default: d.margin)
        cornerRadius = try c.effectsValue(.cornerRadius, default: d.cornerRadius)
    }

    /// Nothing to see: no margin, no rounding, and a shadow that is either
    /// invisible or exactly under the photo.
    public var isIdentity: Bool {
        let s = sanitized
        return s.margin == 0 && s.cornerRadius == 0
            && (s.opacity == 0 || (s.offsetX == 0 && s.offsetY == 0 && s.blur == 0))
    }

    /// Every field finite and in its range.
    var sanitized: DropShadow {
        var s = self
        s.offsetX = EffectsMath.clamp(offsetX, Self.offsetRange)
        s.offsetY = EffectsMath.clamp(offsetY, Self.offsetRange)
        s.blur = EffectsMath.clamp(blur, Self.blurRange)
        s.opacity = EffectsMath.clamp(opacity, 0...1)
        s.margin = EffectsMath.clamp(margin, Self.marginRange)
        s.cornerRadius = EffectsMath.clamp(cornerRadius, Self.cornerRadiusRange)
        return s
    }

    /// Canvas added on each side of a `width` x `height` photo, in whole
    /// pixels of that photo. An invisible shadow adds only the margin.
    public func margins(width: Int, height: Int) -> EdgeMargins {
        let s = sanitized
        let short = Double(max(min(width, height), 0))
        let pad = s.margin * short
        let visible = s.opacity > 0 && s.color.alpha > 0
        let reach = visible ? 3 * s.blur * short : 0
        let dx = visible ? s.offsetX * short : 0, dy = visible ? s.offsetY * short : 0
        func edge(_ v: Double) -> Int { Int((max(0, v) + pad).rounded()) }
        return EdgeMargins(left: edge(reach - dx), top: edge(reach - dy), right: edge(reach + dx),
                           bottom: edge(reach + dy))
    }
}

/// Space around a photo on a grown canvas, in pixels.
public struct EdgeMargins: Hashable, Sendable {
    public var left: Int, top: Int, right: Int, bottom: Int
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

// MARK: - Frame

/// A border around the photo on a grown canvas.
public struct FrameStyle: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// One colour all round.
        case solid
        /// A mat in `color` inside a thin outer band of `accentColor`, with
        /// a keyline of `lineColor` around the photo.
        case matte
        /// A raised moulding in `color`, lit from the top left.
        case bevel
        /// One colour, with a bottom 3.5 times as deep as the other sides.
        case polaroid

        public var title: String {
            switch self {
            case .solid: "Solid"
            case .matte: "Matte"
            case .bevel: "Bevel"
            case .polaroid: "Polaroid"
            }
        }
    }

    public var kind = Kind.solid
    /// Border width, 0...0.25 of the photo's short side (the Polaroid's
    /// bottom is 3.5 times this).
    public var width = 0.04
    public var color = EditColor.white
    /// The matte's outer band.
    public var accentColor = EditColor(red: 0.12, green: 0.12, blue: 0.12)
    /// The matte's keyline, 0...0.02 of the short side (0 draws none).
    public var lineWidth = 0.003
    public var lineColor = EditColor(red: 0.45, green: 0.45, blue: 0.45)

    public static let widthRange = 0.0...0.25
    public static let lineWidthRange = 0.0...0.02
    /// The Polaroid's bottom over its other sides.
    public static let polaroidBottomRatio = 3.5
    /// The matte's outer band, as a share of the width.
    public static let matteBandShare = 0.3

    public init() {}

    private enum CodingKeys: String, CodingKey { case kind, width, color, accentColor, lineWidth, lineColor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameStyle()
        kind = try c.effectsValue(.kind, default: d.kind)
        width = try c.effectsValue(.width, default: d.width)
        color = try c.effectsValue(.color, default: d.color)
        accentColor = try c.effectsValue(.accentColor, default: d.accentColor)
        lineWidth = try c.effectsValue(.lineWidth, default: d.lineWidth)
        lineColor = try c.effectsValue(.lineColor, default: d.lineColor)
    }

    public var isIdentity: Bool { EffectsMath.clamp(width, Self.widthRange) == 0 }

    /// Canvas added on each side of a `width` x `height` photo, in whole
    /// pixels of that photo.
    public func margins(width photoWidth: Int, height photoHeight: Int) -> EdgeMargins {
        let short = Double(max(min(photoWidth, photoHeight), 0))
        let w = EffectsMath.clamp(width, Self.widthRange) * short
        let side = Int(w.rounded())
        let bottom = kind == .polaroid ? Int((w * Self.polaroidBottomRatio).rounded()) : side
        return EdgeMargins(left: side, top: side, right: side, bottom: bottom)
    }
}

// MARK: - Bump map

/// Embossed relief: the photo lit as if its brightness were a height field.
public struct BumpMap: Codable, Hashable, Sendable {
    /// 0...5; 0 is flat (no relief).
    public var strength = 1.0
    /// Where the light comes from, in degrees counter-clockwise from the
    /// right (135 is the top left).
    public var angle = 135.0
    /// The light's height above the horizon, 10...90 degrees.
    public var elevation = 45.0
    /// 0...1: 0 is the relief alone on middle grey, 1 the relief over the
    /// photo's colours.
    public var blend = 1.0
    /// The slope is measured across this many full-resolution pixels, 1...8:
    /// larger follows broader shapes and ignores fine texture.
    public var step = 2.0

    public static let strengthRange = 0.0...5.0
    public static let elevationRange = 10.0...90.0
    public static let stepRange = 1.0...8.0

    public init() {}

    private enum CodingKeys: String, CodingKey { case strength, angle, elevation, blend, step }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BumpMap()
        strength = try c.effectsValue(.strength, default: d.strength)
        angle = try c.effectsValue(.angle, default: d.angle)
        elevation = try c.effectsValue(.elevation, default: d.elevation)
        blend = try c.effectsValue(.blend, default: d.blend)
        step = try c.effectsValue(.step, default: d.step)
    }

    /// Flat relief over the full colours changes nothing.
    public var isIdentity: Bool {
        EffectsMath.clamp(strength, Self.strengthRange) == 0 && EffectsMath.clamp(blend, 0...1) == 1
    }
}

// MARK: - Sketch

/// A drawing made from the photo's edges.
public struct Sketch: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Grey pencil lines on white paper.
        case pencil
        /// Heavier, darker lines with the shadows smudged in.
        case charcoal
        /// Lines in the photo's own colours.
        case coloredPencil

        public var title: String {
            switch self {
            case .pencil: "Pencil"
            case .charcoal: "Charcoal"
            case .coloredPencil: "Colored Pencil"
            }
        }
    }

    public var style = Style.pencil
    /// 0...1: how dark the lines are.
    public var strength = 0.5
    /// How far an edge's line spreads, in full-resolution pixels, 1...40.
    /// Larger radii draw bolder lines and pick up softer edges.
    public var radius = 6.0

    public static let strengthRange = 0.0...1.0
    public static let radiusRange = 1.0...40.0

    public init() {}

    private enum CodingKeys: String, CodingKey { case style, strength, radius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Sketch()
        style = try c.effectsValue(.style, default: d.style)
        strength = try c.effectsValue(.strength, default: d.strength)
        radius = try c.effectsValue(.radius, default: d.radius)
    }

    /// A sketch always changes the photo.
    public var isIdentity: Bool { false }

    /// A line radius that looks the same on any photo: 6 px at 24 MP,
    /// scaled with the linear size.
    public static func defaultRadius(width: Int, height: Int) -> Double {
        EffectsMath.scaledDefault(6, width: width, height: height, range: radiusRange)
    }
}

// MARK: - Oil paint

/// Brush strokes: an anisotropic Kuwahara filter (see `OilPaintKernel`),
/// with the brightness quantised into `levels` soft steps.
public struct OilPaint: Codable, Hashable, Sendable {
    /// Brush radius in full-resolution pixels, 1...16.
    public var radius = 4.0
    /// Brightness steps, 10...60: fewer gives flatter patches of paint.
    public var levels = 30

    public static let radiusRange = 1.0...16.0
    public static let levelsRange = 10...60

    public init() {}

    private enum CodingKeys: String, CodingKey { case radius, levels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OilPaint()
        radius = try c.effectsValue(.radius, default: d.radius)
        levels = try c.effectsValue(.levels, default: d.levels)
    }

    public var isIdentity: Bool { !(radius > 0) }

    /// 4 px at 24 MP, scaled with the linear size, so a brush covers the
    /// same share of any photo.
    public static func defaultRadius(width: Int, height: Int) -> Double {
        EffectsMath.scaledDefault(4, width: width, height: height, range: radiusRange)
    }
}

// MARK: - Lens

/// A round magnifying (or shrinking) lens over part of the photo.
public struct LensEffect: Codable, Hashable, Sendable {
    /// Normalised, top-left origin.
    public var centerX = 0.5
    public var centerY = 0.5
    /// 0.02...1 of the short side.
    public var radius = 0.25
    /// 1...3 bulges the middle out, 0.5...1 pinches it in; 1 is no change.
    /// Below 0.5 the smooth edge would fold over itself.
    public var magnification = 2.0
    /// A glassy rim at the lens's edge.
    public var ring = false

    public static let radiusRange = 0.02...1.0
    public static let magnificationRange = 0.5...3.0

    public init() {}

    private enum CodingKeys: String, CodingKey { case centerX, centerY, radius, magnification, ring }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LensEffect()
        centerX = try c.effectsValue(.centerX, default: d.centerX)
        centerY = try c.effectsValue(.centerY, default: d.centerY)
        radius = try c.effectsValue(.radius, default: d.radius)
        magnification = try c.effectsValue(.magnification, default: d.magnification)
        ring = try c.effectsValue(.ring, default: d.ring)
    }

    public var isIdentity: Bool {
        !ring && (EffectsMath.clamp(magnification, Self.magnificationRange) == 1 || !(radius > 0))
    }
}

// MARK: - Graph

enum EffectsGraph {
    /// Size after a shadow or frame (which add margins); others keep it.
    static func fullSize(after op: EditOperation, from size: EditGraph.Size) -> EditGraph.Size {
        let m: EdgeMargins
        switch op {
        case .dropShadow(let shadow): m = shadow.margins(width: size.width, height: size.height)
        case .frame(let frame): m = frame.margins(width: size.width, height: size.height)
        default: return size
        }
        return EditGraph.Size(width: size.width + m.left + m.right, height: size.height + m.top + m.bottom)
    }

    /// `outputWidth`/`outputHeight` are the working-image size the result
    /// must have (`EditGraph.workingLength` of `fullSize(after:)`).
    static func apply(_ op: EditOperation, to image: CIImage, outputWidth: Int, outputHeight: Int,
                      scale: Double) -> CIImage {
        switch op {
        case .dropShadow(let shadow):
            return dropShadow(shadow.sanitized, image: image, outputWidth: outputWidth, outputHeight: outputHeight,
                              scale: scale)
        case .frame(let frame):
            return self.frame(frame, image: image, outputWidth: outputWidth, outputHeight: outputHeight, scale: scale)
        case .bumpMap(let bump):
            return EffectsKernels.bumpMap(image, bump, scale: scale)
        case .sketch(let sketch):
            return EffectsKernels.sketch(image, sketch, scale: scale)
        case .oilPaint(let paint):
            return OilPaintKernel.paint(image, paint, scale: scale)
        case .lens(let lens):
            return EffectsKernels.lens(image, lens)
        default:
            return image
        }
    }

    /// The operation's input size in full-resolution pixels. The graph
    /// passes only working sizes, and the working image is `workingLength`
    /// of the full one: exact at scale 1, and within a pixel on a proxy (a
    /// hair of the short side), which is all margins need.
    static func estimatedFullSize(_ image: CIImage, scale: Double) -> EditGraph.Size {
        let s = scale > 0 ? scale : 1
        return EditGraph.Size(width: max(1, Int((image.extent.width / s).rounded())),
                              height: max(1, Int((image.extent.height / s).rounded())))
    }

    /// Where the photo goes on the grown canvas, in Core Image coordinates:
    /// the full-resolution margins scaled, kept inside the output (rounding
    /// at a working scale may leave a pixel less room than the margins sum to).
    static func placement(_ margins: EdgeMargins, image: CIImage, outputWidth: Int, outputHeight: Int,
                          scale: Double) -> CGRect {
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        let left = min(max(Int((Double(margins.left) * scale).rounded()), 0), max(outputWidth - w, 0))
        let top = min(max(Int((Double(margins.top) * scale).rounded()), 0), max(outputHeight - h, 0))
        return CGRect(x: left, y: outputHeight - top - h, width: w, height: h)
    }

    private static func dropShadow(_ s: DropShadow, image: CIImage, outputWidth: Int, outputHeight: Int,
                                   scale: Double) -> CIImage {
        let full = estimatedFullSize(image, scale: scale)
        let short = Double(min(full.width, full.height)) * scale
        let rect = placement(s.margins(width: full.width, height: full.height), image: image,
                             outputWidth: outputWidth, outputHeight: outputHeight, scale: scale)
        var photo = image.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        let corner = min(s.cornerRadius * short, Double(min(rect.width, rect.height)) / 2)
        if corner >= 0.25,
           let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
               "inputExtent": CIVector(cgRect: rect), "inputRadius": corner, "inputColor": CIColor.white,
           ])?.outputImage {
            // Multiplies by the mask's coverage: HDR values inside stay as they are.
            photo = photo.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }

        var result = photo
        var shadowColor = s.color
        shadowColor.alpha = EffectsMath.clamp(s.color.alpha, 0...1) * s.opacity
        if shadowColor.alpha > 0 {
            // The photo's own coverage (so a rounded or transparent photo casts
            // its own shape) in the shadow colour, moved, and blurred against
            // a clear surround so it fades out.
            var shadow = shadowColor.image
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: photo])
                .transformed(by: CGAffineTransform(translationX: s.offsetX * short, y: -s.offsetY * short))
            let sigma = s.blur * short
            if sigma > 0.05 {
                shadow = shadow.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            }
            result = photo.composited(over: shadow)
        }
        let canvas = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        return result.composited(over: s.background.image).cropped(to: canvas)
    }

    private static func frame(_ f: FrameStyle, image: CIImage, outputWidth: Int, outputHeight: Int,
                              scale: Double) -> CIImage {
        let full = estimatedFullSize(image, scale: scale)
        let short = Double(min(full.width, full.height)) * scale
        let rect = placement(f.margins(width: full.width, height: full.height), image: image,
                             outputWidth: outputWidth, outputHeight: outputHeight, scale: scale)
        let canvas = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let placed = image.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return EffectsKernels.frame(f, placed: placed, canvas: canvas, photo: rect, shortSide: short)
    }
}

// MARK: - Helpers

enum EffectsMath {
    /// `value` in `range`; a NaN or infinity becomes the lower bound.
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }

    /// A pixel length that suits a 24 MP photo, scaled with the square root
    /// of the pixel count (the linear size) and rounded to a half pixel.
    static func scaledDefault(_ at24MP: Double, width: Int, height: Int, range: ClosedRange<Double>) -> Double {
        let pixels = Double(max(width, 1)) * Double(max(height, 1))
        return clamp((at24MP * (pixels / 24e6).squareRoot() * 2).rounded() / 2, range)
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `defaultValue` when the key is missing (a
    /// document saved before the field existed). A value of the wrong type
    /// still throws.
    func effectsValue<T: Decodable>(_ key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue
    }
}
