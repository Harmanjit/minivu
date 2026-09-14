import Foundation
import ImageIO
import CoreGraphics

/// An animated image's frames and timing, read with ImageIO: GIF, APNG,
/// animated WebP and HEIC image sequences (HEICS).
///
/// Only the header is read on creation; frames are decoded one at a time
/// when asked for. ImageIO hands back each frame fully composited (a GIF
/// frame that only repaints a corner comes back as the whole picture), so
/// a player never has to apply disposal and blending rules itself.
///
/// `@unchecked Sendable`: ImageIO sources may be used from any thread, and
/// `lock` lets only one frame be created at a time, so a player may create
/// this on one thread and decode on another. Draw each frame before asking
/// for the next: a full-size frame decodes as it is drawn, from the
/// composited state ImageIO keeps for the frame after it.
public final class AnimationFrames: @unchecked Sendable {
    /// Frame delays at or below this are what old authoring tools wrote for
    /// "as fast as possible". Browsers show them at 100 ms, and animations
    /// made for the web are timed with that in mind.
    public static let shortestHonouredDelay: TimeInterval = 0.010
    public static let substituteDelay: TimeInterval = 0.100

    public let frameCount: Int
    /// Seconds each frame stays on screen, one per frame.
    public let delays: [TimeInterval]
    /// Times to play through; 0 means forever.
    public let loopCount: Int
    /// The animation's pixel size (the size of every composited frame).
    public let pixelSize: CGSize

    private let source: CGImageSource
    private let lock = NSLock()
    /// No EXIF orientation to apply (true of nearly every animation), so a
    /// frame can be used as stored.
    private let isUpright: Bool

    /// nil when the file can't be read or holds a single image.
    public convenience init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        self.init(source: source)
    }

    public init?(source: CGImageSource) {
        let count = CGImageSourceGetCount(source)
        guard count > 1,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (first[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (first[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        self.source = source
        frameCount = count
        let orientation = (first[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        isUpright = orientation == 1
        pixelSize = CGSize(width: width, height: height)
        delays = (0..<count).map { index in
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            return Self.effectiveDelay(Self.delay(in: props))
        }
        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        loopCount = Self.loopCount(in: fileProps)
    }

    /// One play-through, in seconds.
    public var duration: TimeInterval { delays.reduce(0, +) }

    /// Frame `index`, composited, with its long edge at most `maxPixelSize`.
    ///
    /// Decoding in order is cheapest: ImageIO keeps the previous composited
    /// frame and only applies the next frame's changes to it.
    ///
    /// At full size the image comes straight from the source, still
    /// undecoded: drawing it decodes directly into the caller's bitmap. The
    /// thumbnail route would first decode into a buffer of its own (20% slower
    /// per frame for a 400 x 300 GIF on an M4, 1.18 against 0.93 ms), which
    /// adds up for an animation that loops for as long as it is on screen.
    public func frame(at index: Int, maxPixelSize: Int) -> CGImage? {
        guard (0..<frameCount).contains(index) else { return nil }
        if isUpright, maxPixelSize >= Int(max(pixelSize.width, pixelSize.height)) {
            lock.lock(); defer { lock.unlock() }
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        lock.lock(); defer { lock.unlock() }
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    // MARK: - Properties

    /// The delay stored for one frame in seconds, preferring the unclamped
    /// value (ImageIO clamps the plain one to 100 ms for short delays in
    /// some formats, which would hide what the file really asks for).
    /// 0 when the file stores none.
    static func delay(in props: [CFString: Any]) -> TimeInterval {
        let keys: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for key in keys {
            guard let dictionary = props[key.dictionary] as? [CFString: Any] else { continue }
            for name in [key.unclamped, key.clamped] {
                if let seconds = (dictionary[name] as? NSNumber)?.doubleValue, seconds > 0 { return seconds }
            }
            return 0
        }
        return 0
    }

    /// The browser rule: delays of 10 ms or less (0 included) play at 100 ms.
    /// A hair of tolerance, because 1/100 s stored as a double isn't exact.
    public static func effectiveDelay(_ seconds: TimeInterval) -> TimeInterval {
        seconds <= shortestHonouredDelay + 0.0005 ? substituteDelay : seconds
    }

    /// Loop count from the file properties. A file that says nothing plays
    /// once, as a GIF without the Netscape looping block does in browsers.
    static func loopCount(in props: [CFString: Any]) -> Int {
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
        ]
        for (dictionary, key) in keys {
            guard let values = props[dictionary] as? [CFString: Any] else { continue }
            if let count = (values[key] as? NSNumber)?.intValue { return max(count, 0) }
        }
        return 1
    }
}
