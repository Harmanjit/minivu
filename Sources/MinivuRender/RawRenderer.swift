import Foundation
import CoreImage
import Metal
import MinivuCore

/// Renders camera RAW files from their sensor data, on the GPU, straight
/// into a mipmapped texture.
///
/// ImageIO shows a RAW file through the JPEG preview the camera embedded in
/// it, which is fast but is only as large as the camera made it (many
/// bodies store 1616 px or less) and is always SDR. A real render goes
/// through Apple's RAW engine: `CIRAWFilter` builds the demosaic and
/// development graph, and a Core Image context on our own Metal queue
/// renders it into a private texture. The pixels never visit the CPU.
///
/// Measured on M4 (24 MP Nikon NEFs, filter setup + render + mipmaps; the
/// `RawBenchmark` test): the first render in a process 380 ms, each file's
/// first render 230-290 ms, a second render of it 200-250 ms, with extended
/// dynamic range 210-265 ms, half size 130-145 ms. The embedded full-size
/// preview decodes and uploads in 140-260 ms and has the camera's own
/// colours, which is why it stays the default.
///
/// Memory is the cost. The engine's working buffers take the process
/// footprint up by about 1.6 GB for one full-size render and 0.8 GB for a
/// screen-sized one (3.5 GB and 1.1 GB with three at once), and Core Image
/// keeps them for about five seconds after the last render before letting
/// go (`clearCaches` doesn't release them sooner). So `ImageLoader` runs
/// one render at a time, in a slot of its own, prefetches renders only for
/// the nearest RAW neighbour, and on Macs with 8 GB or less none at all.
public enum RawRenderer {
    /// Apple's RAW engine at full extended dynamic range puts highlights up
    /// to about 2x SDR white (measured peaks of 2.05, 2.13 and 2.52 on the
    /// Nikon test files; darker scenes stay below 1). So a requested
    /// headroom h maps to `extendedDynamicRangeAmount` = log2(h): 1 is SDR,
    /// 2 is the most the engine offers.
    public static let maximumHeadroom: Float = 2

    /// The render as asked for, with the RAW metadata's orientation applied.
    ///
    /// - Parameters:
    ///   - maxPixelSize: long edge to render at, nil for the sensor's full
    ///     size. Smaller renders use the engine's own scale factor, which
    ///     skips work rather than resampling a full render.
    ///   - hdr: keep highlights above SDR white, in a half-float texture.
    ///     Otherwise the result is 8-bit Display P3, like any SDR photo.
    ///   - headroom: with `hdr`, how far above SDR white highlights may
    ///     reach, 1...`maximumHeadroom` (see there).
    ///
    /// Synchronous and slow (a few hundred milliseconds): call it from a
    /// background task. Throws `DecodeError.noImage` when the RAW engine
    /// doesn't support the camera, so callers can fall back to ImageIO.
    public static func render(url: URL, maxPixelSize: Int?, hdr: Bool, headroom: Float,
                              gpu: GPU = .shared) throws -> ImageTexture {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.noImage(url) }
        let native = filter.nativeSize
        let orientedSize = filter.orientation.swapsAxes
            ? CGSize(width: native.height, height: native.width) : native
        let longest = max(orientedSize.width, orientedSize.height)
        guard longest > 0 else { throw DecodeError.noImage(url) }

        let scale = renderScale(longestEdge: Int(longest), maxPixelSize: maxPixelSize)
        // Draft mode trades demosaic quality for speed; a viewer that is
        // about to show 100% wants the real thing.
        filter.isDraftModeEnabled = false
        filter.scaleFactor = Float(scale)
        let amount = hdr ? edrAmount(forHeadroom: headroom) : 0
        filter.extendedDynamicRangeAmount = amount
        // The filter's output is already oriented (`orientation` defaults
        // to the file's own), so the texture comes out upright.
        guard let output = filter.outputImage, !output.extent.isInfinite else { throw DecodeError.noImage(url) }

        let extent = output.extent
        let width = max(1, Int(extent.width.rounded()))
        let height = max(1, Int(extent.height.rounded()))
        guard width <= TextureUploader.maximumDimension, height <= TextureUploader.maximumDimension else {
            throw DecodeError.tooLarge(url)
        }

