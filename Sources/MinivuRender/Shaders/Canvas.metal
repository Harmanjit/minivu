#include "Common.h"

// The image canvas (DESIGN.md 4.4).
//
// One full-screen triangle. For every screen pixel the fragment shader
// maps the pixel into the image with an affine map built on the CPU from
// the zoom and pan, and samples the mipmapped texture there. The work is
// proportional to screen pixels, never image pixels.
//
// Inside the magnifier circle a second map (more zoomed) is used instead,
// so the loupe costs nothing extra.

struct CanvasUniforms {
    float4 imageU;      // u = dot(imageU.xy, p) + imageU.z
    float4 imageV;      // v = dot(imageV.xy, p) + imageV.z
    float4 loupeU;
    float4 loupeV;
    float4 background;  // linear rgb
    float4 loupe;       // centre.xy (px), radius (px), border width (px)
    float4 params;      // display headroom, content headroom, texels per screen px (image), (loupe)
    float4 flags;       // hasImage, loupe, nearest filtering when magnified, checkerboard
};

struct CanvasVertex {
    float4 position [[position]];
};

vertex CanvasVertex canvasVertex(uint vid [[vertex_id]]) {
    // A triangle that covers the viewport: (-1,-1) (3,-1) (-1,3).
    float2 p = float2((vid << 1) & 2, vid & 2);
    CanvasVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// Rolls off values above `knee` so they approach the display headroom
// instead of clipping. Hue is kept by scaling all channels by the same
// factor, driven by the largest one.
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
static float3 toneMapToHeadroom(float3 c, float displayHeadroom, float contentHeadroom) {
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

fragment float4 canvasFragment(CanvasVertex in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               constant CanvasUniforms &u [[buffer(0)]])
{
    float3 p = float3(in.position.xy, 1.0);
    float3 bg = u.background.rgb;
    if (u.flags.x < 0.5) { return float4(bg, 1.0); }

    float d = distance(p.xy, u.loupe.xy);
    bool inLoupe = u.flags.y > 0.5 && d < u.loupe.z;
    float2 uv = inLoupe ? float2(dot(u.loupeU.xyz, p), dot(u.loupeV.xyz, p))
                        : float2(dot(u.imageU.xyz, p), dot(u.imageV.xyz, p));
    float texelsPerPixel = inLoupe ? u.params.w : u.params.z;

    float3 color;
    if (any(uv < 0.0) || any(uv > 1.0)) {
        color = bg;
    } else {
        // Level of detail from how many texels land on one screen pixel.
        float lod = max(0.0, log2(max(texelsPerPixel, 1e-6)));
        bool nearest = u.flags.z > 0.5 && texelsPerPixel < 0.5;
        constexpr sampler smooth(coord::normalized, address::clamp_to_edge,
                                 filter::linear, mip_filter::linear);
        constexpr sampler blocky(coord::normalized, address::clamp_to_edge,
                                 mag_filter::nearest, min_filter::linear, mip_filter::linear);
        float4 c = nearest ? image.sample(blocky, uv, level(lod)) : image.sample(smooth, uv, level(lod));

        float3 under = bg;
        if (u.flags.w > 0.5 && c.a < 0.999) {
            // Checkerboard behind transparency, 8 screen points per square.
            float2 cell = floor(p.xy / 16.0);
            float check = fmod(cell.x + cell.y, 2.0);
            under = mix(float3(0.8), float3(0.55), check);
        }
        // Textures are premultiplied.
        color = c.rgb + under * (1.0 - c.a);
        color = toneMapToHeadroom(color, u.params.x, u.params.y);
    }

    if (inLoupe && d > u.loupe.z - u.loupe.w) {
        // A light ring so the loupe reads against any image.
        color = mix(color, float3(0.9), 0.85);
    }
    return float4(color, 1.0);
}
