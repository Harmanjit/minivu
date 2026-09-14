import Foundation
import CoreGraphics
import CoreImage

/// The effects that are Core Image kernels: frame borders, bump map,
/// sketch, lens, and the structure tensor the oil paint filter steers by.
///
/// Written in Metal and compiled at runtime, for the reasons `ToneKernels`
/// gives: they need Core Image's headers, which the plain shader library
/// can't include. Each kernel joins Core Image's own graph, so a chain of
/// them renders without intermediate textures where Core Image can
/// concatenate them.
///
/// **Scale.** Every length reaching a kernel is in working pixels: full-
/// resolution lengths times `scale`, or fractions of the working image, so
/// the proxy and the saved file agree.
///
/// **HDR.** Nothing clamps except the sketch, whose paper is white by
/// definition (see `sketch`).
///
/// **Extents.** Kernels that read beyond the pixel they write, or depend on
/// its position, are applied over an infinite extent and then cropped.
/// Given the image's own extent instead, the crop that follows matches it
/// and Core Image drops it as redundant, but doesn't clip the kernel either:
/// once a later operation moved the result (a drop shadow's margin), the
/// kernel's values spilled past the image's edge (measured: the frame's
/// outer band, the bump map's and lens's clamped edge colours, all filled
/// the shadow's margin).
enum EffectsKernels {
    /// Helpers every kernel includes. Each kernel is compiled into a
    /// library of its own (see `kernel(_:)`), so these are pasted into each.
    static let prelude = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // The sRGB transfer, mirrored for negative values (see ToneKernels).
    static float effectsEncode(float c) {
        float a = abs(c);
        float e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
        return sign(c) * e;
    }

    static float effectsDecode(float e) {
        float a = abs(e);
        float c = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
        return sign(e) * c;
    }

    static float3 effectsEncode3(float3 c) {
        return float3(effectsEncode(c.r), effectsEncode(c.g), effectsEncode(c.b));
    }

    static float3 effectsDecode3(float3 e) {
        return float3(effectsDecode(e.r), effectsDecode(e.g), effectsDecode(e.b));
    }

    // Display P3 luminance weights, in linear light.
    #define effectsLuma float3(0.2289746, 0.6917385, 0.0792869)

    // How much of the pixel [p - 0.5, p + 0.5] lies in [lo, hi].
    static float effectsCover(float p, float lo, float hi) {
        return clamp(min(p + 0.5, hi) - max(p - 0.5, lo), 0.0, 1.0);
    }

    static float effectsCoverRect(float2 p, float4 r) {
        return effectsCover(p.x, r.x, r.z) * effectsCover(p.y, r.y, r.w);
    }
    """

    /// Each kernel's source, by function name.
    static let sources: [String: String] = [
        "effectsFrame": """
        // The raised moulding's colour at a point (y up), or the plain colour
        // outside the border. `size` is the canvas, `photo` minX minY maxX maxY.
        static float4 effectsBevelAt(float2 p, float2 size, float4 photo, float4 color) {
            float L = max(photo.x, 1e-3), B = max(photo.y, 1e-3);
            float R = max(size.x - photo.z, 1e-3), T = max(size.y - photo.w, 1e-3);
            // Depth across each side, 0 at the outer edge and 1 at the photo; the
            // side with the smallest depth owns the point, which mitres corners.
            float dl = p.x / L, dr = (size.x - p.x) / R, db = p.y / B, dt = (size.y - p.y) / T;
            float depth = dl;
            float2 outward = float2(-1.0, 0.0);
            if (dr < depth) { depth = dr; outward = float2(1.0, 0.0); }
            if (db < depth) { depth = db; outward = float2(0.0, -1.0); }
            if (dt < depth) { depth = dt; outward = float2(0.0, 1.0); }
            depth = clamp(depth, 0.0, 1.0);
            // A rounded profile: the outer half faces outward, the inner half
            // slopes down towards the photo.
            float tilt = 0.75 * cos(M_PI_F * depth);
            float3 n = float3(outward * sin(tilt), cos(tilt));
            float3 light = normalize(float3(-1.0, 1.3, 1.6));   // top left, y up
            float shade = 0.25 + 0.75 * max(dot(n, light), 0.0);
            return float4(color.rgb * shade, color.a);
        }

