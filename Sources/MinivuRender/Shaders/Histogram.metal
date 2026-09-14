#include "Common.h"

// GPU histogram (Histogram.swift). The approach is Harman's Latent
// HistogramCalculator (GPLv3), extended with a luminance channel and an
// "above SDR white" counter.
//
// The naive kernel, every thread atomically incrementing one of a thousand
// global counters, would serialise millions of threads onto a handful of
// memory locations. Instead each threadgroup builds a private histogram in
// on-chip threadgroup memory and merges it into the global one once, at
// the end: a few thousand global atomic additions instead of millions.
//
// Layout of the result buffer (UInt32 each):
//   red 0..255, green 256..511, blue 512..767, luminance 768..1023,
//   1024: pixels brighter than SDR white (any channel above 1.0).

constant uint kHistogramBins = 256;
constant uint kHistogramSlots = 4 * 256 + 1;
constant uint kHistogramAboveWhite = 4 * 256;

/// Display P3 luminance weights, since both texture kinds hold Display P3
/// primaries (linear light). They sum to one, so a grey stays its own value.
inline float histogramLuminance(float3 c) {
    return dot(c, float3(0.2289746, 0.6917385, 0.0792869));
}

inline uint histogramBin(float encoded) {
    return uint(clamp(encoded, 0.0, 1.0) * float(kHistogramBins - 1) + 0.5);
}

kernel void computeHistogram(
    texture2d<float, access::read> image      [[texture(0)]],
    device atomic_uint *histogram             [[buffer(0)]],
    constant uint &lod                        [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]],
    uint tindex                               [[thread_index_in_threadgroup]],
    uint2 threadsPerGroup                     [[threads_per_threadgroup]])
{
    threadgroup atomic_uint local[kHistogramSlots];
    uint stride = threadsPerGroup.x * threadsPerGroup.y;

    // Zero this threadgroup's histogram. The threads share the work (each
    // takes every stride-th slot), which works for any group size,
    // including groups smaller than the slot count.
    for (uint i = tindex; i < kHistogramSlots; i += stride) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Threads past the image's edge still take part in both barriers:
    // skipping one would deadlock the group.
    if (gid.x < image.get_width(lod) && gid.y < image.get_height(lod)) {
        // Both formats read back linear light: bgra8Unorm_srgb decodes on
        // read, rgba16Float stores extended linear Display P3. The bins are
        // display-referred, so the sRGB/P3 transfer curve goes back on, and
        // anything above white lands in the top bin (it would clip in SDR).
        float3 linear = image.read(gid, lod).rgb;
        float3 clipped = clamp(linear, 0.0, 1.0);
        float3 encoded = linearToSRGB(clipped);
        float luma = linearToSRGB(float3(histogramLuminance(clipped))).r;

        atomic_fetch_add_explicit(&local[histogramBin(encoded.r)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[kHistogramBins + histogramBin(encoded.g)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[2 * kHistogramBins + histogramBin(encoded.b)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[3 * kHistogramBins + histogramBin(luma)], 1u, memory_order_relaxed);
        // A hair above 1.0 is rounding in an SDR image drawn into float
        // storage, not a highlight.
        if (max(linear.r, max(linear.g, linear.b)) > 1.002) {
            atomic_fetch_add_explicit(&local[kHistogramAboveWhite], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Merge into the global histogram, skipping the (many) empty slots.
    for (uint i = tindex; i < kHistogramSlots; i += stride) {
        uint count = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (count > 0) {
            atomic_fetch_add_explicit(&histogram[i], count, memory_order_relaxed);
        }
    }
}
