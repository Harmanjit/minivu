import Foundation
import CoreImage

/// The Core Image kernels behind clone, heal and red-eye removal
/// (`RetouchGraph`), in Metal, compiled when first used.
///
/// **Why Core Image kernels.** Every step is a per-pixel formula over a few
/// inputs that Core Image already knows how to produce cheaply (Gaussian
/// blurs, translations, crops), so the retouch graph joins the rest of the
/// edit graph: Core Image works out which pixels each stroke needs, fuses
/// consecutive kernels into one GPU pass, and tiles large exports. The one
/// thing compute kernels would add, arbitrary loops over stroke points, is
/// done on the CPU instead, into small masks (`StrokeMask`).
///
/// **Colour.** Inputs arrive in the working space, extended linear
/// Display P3 with premultiplied alpha. Nothing clamps what it doesn't have
/// to: HDR values above 1 and wide-gamut negatives pass through cloning,
/// pasting and the heal (whose ratio falls back to a difference where a
/// ratio is meaningless). Red-eye's test is a ratio too, so exposure doesn't
/// change which pixels are red; only the grey it paints a pupil is kept
/// from going below black, since a negative grey would be a colour.
enum RetouchKernels {
    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // Pixels inside `rect` (minX, minY, maxX, maxY, whole pixels) come from
    // `patch`, the rest from `prev`. How a retouched region goes back into
    // the image: an exact replacement, alpha included, where a composite
    // would blend a patch that isn't opaque.
    [[stitchable]] float4 minivuRetouchPaste(coreimage::sample_t prev, coreimage::sample_t patch, float4 rect,
                                            coreimage::destination dest) {
        float2 p = dest.coord();
        bool inside = p.x > rect.x && p.x < rect.z && p.y > rect.y && p.y < rect.w;
        return inside ? patch : prev;
    }

    // Clone stamp: the source pixels over the destination by coverage.
    [[stitchable]] float4 minivuRetouchClone(coreimage::sample_t dst, coreimage::sample_t src,
                                            coreimage::sample_t mask, float opacity) {
        return mix(dst, src, clamp(mask.r * opacity, 0.0, 1.0));
    }

    // How much a destination pixel may inform the heal's fill: none where
    // the brush covers it by a third or more (the blemish and most of the
    // brush's soft edge), fully where it doesn't reach.
    [[stitchable]] float4 minivuRetouchFillWeight(coreimage::sample_t mask) {
        float w = 1.0 - smoothstep(0.0, 0.33, mask.r);
        return float4(w);
    }

    [[stitchable]] float4 minivuRetouchWeighted(coreimage::sample_t image, coreimage::sample_t weight) {
        return image * weight.r;
    }

    // Healing brush. The source's pixels, scaled by a ratio that varies
    // smoothly across the brush: the destination's surroundings over the
    // source's surroundings. Both are the same normalised masked blur
    // (`blur(image x w) / blur(w)`, with `w` zero under the brush), so the
    // blemish never informs the correction, and where the brush meets
    // unbrushed pixels the ratio is exactly what turns the source into the
    // destination: the patch's tone and colour match at every point of the
    // edge, and inside they follow the surroundings (a gradient of sky, a
    // cheek turning into shadow). The texture is the source's own.
    //
    // A ratio in linear light, because texture in a photo is mostly
    // reflectance times illumination: pores copied from a sunlit cheek
    // into a shaded one keep the shaded contrast, and HDR grain stays in
    // proportion. Where either side is near zero or negative (deep black,
    // wide-gamut components) a ratio means nothing, and the difference of
    // the two is added instead. `w` cancels out of the ratio; it is needed
    // for the difference, and to tell when there are no surroundings at
    // all, where the source is copied as it is.
    [[stitchable]] float4 minivuRetouchHeal(coreimage::sample_t dst, coreimage::sample_t src,
                                           coreimage::sample_t srcNum, coreimage::sample_t dstNum,
                                           coreimage::sample_t den, coreimage::sample_t mask, float opacity) {
        float support = max(den.r, 1e-4);
        float4 ls = srcNum / support, ld = dstNum / support;
        float3 added = src.rgb + ld.rgb - ls.rgb;
        float3 ratio = src.rgb * (ld.rgb / max(ls.rgb, float3(1e-4)));
        float3 useRatio = smoothstep(0.002, 0.008, min(ls.rgb, ld.rgb));
        float4 healed = float4(mix(added, ratio, useRatio), src.a + ld.a - ls.a);
        healed = mix(src, healed, smoothstep(0.002, 0.02, den.r));
        return mix(dst, healed, clamp(mask.r * opacity, 0.0, 1.0));
    }

    // How red a colour is, in linear light: red over the larger of green
    // and blue. A red-eye pupil measures 5 to 15, skin 1.5 to 2, and a
    // brown iris about 3, since brown keeps a lot of green; the floor keeps
    // near-black noise from counting.
    static float minivuRedness(float3 c) {
        return c.r / max(max(c.g, c.b), 0.005);
    }

