#include "Common.h"

// Slideshow transitions (DESIGN.md 5, Tools).
//
// One full-screen triangle and one fragment shader for all eight
// transitions, chosen by an index: a pipeline per transition would cost
// eight compilations for what is a switch over a few lines each.
//
// Each image is drawn aspect-fit on black inside a rectangle the CPU works
// out per frame (`SlideshowGeometry`). Transitions that move or scale an
// image (slide, push, zoom) do it by moving that rectangle, so the shader
// only decides, per pixel, how much of the new image shows. Work is
// proportional to screen pixels: two trilinear samples at most, and only
// one wherever a pixel is wholly old or wholly new.

struct SlideshowUniforms {
    float4 fromRect;   // origin.xy, size.zw, in drawable pixels, top-left origin
    float4 toRect;
    float4 fromInfo;   // has image, content headroom, mip level, unused
    float4 toInfo;
    float4 params;     // eased progress, transition index, display headroom, 1 when going backward
    float4 view;       // width, height (pixels), soft edge width (pixels), noise cells across the short side
};

struct SlideshowVertex {
    float4 position [[position]];
};

vertex SlideshowVertex slideshowVertex(uint vid [[vertex_id]]) {
    // A triangle that covers the viewport: (-1,-1) (3,-1) (-1,3).
    float2 p = float2((vid << 1) & 2, vid & 2);
    SlideshowVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// One image, aspect-fit inside `rect`, black around it, tone mapped to the
// display on its own terms: an HDR photo and an SDR one fading into each
// other each keep their look instead of sharing one roll-off.
static float3 slideshowSample(texture2d<float> image, float4 rect, float4 info, float2 p, float displayHeadroom) {
    if (info.x < 0.5) { return float3(0.0); }
    float2 uv = (p - rect.xy) / rect.zw;
    if (any(uv < 0.0) || any(uv > 1.0)) { return float3(0.0); }
    constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    // Textures are premultiplied, so over black the colour is just rgb.
    float3 c = image.sample(smooth, uv, level(info.z)).rgb;
    return toneMapToHeadroom(c, displayHeadroom, info.y);
}

// A 2D integer hash (a variant of PCG), stable across GPUs: the dissolve
// pattern is the same on every Mac and in every frame.
static float slideshowHash(float2 cell) {
    uint2 c = uint2(int2(cell) + 65536);
    uint h = c.x * 1664525u + c.y * 1013904223u;
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h) / 4294967295.0;
}

// Smooth value noise in 0...1.
static float slideshowNoise(float2 x) {
    float2 i = floor(x);
    float2 f = fract(x);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = slideshowHash(i);
    float b = slideshowHash(i + float2(1, 0));
    float c = slideshowHash(i + float2(0, 1));
    float d = slideshowHash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fragment float4 slideshowFragment(SlideshowVertex in [[stage_in]],
                                  texture2d<float> fromImage [[texture(0)]],
                                  texture2d<float> toImage [[texture(1)]],
                                  constant SlideshowUniforms &u [[buffer(0)]])
{
    float2 p = in.position.xy;
    float t = u.params.x;
    int kind = int(u.params.y + 0.5);
    float headroom = u.params.z;
    float width = u.view.x;
    float height = u.view.y;
    float soft = u.view.z;
    // Distance along the direction of travel: going forward the new image
    // arrives from the right, going backward from the left.
    float along = u.params.w > 0.5 ? width - p.x : p.x;

    // How much of the new image this pixel shows, 0...1.
    float w;
    switch (kind) {
        case 1: {
            // Fade through black: the old image fades out, then the new in.
            float3 color = t < 0.5
                ? slideshowSample(fromImage, u.fromRect, u.fromInfo, p, headroom) * (1.0 - 2.0 * t)
                : slideshowSample(toImage, u.toRect, u.toInfo, p, headroom) * (2.0 * t - 1.0);
            return float4(color, 1.0);
        }
        case 2:   // slide: the new image's screen moves in over the old
        case 3: { // push: both move (the rectangles say so)
            // Half a pixel either side of the leading edge, for a clean line.
            float edge = (1.0 - t) * width;
            w = smoothstep(edge - 0.5, edge + 0.5, along);
            break;
        }
        case 4: {
            // Wipe: a soft edge crosses the screen. The edge starts a soft
            // width beyond the screen and ends one before it, so t = 0 and
            // t = 1 show one image exactly.
            float edge = (1.0 - t) * (width + 2.0 * soft) - soft;
            w = smoothstep(edge - soft, edge + soft, along);
            break;
        }
        case 6: {
            // Iris: a circle, round on screen whatever its shape, opening
            // from the centre until it clears the corners.
            float d = distance(p, float2(width, height) * 0.5);
            float reach = 0.5 * length(float2(width, height));
            float radius = t * (reach + 2.0 * soft) - soft;
            w = 1.0 - smoothstep(radius - soft, radius + soft, d);
            break;
        }
        case 7: {
            // Dissolve: each pixel turns when progress passes the noise
            // there, with a soft band, so blotches grow and merge. Two
            // octaves of noise sized to the short side, so it looks the
            // same on any screen.
            float2 q = p / min(width, height) * u.view.w;
            float n = 0.65 * slideshowNoise(q) + 0.35 * slideshowNoise(q * 2.7 + 19.0);
            const float band = 0.08;
            w = smoothstep(n - band, n + band, t * (1.0 + 2.0 * band) - band);
            break;
        }
        default:
            // Cross-fade (0), and zoom (5), whose rectangles grow and settle.
            w = t;
            break;
    }

    if (w <= 0.0) { return float4(slideshowSample(fromImage, u.fromRect, u.fromInfo, p, headroom), 1.0); }
    if (w >= 1.0) { return float4(slideshowSample(toImage, u.toRect, u.toInfo, p, headroom), 1.0); }
    float3 a = slideshowSample(fromImage, u.fromRect, u.fromInfo, p, headroom);
    float3 b = slideshowSample(toImage, u.toRect, u.toInfo, p, headroom);
    return float4(mix(a, b, w), 1.0);
}
