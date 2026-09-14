import Foundation
import CoreImage
import Metal

/// Mirror of `ResampleUniforms` in Resample.metal.
struct ResampleUniforms {
    var origins = SIMD4<Float>()
    var params = SIMD4<Float>()
    var config = SIMD4<Float>()
}

/// Resize with one of the eleven filters, as a node in a Core Image graph.
///
/// Core Image has only Lanczos (and affine sampling) built in, so the
/// filters are a Metal compute kernel (Resample.metal) wrapped in a
/// `CIImageProcessorKernel`: Core Image hands it the input as a texture,
/// asks for a region of the output, and the kernel encodes one compute pass
/// into Core Image's own command buffer. The graph around it stays on the
/// GPU and in half-float linear light, so resizing composes with every
/// other operation without a copy to the CPU.
///
/// One application resamples one axis; `resize` chains two (rows, then
/// columns). Core Image may split a large render into tiles and call the
/// kernel once per tile, so the kernel works in Core Image's global pixel
/// coordinates and never assumes it sees the whole image.
final class ResampleKernel: CIImageProcessorKernel {
    /// Most input pixels read for one output pixel in one pass. A tap
    /// window is the filter's support times two, stretched by the
    /// reduction when shrinking, so Lanczos 8 reaches the cap at a 32x
    /// reduction, Lanczos 3 at 85x and Box at 510x. Beyond that the filter
    /// is stretched no further: the result is still smooth, but detail
    /// finer than the output grid can start to alias. The cap bounds the
    /// work per pixel (and so a GPU pass's time, which macOS watches) for
    /// absurd requests like 16000 px to 20 px.
    static let maximumTaps = 512

    /// Resizes `image` (extent at the origin, whole pixels) to exactly
    /// `width` x `height`. An axis whose length doesn't change is left alone:
    /// even at 1:1 a smoothing filter such as B-Spline would soften it.
    static func resize(_ image: CIImage, width: Int, height: Int, filter: ResampleFilter) -> CIImage {
        let inWidth = Int(image.extent.width.rounded())
        let inHeight = Int(image.extent.height.rounded())
        guard width > 0, height > 0, inWidth > 0, inHeight > 0 else { return image }
        var result = image
        if width != inWidth {
            result = pass(result, axis: 0, from: inWidth, to: width, across: inHeight, filter: filter)
        }
        if height != inHeight {
            result = pass(result, axis: 1, from: inHeight, to: height, across: width, filter: filter)
        }
        return result
    }

    /// The scale the filter is evaluated at for a pass from `from` to `to`
    /// pixels: 1 when enlarging (the filter keeps its shape), the reduction
    /// when shrinking (the filter widens), raised where the widened filter
    /// would need more than `maximumTaps`.
    static func filterScale(from: Int, to: Int, support: Double) -> Double {
        let scale = min(Double(to) / Double(from), 1)
        let capped = 2 * support / Double(maximumTaps - 2)
        return max(scale, capped)
    }

    private static func pass(_ image: CIImage, axis: Int, from: Int, to: Int, across: Int,
                             filter: ResampleFilter) -> CIImage {
        let extent = axis == 0
            ? CGRect(x: 0, y: 0, width: to, height: across)
            : CGRect(x: 0, y: 0, width: across, height: to)
        let arguments: [String: Any] = [
            "axis": axis,
            "from": from,
            "to": to,
            "filter": filter.rawValue,
        ]
        do {
            return try apply(withExtent: extent, inputs: [image], arguments: arguments)
        } catch {
            // `apply` only throws for malformed arguments, which the code
            // above can't produce; an unchanged image beats a crash.
            return image
        }
    }

    // MARK: - CIImageProcessorKernel

    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    /// The input rows (or columns) an output rectangle needs: its span
    /// mapped back through the scale and widened by the filter's reach,
    /// limited to the image, since the kernel repeats edge pixels rather
    /// than reading outside.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let p = Parameters(arguments) else { return outputRect }
        let radius = p.support / p.filterScale + 1
        let lo = max(0, floor(Double(p.axis == 0 ? outputRect.minX : outputRect.minY) / p.scale - radius))
        let hi = min(Double(p.from), ceil(Double(p.axis == 0 ? outputRect.maxX : outputRect.maxY) / p.scale + radius))
        guard hi > lo else { return .null }
        return p.axis == 0
            ? CGRect(x: lo, y: outputRect.minY, width: hi - lo, height: outputRect.height)
            : CGRect(x: outputRect.minX, y: lo, width: outputRect.width, height: hi - lo)
    }

    override class func process(with inputs: [any CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: any CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture, let destination = output.metalTexture,
              let commands = output.metalCommandBuffer, let p = Parameters(arguments) else {
            throw GPUError.allocationFailed("resample textures")
        }
        let gpu = GPU.shared
        let pipeline = try gpu.computePipeline("resampleAxis")
        var uniforms = ResampleUniforms(
            origins: SIMD4(Float(input.region.minX), Float(input.region.maxY),
                           Float(output.region.minX), Float(output.region.maxY)),
            params: SIMD4(Float(p.scale), Float(p.filterScale), Float(p.support), Float(p.from)),
            config: SIMD4(Float(p.filter.shaderID), Float(p.axis), 0, 0))
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw GPUError.allocationFailed("a resample encoder")
        }
        encoder.label = "minivu resample \(p.filter.rawValue) axis \(p.axis)"
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResampleUniforms>.stride, index: 0)
        gpu.dispatch(pipeline, size: MTLSize(width: destination.width, height: destination.height, depth: 1),
                     encoder: encoder)
        encoder.endEncoding()
    }

    /// The arguments dictionary, typed.
    private struct Parameters {
        let axis: Int
        let from: Int
        let filter: ResampleFilter
        /// Output pixels per input pixel.
        let scale: Double
        let filterScale: Double
        var support: Double { filter.support }

        init?(_ arguments: [String: Any]?) {
            guard let arguments, let axis = arguments["axis"] as? Int, let from = arguments["from"] as? Int,
                  let to = arguments["to"] as? Int, let name = arguments["filter"] as? String,
                  let filter = ResampleFilter(rawValue: name), from > 0, to > 0 else { return nil }
            self.axis = axis
            self.from = from
            self.filter = filter
            self.scale = Double(to) / Double(from)
            self.filterScale = ResampleKernel.filterScale(from: from, to: to, support: filter.support)
        }
    }
}
