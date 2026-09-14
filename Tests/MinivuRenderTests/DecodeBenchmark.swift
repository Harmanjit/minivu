import Testing
import Foundation
@testable import MinivuRender
@testable import MinivuCore

/// Timings on real photos. Runs only when MINIVU_BENCH_DIR points at a
/// folder of images, e.g. MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter Benchmark
@Suite struct DecodeBenchmark {
    static let folder = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: folder != nil))
    func decodeAndUpload() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.folder!, includingPropertiesForKeys: nil)
            .filter(ImageFormats.isImage).sorted { $0.lastPathComponent < $1.lastPathComponent }
        _ = GPU.shared
        for url in files {
            let clock = ContinuousClock()
            var thumb = Duration.zero, screen = Duration.zero, full = Duration.zero, upload = Duration.zero
            thumb = clock.measure { _ = ImageDecoder.thumbnail(for: url, maxPixelSize: 320) }
            var decoded: DecodedImage?
            screen = try clock.measure { decoded = try ImageDecoder.decode(url, maxPixelSize: 3024) }
            let t0 = clock.now
            let fullImage = try ImageDecoder.decode(url)
            let texture = try TextureUploader.upload(fullImage)   // lazy decode happens inside
            full = clock.now - t0
            upload = try clock.measure { _ = try TextureUploader.upload(decoded!) }
            print(String(format: "%-28@ %5.0fx%-5.0f thumb %6.1f ms | screen decode %6.1f + upload %6.1f ms | full decode+upload %7.1f ms  %@ %d MB",
                         url.lastPathComponent as NSString, fullImage.imageSize.width, fullImage.imageSize.height,
                         thumb.ms, screen.ms, upload.ms, full.ms,
                         (texture.isHDR ? "HDR" : "SDR") as NSString, texture.byteCost / 1_000_000))
        }
    }
}

/// Screen-sized decode + upload of each JPEG/HEIC for a 3420 px wide canvas:
/// the canvas's long edge against the image fitted into it, median of 5.
///     MINIVU_BENCH_DIR=<copy of ~/latent/TestAssets> swift test --filter FitBenchmark
@Suite(.serialized) struct FitBenchmark {
    @Test(.enabled(if: DecodeBenchmark.folder != nil))
    func longEdgeAgainstFitted() throws {
        let files = try FileManager.default.contentsOfDirectory(at: DecodeBenchmark.folder!, includingPropertiesForKeys: nil)
            .filter { ["jpg", "heic"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        _ = GPU.shared
        let clock = ContinuousClock()
        func median(_ run: () throws -> ImageTexture) rethrows -> (ms: Double, texture: ImageTexture) {
            var texture: ImageTexture?
            var times: [Double] = []
            for _ in 0..<5 { times.append(try clock.measure { texture = try run() }.ms) }
            return (times.sorted()[2], texture!)
        }
        for url in files {
            for canvas in [CGSize(width: 3420, height: 2048), CGSize(width: 3420, height: 2214)] {
                let edge = try median { try TextureUploader.upload(ImageDecoder.decode(url, maxPixelSize: Int(canvas.width))) }
                let fit = try median { try TextureUploader.upload(ImageDecoder.decode(url, fitting: canvas)) }
                print(String(format: "%-20@ canvas %.0fx%.0f  long edge: %4d px %6.1f ms %4d MB | fitted: %4d px %6.1f ms %4d MB",
                             url.lastPathComponent as NSString, canvas.width, canvas.height,
                             edge.texture.texture.width, edge.ms, edge.texture.byteCost / 1_000_000,
                             fit.texture.texture.width, fit.ms, fit.texture.byteCost / 1_000_000))
            }
        }
    }
}

/// RAW renders (RawRenderer) against the embedded preview. The first render
/// in the process pays for Core Image's setup; "first" is each file's first
/// render, "again" a second render of the same file.
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter RawBenchmark
@Suite(.serialized) struct RawBenchmark {
    @Test(.enabled(if: DecodeBenchmark.folder != nil))
    func rawRender() throws {
        let files = try FileManager.default.contentsOfDirectory(at: DecodeBenchmark.folder!, includingPropertiesForKeys: nil)
            .filter { ImageFormats.kind(of: $0) == .raw }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        _ = GPU.shared
        let clock = ContinuousClock()
        for url in files {
            var texture: ImageTexture?
            let first = try clock.measure { texture = try RawRenderer.render(url: url, maxPixelSize: nil, hdr: false, headroom: 1) }
            let again = try clock.measure { _ = try RawRenderer.render(url: url, maxPixelSize: nil, hdr: false, headroom: 1) }
            var hdr: ImageTexture?
            let hdrTime = try clock.measure { hdr = try RawRenderer.render(url: url, maxPixelSize: nil, hdr: true, headroom: 2) }
            let half = try clock.measure { _ = try RawRenderer.render(url: url, maxPixelSize: 3008, hdr: false, headroom: 1) }
            let preview = try clock.measure {
                if let decoded = try ImageDecoder.decodeRawPreview(url) { _ = try TextureUploader.upload(decoded) }
            }
            print(String(format: "%-24@ %dx%d  RAW first %6.0f ms  again %6.0f ms  HDR %6.0f ms (peak %.2f)  3008 px %5.0f ms | preview+upload %5.0f ms",
                         url.lastPathComponent as NSString, texture!.texture.width, texture!.texture.height,
                         first.ms, again.ms, hdrTime.ms, hdr!.contentHeadroom, half.ms, preview.ms))
        }
    }
}

extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
