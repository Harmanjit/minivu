#include <metal_stdlib>
using namespace metal;

// Shared by every shader file. At runtime the sources are concatenated
// with this header pasted in once at the top (see GPU.loadLibrary).

// sRGB / Display P3 transfer function, for the rare kernel that sees
// encoded values. Textures stored as *_srgb formats decode automatically.
inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

inline float3 linearToSRGB(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

// Rec. 709 / sRGB luminance weights, valid in linear light.
inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Rolls off values above `knee` so they approach the display headroom
// instead of clipping. Hue is kept by scaling all channels by the same
// factor, driven by the largest one.
//
// Shared by the canvas and the slideshow, so both show HDR the same way. It
// lives here rather than in Canvas.metal because make_app.sh may compile
// each shader file on its own, where one file can't see another's functions.
//
// What the curve guarantees (HeadroomToneMap in CanvasRenderer.swift is a
// line-for-line copy that the tests check):
// - Content that fits the display (every SDR image: headroom 1) passes
//   through untouched.
// - Below the knee nothing changes. The knee is 3/4 of the display
//   headroom, so on any screen with 1.33x headroom or more, SDR white and
//   everything under it keep their exact values; only an SDR screen has to
//   give up the top quarter of its range to fit the highlights in.
// - Above it the curve is continuous, rises monotonically with a slope
//   between 0 and 1 (it never brightens and never adds contrast), and
//   reaches exactly the display headroom at the content headroom. Anything
//   brighter than the content claims to be is held there.
inline float3 toneMapToHeadroom(float3 c, float displayHeadroom, float contentHeadroom) {
    float peak = max(c.r, max(c.g, c.b));
    if (contentHeadroom <= displayHeadroom || peak <= 0.0) { return c; }
    float knee = displayHeadroom * 0.75;
    if (peak <= knee) { return c; }
    // Map [knee, contentHeadroom] onto [knee, displayHeadroom] with a
    // smooth curve whose slope starts at 1 (no visible kink at the knee).
    float range = displayHeadroom - knee;
    float x = (peak - knee) / range;
    float xMax = (contentHeadroom - knee) / range;
    // Extended Reinhard: y = x (1 + x/xMax^2) / (1 + x), y(xMax) = 1.
    float y = x * (1.0 + x / (xMax * xMax)) / (1.0 + x);
    float mapped = knee + range * min(y, 1.0);
    return c * (mapped / peak);
}
