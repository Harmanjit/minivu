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
