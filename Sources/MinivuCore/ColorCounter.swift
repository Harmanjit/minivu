import Foundation
import CoreGraphics

/// Counts the distinct colours in an image, as FastStone's "Count Colors".
///
/// The image is drawn once into an 8-bit-per-channel bitmap in its own
/// colour space (sRGB when it has none, or one a bitmap can't use), so the
/// count is of the colours the file stores rather than of what a conversion
/// to some other space made of them. Each colour is a 24-bit number, and a
/// bitset with one bit per possible colour (2^24 bits, 2 MB) marks the ones
/// seen; the count is the number of bits set. That is a single pass of
/// shifts and ORs with no hashing and no allocation per pixel, and the
/// bitset stays in the CPU's cache: 27 ms for a 24 MP photo in a release
/// build, drawing included (`ColorCounterBenchmark`).
///
/// - Alpha is ignored: the bitmap has no alpha channel, so a translucent
///   pixel counts as the colour it shows over black, and a fully
///   transparent one as black.
/// - Deeper images (16-bit, float, HDR) are counted at 8 bits per channel,
///   so the answer is at most 16,777,216 and matches an 8-bit export.
public enum ColorCounter {
    /// Number of possible 24-bit colours, and bits in the bitset.
    public static let colorSpaceSize = 1 << 24

    /// The bitmap the count draws into could not be allocated, so there is
    /// no answer to give. Reporting no colours instead would be a wrong
    /// answer, and an image this large is exactly where it would happen.
    public struct OutOfMemory: Error {}

    /// The most pixels an image may have before counting it is refused, on
    /// a Mac with `physicalMemory` bytes of RAM.
    ///
    /// A count holds the whole image twice over: the copy ImageIO decodes
    /// (four bytes a pixel, and more again while a 16-bit file converts)
    /// and the 8-bit bitmap drawn from it here. Eight bytes a pixel, then,
    /// and a quarter of RAM is as much as one count may take. That is a
    /// larger share than a cache may claim, because this is a transient
    /// allocation the user asked for and waits on, but only so large: a
    /// 30000x30000 stitched TIFF wants 7.2 GB, which a 16 GB Mac would
    /// spend a minute paging for before it could answer. So 268 megapixels
    /// on an 8 GB Mac and 2.1 gigapixels on a 64 GB one, neither of which
    /// puts a 24 MP photo or a 200 MP panorama in question.
    public static func maximumPixels(physicalMemory: UInt64) -> Int {
        Int(physicalMemory / 32)
    }

    /// - Parameter isCancelled: checked once per row, from the calling
    ///   thread; the default follows the current task.
    /// - Throws: `CancellationError` when `isCancelled` returns true, and
    ///   `OutOfMemory` when the bitmap can't be allocated. An image with no
    ///   pixels at all is not a failure: it has no colours, so 0.
    public static func countUniqueColors(in image: CGImage,
                                         isCancelled: () -> Bool = { Task.isCancelled }) throws -> Int {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo),
              let data = context.data else { throw OutOfMemory() }
        // Exact pixels: no resampling or dithering between image and bitmap.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if isCancelled() { throw CancellationError() }

        let words = colorSpaceSize / 64
        var bits = [UInt64](repeating: 0, count: words)
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        try bits.withUnsafeMutableBufferPointer { set in
            // Big-endian RGBX: r, g, b, then the unused byte. Rows are
            // contiguous (bytesPerRow is exactly width * 4).
            for y in 0..<height {
                if isCancelled() { throw CancellationError() }
                var i = y * width * 4
                let end = i + width * 4
                while i < end {
                    let color = Int(pixels[i]) << 16 | Int(pixels[i + 1]) << 8 | Int(pixels[i + 2])
                    set[color &>> 6] |= 1 &<< UInt64(color & 63)
                    i &+= 4
                }
            }
        }
        return bits.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}
