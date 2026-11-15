import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// What a video file is, read from its tracks without decoding a frame.
public struct VideoInfo: Sendable, Equatable {
    /// Size as displayed: the track's natural size turned by its preferred
    /// transform, so a portrait phone video is taller than it is wide.
    public var pixelSize: CGSize
    /// Seconds.
    public var duration: Double
    /// Frames a second as the track declares it; nil when it doesn't.
    public var frameRate: Double?
    /// The track is HDR (HLG, PQ or Dolby Vision).
    public var isHDR: Bool
    public var hasAudio: Bool
    /// AVFoundation can play the file on this Mac (its codecs are known).
    public var isPlayable: Bool
    /// The video codec's four-character code ("hvc1", "avc1", "apcn").
    public var codec: String?

    public init(pixelSize: CGSize, duration: Double, frameRate: Double? = nil, isHDR: Bool = false,
                hasAudio: Bool = false, isPlayable: Bool = true, codec: String? = nil) {
        self.pixelSize = pixelSize
        self.duration = duration
        self.frameRate = frameRate
        self.isHDR = isHDR
        self.hasAudio = hasAudio
        self.isPlayable = isPlayable
        self.codec = codec
    }
}

/// Reads videos for the browser and the viewer (G18): their size and
/// length, a thumbnail and the viewer's first frame. Playback itself is
/// AVKit's, in the app.
///
/// Everything here blocks the calling thread while AVFoundation opens the
/// file and decodes a frame, so call it off the main thread, from GCD (the
/// thumbnail service, the image loader, `BlockingWork`), never from the
/// cooperative pool: AVFoundation's loading is asynchronous in Swift, and
/// each call here waits on a semaphore for a task that only awaits it.
/// A file that takes longer than `timeout` is given up on, as an
/// unreadable file is.
public enum VideoFrames {
    /// How long one read may take before the file counts as unreadable: a
    /// damaged file must not hold a thumbnail worker for ever.
    static let timeout: TimeInterval = 10

    /// At most this many frames decode at once. A 4K HEVC frame holds tens of
    /// megabytes in the decoder while it is made, and the thumbnail service
    /// runs a worker per core; photos don't need the cap, which is why it is
    /// here rather than there.
    static let frameSlots = DispatchSemaphore(value: 3)

    static func asset(_ url: URL) -> AVURLAsset {
        // The container's own duration is enough for a badge; precise timing
        // can mean reading the whole file.
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    }

    // MARK: - Info

    /// Size, length and HDR of the first video track; nil for a file with no
    /// video track, or one AVFoundation can't open.
    public static func info(for url: URL) -> VideoInfo? {
        let asset = asset(url)
        return wait {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let (natural, transform, rate, characteristics, formats) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics, .formatDescriptions)
            let (duration, playable) = try await asset.load(.duration, .isPlayable)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let turned = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
            guard size.width > 0, size.height > 0 else { return nil }
            let seconds = duration.seconds
            return VideoInfo(pixelSize: size, duration: seconds.isFinite ? max(seconds, 0) : 0,
                             frameRate: rate > 0 ? Double(rate) : nil,
                             isHDR: characteristics.contains(.containsHDRVideo), hasAudio: !audio.isEmpty,
                             isPlayable: playable,
                             codec: formats.first.map { fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) })
        } ?? nil
    }

    // MARK: - Frames

    /// Where a thumbnail is taken from: a little way in, since many videos
    /// open on black (a fade, a lens cap, the moment the button was
    /// pressed). A second in, or a tenth of the way through a short clip.
    public static func posterTime(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(1, duration / 10)
    }

    /// A thumbnail at most `maxPixelSize` on its long edge, oriented, SDR,
    /// from `posterTime`. Nil when the file has no frame to give.
    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let info = info(for: url) else { return nil }
        let time = posterTime(duration: info.duration)
        // Near enough: a keyframe close by decodes far faster than the exact
        // frame, and nobody can tell which frame a thumbnail came from.
        return frame(of: url, at: time, maxPixelSize: maxPixelSize, allowHDR: false,
                     toleranceBefore: time / 2, toleranceAfter: 1)
    }

    /// One frame at most `maxPixelSize` on its long edge (nil: full size),
    /// oriented. With `allowHDR` an HDR video's frame keeps its highlights
    /// (`matchSource`); otherwise AVFoundation tone maps it to SDR. The
    /// tolerances are in seconds; zero for both gives exactly that frame.
    public static func frame(of url: URL, at seconds: Double, maxPixelSize: Int?, allowHDR: Bool,
                             toleranceBefore: Double = 0, toleranceAfter: Double = 0) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset(url))
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize, maxPixelSize > 0 {
            // Fits the frame inside the square, keeping its shape.
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        generator.requestedTimeToleranceBefore = CMTime(seconds: max(toleranceBefore, 0), preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: max(toleranceAfter, 0), preferredTimescale: 600)
        generator.dynamicRangePolicy = allowHDR ? .matchSource : .forceSDR

        frameSlots.wait()
        defer { frameSlots.signal() }
        let result = ResultBox<CGImage>()
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)) {
            image, _, _ in
            result.set(image)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return result.value
    }

    // MARK: - Text

    /// "0:07", "12:34" or "1:02:03", as the Finder and Photos show lengths.
    /// Rounded down, so a clip of 9.9 s reads 0:09 as its last second does
    /// in a player.
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }

    /// "hvc1" from its code; spaces kept ("raw "), unprintable bytes dropped.
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
    }

    // MARK: - Waiting

    /// Runs AVFoundation's asynchronous loading and waits for it on this
    /// (GCD) thread. Nil on failure or after `timeout`.
    static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let result = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            result.set(try? await work())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }
        return result.value
    }

    /// One value handed from a completion handler to the waiting thread.
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?

        func set(_ value: T?) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }
}
