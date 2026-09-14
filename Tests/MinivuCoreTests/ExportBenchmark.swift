import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

/// Encode timings for a 24 MP photo. Runs only when MINIVU_BENCH_DIR points
/// at the test assets, e.g.
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter ExportBenchmark
@Suite(.serialized) struct ExportBenchmark {
    static let folder = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("HSB_6548.jpg").path) } ?? false))
    func encode24MP() throws {
        let url = Self.folder!.appendingPathComponent("HSB_6548.jpg")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        // Decoded up front (ImageIO decodes lazily), so only encoding is timed.
        let lazy = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        let ctx = try #require(CGContext(data: nil, width: lazy.width, height: lazy.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: lazy.colorSpace ?? ExportFixtures.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(lazy, in: CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
        let image = try #require(ctx.makeImage())

        let cases: [(String, ExportOptions)] = [
            ("JPEG q0.9", { var o = ExportOptions.defaults(for: .jpeg); o.quality = 0.9; return o }()),
            ("HEIC q0.8", ExportOptions.defaults(for: .heic)),
            ("PNG 8-bit", ExportOptions.defaults(for: .png)),
            ("TIFF 16-bit LZW", { var o = ExportOptions.defaults(for: .tiff); o.sixteenBit = true; o.tiffCompression = .lzw; return o }()),
        ]
        let t = try TemporaryFolder()
        let clock = ContinuousClock()
        for (label, options) in cases {
            _ = try ImageEncoder.encode(TestImages.gradient(), options: options, metadataSource: nil)   // warm the codec
            var size = 0
            let memory = try clock.measure { size = try ImageEncoder.encode(image, options: options, metadataSource: url).count }
            let prepare = try clock.measure { _ = try ImageEncoder.prepare(image, options: options) }
            let file = t.url.appendingPathComponent("out." + options.format.fileExtension)
            let write = try clock.measure { try ImageEncoder.write(image, to: file, options: options, metadataSource: url) }
            print(String(format: "%-16@ %dx%d  encode %6.0f ms (pixel prep %4.0f ms)  write file %6.0f ms  %6.1f MB",
                         label as NSString, image.width, image.height, memory.ms, prepare.ms, write.ms, Double(size) / 1_000_000))
        }
    }
}

private extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
