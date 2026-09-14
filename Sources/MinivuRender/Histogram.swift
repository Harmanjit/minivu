import Foundation
import Metal
import MinivuCore

/// The histogram of an image on the GPU: 256 bins each of red, green, blue
/// and luminance, display-referred (what an SDR screen or an 8-bit export
/// would hold), plus how many pixels are brighter than SDR white.
public struct HistogramData: Sendable, Equatable {
    public static let binCount = 256

    public enum Channel: Int, CaseIterable, Sendable {
        case red, green, blue, luminance
    }

    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    /// Relative luminance in linear light (Display P3 weights), encoded with
    /// the sRGB curve like the colour channels: how light each pixel looks,
    /// so a saturated red counts as a middle tone rather than a shadow.
    public var luminance: [UInt32]
    /// Pixels with any channel above 1.0 in an extended-range (HDR)
    /// texture: highlights an SDR screen or file would clip. Always 0 for
    /// 8-bit textures.
    public var aboveSDRWhite: Int
    /// Pixels counted: those of the sampled mip level, not of the image.
    public var pixelCount: Int
    /// The mip level measured (see `Histogram.level`), and its size.
    public var level: Int
    public var sampledWidth: Int
    public var sampledHeight: Int

    public init(red: [UInt32], green: [UInt32], blue: [UInt32], luminance: [UInt32], aboveSDRWhite: Int,
                pixelCount: Int, level: Int = 0, sampledWidth: Int = 0, sampledHeight: Int = 0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.aboveSDRWhite = aboveSDRWhite
        self.pixelCount = pixelCount
        self.level = level
        self.sampledWidth = sampledWidth
        self.sampledHeight = sampledHeight
    }

    public func bins(_ channel: Channel) -> [UInt32] {
        switch channel {
        case .red: red
        case .green: green
        case .blue: blue
        case .luminance: luminance
        }
    }

    /// Fraction of pixels in the bottom bin (crushed to black) of `channel`.
    public func shadowClipping(_ channel: Channel) -> Double {
        fraction(bins(channel).first ?? 0)
    }

    /// Fraction of pixels in the top bin (blown to white) of `channel`.
    public func highlightClipping(_ channel: Channel) -> Double {
        fraction(bins(channel).last ?? 0)
    }

    /// Fraction of pixels brighter than SDR white.
    public var aboveSDRWhiteFraction: Double { fraction(UInt32(clamping: aboveSDRWhite)) }

    /// The tallest bin among `channels`, for scaling a plot.
    public func peak(_ channels: [Channel] = Channel.allCases) -> UInt32 {
        channels.map { bins($0).max() ?? 0 }.max() ?? 0
    }

    private func fraction(_ count: UInt32) -> Double {
        pixelCount > 0 ? Double(count) / Double(pixelCount) : 0
    }
}

/// Computes `HistogramData` for a texture with a compute kernel
/// (Shaders/Histogram.metal).
///
/// It measures the mip level whose long edge is closest to 1024 px rather
/// than every pixel. A mip level is a box-filtered (linear light) copy, so
/// the shape of the distribution is the same to the eye at a sixth of a
/// 24 MP photo's width, and the cost stops depending on the image: about a
/// million pixels at most, a millisecond or two. What averaging does lose
/// is isolated extremes (a few blown specular pixels merge with their
/// neighbours), which a clipping warning at 0.1% ignores anyway.
///
/// Thread-safe; runs synchronously and waits for the GPU, so call it off
/// the main thread. Calls are serialised because they share one result
/// buffer (shared storage, the one place the counts cross back to the CPU).
public enum Histogram {
    /// Long edge, in pixels, of the level worth measuring.
    public static let targetLongEdge = 1024

    public static func compute(texture: ImageTexture) throws -> HistogramData {
        try Calculator.shared.compute(texture.texture)
    }

    /// The mip level whose long edge is closest to `target`, measured as a
    /// ratio (a level twice too big and one half too small are equally far),
    /// with ties going to the larger level. Levels halve with rounding down
    /// and never go below 1 px, as Metal's do.
    public static func level(width: Int, height: Int, levelCount: Int, target: Int = targetLongEdge) -> Int {
        guard levelCount > 1, target > 0 else { return 0 }
        var best = 0
        var bestDistance = Double.infinity
        for level in 0..<levelCount {
            let edge = max(max(width, height) >> level, 1)
            let distance = abs(log2(Double(edge) / Double(target)))
            if distance < bestDistance - 1e-9 {
                best = level
                bestDistance = distance
            }
        }
        return best
    }

    /// Slots in the result buffer: four channels of bins, then the count of
    /// pixels above SDR white.
    static let slotCount = 4 * HistogramData.binCount + 1

    final class Calculator: @unchecked Sendable {
        static let shared = Calculator(gpu: .shared)

        private let gpu: GPU
        private let lock = NSLock()
        private var buffer: MTLBuffer?

        init(gpu: GPU) {
            self.gpu = gpu
        }

        func compute(_ texture: MTLTexture) throws -> HistogramData {
            lock.lock(); defer { lock.unlock() }
            let pipeline = try gpu.computePipeline("computeHistogram")
            let length = Histogram.slotCount * MemoryLayout<UInt32>.stride
            if buffer == nil { buffer = gpu.device.makeBuffer(length: length, options: .storageModeShared) }
            guard let buffer, let commands = gpu.queue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder() else {
                throw GPUError.allocationFailed("a histogram buffer")
            }
            memset(buffer.contents(), 0, length)

            let level = Histogram.level(width: texture.width, height: texture.height,
                                        levelCount: texture.mipmapLevelCount)
            let width = max(texture.width >> level, 1)
            let height = max(texture.height >> level, 1)
            var lod = UInt32(level)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.setBytes(&lod, length: MemoryLayout<UInt32>.size, index: 1)
            // Whole threadgroups only: the kernel's barriers need every
            // thread of a group to run, including those past the edge.
            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }

            let bins = HistogramData.binCount
            let counts = UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt32.self, capacity: Histogram.slotCount),
                                             count: Histogram.slotCount)
            return HistogramData(red: Array(counts[0..<bins]), green: Array(counts[bins..<2 * bins]),
                                 blue: Array(counts[2 * bins..<3 * bins]), luminance: Array(counts[3 * bins..<4 * bins]),
                                 aboveSDRWhite: Int(counts[4 * bins]), pixelCount: width * height,
                                 level: level, sampledWidth: width, sampledHeight: height)
        }
    }
}
