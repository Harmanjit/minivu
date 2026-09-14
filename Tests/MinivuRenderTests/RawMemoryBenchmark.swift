import Testing
import Foundation
import CoreImage
import Metal
import Darwin
@testable import MinivuRender
@testable import MinivuCore

/// Process footprint of RAW renders under a Core Image memory limit, for
/// `RawRenderer.memoryTarget`. Each limit needs a fresh process, since Core
/// Image keeps the RAW engine's buffers for seconds, so it runs only when
/// MINIVU_RAW_MEMORY_TARGET names one (0: no limit):
///     for t in 0 256 512 1024; do MINIVU_BENCH_DIR=~/latent/TestAssets \
///       MINIVU_RAW_MEMORY_TARGET=$t swift test --filter RawMemoryBenchmark; done
@Suite(.serialized) struct RawMemoryBenchmark {
    static let target = ProcessInfo.processInfo.environment["MINIVU_RAW_MEMORY_TARGET"].flatMap(Int.init)

    /// The process footprint now, and its peak, in megabytes.
    static func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
    }

    @Test func eightGigabyteMacsLimitTheRawContext() {
        #expect(RawRenderer.memoryTarget(physicalMemory: 8 << 30) == 512)
        #expect(RawRenderer.memoryTarget(physicalMemory: 16 << 30) == nil)
    }

    @Test(.enabled(if: DecodeBenchmark.folder != nil && target != nil))
    func rawRenderFootprint() throws {
        let gpu = GPU.shared
        var options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
        ]
        if Self.target! > 0 { options[.memoryTarget] = Self.target! }
        let context = CIContext(mtlCommandQueue: gpu.queue, options: options)
        let base = Self.footprint()
        for name in ["HSB_6548.NEF", "HSB_2615.NEF", "HSB_2639.NEF"] {
            for scale in [1.0, 0.5] {
                let clock = ContinuousClock()
                var size = CGSize.zero
                let duration = try clock.measure {
                    let filter = try #require(CIRAWFilter(imageURL: DecodeBenchmark.folder!.appendingPathComponent(name)))
                    filter.scaleFactor = Float(scale)
                    let output = try #require(filter.outputImage)
                    size = output.extent.size
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm_srgb, width: Int(size.width), height: Int(size.height), mipmapped: false)
                    descriptor.storageMode = .private
                    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    let texture = try #require(gpu.device.makeTexture(descriptor: descriptor))
                    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
                    destination.colorSpace = CGColorSpace(name: CGColorSpace.linearDisplayP3)
                    let origin = CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY)
                    _ = try context.startTask(toRender: output.transformed(by: origin), to: destination).waitUntilCompleted()
                }
                let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                let now = Self.footprint()
                print(String(format: "limit %d MB %@ at %.1f (%.0fx%.0f): %.0f ms, footprint +%.0f MB, peak +%.0f MB",
                             Self.target!, name, scale, size.width, size.height, ms, now.now - base.now, now.peak - base.now))
            }
        }
    }
}
