import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

@Suite struct ColorCounterTests {
    /// An 8-bit image from a per-pixel colour function.
    func image(width: Int, height: Int, space: String = CGColorSpace.sRGB as String,
               alpha: CGImageAlphaInfo = .noneSkipLast,
               _ color: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
        let colorSpace = try #require(CGColorSpace(name: space as CFString))
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: colorSpace, bitmapInfo: alpha.rawValue))
        return try #require(context.makeImage())
    }

    /// An image no bitmap could ever be allocated for (a petabyte of
    /// pixels). Its own pixels are never read: the count gives up before it
    /// draws, so the provider is asked for nothing and vends nothing.
    func imageTooLargeForAnyBitmap() throws -> CGImage {
        let side = 1 << 24
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: { _ in nil },
                                                      releaseBytePointer: nil,
                                                      getBytesAtPosition: { _, _, _, _ in 0 }, releaseInfo: nil)
        let provider = try #require(CGDataProvider(directInfo: nil, size: off_t(side) * off_t(side) * 4,
                                                   callbacks: &callbacks))
        return try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent))
    }

    @Test func solidAndTwoColourImages() throws {
        #expect(try ColorCounter.countUniqueColors(in: image(width: 31, height: 17) { _, _ in (12, 200, 99, 255) }) == 1)
        #expect(try ColorCounter.countUniqueColors(in: image(width: 31, height: 17) { x, _ in
            x < 10 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }) == 2)
    }

    @Test func everyRedGreenPairIsItsOwnColour() throws {
        let counted = try ColorCounter.countUniqueColors(in: image(width: 256, height: 256) { x, y in
            (UInt8(x), UInt8(y), 7, 255)
        })
        #expect(counted == 65_536)
    }

    /// 4096 x 4096 pixels holding each 24-bit colour exactly once: every
    /// bit of the bitset, the first and last word included.
    @Test func allSixteenMillionColours() throws {
        let counted = try ColorCounter.countUniqueColors(in: image(width: 4096, height: 4096) { x, y in
            let c = y * 4096 + x
            return (UInt8(c >> 16), UInt8((c >> 8) & 255), UInt8(c & 255), 255)
        })
        #expect(counted == ColorCounter.colorSpaceSize)
    }

    @Test func theUnusedFourthByteDoesNotSplitColours() throws {
        // Same RGB, different bytes in the skipped channel.
        let counted = try ColorCounter.countUniqueColors(in: image(width: 64, height: 1) { x, _ in
            (40, 50, 60, UInt8(x))
        })
        #expect(counted == 1)
    }

    @Test func countsInTheImagesOwnColourSpace() throws {
        // Two saturated Display P3 reds that both lie outside sRGB: converted
        // to sRGB they would clip to the same colour.
        let p3 = try image(width: 20, height: 20, space: CGColorSpace.displayP3 as String) { x, _ in
            x < 10 ? (255, 0, 0, 255) : (250, 0, 0, 255)
        }
        #expect(try ColorCounter.countUniqueColors(in: p3) == 2)
        // A grey image (not RGB) is counted in sRGB.
        let grey = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        grey.setFillColor(gray: 0.5, alpha: 1)
        grey.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let greyImage = try #require(grey.makeImage())
        #expect(try ColorCounter.countUniqueColors(in: greyImage) == 2)
    }

    /// The smallest image there can be: Core Graphics makes no image with a
    /// zero side, so the count of an empty one stays a guard rather than a
    /// case a test can reach.
    @Test func aSinglePixelIsOneColour() throws {
        #expect(try ColorCounter.countUniqueColors(in: image(width: 1, height: 1) { _, _ in (9, 200, 9, 255) }) == 1)
    }

    /// Nought colours would read as a real answer, so a bitmap that could
    /// not be allocated throws rather than returning one.
    @Test func failingToAllocateTheBitmapThrowsRatherThanCountingNoColours() throws {
        #expect(throws: ColorCounter.OutOfMemory.self) {
            try ColorCounter.countUniqueColors(in: imageTooLargeForAnyBitmap())
        }
    }

    @Test func theBudgetLeavesRoomForBothCopiesOfTheImage() {
        // A quarter of memory at the eight bytes a pixel a count holds.
        #expect(ColorCounter.maximumPixels(physicalMemory: 8 << 30) == 268_435_456)
        #expect(ColorCounter.maximumPixels(physicalMemory: 64 << 30) == 2_147_483_648)
        // A 24 MP photo counts even on the smallest Mac; a 30000x30000
        // stitched TIFF is refused on all but a very large one.
        #expect(ColorCounter.maximumPixels(physicalMemory: 8 << 30) > 24_000_000)
        #expect(ColorCounter.maximumPixels(physicalMemory: 16 << 30) < 30_000 * 30_000)
        #expect(ColorCounter.maximumPixels(physicalMemory: 64 << 30) > 30_000 * 30_000)
    }

    @Test func stopsWhenCancelled() throws {
        let picture = try image(width: 64, height: 64) { x, y in (UInt8(x), UInt8(y), 0, 255) }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ColorCounter.countUniqueColors(in: picture) {
                checks += 1
                return checks > 3
            }
        }
        #expect(checks == 4)
    }
}

/// Counting a 24 MP photo. Runs only when MINIVU_BENCH_DIR points at the
/// test assets; measure a release build:
///     MINIVU_BENCH_DIR=~/latent/TestAssets swift test -c release --filter ColorCounterBenchmark
@Suite struct ColorCounterBenchmark {
    static let photo = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("HSB_6548.jpg") }

    @Test(.enabled(if: photo.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
    func count24MP() throws {
        let decoded = try ImageDecoder.decode(Self.photo!, allowHDR: false)
        let clock = ContinuousClock()
        var count = 0
        var best = Duration.seconds(100)
        for _ in 0..<5 {
            let time = try clock.measure { count = try ColorCounter.countUniqueColors(in: decoded.image) }
            best = min(best, time)
        }
        let ms = Double(best.components.seconds) * 1000 + Double(best.components.attoseconds) / 1e15
        print(String(format: "ColorCounter %dx%d: %d colours, best of 5 %.0f ms", decoded.image.width,
                     decoded.image.height, count, ms))
    }
}
