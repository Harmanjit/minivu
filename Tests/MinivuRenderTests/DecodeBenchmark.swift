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

extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
