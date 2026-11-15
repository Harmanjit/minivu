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

/// What a video says about where and when it was made, and its data rate:
/// the info panel's extra lines for a video (G18). Read only when the panel
/// asks, never for the grid.
public struct VideoMetadata: Sendable, Equatable {
    /// Bits a second over the whole file: its size over its length, as
    /// QuickTime Player's inspector gives it.
    public var dataRate: Double?
    /// When recording began: the camera's own wall clock and zone where the
    /// file has them (QuickTime's creation date, as an iPhone writes it),
    /// else the container's creation time.
    public var created: Created?
    public var location: Location?
    public var make: String?
    public var model: String?

    public struct Created: Sendable, Equatable {
        public var date: Date
        /// The zone the camera's clock was in; nil when the file doesn't say.
        public var timeZone: TimeZone?
    }

    /// Degrees, north and east positive; metres above sea level.
    public struct Location: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
    }

    public init(dataRate: Double? = nil, created: Created? = nil, location: Location? = nil, make: String? = nil,
                model: String? = nil) {
        self.dataRate = dataRate
        self.created = created
        self.location = location
        self.make = make
        self.model = model
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
    static let frameSlotCount = 3
    static let frameSlots = DispatchSemaphore(value: frameSlotCount)

    /// Frames being decoded now, and the most there have been at once since
    /// `resetPeak`: what the tests check a folder of videos against.
    static let decoding = Gauge()

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

    // MARK: - Metadata

    /// The data rate, creation date, location and camera of a video; nil
    /// for a file AVFoundation can't open. A few reads of the container's
    /// header, no frame.
    public static func metadata(for url: URL) -> VideoMetadata? {
        let asset = asset(url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init)
        return wait {
            let (duration, items, creation) = try await asset.load(.duration, .metadata, .creationDate)
            var metadata = VideoMetadata()
            let seconds = duration.seconds
            if let bytes, seconds.isFinite, seconds > 0 { metadata.dataRate = bytes * 8 / seconds }
            func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
                for identifier in identifiers {
                    for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                        if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
                    }
                }
                return nil
            }
            // An iPhone's creation date keeps the zone it was recorded in;
            // the container's own is an instant in UTC.
            if let text = await string([.quickTimeMetadataCreationDate]), let created = parseCreationDate(text) {
                metadata.created = created
            } else if let creation, let date = try? await creation.load(.dateValue) {
                metadata.created = VideoMetadata.Created(date: date, timeZone: nil)
            }
            if let text = await string([.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709,
                                        .commonIdentifierLocation]) {
                metadata.location = parseISO6709(text)
            }
            metadata.make = await string([.quickTimeMetadataMake, .commonIdentifierMake, .quickTimeUserDataMake])
            metadata.model = await string([.quickTimeMetadataModel, .commonIdentifierModel, .quickTimeUserDataModel])
            return metadata
        } ?? nil
    }

    /// QuickTime's creation date, "2024-05-01T14:30:00+0100" (the zone is
    /// sometimes left out, or written "+01:00" or "Z").
    static func parseCreationDate(_ text: String) -> VideoMetadata.Created? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 19 else { return nil }
        let clock = String(trimmed.prefix(19))
        // Fractions of a second come before the zone and are dropped.
        let rest = trimmed.dropFirst(19).drop { $0 == "." || $0.isNumber }
        let offset = rest.isEmpty ? nil : String(rest)
        guard let parsed = MetadataReader.parseExifDate(clock, offset: offset) else { return nil }
        return VideoMetadata.Created(date: parsed.date, timeZone: parsed.hasOffset ? parsed.timeZone : nil)
    }

    /// A point in ISO 6709 as phones and cameras write it: "+37.3349-122.0090+010.000/",
    /// latitude then longitude then an optional altitude, each signed. The
    /// whole-number digits tell degrees (±DD, ±DDD), degrees and minutes
    /// (±DDMM, ±DDDMM) and degrees, minutes and seconds (±DDMMSS, ±DDDMMSS)
    /// apart, any of them with a decimal fraction.
    static func parseISO6709(_ text: String) -> VideoMetadata.Location? {
        var parts: [String] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" {
                if !current.isEmpty { parts.append(current) }
                current = String(character)
            } else if character.isNumber || character == "." {
                guard !current.isEmpty else { return nil }
                current.append(character)
            } else {
                break
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count >= 2, let latitude = degrees(parts[0], degreeDigits: 2),
              let longitude = degrees(parts[1], degreeDigits: 3),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        let altitude = parts.count > 2 ? Double(parts[2]) : nil
        return VideoMetadata.Location(latitude: latitude, longitude: longitude, altitude: altitude)
    }

    /// One signed ISO 6709 coordinate in decimal degrees.
    private static func degrees(_ part: String, degreeDigits: Int) -> Double? {
        let sign: Double = part.hasPrefix("-") ? -1 : 1
        let body = part.dropFirst()
        let whole = body.prefix { $0 != "." }
        let fraction = body.dropFirst(whole.count)
        guard !whole.isEmpty, whole.allSatisfy(\.isNumber) else { return nil }
        let value: Double?
        switch whole.count - degreeDigits {
        case 0:
            value = Double(body)
        case 2:
            guard let d = Double(whole.prefix(degreeDigits)), let m = Double(whole.dropFirst(degreeDigits) + fraction),
                  m < 60 else { return nil }
            value = d + m / 60
        case 4:
            let minutes = whole.dropFirst(degreeDigits).prefix(2)
            guard let d = Double(whole.prefix(degreeDigits)), let m = Double(minutes),
                  let s = Double(whole.dropFirst(degreeDigits + 2) + fraction), m < 60, s < 60 else { return nil }
            value = d + m / 60 + s / 3600
        default:
            value = nil
        }
        return value.map { sign * $0 }
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
    ///
    /// The length is read from the same asset the frame is taken from, so a
    /// folder of videos opens each file's header once per thumbnail.
    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        let asset = asset(url)
        guard let duration = wait({ try await asset.load(.duration).seconds }) else { return nil }
        let time = posterTime(duration: duration)
        // Near enough: a keyframe close by decodes far faster than the exact
        // frame, and nobody can tell which frame a thumbnail came from.
        return frame(of: asset, at: time, maxPixelSize: maxPixelSize, allowHDR: false,
                     toleranceBefore: time / 2, toleranceAfter: 1)
    }

    /// The frame shown at `seconds`, at the video's own size, oriented and
    /// SDR: what Copy Frame and Save Frame As hand over (G18). A player
    /// paused at the very end reports a time just past the last frame,
    /// which has no exact frame; the last one before it is taken then.
    public static func still(of url: URL, at seconds: Double) -> CGImage? {
        frame(of: url, at: seconds, maxPixelSize: nil, allowHDR: false)
            ?? frame(of: url, at: seconds, maxPixelSize: nil, allowHDR: false, toleranceBefore: 1)
    }

    /// One frame at most `maxPixelSize` on its long edge (nil: full size),
    /// oriented. With `allowHDR` an HDR video's frame keeps its highlights
    /// (`matchSource`); otherwise AVFoundation tone maps it to SDR. The
    /// tolerances are in seconds; zero for both gives exactly that frame.
    public static func frame(of url: URL, at seconds: Double, maxPixelSize: Int?, allowHDR: Bool,
                             toleranceBefore: Double = 0, toleranceAfter: Double = 0) -> CGImage? {
        frame(of: asset(url), at: seconds, maxPixelSize: maxPixelSize, allowHDR: allowHDR,
              toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter)
    }

    static func frame(of asset: AVURLAsset, at seconds: Double, maxPixelSize: Int?, allowHDR: Bool,
                      toleranceBefore: Double, toleranceAfter: Double) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize, maxPixelSize > 0 {
            // Fits the frame inside the square, keeping its shape.
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        generator.requestedTimeToleranceBefore = CMTime(seconds: max(toleranceBefore, 0), preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: max(toleranceAfter, 0), preferredTimescale: 600)
        generator.dynamicRangePolicy = allowHDR ? .matchSource : .forceSDR

        frameSlots.wait()
        decoding.enter()
        defer {
            decoding.leave()
            frameSlots.signal()
        }
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

    /// A count of work in progress and its high-water mark.
    final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var highest = 0

        func enter() {
            lock.withLock {
                current += 1
                highest = max(highest, current)
            }
        }

        func leave() { lock.withLock { current -= 1 } }

        var peak: Int { lock.withLock { highest } }

        func resetPeak() { lock.withLock { highest = current } }
    }

    /// One value handed from a completion handler to the waiting thread.
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?

        func set(_ value: T?) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }
}