    // circle: centre x, y and radius in working pixels, feather fraction.
    static float minivuRadial(float2 p, float4 circle) {
        float d = distance(p, circle.xy);
        return 1.0 - smoothstep(circle.z * (1.0 - circle.w), circle.z, d);
    }

    // Red pixels inside the spot's circle, softly: the raw pupil mask.
    // thresholds: redness where the mask starts and where it is full.
    [[stitchable]] float4 minivuRedEyeMask(coreimage::sample_t s, float4 circle, float2 thresholds,
                                          coreimage::destination dest) {
        if (s.a <= 0.0) { return float4(0.0); }
        float red = smoothstep(thresholds.x, thresholds.y, minivuRedness(s.rgb / s.a));
        return float4(red * minivuRadial(dest.coord(), circle));
    }

    // The correction. `smooth` is the raw mask blurred: high inside the red
    // pupil, low on a stray red pixel, so specks elsewhere in the circle are
    // left alone while the pupil's edge is corrected softly. Each pixel is
    // also gated by its own redness, which keeps the white catchlight, the
    // iris and the skin exactly as they were. The pupil becomes a neutral
    // grey at the level of its green and blue channels, which the flash's
    // red reflection doesn't reach: they still carry the pupil's real
    // shading, so it reads as a dark pupil with depth rather than a black
    // disc.
    // params: mask gain, strength, darkening of the grey, unused.
    [[stitchable]] float4 minivuRedEyeFix(coreimage::sample_t s, coreimage::sample_t smooth, float4 circle,
                                         float2 thresholds, float4 params, coreimage::destination dest) {
        if (s.a <= 0.0) { return s; }
        float3 c = s.rgb / s.a;
        float gate = smoothstep(thresholds.x, thresholds.y, minivuRedness(c));
        float m = clamp(smooth.r * params.x, 0.0, 1.0) * gate * minivuRadial(dest.coord(), circle);
        float y = max(min(c.g, c.b), 0.0) * params.z;
        float3 o = mix(c, float3(y), clamp(m * params.y, 0.0, 1.0));
        return float4(o * s.a, s.a);
    }
    """

    /// Compiled once, on first use; see `ToneKernels.kernels` for why a
    /// failure is fatal.
    private static let kernels: [String: CIKernel] = {
        do {
            let list = try CIKernel.kernels(withMetalString: source)
            return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        } catch {
            fatalError("Retouch kernels failed to compile: \(error)")
        }
    }()

    private static func kernel(_ name: String) -> CIKernel {
        guard let kernel = kernels[name] else { fatalError("Retouch kernel \(name) is missing") }
        return kernel
    }

    /// `patch` in place of `prev` inside `rect` (whole pixels), over `extent`.
    static func paste(_ patch: CIImage, rect: CGRect, over prev: CIImage, extent: CGRect) -> CIImage {
        let vector = CIVector(x: rect.minX, y: rect.minY, z: rect.maxX, w: rect.maxY)
        return kernel("minivuRetouchPaste").apply(extent: extent, roiCallback: { index, r in
            index == 1 ? r.intersection(rect) : r
        }, arguments: [prev, patch, vector]) ?? prev
    }

    static func clone(destination: CIImage, source: CIImage, mask: CIImage, opacity: Double, extent: CGRect) -> CIImage {
        kernel("minivuRetouchClone").apply(extent: extent, roiCallback: { _, r in r },
                                           arguments: [destination, source, mask, Float(opacity)]) ?? destination
    }

    /// 1 where the brush doesn't reach, 0 under it; infinite, like the
    /// clamped image it weights.
    static func fillWeight(_ mask: CIImage) -> CIImage {
        kernel("minivuRetouchFillWeight").apply(extent: .infinite, roiCallback: { _, r in r }, arguments: [mask])
            ?? mask
    }

    static func weighted(_ image: CIImage, by weight: CIImage) -> CIImage {
        kernel("minivuRetouchWeighted").apply(extent: .infinite, roiCallback: { _, r in r },
                                              arguments: [image, weight]) ?? image
    }

    static func heal(destination: CIImage, source: CIImage, sourceNumerator: CIImage,
                     destinationNumerator: CIImage, denominator: CIImage, mask: CIImage, opacity: Double,
                     extent: CGRect) -> CIImage {
        kernel("minivuRetouchHeal").apply(extent: extent, roiCallback: { _, r in r }, arguments: [
            destination, source, sourceNumerator, destinationNumerator, denominator, mask, Float(opacity),
        ]) ?? destination
    }

    static func redEyeMask(_ image: CIImage, circle: CIVector, thresholds: CIVector, extent: CGRect) -> CIImage {
        kernel("minivuRedEyeMask").apply(extent: extent, roiCallback: { _, r in r },
                                         arguments: [image, circle, thresholds]) ?? image
    }

    static func redEyeFix(_ image: CIImage, smoothMask: CIImage, circle: CIVector, thresholds: CIVector,
                          params: CIVector, extent: CGRect) -> CIImage {
        kernel("minivuRedEyeFix").apply(extent: extent, roiCallback: { _, r in r },
                                        arguments: [image, smoothMask, circle, thresholds, params]) ?? image
    }
}
