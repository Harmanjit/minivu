import Foundation
import CoreGraphics
import CoreImage

/// Compiles an operation list into a Core Image graph (DESIGN.md 4.7).
///
/// A pure function: the same image, operations and scale always give the
/// same graph, and building it touches no pixels (Core Image renders lazily),
/// so it costs well under a millisecond and runs for every slider movement.
///
/// **Scale.** `scale` is the working image's size over the full-resolution
/// size: 1 when saving, about 0.5 for a screen-sized proxy of a 24 MP photo.
/// Lengths in operations are full-resolution pixels and are multiplied by
/// it; positions are normalised and need nothing. Sizes are tracked twice,
/// in full-resolution pixels (exact integers, what `outputSize` reports)
/// and in working pixels (always `workingLength` of the full size), so a
/// crop, a resize and a rotation give the preview the same proportions as
/// the saved file, and after every operation the working image sits at the
/// origin with whole-pixel dimensions.
///
/// **Orientation.** Core Image's y axis points up; crops are given with a
/// top-left origin, as the canvas draws them, and converted here.
///
/// **Colour.** The graph runs in the context's working space, extended
/// linear Display P3 in half floats. Nothing clamps unless the operation's
/// purpose is to clip (levels' black and white points, a curve that flattens):
/// HDR highlights above 1 and wide-gamut values below 0 pass through every
/// other operation. Tone operations that users judge by eye (lighting,
/// lightness, curves, levels, negative) work on encoded values, where 0.5
/// is a middle grey; ones that model light (temperature, saturation,
/// shadows and highlights, resampling, blur) work in linear light.
public enum EditGraph {
    /// A dimension in working pixels for a full-resolution one: never zero.
    public static func workingLength(_ full: Int, scale: Double) -> Int {
        max(1, Int((Double(full) * scale).rounded()))
    }

    /// The full-resolution pixel size after `operations`, starting from
    /// `source`.
    public static func outputSize(source: CGSize, operations: [EditOperation]) -> CGSize {
        var size = Size(width: Int(source.width.rounded()), height: Int(source.height.rounded()))
        for op in operations where !op.isIdentity {
            size = fullSize(after: op, from: size)
        }
        return CGSize(width: size.width, height: size.height)
    }

    /// The graph for `operations` applied to `source`, which must have its
    /// extent at the origin with `EditGraph.workingLength` of
    /// `sourceSize` for its dimensions at `scale`.
    public static func image(source: CIImage, sourceSize: CGSize, operations: [EditOperation],
                             scale: Double) -> CIImage {
        var full = Size(width: Int(sourceSize.width.rounded()), height: Int(sourceSize.height.rounded()))
        var image = source
        for op in operations where !op.isIdentity {
            let next = fullSize(after: op, from: full)
            image = apply(op, to: image, size: next, scale: scale)
            full = next
        }
        return image
    }

    // MARK: - Sizes

    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    static func fullSize(after op: EditOperation, from size: Size) -> Size {
        switch op {
        case .resize(let width, let height, _):
            return Size(width: width, height: height)
        case .rotate90(let turns):
            return EditOperation.normalizedTurns(turns) % 2 == 1 ? Size(width: size.height, height: size.width) : size
        case .rotate(let degrees, let autoCrop):
            let r = rotatedSize(width: Double(size.width), height: Double(size.height), degrees: degrees,
                                autoCrop: autoCrop)
            return Size(width: r.width, height: r.height)
        case .crop(let rect):
            let r = pixelRect(rect, width: size.width, height: size.height)
            return Size(width: r.width, height: r.height)
        default:
            return size
        }
    }

    /// A normalised top-left rectangle in whole pixels of a `width` x
    /// `height` image: edges rounded to the nearest pixel, clipped to the
    /// image, at least one pixel each way.
    static func pixelRect(_ rect: CGRect, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let r = rect.standardized
        func span(_ lo: CGFloat, _ hi: CGFloat, _ length: Int) -> (Int, Int) {
            let start = min(max(Int((lo * CGFloat(length)).rounded()), 0), length - 1)
            let end = min(max(Int((hi * CGFloat(length)).rounded()), start + 1), length)
            return (start, end - start)
        }
        let (x, w) = span(r.minX, r.maxX, width)
        let (y, h) = span(r.minY, r.maxY, height)
        return (x, y, w, h)
    }

