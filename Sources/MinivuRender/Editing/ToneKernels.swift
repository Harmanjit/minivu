import Foundation
import CoreImage

/// The two tone operations Core Image has no fitting filter for, as Core
/// Image kernels written in Metal and compiled when first used.
///
/// **Why not built-ins.** `CIHighlightShadowAdjust` brightens HDR
/// highlights when asked to darken highlights (measured: 2.0 becomes 2.43),
/// `CIGammaAdjust` clamps negative (wide-gamut) components to zero, and
/// `CIColorCurves` clamps everything to its table's domain, which flattens
/// every highlight above SDR white. These kernels define what happens to
/// extended-range values instead.
///
/// **Why Core Image kernels, not compute kernels.** Colour kernels join
/// Core Image's own: the whole chain of colour operations compiles into one
/// GPU pass with no intermediate texture. Measured on M4, rendering a
/// 3024 x 2016 half-float image with its mip chain: 4.8 ms with no operation,
/// 5.8 ms with the table kernel. A `CIImageProcessorKernel` (which always
/// needs textures of its own) measured about 6 ms for itself alone.
///
/// **Why the source lives here.** `GPU` compiles every `.metal` file in
/// Shaders into one plain Metal library, and Core Image kernels need Core
/// Image's headers and `[[stitchable]]` functions, which that library can't
/// contain. `CIKernel.kernels(withMetalString:)` compiles them at runtime
/// (about 100 ms, once per launch) on any Mac whose GPU supports dynamic
/// libraries, which every Apple Silicon Mac does.
enum ToneKernels {
    static let prelude = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // Display P3 uses the sRGB transfer curve. Mirrored for negative values,
    // as extended colour spaces define it, so out-of-gamut colours survive.
    static float3 minivuEncode(float3 c) {
        float3 a = abs(c);
        float3 e = select(1.055 * pow(a, float3(1.0 / 2.4)) - 0.055, a * 12.92, a <= 0.0031308);
        return sign(c) * e;
    }

    static float3 minivuDecode(float3 e) {
        float3 a = abs(e);
        float3 c = select(pow((a + 0.055) / 1.055, float3(2.4)), a / 12.92, a <= 0.04045);
        return sign(e) * c;
    }

    """

    static let lightingSource = """
    // params: brightness offset, contrast factor, 1 / gamma, shadows (-1...1).
    [[stitchable]] float4 minivuLighting(coreimage::sample_t s, float4 params, float highlights) {
        if (s.a <= 0.0) { return s; }
        float3 c = s.rgb / s.a;

        // Shadows and highlights: an exposure change weighted by how dark or
        // bright the pixel is, up to 1.5 stops. Multiplying all three channels
        // keeps hue and saturation; black stays black. Highlights reach all
        // the way up, so darkening highlights also recovers HDR highlights.
        float y = max(dot(c, float3(0.2289746, 0.6917385, 0.0792869)), 0.0);
        float l = minivuEncode(float3(y)).x;
        float stops = params.w * (1.0 - smoothstep(0.0, 0.75, l)) + highlights * smoothstep(0.25, 1.0, l);
        c *= pow(2.0, 1.5 * stops);

        // Brightness, contrast and gamma on the encoded scale, where 0.5 is a
        // middle grey; none of them clamps.
        float3 e = minivuEncode(c);
        e += params.x;
        e = (e - 0.5) * params.y + 0.5;
        e = sign(e) * pow(abs(e), float3(params.z));
        return float4(minivuDecode(e) * s.a, s.a);
    }
    """

    static let toneTableSource = """
    // A per-channel tone table (curves, levels) on the encoded scale, straight
    // lines beyond it (see ToneTable).
    [[stitchable]] float4 minivuToneTable(coreimage::sampler src, coreimage::sampler table, float size,
                                         float3 lowValue, float3 highValue, float3 lowSlope, float3 highSlope) {
        float4 s = src.sample(src.coord());
        if (s.a <= 0.0) { return s; }
        float3 e = minivuEncode(s.rgb / s.a);
        float3 x = clamp(e, 0.0, 1.0) * (size - 1.0) + 0.5;
        float3 inside = float3(table.sample(table.transform(float2(x.r, 0.5))).r,
                               table.sample(table.transform(float2(x.g, 0.5))).g,
                               table.sample(table.transform(float2(x.b, 0.5))).b);
        float3 below = lowValue + e * lowSlope;
        float3 above = highValue + (e - 1.0) * highSlope;
        float3 o = select(select(inside, above, e > 1.0), below, e < 0.0);
        return float4(minivuDecode(o) * s.a, s.a);
    }
    """

    /// Compiled once, on first use. A Mac that can't compile them can't run
    /// Metal at all (see `GPU.shared`), so failing loudly is right.
    ///
    /// Each kernel is compiled into a library of its own. Two kernels from
    /// one runtime library that first render at the same moment on two
    /// threads (a preview and a full-resolution render) can swap for the rest
    /// of the process; see `EffectsKernels.kernel(_:)`.
    private static let kernels: [String: CIKernel] = {
        do {
            let list = try [lightingSource, toneTableSource].flatMap {
                try CIKernel.kernels(withMetalString: prelude + $0)
            }
            return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        } catch {
            fatalError("Edit kernels failed to compile: \(error)")
        }
    }()

    /// Brightness, contrast, gamma, shadows and highlights, as
    /// `EditOperation.lighting` defines them:
    /// - brightness -1...1 adds up to half the encoded range (+1 lifts black
    ///   to a middle grey);
    /// - contrast -1...1 scales the distance from middle grey by 3^contrast
    ///   (a third to three times);
    /// - gamma 0.1...5 raises encoded values to 1/gamma;
    /// - shadows and highlights -1...1 are up to 1.5 stops darker or
    ///   brighter, fading out towards the other end of the tonal range.
    static func lighting(_ image: CIImage, brightness: Double, contrast: Double, gamma: Double,
                         shadows: Double, highlights: Double) -> CIImage {
        guard let kernel = kernels["minivuLighting"] as? CIColorKernel else { return image }
        let g = gamma.isFinite && gamma > 0 ? min(max(gamma, 0.1), 5) : 1
        let params = CIVector(x: CGFloat(clampUnit(brightness) * 0.5), y: CGFloat(pow(3, clampUnit(contrast))),
                              z: CGFloat(1 / g), w: CGFloat(clampUnit(shadows)))
        return kernel.apply(extent: image.extent, arguments: [image, params, clampUnit(highlights)]) ?? image
    }

    /// Applies a curves or levels table.
    static func toneTable(_ image: CIImage, _ table: ToneTable) -> CIImage {
        guard let kernel = kernels["minivuToneTable"] else { return image }
        let data = table.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the table holds numbers, not colours, and must
        // reach the kernel exactly as written.
        let tableImage = CIImage(bitmapData: data, bytesPerRow: table.size * 16,
                                 size: CGSize(width: table.size, height: 1), format: .RGBAf, colorSpace: nil)
        let tableExtent = tableImage.extent
        func vector(_ v: SIMD3<Float>) -> CIVector { CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z)) }
        return kernel.apply(extent: image.extent,
                            roiCallback: { index, rect in index == 0 ? rect : tableExtent },
                            arguments: [image, tableImage, Float(table.size), vector(table.lowValue),
                                        vector(table.highValue), vector(table.lowSlope), vector(table.highSlope)])
            ?? image
    }

    private static func clampUnit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, -1), 1) : 0
    }
}