        let format: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm_srgb
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.storageMode = .private
        // Core Image writes with a render or compute pass, whichever its
        // kernels need; the canvas only reads.
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else {
            throw GPUError.allocationFailed("a RAW texture")
        }

        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
        // Core Image's origin is bottom-left, textures' top-left.
        destination.isFlipped = true
        // For an _srgb texture Metal applies the sRGB curve as it stores, so
        // Core Image must hand it linear values: telling it "Display P3"
        // would encode twice and wash the picture out.
        destination.colorSpace = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3
                                                        : CGColorSpace.linearDisplayP3)
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let task = try context(for: gpu).startTask(toRender: output.transformed(by: origin), to: destination)

        // Same command buffer: the mip chain is built right after the render,
        // in one GPU submission.
        guard let blit = commands.makeBlitCommandEncoder() else {
            throw GPUError.allocationFailed("a mipmap encoder")
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        if let error = commands.error { throw error }

        var contentHeadroom: Float = 1
        if hdr {
            // The filter reports no headroom of its own (`contentHeadroom` is
            // 0, "unknown"), and a fixed guess would either clip the brightest
            // highlights or squash a scene that never gets near it. The real
            // peak costs one GPU reduction pass (about 10 ms for 24 MP) and a
            // single pixel read back.
            contentHeadroom = max(1, peakValue(of: texture, gpu: gpu) ?? pow(2, amount))
        }
        return ImageTexture(texture: texture, imageSize: orientedSize, isFullResolution: scale == 1,
                            isHDR: hdr, contentHeadroom: contentHeadroom)
    }

    /// The render scale for a request: 1 for full resolution or a request
    /// at least as large as the image, otherwise the fraction that gives the
    /// requested long edge. Always inside Metal's texture limit.
    static func renderScale(longestEdge: Int, maxPixelSize: Int?) -> Double {
        guard longestEdge > 0 else { return 1 }
        var scale = 1.0
        if let maxPixelSize, maxPixelSize < longestEdge {
            scale = Double(max(maxPixelSize, 1)) / Double(longestEdge)
        }
        return min(scale, Double(TextureUploader.maximumDimension) / Double(longestEdge))
    }

    /// `extendedDynamicRangeAmount` for a requested headroom (see
    /// `maximumHeadroom`).
    static func edrAmount(forHeadroom headroom: Float) -> Float {
        guard headroom.isFinite, headroom > 1 else { return 0 }
        return min(log2(headroom), 1)
    }

    // MARK: - Core Image

    /// One context for every render: creating one is expensive, and it
    /// keeps compiled kernels between files. It shares the app's device
    /// and command queue, so Core Image's work is ordered with ours.
    ///
    /// Working space is extended linear Display P3 in half floats, the
    /// canvas's own space, so nothing is converted twice or clipped before
    /// it reaches the texture.
    private static let sharedContext = makeContext(gpu: .shared)

    private static func context(for gpu: GPU) -> CIContext {
        gpu === GPU.shared ? sharedContext : makeContext(gpu: gpu)
    }

    private static func makeContext(gpu: GPU) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAh,
            // A viewer renders each file once; caching intermediates would
            // only hold memory.
            .cacheIntermediates: false,
            .name: "minivu RAW",
        ]
        if let target = memoryTarget(physicalMemory: ProcessInfo.processInfo.physicalMemory) {
            options[.memoryTarget] = target
        }
        return CIContext(mtlCommandQueue: gpu.queue, options: options)
    }

    /// The memory limit in megabytes for the RAW context's render tasks
    /// (`kCIContextMemoryLimit`), or nil for Core Image's own choice.
    ///
    /// 512 MB on Macs with 8 GB or less. Measured on M4 (16 GB) with three
    /// 24 MP NEFs rendered at full and half size in turn (`RawMemoryBenchmark`):
    /// the first full render's footprint +1.22 GB without a limit, +0.90 GB
    /// at 512 MB, +0.70 GB at 256 MB; the peak over all six renders 2.23 GB,
    /// 1.80 GB and 1.73 GB. Full renders took 185-190 ms, 205-210 ms (+10%)
    /// and 265-430 ms; half-size ones 115-120 ms, 113-117 ms and 145-220 ms.
    /// 1024 MB saved nothing (peak 2.74 GB). So 512 MB takes a fifth to a
    /// quarter off the footprint for a tenth more time on a full render,
    /// worth it where memory is tight and not where it isn't; below that
    /// the time grows much faster than the saving. Most of what remains is
    /// the RAW engine's own buffers, which no context option limits (see
    /// the type's documentation).
    static func memoryTarget(physicalMemory: UInt64) -> Int? {
        physicalMemory <= 8 << 30 ? 512 : nil
    }

    /// The largest channel value anywhere in `texture`.
    private static func peakValue(of texture: MTLTexture, gpu: GPU) -> Float? {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: space]) else { return nil }
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context(for: gpu).render(maximum, toBitmap: &pixel, rowBytes: 16,
                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        let peak = max(pixel[0], pixel[1], pixel[2])
        return peak.isFinite && peak > 0 ? peak : nil
    }
}
