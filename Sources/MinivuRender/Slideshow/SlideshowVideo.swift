import Foundation
import AVFoundation

/// The video codecs a slideshow can be exported with. Both are encoded by
/// the Mac's media engine through `AVAssetWriter`.
public enum SlideshowVideoCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264, hevc

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }

    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }

    /// HEVC needs about 60% of H.264's bits for the same picture.
    var bitRateFactor: Double { self == .h264 ? 1 : 0.6 }
}

/// The file a slideshow video is written as.
public enum SlideshowVideoContainer: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp4, mov

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4: "MPEG-4 (.mp4)"
        case .mov: "QuickTime (.mov)"
        }
    }

    public var fileExtension: String { rawValue }

    /// The uniform type identifier, for save panels.
    public var typeIdentifier: String { self == .mp4 ? "public.mpeg-4" : "com.apple.quicktime-movie" }

    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

/// How many bits the encoder may spend.
public enum SlideshowVideoQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// H.264 bits per pixel per frame. Medium is about 5 Mbit/s at 1080p
    /// and 30 frames a second, as streaming services use; high doubles it
    /// for pictures that keep their grain.
    var bitsPerPixel: Double {
        switch self {
        case .low: 0.04
        case .medium: 0.08
        case .high: 0.16
        }
    }
}

/// The picture size of an exported video.
public enum SlideshowVideoResolution: String, Codable, CaseIterable, Sendable, Identifiable {
    case hd720, hd1080, uhd4K, screen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hd720: "720p (1280 × 720)"
        case .hd1080: "1080p (1920 × 1080)"
        case .uhd4K: "4K (3840 × 2160)"
        case .screen: "Screen size"
        }
    }

    /// The size in pixels; `.screen` is the screen's own pixel size, made
    /// even both ways (4:2:0 video has one colour sample per two pixels).
    /// An unknown screen counts as 1080p.
    public func pixelSize(screen: CGSize?) -> CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .uhd4K: return CGSize(width: 3840, height: 2160)
        case .screen:
            guard let screen, screen.width >= 2, screen.height >= 2 else { return CGSize(width: 1920, height: 1080) }
            // Within H.264's and HEVC's 8192 px limit, keeping the shape.
            let scale = min(1, 8192 / max(screen.width, screen.height))
            func even(_ value: CGFloat) -> CGFloat { max(2, ((value * scale) / 2).rounded(.down) * 2) }
            return CGSize(width: even(screen.width), height: even(screen.height))
        }
    }
}

/// What a slideshow video is encoded as.
public struct SlideshowVideoFormat: Sendable, Equatable {
    public static let frameRates = [24, 30, 60]

    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: SlideshowVideoCodec
    public var container: SlideshowVideoContainer
    public var quality: SlideshowVideoQuality

    public init(width: Int, height: Int, frameRate: Int = 30, codec: SlideshowVideoCodec = .h264,
                container: SlideshowVideoContainer = .mp4, quality: SlideshowVideoQuality = .medium) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.container = container
        self.quality = quality
    }

    public var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// Bits a second the encoder aims at.
    public var averageBitRate: Int {
        Int(Double(width * height * frameRate) * quality.bitsPerPixel * codec.bitRateFactor)
    }
}

/// Everything a slideshow video shows, settled before the first frame: the
/// slides in order with the transition into each, how long things take, and
/// the music. The app makes it from Settings > Slideshow
/// (`SlideshowVideoPlanner`).
public struct SlideshowVideoPlan: Sendable {
    public struct Slide: Sendable, Equatable {
        public var url: URL
        /// The transition that brings this slide on. The first slide always
        /// fades in from black, as the live show's does.
        public var transition: SlideshowTransition
        public var caption: String?

        public init(url: URL, transition: SlideshowTransition = .crossFade, caption: String? = nil) {
            self.url = url
            self.transition = transition
            self.caption = caption
        }
    }