    /// The size of an image turned by `degrees`: its bounding box, or with
    /// `autoCrop` the largest upright rectangle inside it (rounded down, so
    /// no transparent corner shows).
    static func rotatedSize(width: Double, height: Double, degrees: Double, autoCrop: Bool) -> (width: Int, height: Int) {
        let angle = degrees * .pi / 180
        let s = abs(sin(angle)), c = abs(cos(angle))
        if !autoCrop {
            // To the nearest pixel: rounding up would add a transparent row
            // for the slightest turn, and the corners that rounding down can
            // clip are under half a pixel, and antialiased anyway.
            return (max(1, Int((width * c + height * s).rounded())), max(1, Int((width * s + height * c).rounded())))
        }
        let inner = largestInscribedRectangle(width: width, height: height, sine: s, cosine: c)
        return (max(1, Int((inner.width + 1e-6).rounded(.down))), max(1, Int((inner.height + 1e-6).rounded(.down))))
    }

    /// The largest-area axis-aligned rectangle inside a `width` x `height`
    /// rectangle turned by an angle with the given |sin| and |cos|.
    ///
    /// Two cases. When the turned rectangle is long and thin enough the best
    /// rectangle touches only its two long sides, and is limited by the
    /// short side: half of it, projected. Otherwise all four corners touch,
    /// and the size solves the two linear equations of those contacts.
    static func largestInscribedRectangle(width: Double, height: Double, sine s: Double,
                                          cosine c: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        let widthIsLonger = width >= height
        let long = widthIsLonger ? width : height
        let short = widthIsLonger ? height : width
        if short <= 2 * s * c * long || abs(s - c) < 1e-10 {
            let x = 0.5 * short
            return widthIsLonger ? (x / s, x / c) : (x / c, x / s)
        }
        let cos2a = c * c - s * s
        return ((width * c - height * s) / cos2a, (height * c - width * s) / cos2a)
    }

    // MARK: - Operations

    /// One operation on the working image; `size` is the full-resolution
    /// size it produces.
    private static func apply(_ op: EditOperation, to image: CIImage, size: Size, scale: Double) -> CIImage {
        // The working image is `workingLength` of the full size; its own
        // extent says so exactly, whatever produced it.
        let w = image.extent.width.rounded()
        let h = image.extent.height.rounded()
        let outW = workingLength(size.width, scale: scale)
        let outH = workingLength(size.height, scale: scale)

        switch op {
        case .resize(_, _, let filter):
            return ResampleKernel.resize(image, width: outW, height: outH, filter: filter)

        case .rotate90(let turns):
            // Exact matrices, not `rotationAngle`, whose cos(90°) of 6e-17
            // would put the edges a hair off whole pixels. Each maps the
            // image back onto the origin. Clockwise on screen is clockwise
            // with y up too, since both flips cancel: (x, y) -> (y, w - x)
            // moves the top-left corner (0, h) to the top-right (h, w).
            let t: CGAffineTransform = switch EditOperation.normalizedTurns(turns) {
            case 1: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            default: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            }
            return image.transformed(by: t)

        case .flip(let horizontal):
            let t = horizontal ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
                               : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
            return image.transformed(by: t)

        case .crop(let rect):
            // The origin in working pixels, the size from the full-resolution
            // crop so preview and saved file agree; nudged inward if rounding
            // would reach past the edge.
            let wx = min(max(Int((rect.standardized.minX * w).rounded()), 0), max(Int(w) - outW, 0))
            let wy = min(max(Int((rect.standardized.minY * h).rounded()), 0), max(Int(h) - outH, 0))
            let bottom = Int(h) - wy - outH
            let region = CGRect(x: wx, y: bottom, width: outW, height: outH)
            return image.cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -CGFloat(wx), y: -CGFloat(bottom)))

