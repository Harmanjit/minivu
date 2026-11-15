import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import UniformTypeIdentifiers
@testable import MinivuRender
@testable import MinivuCore

/// Slideshow videos: the timeline, and short files written and read back
/// with AVFoundation (never played aloud).
@Suite struct SlideshowVideoTests {
    /// A solid sRGB picture on disk, in a folder of the test's own.
    static func solid(_ name: String, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                      width: Int = 160, height: Int = 90, in folder: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// Two seconds of a quiet 440 Hz tone as a WAV file, written, not played.
    static func tone(in folder: URL, seconds: Double = 2) throws -> URL {
        let url = folder.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        return url
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-video-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Red, green and blue slides, one second each with half-second
    /// transitions, at 24 frames a second.
    static func plan(in folder: URL, transition: SlideshowTransition = .wipe, captions: Bool = false,
                     music: [URL] = []) throws -> SlideshowVideoPlan {
        let colours: [(String, CGFloat, CGFloat, CGFloat)] = [("red.png", 1, 0, 0), ("green.png", 0, 1, 0),
                                                              ("blue.png", 0, 0, 1)]
        let slides = try colours.map { name, r, g, b in
            SlideshowVideoPlan.Slide(url: try solid(name, r, g, b, in: folder), transition: transition,
                                     caption: captions ? "A caption for \(name)" : nil)
        }
        return SlideshowVideoPlan(slides: slides, interval: 1, transitionDuration: 0.5, enlargeSmallImages: true,
                                  music: music)
    }

    static let format = SlideshowVideoFormat(width: 320, height: 180, frameRate: 24)

    /// Every frame of `url`'s video track as BGRA bytes, with the track.
    struct Decoded {
        var frames: [[UInt8]]
        var width: Int
        var height: Int
        var codec: FourCharCode
        var duration: CMTime
        var hasAudio: Bool
        var audioDuration: CMTime

        /// The colour at a point, measured from the top left, as RGB.
        func rgb(frame: Int, x: Int, y: Int) -> SIMD3<Int> {
            let offset = (y * width + x) * 4
            let bytes = frames[frame]
            return SIMD3(Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }

        func difference(_ a: Int, _ b: Int) -> Int {
            zip(frames[a], frames[b]).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        }
    }

    static func decode(_ url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { target in
                for y in 0..<height {
                    memcpy(target.baseAddress! + y * width * 4, base + y * row, width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(bytes)
        }
        return Decoded(frames: frames, width: Int(size.width), height: Int(size.height),
                       codec: CMFormatDescriptionGetMediaSubType(description),
                       duration: try await asset.load(.duration), hasAudio: audio != nil,
                       audioDuration: try await audio?.load(.timeRange).duration ?? .zero)
    }

    static func close(_ a: SIMD3<Int>, _ b: SIMD3<Int>, tolerance: Int = 24) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
    }

    // MARK: - Timeline

    @Test func timelineCountsWholeFrames() {
        let timeline = SlideshowVideoTimeline(slideCount: 3, frameRate: 24, interval: 1, transitionDuration: 0.5)
        #expect(timeline.transitionFrames == 12 && timeline.holdFrames == 24)
        // Three slides of 36 frames, then 12 fading to black: five seconds.
        #expect(timeline.totalFrames == 120)
        #expect(timeline.duration == CMTime(value: 120, timescale: 24))

        // The first slide fades in from black, its caption over a quarter second.
        let first = timeline.moment(at: 0)
        #expect(first.from == nil && first.to == 0 && first.progress == Float(1) / 12)
        #expect(first.captionOpacity == Float(1) / 6)
        #expect(timeline.moment(at: 11) == .init(from: nil, to: 0, progress: 1, caption: 0, captionOpacity: 1))
        #expect(timeline.moment(at: 20).isStill)
        // The second slide's transition, from the first.
        let crossing = timeline.moment(at: 36 + 5)
        #expect(crossing.from == 0 && crossing.to == 1 && crossing.progress == Float(6) / 12 && !crossing.isStill)
        #expect(crossing.caption == 1)
        // The last frame is black, the caption gone.
        let last = timeline.moment(at: 119)
        #expect(last.from == 2 && last.to == nil && last.progress == 1 && last.captionOpacity == 0)
        // Past either end is the end.
        #expect(timeline.moment(at: 500) == last)
        #expect(SlideshowVideoTimeline(slideCount: 0, frameRate: 30, interval: 4, transitionDuration: 1).totalFrames == 0)
    }

    @Test func resolutionsAndBitRates() {
        #expect(SlideshowVideoResolution.hd1080.pixelSize(screen: nil) == CGSize(width: 1920, height: 1080))
        #expect(SlideshowVideoResolution.uhd4K.pixelSize(screen: nil) == CGSize(width: 3840, height: 2160))
        // The screen's pixels, made even; within the codecs' 8192 px.
        #expect(SlideshowVideoResolution.screen.pixelSize(screen: CGSize(width: 3025, height: 1965))
                == CGSize(width: 3024, height: 1964))
        #expect(SlideshowVideoResolution.screen.pixelSize(screen: CGSize(width: 10240, height: 4320))
                == CGSize(width: 8192, height: 3456))
        #expect(SlideshowVideoResolution.screen.pixelSize(screen: nil) == CGSize(width: 1920, height: 1080))
        let medium = SlideshowVideoFormat(width: 1920, height: 1080, frameRate: 30)
        #expect((4_900_000...5_100_000).contains(medium.averageBitRate))
        var hevc = medium
        hevc.codec = .hevc
        #expect(hevc.averageBitRate < medium.averageBitRate)
    }

    // MARK: - Files

    @Test func writesTheShowFrameByFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = try Self.plan(in: folder)
        let url = folder.appendingPathComponent("show.mp4")
        let decodes = SlideshowVideoDecodeLog()
        try await SlideshowVideoWriter.write(plan, format: Self.format, to: url, decode: { url, size, settings in
            decodes.append(size)
            return try SlideshowVideoWriter.defaultDecode(url, size, settings)
        })
        let video = try await Self.decode(url)
        #expect(video.frames.count == 120)
        #expect(video.duration == CMTime(value: 5, timescale: 1))
        #expect(video.width == 320 && video.height == 180)
        #expect(video.codec == kCMVideoCodecType_H264)
        #expect(!video.hasAudio)
        // Each slide decoded once, fitted to the video.
        #expect(decodes.sizes == [CGSize(width: 320, height: 180), CGSize(width: 320, height: 180),
                                  CGSize(width: 320, height: 180)])

