#include "Common.h"

// Oil painting: an anisotropic Kuwahara filter with polynomial sector
// weights (Kyprianidis, Semmo, Kang and Döllner, "Anisotropic Kuwahara
// Filtering with Polynomial Weighting Functions", 2010), run by
// `OilPaintKernel` (a CIImageProcessorKernel).
//
// Around each pixel an ellipse, stretched along the local edge by how
// strongly the structure tensor says there is one, is mapped to a unit disc
// and split into eight overlapping sectors. Each sector's weighted mean and
// variance are gathered in one pass over the ellipse's pixels, and the
// output is the means blended by how uniform each sector is: sectors that
// straddle an edge have a large variance and count for almost nothing, so
// the edge stays sharp, while in flat or noisy areas all sectors are alike
// and their average smooths the noise away. Pixels are read in pairs
// mirrored through the centre, since a sample's weight for sector k is its
// mirror's weight for sector k + 4.
//
// The image arrives on the sRGB-encoded scale (Core Image converts before
// and after), so the variance that decides what counts as an edge follows
// perceived differences. Values above 1 (HDR) are simply larger numbers.
// After filtering, brightness is quantised into `levels` soft steps, the
// flat patches of paint a brush leaves.

// Mirror of `OilPaintUniforms` in OilPaintKernel.swift, all float4.
struct OilPaintUniforms {
    // Core Image coordinates of the colour texture's left and top edges, then
    // the output texture's (minX, maxY, minX, maxY).
    float4 origins;
    // The tensor texture's left and top edges, unused, unused.
    float4 tensorOrigin;
    // Radius in working pixels, sector overlap zeta, sector envelope eta,
    // sharpness q.
    float4 params;
    // Brightness levels, anisotropy alpha, unused, unused.
    float4 config;
    // The picture's edges inside the colour texture, as texture coordinates:
    // left, top, right, bottom. Samples clamp to these rather than to the
    // texture, which can carry a ring of padding Core Image added.
    float4 sourceBounds;
};

// The eight polynomial sector weights of a point in the unit disc, as two
// groups of four: sectors 0-3 in `a`, 4-7 in `b`. Sector k + 4 is sector k
// turned half way round, so the mirrored point's weights are the same two
// groups swapped.
static void oilSectorWeights(float2 v, float zeta, float eta, thread float4 &a, thread float4 &b) {
    float2 poly = zeta - eta * v * v;
    float2 u = M_SQRT1_2_F * float2(v.x - v.y, v.x + v.y);
    float2 upoly = zeta - eta * u * u;
    // Sectors 0, 2, 4, 6 face +y, -x, -y, +x; 1, 3, 5, 7 the same turned 45°.
    float4 even = max(float4(v.y + poly.x, -v.x + poly.y, -v.y + poly.x, v.x + poly.y), 0.0);
    float4 odd = max(float4(u.y + upoly.x, -u.x + upoly.y, -u.y + upoly.x, u.x + upoly.y), 0.0);
    even *= even;
    odd *= odd;
    a = float4(even.x, odd.x, even.y, odd.y);
    b = float4(even.z, odd.z, even.w, odd.w);
}