        case .rotate(let degrees, _):
            // Turn about the centre and place that centre in the middle of the
            // output; the crop keeps either the bounding box (transparent
            // corners, which Core Image's clear surround provides) or the
            // inscribed rectangle. Screen clockwise is negative with y up.
            let angle = -degrees * .pi / 180
            let t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: CGFloat(outW) / 2, y: CGFloat(outH) / 2))
            return image.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))

        case .sharpen(let amount, let radius):
            let r = radius * scale
            guard r > 0.01 else { return image }
            return image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: r,
                                                              kCIInputIntensityKey: min(max(amount, 0), 5)])
                .cropped(to: image.extent)

        case .blur(let radius):
            let r = radius * scale
            guard r > 0.01 else { return image }
            // Repeat the edges outward first: blurring against Core Image's
            // clear surround would fade the borders to transparent.
            return image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r])
                .cropped(to: image.extent)

        case .lighting(let brightness, let contrast, let gamma, let shadows, let highlights):
            return ToneKernels.lighting(image, brightness: brightness, contrast: contrast, gamma: gamma,
                                        shadows: shadows, highlights: highlights)

        case .colors(let hue, let saturation, let lightness, let temperature, let tint):
            return colors(image, hue: hue, saturation: saturation, lightness: lightness,
                          temperature: temperature, tint: tint)

        case .rgbAdjust(let red, let green, let blue):
            // A gain per channel in linear light, one stop at either end:
            // black stays black, and HDR values scale like the rest.
            func gain(_ v: Double) -> CGFloat { CGFloat(pow(2, clampUnit(v))) }
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain(red), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain(green), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain(blue), w: 0),
            ])

        case .curves(let curves):
            return ToneKernels.toneTable(image, curves.toneTable())

        case .levels(let levels):
            return ToneKernels.toneTable(image, levels.toneTable())

        case .grayscale:
            // Display P3's own luminance weights in linear light, so a grey
            // keeps the brightness the colour had (and HDR stays HDR).
            let y = CIVector(x: 0.2289746, y: 0.6917385, z: 0.0792869, w: 0)
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": y, "inputGVector": y, "inputBVector": y,
            ])

        case .sepia(let intensity):
            // Core Image's tone mixes towards a warm monochrome without
            // clamping (an HDR 2.0 grey measured 2.0, 1.98, 1.84).
            return image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: min(max(intensity, 0), 1)])

        case .negative:
            // Inverted on the encoded scale, as a film negative looks: middle
            // grey stays middle grey. `CIColorInvert` unpremultiplies first, so
            // transparent pixels stay transparent. Values above white come out
            // below black.
            return encoded(image) { $0.applyingFilter("CIColorInvert") }
        }
    }

    /// Hue, saturation, lightness, temperature and tint:
    /// - temperature -1...1 moves the white point a stop of colour
    ///   temperature warmer or cooler (6500 K to 3250 K or 13000 K);
    /// - tint -1...1 towards magenta (positive) or green;
    /// - hue in degrees turns every colour around the colour wheel (positive
    ///   takes red towards yellow);
    /// - saturation -1...1 from grey to twice as saturated, in linear light;
    /// - lightness -1...1 fades towards black or white on the encoded scale.
    private static func colors(_ image: CIImage, hue: Double, saturation: Double, lightness: Double,
                               temperature: Double, tint: Double) -> CIImage {
        var result = image
        if temperature != 0 || tint != 0 {
            let target = 6500 * pow(2, -clampUnit(temperature))
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(target), y: CGFloat(-100 * clampUnit(tint))),
            ])
        }
        if hue.isFinite, hue.truncatingRemainder(dividingBy: 360) != 0 {
            result = result.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * .pi / 180])
        }
        if saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + clampUnit(saturation),
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
        }
        let l = clampUnit(lightness)
        if l != 0 {
            // Towards white: e + (1 - e) l. Towards black: e (1 + l).
            let gain = CGFloat(l > 0 ? 1 - l : 1 + l)
            let bias = CGFloat(l > 0 ? l : 0)
            result = encoded(result) {
                $0.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
                ])
            }
        }
        return result
    }

    /// Runs `body` on encoded (sRGB-curve) values. Both conversions are
    /// extended-range and join the neighbouring colour kernels in one pass.
    private static func encoded(_ image: CIImage, _ body: (CIImage) -> CIImage) -> CIImage {
        body(image.applyingFilter("CILinearToSRGBToneCurve")).applyingFilter("CISRGBToneCurveToLinear")
    }

    private static func clampUnit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, -1), 1) : 0
    }
}