        // Stills are the slides; the first frame is nearly black, the last black.
        let middle = (x: 160, y: 90)
        #expect(Self.close(video.rgb(frame: 24, x: middle.x, y: middle.y), SIMD3(255, 0, 0)))
        #expect(Self.close(video.rgb(frame: 60, x: middle.x, y: middle.y), SIMD3(0, 255, 0)))
        #expect(Self.close(video.rgb(frame: 96, x: middle.x, y: middle.y), SIMD3(0, 0, 255)))
        #expect(Self.close(video.rgb(frame: 119, x: middle.x, y: middle.y), SIMD3(0, 0, 0)))
        let fadeIn = [0, 5, 11].map { video.rgb(frame: $0, x: middle.x, y: middle.y).x }
        #expect(fadeIn[0] < 80 && fadeIn[0] < fadeIn[1] && fadeIn[1] < fadeIn[2])
        // Frames of a still are alike; a transition's differ from the
        // stills either side: half way through, the wipe has brought the
        // new slide in from the right.
        #expect(video.difference(20, 30) <= 8)
        let wiping = 36 + 6
        #expect(video.difference(wiping, 24) > 100 && video.difference(wiping, 60) > 100)
        #expect(Self.close(video.rgb(frame: wiping, x: 20, y: 90), SIMD3(255, 0, 0)))
        #expect(Self.close(video.rgb(frame: wiping, x: 300, y: 90), SIMD3(0, 255, 0)))
    }

    @Test func writesHEVCInAQuickTimeMovie() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var format = Self.format
        format.codec = .hevc
        format.container = .mov
        format.frameRate = 30
        let url = folder.appendingPathComponent("show.mov")
        try await SlideshowVideoWriter.write(try Self.plan(in: folder, transition: .dissolve), format: format, to: url)
        let video = try await Self.decode(url)
        #expect(video.codec == kCMVideoCodecType_HEVC)
        // 3 × (15 + 30) + 15 frames at 30 a second.
        #expect(video.frames.count == 150)
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        #expect(type?.conforms(to: .quickTimeMovie) == true)
    }

    @Test func musicBecomesTheSoundTrack() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two seconds of music for a five-second video: it plays round
        // again, and is cut where the picture ends.
        let plan = try Self.plan(in: folder, music: [try Self.tone(in: folder)])
        let url = folder.appendingPathComponent("show.mp4")
        try await SlideshowVideoWriter.write(plan, format: Self.format, to: url)
        let video = try await Self.decode(url)
        #expect(video.hasAudio)
        #expect(abs(video.audioDuration.seconds - 5) < 0.1)
        #expect(video.frames.count == 120)
    }

    @Test func unreadableMusicLeavesASilentVideo() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notMusic = folder.appendingPathComponent("song.mp3")
        try Data("not a song".utf8).write(to: notMusic)
        let url = folder.appendingPathComponent("show.mp4")
        try await SlideshowVideoWriter.write(try Self.plan(in: folder, music: [notMusic]), format: Self.format, to: url)
        let video = try await Self.decode(url)
        #expect(!video.hasAudio && video.frames.count == 120)
    }

    @Test func captionsAreDrawnInTheCorner() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("plain.mp4")
        let captioned = folder.appendingPathComponent("captioned.mp4")
        try await SlideshowVideoWriter.write(try Self.plan(in: folder), format: Self.format, to: plain)
        try await SlideshowVideoWriter.write(try Self.plan(in: folder, captions: true), format: Self.format,
                                             to: captioned)
        let without = try await Self.decode(plain), with = try await Self.decode(captioned)
        // The bottom-left corner of the blue still gains white text; the
        // top right stays blue.
        func brightest(_ video: Decoded, frame: Int) -> Int {
            var most = 0
            for y in 150..<176 { for x in 8..<120 { most = max(most, video.rgb(frame: frame, x: x, y: y).x) } }
            return most
        }
        #expect(brightest(without, frame: 96) < 40)
        #expect(brightest(with, frame: 96) > 160)
        #expect(Self.close(with.rgb(frame: 96, x: 300, y: 10), SIMD3(0, 0, 255)))
    }

    @Test func cancellingLeavesNoFile() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("show.mp4")
        let cancelled = SlideshowVideoFlag()
        // Cancelled a little way in, as the Cancel button would be.
        await #expect(throws: CancellationError.self) {
            try await SlideshowVideoWriter.write(try Self.plan(in: folder), format: Self.format, to: url,
                                                 isCancelled: { cancelled.isSet },
                                                 progress: { if $0 > 0.2 { cancelled.set() } })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func holdsAtMostThreeSlides() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var plan = try Self.plan(in: folder)
        plan.slides += plan.slides + plan.slides
        let slides = SlideshowVideoSlides(plan: plan, size: CGSize(width: 64, height: 36),
                                          decode: SlideshowVideoWriter.defaultDecode, isCancelled: { false })
        for index in plan.slides.indices {
            slides.arriving(index)
            #expect(slides.texture(index) != nil)
            if index > 0 { #expect(slides.texture(index - 1) != nil) }
        }
        #expect(slides.peakHeld <= 3)
    }
}

/// Decode sizes recorded from the decode queue.
final class SlideshowVideoDecodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CGSize] = []
    func append(_ size: CGSize) { lock.withLock { values.append(size) } }
    var sizes: [CGSize] { lock.withLock { values } }
}

final class SlideshowVideoFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