kernel void effectsOilPaint(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::read> tensor [[texture(1)]],
                            texture2d<half, access::write> dst [[texture(2)]],
                            constant OilPaintUniforms &u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int srcW = int(src.get_width()), srcH = int(src.get_height());
    // The picture's own edges within the colour texture (see `sourceBounds`):
    // samples stop there, not at the texture's, which can carry a ring of
    // transparent padding Core Image added.
    int loX = max(0, int(u.sourceBounds.x)), loY = max(0, int(u.sourceBounds.y));
    int hiX = min(srcW - 1, int(u.sourceBounds.z)), hiY = min(srcH - 1, int(u.sourceBounds.w));

    // This pixel in Core Image coordinates (y up), then in each texture
    // (top row first).
    int x = int(u.origins.z) + int(gid.x);
    int y = int(u.origins.w) - 1 - int(gid.y);
    int sx = x - int(u.origins.x);
    int sy = int(u.origins.y) - 1 - y;
    int tx = clamp(x - int(u.tensorOrigin.x), 0, int(tensor.get_width()) - 1);
    int ty = clamp(int(u.tensorOrigin.y) - 1 - y, 0, int(tensor.get_height()) - 1);

    // Direction and strength of the local structure.
    float4 t = tensor.read(uint2(tx, ty));
    float E = t.r, F = t.g, G = t.b;
    float root = sqrt(max((E - G) * (E - G) + 4.0 * F * F, 0.0));
    float l1 = 0.5 * (E + G + root), l2 = 0.5 * (E + G - root);
    float2 dir = float2(l1 - E, -F);
    float len = length(dir);
    dir = len > 1e-8 ? dir / len : float2(0.0, 1.0);
    float anisotropy = (l1 + l2) > 1e-8 ? (l1 - l2) / (l1 + l2) : 0.0;

    float radius = u.params.x;
    float alpha = u.config.y;
    float a = radius * clamp((alpha + anisotropy) / alpha, 0.1, 2.0);
    float b = radius * clamp(alpha / (alpha + anisotropy), 0.1, 2.0);
    float c = dir.x, s = dir.y;
    // Offsets (y up) to the unit disc: rotate onto the ellipse's axes, then
    // divide by its semi-axes.
    float2x2 toDisc = float2x2(float2(c / a, -s / b), float2(s / a, c / b));
    int maxX = int(ceil(sqrt(a * a * c * c + b * b * s * s)));
    int maxY = int(ceil(sqrt(a * a * s * s + b * b * c * c)));

    // Per-sector sums, sectors 0-3 in the A vectors and 4-7 in the B ones:
    // weighted red, green, blue and alpha, and weighted squared length of
    // the colour (all a sector's variance needs is the sum over channels). A
    // sample adds to sector k with its weight for k, and its mirror adds
    // with the same weight to sector k + 4, so both groups share one weight
    // total. The centre belongs to every sector a little, so none is empty.
    //
    // Alpha is filtered like the colours rather than taken from the centre:
    // the colours are premultiplied, so a sector's mean colour is only valid
    // with that sector's mean alpha. With the centre's alpha, a half-covered
    // pixel on a transparent edge (a rotation's corners, a PNG's cut-out)
    // took opaque sectors' colour and came out up to two and a half times
    // too bright once unpremultiplied. Alpha counts in the variance too, so a
    // sector across such an edge counts for little, like one across a
    // colour edge.
    float4 cc = src.read(uint2(clamp(sx, loX, hiX), clamp(sy, loY, hiY)));
    float4 rA = float4(cc.r * 0.125), gA = float4(cc.g * 0.125), bA = float4(cc.b * 0.125);
    float4 aA = float4(cc.a * 0.125);
    float4 rB = rA, gB = gA, bB = bA, aB = aA;
    float4 qA = float4(dot(cc, cc) * 0.125), qB = qA;
    float4 weight = float4(0.125);

    float zeta = u.params.y, eta = u.params.z;
    for (int j = 0; j <= maxY; j++) {
        for (int i = -maxX; i <= maxX; i++) {
            if (j == 0 && i <= 0) { continue; }
            float2 v = toDisc * float2(i, j);
            float d2 = dot(v, v);
            if (d2 > 1.0) { continue; }
            float4 wa, wb;
            oilSectorWeights(v, zeta, eta, wa, wb);
            float total = wa.x + wa.y + wa.z + wa.w + wb.x + wb.y + wb.z + wb.w;
            if (total <= 0.0) { continue; }
            float g = exp(-M_PI_F * d2) / total;
            wa *= g;
            wb *= g;
            // Texture rows count down while j counts up.
            float4 up = src.read(uint2(clamp(sx + i, loX, hiX), clamp(sy - j, loY, hiY)));
            float4 lo = src.read(uint2(clamp(sx - i, loX, hiX), clamp(sy + j, loY, hiY)));
            float upq = dot(up, up), loq = dot(lo, lo);
            rA += up.r * wa + lo.r * wb;  rB += up.r * wb + lo.r * wa;
            gA += up.g * wa + lo.g * wb;  gB += up.g * wb + lo.g * wa;
            bA += up.b * wa + lo.b * wb;  bB += up.b * wb + lo.b * wa;
            aA += up.a * wa + lo.a * wb;  aB += up.a * wb + lo.a * wa;
            qA += upq * wa + loq * wb;    qB += upq * wb + loq * wa;
            weight += wa + wb;
        }
    }

    // Blend the sector means, each by how uniform its sector is.
    float q = u.params.w;
    float4 inverse = 1.0 / weight;
    float4 result = float4(0.0);
    float weights = 0.0;
    for (int group = 0; group < 2; group++) {
        float4 mr = (group == 0 ? rA : rB) * inverse;
        float4 mg = (group == 0 ? gA : gB) * inverse;
        float4 mb = (group == 0 ? bA : bB) * inverse;
        float4 ma = (group == 0 ? aA : aB) * inverse;
        float4 mq = (group == 0 ? qA : qB) * inverse;
        float4 sigma2 = abs(mq - (mr * mr + mg * mg + mb * mb + ma * ma));
        float4 wk = 1.0 / (1.0 + pow(255.0 * sigma2, float4(0.5 * q)));
        result += float4(dot(mr, wk), dot(mg, wk), dot(mb, wk), dot(ma, wk));
        weights += wk.x + wk.y + wk.z + wk.w;
    }
    // A blend of premultiplied means with weights summing to one is itself
    // premultiplied.
    float4 painted = result / max(weights, 1e-8);

    // Soft brightness steps: a shift of the encoded colour to the nearest of
    // `levels` luminance steps, eased across the middle third of each step.
    float levels = u.config.x;
    if (levels > 0.0 && painted.a > 0.0) {
        float3 colour = painted.rgb / painted.a;
        float lum = dot(colour, float3(0.2126, 0.7152, 0.0722));
        float scaled = lum * levels;
        float base = floor(scaled);
        float stepped = (base + smoothstep(0.33, 0.67, scaled - base)) / levels;
        // A channel at or above zero stays there: the shift darkens a pure
        // colour's other channels to nothing, not below it.
        colour = max(colour + (stepped - lum), min(colour, 0.0));
        painted.rgb = colour * painted.a;
    }
    painted.a = clamp(painted.a, 0.0, 1.0);
    dst.write(half4(painted), gid);
}