    public var slides: [Slide]
    /// Seconds each slide stays once its transition has finished.
    public var interval: Double
    /// Seconds each transition takes.
    public var transitionDuration: Double
    public var enlargeSmallImages: Bool
    /// Songs in playing order, played round and round to fill the video.
    public var music: [URL]
    /// How images decode (HDR, RAW), as the viewer has them.
    public var display: DisplaySettings

    public init(slides: [Slide], interval: Double, transitionDuration: Double, enlargeSmallImages: Bool = false,
                music: [URL] = [], display: DisplaySettings = DisplaySettings()) {
        self.slides = slides
        self.interval = interval
        self.transitionDuration = transitionDuration
        self.enlargeSmallImages = enlargeSmallImages
        self.music = music
        self.display = display
    }
}

/// Which slides each frame of the video shows, in whole frames.
///
/// Every slide comes on with its transition, then stays for the interval;
/// after the last one the picture fades to black over one more transition.
/// The live show plays the same way (its first slide fades in from black),
/// except that it ends by closing its window.
public struct SlideshowVideoTimeline: Equatable, Sendable {
    /// One frame: a still slide, or part of a transition.
    public struct Moment: Equatable, Sendable {
        /// The slide going away; nil for black, or for a still.
        public var from: Int?
        /// The slide on screen or arriving; nil for black.
        public var to: Int?
        /// Through the transition, 0...1; 1 for a still.
        public var progress: Float
        /// The caption showing: the slide arriving's, from the moment its
        /// transition begins, as the live show swaps it.
        public var caption: Int?
        /// How visible the caption is: it fades in over the first slide's
        /// first quarter second and out with the last fade to black.
        public var captionOpacity: Float

        public var isStill: Bool { from == nil && progress >= 1 }
    }

    /// The live caption's fade, in seconds (`SlideshowCaptionView.show`).
    public static let captionFade = 0.25

    public let slideCount: Int
    public let frameRate: Int
    public let transitionFrames: Int
    public let holdFrames: Int

    public init(slideCount: Int, frameRate: Int, interval: Double, transitionDuration: Double) {
        self.slideCount = max(0, slideCount)
        self.frameRate = max(1, frameRate)
        transitionFrames = max(1, Int((transitionDuration * Double(self.frameRate)).rounded()))
        holdFrames = max(1, Int((interval * Double(self.frameRate)).rounded()))
    }

    /// Frames per slide: its transition and its stay.
    public var framesPerSlide: Int { transitionFrames + holdFrames }

    /// Every slide, then the fade to black; none without slides.
    public var totalFrames: Int { slideCount == 0 ? 0 : slideCount * framesPerSlide + transitionFrames }

    public var duration: CMTime { CMTime(value: CMTimeValue(totalFrames), timescale: CMTimeScale(frameRate)) }

    /// What frame `frame` shows. A transition's last frame is at progress 1,
    /// so the slide arrives exactly on time, and the video's last frame is
    /// black.
    public func moment(at frame: Int) -> Moment {
        let frame = min(max(frame, 0), max(totalFrames - 1, 0))
        let slide = frame / framesPerSlide
        let within = frame % framesPerSlide
        let captionFrames = max(1, Double(frameRate) * Self.captionFade)
        if slide >= slideCount {
            // The fade to black after the last slide.
            let progress = Float(within + 1) / Float(transitionFrames)
            return Moment(from: slideCount - 1, to: nil, progress: progress, caption: slideCount - 1,
                          captionOpacity: 1 - progress)
        }
        let opacity = slide == 0 ? Float(min(1, Double(frame + 1) / captionFrames)) : 1
        if within < transitionFrames {
            let progress = Float(within + 1) / Float(transitionFrames)
            return Moment(from: slide == 0 ? nil : slide - 1, to: slide, progress: progress, caption: slide,
                          captionOpacity: opacity)
        }
        return Moment(from: nil, to: slide, progress: 1, caption: slide, captionOpacity: opacity)
    }
}
