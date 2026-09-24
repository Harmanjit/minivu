import Foundation
import CoreImage
import Metal

/// Mirror of `OilPaintUniforms` in EffectsOilPaint.metal.
struct OilPaintUniforms {
    var origins = SIMD4<Float>()
    var tensorOrigin = SIMD4<Float>()
    var params = SIMD4<Float>()
    var config = SIMD4<Float>()
    var sourceBounds = SIMD4<Float>()
}

/// Oil painting as a node in a Core Image graph: an anisotropic Kuwahara
/// filter (EffectsOilPaint.metal explains the algorithm) wrapped in a
/// `CIImageProcessorKernel`, like `ResampleKernel`.
///
/// Why a compute kernel: each output pixel gathers eight weighted sums over
/// a variable ellipse of up to (4r + 1)² pixels, which a Core Image kernel
/// (a fixed-size function with no loops over the input) can't express.
///
/// The graph around it: the image is encoded to the sRGB curve, its
/// structure tensor is computed and smoothed by Core Image kernels, and both
/// reach the kernel as textures; the result is decoded back to linear.
/// Core Image may render in tiles, so `roi` widens each request by the
/// largest ellipse the kernel can read.
///
/// **Scale.** The radius is in full-resolution pixels, multiplied by the
/// working scale, so the proxy shows the same strokes smaller.
final class OilPaintKernel: CIImageProcessorKernel {
    /// Stroke sharpness: how strongly a sector's variance keeps it out of
    /// the blend. 8 is the paper's choice; lower blurs across edges.
    static let sharpness: Float = 8
    /// How far anisotropy may stretch the ellipse (the paper's alpha): at 1
    /// a perfectly straight edge gives semi-axes of twice and half the
    /// radius, a 4:1 ellipse along it.
    static let anisotropyAlpha: Float = 1
    /// Below this working radius the filter can't find sectors (a disc of
    /// two pixels), so it runs at this radius.
    static let minimumWorkingRadius = 1.5

    static func paint(_ image: CIImage, _ paint: OilPaint, scale: Double) -> CIImage {
        let extent = image.extent
        let radius = max(EffectsMath.clamp(paint.radius, OilPaint.radiusRange) * scale, minimumWorkingRadius)
        let levels = min(max(paint.levels, OilPaint.levelsRange.lowerBound), OilPaint.levelsRange.upperBound)
        let encoded = image.clampedToExtent().applyingFilter("CILinearToSRGBToneCurve")
        guard let tensor = EffectsKernels.structureTensor(encoded, scale: scale)?.cropped(to: extent) else { return image }
        let arguments: [String: Any] = ["radius": radius, "levels": levels, "extent": CIVector(cgRect: extent)]
        do {
            // A pixel wider than the image, so the crop below is a real one
            // (see "Extents" on `EffectsKernels`).
            return try apply(withExtent: extent.insetBy(dx: -1, dy: -1), inputs: [encoded.cropped(to: extent), tensor],
                             arguments: arguments)
                .applyingFilter("CISRGBToneCurveToLinear")
                .cropped(to: extent)
        } catch {
            // Only malformed arguments throw, which the code above can't make.
            return image
        }
    }

    // MARK: - CIImageProcessorKernel

    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    /// The colours within the largest ellipse (twice the radius along an
    /// edge) of every output pixel, limited to the image, whose edge pixels
    /// the kernel repeats; the tensor only at the pixel itself.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard input == 0 else { return outputRect }
        let radius = (arguments?["radius"] as? Double) ?? 0
        let reach = ceil(2 * radius) + 1
        let expanded = outputRect.insetBy(dx: -reach, dy: -reach)
        guard let extent = (arguments?["extent"] as? CIVector)?.cgRectValue else { return expanded }
        return expanded.intersection(extent)
    }

    override class func process(with inputs: [any CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: any CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 2, let source = inputs[0].metalTexture, let tensor = inputs[1].metalTexture,
              let destination = output.metalTexture, let commands = output.metalCommandBuffer,
              let radius = arguments?["radius"] as? Double, let levels = arguments?["levels"] as? Int,
              let extent = (arguments?["extent"] as? CIVector)?.cgRectValue else {
            throw GPUError.allocationFailed("oil paint textures")
        }
        let gpu = GPU.shared
        let pipeline = try gpu.computePipeline("effectsOilPaint")
        // Sector overlap as the reference implementation sets it: zeta falls
        // with the radius so the centre's overlap stays about two pixels
        // wide; eta puts each sector's edge at 3π/16 off its axis.
        let zeta = 2 / Float(max(radius, 2))
        let envelope = Float.pi * 3 / 16
        let eta = (zeta + cos(envelope)) / (sin(envelope) * sin(envelope))
        var uniforms = OilPaintUniforms(
            origins: SIMD4(Float(inputs[0].region.minX), Float(inputs[0].region.maxY),
                           Float(output.region.minX), Float(output.region.maxY)),
            tensorOrigin: SIMD4(Float(inputs[1].region.minX), Float(inputs[1].region.maxY), 0, 0),
            params: SIMD4(Float(radius), zeta, eta, sharpness),
            config: SIMD4(Float(levels), anisotropyAlpha, 0, 0),
            // Where the picture itself sits in the colour texture. macOS 27
            // hands the kernel a region a pixel larger on every side than
            // the one `roi` asked for, and fills that ring with transparent
            // black rather than rendered content: clamping a sample to the
            // texture repeats the ring and the effect comes out with a
            // see-through fringe. Clamping to these bounds repeats the
            // picture's own edge, which is what the kernel documents.
            sourceBounds: SIMD4(Float(extent.minX - inputs[0].region.minX),
                                Float(inputs[0].region.maxY - extent.maxY),
                                Float(extent.maxX - 1 - inputs[0].region.minX),
                                Float(inputs[0].region.maxY - 1 - extent.minY)))
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw GPUError.allocationFailed("an oil paint encoder")
        }
        encoder.label = "minivu oil paint"
        encoder.setTexture(source, index: 0)
        encoder.setTexture(tensor, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<OilPaintUniforms>.stride, index: 0)
        gpu.dispatch(pipeline, size: MTLSize(width: destination.width, height: destination.height, depth: 1),
                     encoder: encoder)
        encoder.endEncoding()
    }
}