        static float4 effectsBorder(float2 p, float2 size, float4 photo, float4 params, float4 color, float4 accent,
                                    float4 line) {
            int kind = int(params.x + 0.5);
            if (kind == 1) {
                float band = params.y;
                float4 result = accent;
                float mat = effectsCoverRect(p, float4(band, band, size.x - band, size.y - band));
                result = mix(result, color, mat);
                float w = params.z;
                if (w > 0.0) {
                    float keyline = effectsCoverRect(p, float4(photo.xy - w, photo.zw + w));
                    result = mix(result, line, keyline);
                }
                return result;
            }
            if (kind == 2) {
                // Four samples per pixel smooth the mitres' diagonal seams.
                float4 sum = float4(0.0);
                sum += effectsBevelAt(p + float2(-0.25, -0.25), size, photo, color);
                sum += effectsBevelAt(p + float2(0.25, -0.25), size, photo, color);
                sum += effectsBevelAt(p + float2(-0.25, 0.25), size, photo, color);
                sum += effectsBevelAt(p + float2(0.25, 0.25), size, photo, color);
                return sum * 0.25;
            }
            return color;
        }

        // The photo over its border. `image` is the photo already placed on
        // the canvas; params: kind (0 solid, 1 matte, 2 bevel, 3 polaroid), the
        // matte's band width, the keyline width, unused.
        [[stitchable]] float4 effectsFrame(coreimage::sampler image, float2 size, float4 photo, float4 params,
                                           float4 color, float4 accent, float4 line, coreimage::destination dest) {
            float2 p = dest.coord();
            float4 s = image.sample(image.transform(p));
            return s + effectsBorder(p, size, photo, params, color, accent, line) * (1.0 - s.a);
        }
        """,
        "effectsHeight": """
        // Encoded luminance, the bump map's height field, in red.
        [[stitchable]] float4 effectsHeight(coreimage::sample_t s) {
            float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
            float h = effectsEncode(max(dot(c, effectsLuma), 0.0));
            return float4(h, h, h, 1.0);
        }
        """,
        "effectsBumpMap": """
        // light: unit vector (y up); params: step in working pixels, step in
        // full-resolution pixels, gain, blend.
        [[stitchable]] float4 effectsBumpMap(coreimage::sampler src, coreimage::sampler height, float3 light,
                                             float4 params, coreimage::destination dest) {
            float2 p = dest.coord();
            float4 s = src.sample(src.transform(p));
            float d = params.x;
            #define H(dx, dy) height.sample(height.transform(p + float2(dx, dy) * d)).r
            float tl = H(-1.0, 1.0), t = H(0.0, 1.0), tr = H(1.0, 1.0);
            float l = H(-1.0, 0.0), r = H(1.0, 0.0);
            float bl = H(-1.0, -1.0), b = H(0.0, -1.0), br = H(1.0, -1.0);
            #undef H
            // Sobel, divided by its weights (8) and by the two steps it spans in
            // full-resolution pixels: a slope per full-resolution pixel, so the
            // proxy and the saved file light the same shapes the same way.
            float gx = ((tr + 2.0 * r + br) - (tl + 2.0 * l + bl)) / (8.0 * params.y);
            float gy = ((tl + 2.0 * t + tr) - (bl + 2.0 * b + br)) / (8.0 * params.y);
            float3 n = normalize(float3(-gx * params.z, -gy * params.z, 1.0));
            // 1 on flat ground, below on slopes facing away, above facing the light.
            float relief = max(dot(n, light), 0.0) / max(light.z, 1e-3);

            float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
            float3 e = effectsEncode3(c);
            // Shadows multiply; lit slopes lighten towards white like a screen, so
            // an SDR photo stays SDR and HDR highlights are never pushed down.
            float lift = min(relief - 1.0, 1.0);
            float3 lit = relief < 1.0 ? e * relief : e + max(1.0 - e, 0.0) * lift;
            float grey = relief < 1.0 ? 0.5 * relief : 0.5 + 0.5 * lift;
            float3 o = mix(float3(grey), lit, params.w);
            // The photo's own coverage at any blend: the grey relief is of the
            // photo, so a rotation's transparent corners stay transparent
            // rather than filling with grey as the colour is turned down.
            return float4(effectsDecode3(o) * s.a, s.a);
        }
        """,
        "effectsSketchGrey": """
        // Encoded grey, clamped to paper's range, in red; its inverse in green.
        [[stitchable]] float4 effectsSketchGrey(coreimage::sample_t s) {
            float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
            float g = clamp(effectsEncode(dot(c, effectsLuma)), 0.0, 1.0);
            return float4(g, 1.0 - g, 0.0, 1.0);
        }
        """,
        "effectsSketch": """
        // grey: red is the grey; blurred: green is the blurred inverse; params:
        // style (0 pencil, 1 charcoal, 2 coloured), line exponent, unused, unused.
        [[stitchable]] float4 effectsSketch(coreimage::sample_t s, coreimage::sample_t grey, coreimage::sample_t blurred,
                                            float4 params) {
            float g = grey.r;
            float b = clamp(blurred.g, 0.0, 1.0);
            // Colour dodge of the grey by its blurred inverse: where nothing
            // changes the two cancel to white paper; across an edge the blur lags
            // and the darker side stays dark.
            float dodge = b >= 0.999 ? (g > 0.0 ? 1.0 : 0.0) : min(g / (1.0 - b), 1.0);
            float lines = pow(dodge, params.y);
            int style = int(params.x + 0.5);
            float3 o;
            if (style == 1) {
                // Charcoal: the blurred tone smudged into the shadows.
                float tone = 1.0 - b;
                o = float3(lines * mix(1.0, smoothstep(0.0, 0.8, tone), 0.45));
            } else if (style == 2) {
                // Coloured pencil: each stroke in the photo's hue, a little more
                // saturated and at a pencil's depth whatever the photo's
                // brightness, so dim colours still read as colours; paper
                // stays white.
                float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
                float3 e = clamp(effectsEncode3(c), 0.0, 1.0);
                float m = max(max(e.r, e.g), e.b);
                float3 hue = e / max(m, 1e-3);
                hue = clamp(mix(float3(dot(hue, float3(0.2126, 0.7152, 0.0722))), hue, 1.5), 0.0, 1.0);
                float3 pigment = hue * mix(0.25, 0.7, m);
                o = 1.0 - (1.0 - lines) * (1.0 - pigment);
            } else {
                o = float3(lines);
            }
            return float4(effectsDecode3(o) * s.a, s.a);
        }
        """,
        "effectsLens": """
        // lens: centre x, y (working pixels, y up), radius, 1 / magnification.
        // Returns where each output pixel samples the input: 1 / magnification of
        // the distance at the centre, easing to the true distance at the rim
        // with zero slope there, so the edge is invisible.
        [[stitchable]] float2 effectsLens(float4 lens, coreimage::destination dest) {
            float2 p = dest.coord();
            float2 d = p - lens.xy;
            float r = length(d);
            float t = r / max(lens.z, 1e-3);
            if (t >= 1.0) { return p; }
            float h = t * t * (3.0 - 2.0 * t);
            return lens.xy + d * mix(lens.w, 1.0, h);
        }
        """,
        "effectsLensRing": """
        // The lens's rim over the image: a highlight strongest towards the top
        // left and a faint dark line outside it. lens: centre x, y, radius, rim
        // width.
        [[stitchable]] float4 effectsLensRing(coreimage::sampler image, float4 lens, coreimage::destination dest) {
            float4 s = image.sample(image.transform(dest.coord()));
            float2 d = dest.coord() - lens.xy;
            float r = length(d);
            float w = max(lens.w, 0.5);
            float inside = effectsCover(r, lens.z - w, lens.z);
            float outside = effectsCover(r, lens.z, lens.z + max(w * 0.35, 0.5));
            float2 dir = r > 0.0 ? d / r : float2(0.0);
            float facing = 0.5 + 0.5 * dot(dir, normalize(float2(-1.0, 1.0)));
            float highlight = inside * (0.2 + 0.5 * facing);
            float shadow = outside * 0.35;
            // Premultiplied white over black (the two never overlap), over the image.
            float4 rim = float4(float3(highlight), highlight + shadow);
            return rim + s * (1.0 - rim.a);
        }
        """,
        "effectsStructureTensor": """
        // The structure tensor of an encoded image, from a Sobel over one working
        // pixel: (E, F, G) = (gx.gx, gx.gy, gy.gy) summed over the channels.
        [[stitchable]] float4 effectsStructureTensor(coreimage::sampler src, coreimage::destination dest) {
            float2 p = dest.coord();
            #define S(dx, dy) src.sample(src.transform(p + float2(dx, dy))).rgb
            float3 tl = S(-1.0, 1.0), t = S(0.0, 1.0), tr = S(1.0, 1.0);
            float3 l = S(-1.0, 0.0), r = S(1.0, 0.0);
            float3 bl = S(-1.0, -1.0), b = S(0.0, -1.0), br = S(1.0, -1.0);
            #undef S
            float3 gx = ((tr + 2.0 * r + br) - (tl + 2.0 * l + bl)) * 0.25;
            float3 gy = ((tl + 2.0 * t + tr) - (bl + 2.0 * b + br)) * 0.25;
            return float4(dot(gx, gx), dot(gx, gy), dot(gy, gy), 1.0);
        }
        """,
    ]

    /// The compiled kernel named `name`, compiled on first use (about 90 ms
    /// the first time a Mac ever compiles it, a few milliseconds once the
    /// system's shader cache has it), so only the effects used pay.
    ///
    /// **One library per kernel.** Compiled together, as `ToneKernels` does,
    /// two kernels of one library that first render at the same moment on
    /// two threads (a preview beside a full-resolution render) can leave
    /// Core Image running one in place of the other for the rest of the
    /// process: measured with a bump map and an oil painting started
    /// together, the bump map read the structure tensor as its height field
    /// in two runs out of three. Kernels in separate libraries never did.
    static func kernel(_ name: String) -> CIKernel? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let kernel = cache.kernels[name] { return kernel }
        guard let body = sources[name] else { return nil }
        do {
            let kernel = try CIKernel.kernels(withMetalString: prelude + body).first { $0.name == name }
            cache.kernels[name] = kernel
            return kernel
        } catch {
            // The sources are fixed, and a Mac that can't compile them can't
            // run Metal at all (see `GPU.shared`): failing loudly is right.
            fatalError("Effect kernel \(name) failed to compile: \(error)")
        }
    }

    /// `CIKernel` is immutable once made and safe to use from any thread;
    /// the dictionary is behind the lock.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var kernels: [String: CIKernel] = [:]
    }

    private static let cache = Cache()

    // MARK: - Frame

    /// `placed` (the photo, already moved onto the canvas) over its border:
    /// `canvas` at the origin, `photo` the photo's rectangle on it,
    /// `shortSide` the photo's short side in working pixels.
    ///
    /// A general kernel rather than a colour kernel, although it reads one
    /// pixel: Core Image moves later transforms (a flip, another operation's
    /// placement) inside colour kernels as if they didn't depend on position,
    /// which drew the border in the wrong place.
    static func frame(_ f: FrameStyle, placed: CIImage, canvas: CGRect, photo: CGRect, shortSide: Double) -> CIImage {
        let fallback = placed.composited(over: f.color.image).cropped(to: canvas)
        guard let kernel = Self.kernel("effectsFrame") else { return fallback }
        let kind: Double = switch f.kind {
        case .solid: 0
        case .matte: 1
        case .bevel: 2
        case .polaroid: 3
        }
        let width = EffectsMath.clamp(f.width, FrameStyle.widthRange) * shortSide
        let params = CIVector(x: kind, y: width * FrameStyle.matteBandShare,
                              z: EffectsMath.clamp(f.lineWidth, FrameStyle.lineWidthRange) * shortSide, w: 0)
        return kernel.apply(extent: .infinite, roiCallback: { _, rect in rect }, arguments: [
            placed, CIVector(x: canvas.width, y: canvas.height),
            CIVector(x: photo.minX, y: photo.minY, z: photo.maxX, w: photo.maxY),
            params, f.color.vector, f.accentColor.vector, f.lineColor.vector,
        ])?.cropped(to: canvas) ?? fallback
    }

    // MARK: - Bump map

    /// How steeply a slope of one encoded unit per full-resolution pixel
    /// tilts the surface at strength 1. Photos rarely change more than a
    /// tenth per pixel, which this turns into a clearly visible relief.
    static let bumpGain = 12.0

    static func bumpMap(_ image: CIImage, _ bump: BumpMap, scale: Double) -> CIImage {
        guard let heightKernel = Self.kernel("effectsHeight") as? CIColorKernel,
              let kernel = Self.kernel("effectsBumpMap") else { return image }
        let extent = image.extent
        let step = EffectsMath.clamp(bump.step, BumpMap.stepRange)
        let workingStep = step * scale
        let clampedImage = image.clampedToExtent()
        var height = heightKernel.apply(extent: .infinite, arguments: [clampedImage]) ?? clampedImage
        // Half a step of blur: the full-resolution height field loses the
        // detail a proxy never had, so both light the same shapes.
        let sigma = 0.5 * workingStep
        if sigma > 0.3 {
            height = height.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
        }
        let azimuth = bump.angle.isFinite ? bump.angle * .pi / 180 : 0.75 * .pi
        let elevation = EffectsMath.clamp(bump.elevation, BumpMap.elevationRange) * .pi / 180
        let light = CIVector(x: cos(azimuth) * cos(elevation), y: sin(azimuth) * cos(elevation), z: sin(elevation))
        let reach = workingStep + 1
        let params = CIVector(x: workingStep, y: step,
                              z: EffectsMath.clamp(bump.strength, BumpMap.strengthRange) * bumpGain,
                              w: EffectsMath.clamp(bump.blend, 0...1))
        return kernel.apply(extent: .infinite, roiCallback: { index, rect in
            index == 0 ? rect : rect.insetBy(dx: -reach - 3 * sigma, dy: -reach - 3 * sigma)
        }, arguments: [clampedImage, height, light, params])?.cropped(to: extent) ?? image
    }

    // MARK: - Sketch

    /// The line exponent for each style at a strength: pencil 1 to 4,
    /// charcoal 2 to 7.
    static func sketchExponent(_ sketch: Sketch) -> Double {
        let s = EffectsMath.clamp(sketch.strength, Sketch.strengthRange)
        return sketch.style == .charcoal ? 2 + 5 * s : 1 + 3 * s
    }

    /// Clamps to 0...1 on the encoded scale: the result is a drawing on white
    /// paper, and an HDR highlight has no brighter paper to become.
    static func sketch(_ image: CIImage, _ sketch: Sketch, scale: Double) -> CIImage {
        guard let greyKernel = Self.kernel("effectsSketchGrey") as? CIColorKernel,
              let kernel = Self.kernel("effectsSketch") as? CIColorKernel else { return image }
        let extent = image.extent
        let clampedImage = image.clampedToExtent()
        var grey = greyKernel.apply(extent: .infinite, arguments: [clampedImage]) ?? clampedImage
        // A touch of smoothing keeps sensor noise from speckling the paper.
        let smoothing = 0.6 * scale
        if smoothing > 0.3 {
            grey = grey.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: smoothing])
        }
        var radius = EffectsMath.clamp(sketch.radius, Sketch.radiusRange)
        if sketch.style == .charcoal { radius *= 1.6 }
        let blurred = grey.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(radius * scale, 0.3)])
        let style: Double = switch sketch.style {
        case .pencil: 0
        case .charcoal: 1
        case .coloredPencil: 2
        }
        return kernel.apply(extent: extent, arguments: [image, grey, blurred,
                                                        CIVector(x: style, y: sketchExponent(sketch), z: 0, w: 0)])
            ?? image
    }

    // MARK: - Lens

    static func lens(_ image: CIImage, _ lens: LensEffect) -> CIImage {
        let extent = image.extent
        let w = Double(extent.width), h = Double(extent.height)
        let cx = EffectsMath.clamp(lens.centerX, 0...1) * w
        let cy = (1 - EffectsMath.clamp(lens.centerY, 0...1)) * h
        let radius = EffectsMath.clamp(lens.radius, LensEffect.radiusRange) * min(w, h)
        let magnification = EffectsMath.clamp(lens.magnification, LensEffect.magnificationRange)
        let bounds = CGRect(x: cx - radius, y: cy - radius, width: 2 * radius, height: 2 * radius)
        var result = image
        if magnification != 1, let warp = Self.kernel("effectsLens") as? CIWarpKernel {
            // Every sample of a point inside the lens lies inside it too.
            result = warp.apply(extent: .infinite, roiCallback: { _, rect in
                rect.intersects(bounds) ? rect.union(bounds.insetBy(dx: -2, dy: -2)) : rect
            }, image: image.clampedToExtent(), arguments: [
                CIVector(x: cx, y: cy, z: radius, w: 1 / magnification),
            ])?.cropped(to: extent) ?? image
        }
        // A general kernel over the image, not a colour kernel composited on
        // top, for the reason `frame` gives.
        if lens.ring, let ring = Self.kernel("effectsLensRing"),
           let rim = ring.apply(extent: .infinite, roiCallback: { _, rect in rect }, arguments: [
               result, CIVector(x: cx, y: cy, z: radius, w: max(radius * 0.025, 1)),
           ]) {
            result = rim.cropped(to: extent)
        }
        return result
    }

    // MARK: - Oil paint

    /// The smoothed structure tensor of an encoded image, which gives the
    /// oil paint filter each pixel's edge direction and how strongly it has
    /// one. Blurred by 2 full-resolution pixels so the direction varies
    /// smoothly into strokes.
    static func structureTensor(_ encoded: CIImage, scale: Double) -> CIImage? {
        guard let kernel = Self.kernel("effectsStructureTensor") else { return nil }
        guard let tensor = kernel.apply(extent: .infinite, roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
                                        arguments: [encoded]) else { return nil }
        return tensor.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2 * scale, 0.5)])
    }
}
