#include "Common.h"

// Resize with any of the eleven filters (DESIGN.md 4.7).
//
// A 2D resample with a separable filter is two 1D ones: rows first, then
// columns. `ResampleKernel` (a CIImageProcessorKernel) runs this kernel once
// per axis, so the image is resampled in Core Image's linear working space
// with premultiplied alpha, which is what keeps edges between bright and
// dark or opaque and clear areas from picking up dark fringes.
//
// For each output pixel the kernel finds the centre it maps to in the input,
// reads every input pixel within the filter's reach and averages them with
// the filter's weights. When shrinking, the filter is stretched by the
// reduction (a 4x smaller image averages 4x as many pixels per tap window);
// otherwise detail finer than the new pixel grid would alias into moire.
// Weights are divided by their sum, so a flat area stays exactly flat
// whatever the phase of the sample grid.
//
// Pixels outside the image are its edge pixels repeated, so the borders of
// a resized image keep their colour and stay opaque.

// Mirror of `ResampleUniforms` in ResampleKernel.swift. All float4, so the
// Swift and Metal layouts can't drift apart through padding.
struct ResampleUniforms {
    // Core Image coordinates of the input texture's left and top edges, then
    // the output texture's (minX, maxY, minX, maxY). Core Image hands a
    // processor kernel its textures top row first.
    float4 origins;
    // Output pixels per input pixel along the axis; the scale the filter is
    // evaluated at (1 when enlarging, the reduction when shrinking, possibly
    // raised to cap the taps); the filter's support; the input image's length
    // along the axis in pixels.
    float4 params;
    // Filter id, axis (0 rows, 1 columns), unused, unused.
    float4 config;
};

static float resampleSinc(float x) {
    if (x < 1e-6) { return 1.0; }
    float px = M_PI_F * x;
    return sin(px) / px;
}

// Mitchell and Netravali's cubic family (see ResampleFilter.cubic).
static float resampleCubic(float t, float b, float c) {
    if (t < 1.0) {
        return ((12.0 - 9.0 * b - 6.0 * c) * t * t * t + (-18.0 + 12.0 * b + 6.0 * c) * t * t + (6.0 - 2.0 * b)) / 6.0;
    }
    if (t < 2.0) {
        return ((-b - 6.0 * c) * t * t * t + (6.0 * b + 30.0 * c) * t * t + (-12.0 * b - 48.0 * c) * t
                + (8.0 * b + 24.0 * c)) / 6.0;
    }
    return 0.0;
}

// Same functions, same ids as ResampleFilter.weight and .shaderID in Swift.
static float resampleWeight(uint filter, float x) {
    float t = abs(x);
    switch (filter) {
    case 0:  // Box
        return t <= 0.5 ? 1.0 : 0.0;
    case 1:  // Triangle
        return max(0.0, 1.0 - t);
    case 2:  // Hermite
        return t < 1.0 ? (2.0 * t - 3.0) * t * t + 1.0 : 0.0;
    case 3:  // Bell (quadratic B-spline)
        if (t < 0.5) { return 0.75 - t * t; }
        if (t < 1.5) { return 0.5 * (t - 1.5) * (t - 1.5); }
        return 0.0;
    case 4:  // B-Spline (cubic)
        return resampleCubic(t, 1.0, 0.0);
    case 5:  // Mitchell
        return resampleCubic(t, 1.0 / 3.0, 1.0 / 3.0);
    case 6:  // Catmull-Rom
        return resampleCubic(t, 0.0, 0.5);
    case 7:  // Cosine
        return t < 1.0 ? (cos(M_PI_F * t) + 1.0) * 0.5 : 0.0;
    case 8:  // Quadratic (Dodgson's interpolating quadratic)
        if (t < 0.5) { return 1.0 - 2.0 * t * t; }
        if (t < 1.5) { return (t - 1.0) * (t - 1.5); }
        return 0.0;
    case 9:  // Lanczos 3
        return t < 3.0 ? resampleSinc(t) * resampleSinc(t / 3.0) : 0.0;
    case 10: // Lanczos 8
        return t < 8.0 ? resampleSinc(t) * resampleSinc(t / 8.0) : 0.0;
    default:
        return 0.0;
    }
}

kernel void resampleAxis(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant ResampleUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    uint filter = uint(u.config.x);
    bool vertical = u.config.y > 0.5;
    int srcW = int(src.get_width());
    int srcH = int(src.get_height());

    // Along the axis, in Core Image's global pixel coordinates (pixel i
    // covers [i, i+1), its centre is i + 0.5; rows count up from the bottom).
    float outCentre = vertical ? (u.origins.w - float(gid.y) - 0.5) : (u.origins.z + float(gid.x) + 0.5);
    float centre = outCentre / u.params.x;
    float filterScale = u.params.y;
    float radius = u.params.z / filterScale;
    int length = int(u.params.w);
    int first = int(floor(centre - radius));
    int last = int(ceil(centre + radius));

    // Across the axis the output and input rows (or columns) are the same
    // image rows, just in textures that may start at different places.
    int across = vertical ? int(u.origins.z - u.origins.x) + int(gid.x)
                          : int(u.origins.y - u.origins.w) + int(gid.y);
    across = clamp(across, 0, (vertical ? srcW : srcH) - 1);

    float4 sum = float4(0.0);
    float weights = 0.0;
    for (int i = first; i <= last; i++) {
        float w = resampleWeight(filter, (float(i) + 0.5 - centre) * filterScale);
        if (w == 0.0) { continue; }
        int index = clamp(i, 0, length - 1);   // repeat the edge pixels
        uint2 coord;
        if (vertical) {
            int row = clamp(int(u.origins.y) - 1 - index, 0, srcH - 1);
            coord = uint2(across, row);
        } else {
            int column = clamp(index - int(u.origins.x), 0, srcW - 1);
            coord = uint2(column, across);
        }
        sum += src.read(coord) * w;
        weights += w;
    }
    if (abs(weights) < 1e-6) {
        // Unreachable for these filters (the nearest tap always has weight),
        // but a division by zero would write NaNs that spread through every
        // later operation.
        int index = clamp(int(floor(centre)), 0, length - 1);
        uint2 coord = vertical ? uint2(across, clamp(int(u.origins.y) - 1 - index, 0, srcH - 1))
                               : uint2(clamp(index - int(u.origins.x), 0, srcW - 1), across);
        dst.write(src.read(coord), gid);
        return;
    }
    dst.write(sum / weights, gid);
}
