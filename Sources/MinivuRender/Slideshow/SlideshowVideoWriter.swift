import Foundation
import AVFoundation
import CoreImage
import CoreText
import CoreVideo
import Metal

/// Writes a slideshow as a video file (H.264 or HEVC through
/// `AVAssetWriter`), with the music, if any, as its sound.
///
/// - **The live show's pictures.** Every frame is drawn by
///   `SlideshowRenderer`, the shader the slideshow plays with, into a
///   half-float pixel buffer seen by Metal through a `CVMetalTextureCache`;
///   Core Image then converts it into the encoder's 8-bit Rec. 709 buffer
///   from the writer's pool. Slides are tone mapped to SDR white, as on an
///   SDR screen, so HDR photos keep their look without their highlights.
/// - **Memory stays at three slides** fitted to the video: the one going
///   away, the one arriving and the next, decoded one at a time on a queue
///   of its own while frames are drawn (`SlideshowVideoSlides`).
/// - **Stills cost nothing to draw.** A frame that shows what the frame
///   before showed hands the encoder the same pixel buffer again.
/// - **Cancelling leaves nothing.** The writer is cancelled and its file
///   removed; the caller writes to a scratch file and moves it into place
///   only when this returns.
public enum SlideshowVideoWriter {
    public enum Failure: Error, CustomStringConvertible {
        case noSlides
        case cannotEncode(String)

        public var description: String {
            switch self {
            case .noSlides: "There are no pictures to put in the video."
            case .cannotEncode(let detail): "The video couldn’t be encoded: \(detail)"
            }
        }
    }

    /// Decodes one slide fitted into the video's size; the default is the
    /// viewer's decode (`ImageLoader.decodeOnce`). Tests count calls.
    public typealias Decode = @Sendable (URL, CGSize, DisplaySettings) throws -> ImageTexture

    public static let defaultDecode: Decode = { url, size, settings in
        try ImageLoader.decodeOnce(url, fitting: size, settings: settings)
    }

    /// Writes `plan` as `format` to `url`, which must not exist yet.
    /// `progress` gets the fraction of frames written, now and then, from a
    /// background queue. Throws `CancellationError` once `isCancelled` says
    /// so, having removed whatever was written.
    public static func write(_ plan: SlideshowVideoPlan, format: SlideshowVideoFormat, to url: URL,
                             gpu: GPU = .shared, decode: @escaping Decode = defaultDecode,
                             isCancelled: @escaping @Sendable () -> Bool = { false },
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !plan.slides.isEmpty else { throw Failure.noSlides }
        let timeline = SlideshowVideoTimeline(slideCount: plan.slides.count, frameRate: format.frameRate,
                                              interval: plan.interval, transitionDuration: plan.transitionDuration)
        let writer = try AVAssetWriter(outputURL: url, fileType: format.container.fileType)
        do {
            try await write(plan, timeline: timeline, format: format, writer: writer, gpu: gpu, decode: decode,
                            isCancelled: isCancelled, progress: progress)
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func write(_ plan: SlideshowVideoPlan, timeline: SlideshowVideoTimeline,
                              format: SlideshowVideoFormat, writer: AVAssetWriter, gpu: GPU, decode: @escaping Decode,
                              isCancelled: @escaping @Sendable () -> Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(format))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: format.width,
            kCVPixelBufferHeightKey as String: format.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoInput) else { throw Failure.cannotEncode("no \(format.codec.title) encoder") }
        writer.add(videoInput)

        let music = plan.music.isEmpty ? nil : try await SlideshowVideoMusic.make(plan.music, duration: timeline.duration)
        var audioInput: AVAssetWriterInput?
        if music != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: SlideshowVideoMusic.encoderSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let frames = try SlideshowVideoFrames(format: format, gpu: gpu)
        let slides = SlideshowVideoSlides(plan: plan, size: format.pixelSize, decode: decode, isCancelled: isCancelled)
        guard writer.startWriting() else {
            throw writer.error ?? Failure.cannotEncode("the writer wouldn’t start")
        }
        writer.startSession(atSourceTime: .zero)

        let video = VideoPump(plan: plan, timeline: timeline, input: videoInput, adaptor: adaptor, frames: frames,
                              slides: slides, isCancelled: isCancelled, progress: progress)
        let audio: AudioPump?
        if let music, let audioInput {
            audio = try AudioPump(music: music, input: audioInput, isCancelled: isCancelled)
        } else {
            audio = nil
        }
        // Both tracks are fed side by side, each on its own queue: the
        // writer interleaves them, and holds back whichever runs ahead.
        async let videoDone: Void = video.run()
        if let audio { await audio.run() }
        await videoDone

        if isCancelled() { throw CancellationError() }
        if let error = video.error ?? audio?.error { throw error }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? Failure.cannotEncode("the file wasn’t finished")
        }
        progress(1)
    }

    static func videoSettings(_ format: SlideshowVideoFormat) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: format.averageBitRate,
            AVVideoExpectedSourceFrameRateKey: format.frameRate,
            // A key frame every two seconds, so a player seeks quickly.
            AVVideoMaxKeyFrameIntervalKey: format.frameRate * 2,
        ]
        if format.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: format.codec.avCodec,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }
}

/// Feeds the video track: draws each frame the timeline asks for and
/// appends it. Touched only on its own serial queue once running, which is
/// what makes the unchecked `Sendable` safe.
private final class VideoPump: @unchecked Sendable {
    private let plan: SlideshowVideoPlan
    private let timeline: SlideshowVideoTimeline
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frames: SlideshowVideoFrames
    private let slides: SlideshowVideoSlides
    private let isCancelled: @Sendable () -> Bool
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "minivu.slideshow-video.frames", qos: .userInitiated)

    private var frame = 0
    private var finished = false
    private var last: (moment: SlideshowVideoTimeline.Moment, buffer: CVPixelBuffer)?
    private(set) var error: Error?

    init(plan: SlideshowVideoPlan, timeline: SlideshowVideoTimeline, input: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, frames: SlideshowVideoFrames, slides: SlideshowVideoSlides,
         isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) {
        self.plan = plan
        self.timeline = timeline
        self.input = input
        self.adaptor = adaptor
        self.frames = frames
        self.slides = slides
        self.isCancelled = isCancelled
        self.progress = progress
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished, pump() else { return }
                finished = true
                input.markAsFinished()
                last = nil
                slides.release()
                continuation.resume()
            }
        }
    }

    /// Appends frames while the writer takes them; true when done (every
    /// frame written, cancelled, or failed).
    private func pump() -> Bool {
        let total = timeline.totalFrames
        // About a hundred progress reports for the whole video.
        let reportEvery = max(1, total / 100)
        while input.isReadyForMoreMediaData {
            if frame >= total || isCancelled() || error != nil { return true }
            do {
                let moment = timeline.moment(at: frame)
                let buffer: CVPixelBuffer
                if let last, last.moment == moment {
                    buffer = last.buffer
                } else {
                    buffer = try draw(moment)
                }
                last = (moment, buffer)
                let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.frameRate))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw SlideshowVideoWriter.Failure.cannotEncode("a frame was refused")
                }
            } catch {
                self.error = error
                return true
            }
            frame += 1
            if frame % reportEvery == 0 { progress(Double(frame) / Double(total)) }
        }
        return false
    }

    private func draw(_ moment: SlideshowVideoTimeline.Moment) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw SlideshowVideoWriter.Failure.cannotEncode("no pixel buffers")
        }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { throw GPUError.allocationFailed("a video frame") }
        if let to = moment.to { slides.arriving(to) }
        let from = moment.from.flatMap(slides.texture)
        let to = moment.to.flatMap(slides.texture)
        // The first slide fades in from black and the last fades to black,
        // as the live show's first slide does; between them each slide
        // comes on with its own transition.
        var kind = SlideshowTransition.crossFade
        if moment.from != nil, let arriving = moment.to { kind = plan.slides[arriving].transition }
        let frame = SlideshowFrame(from: from, to: to, transition: kind, progress: moment.progress,
                                   direction: .forward, displayHeadroom: 1,
                                   enlargeSmallImages: plan.enlargeSmallImages)
        let caption = moment.caption.flatMap { plan.slides[$0].caption }
        try frames.draw(frame, caption: caption, captionOpacity: CGFloat(moment.captionOpacity), into: buffer)
        return buffer
    }
}

/// Feeds the sound track from the music's reader. Touched only on its own
/// serial queue once running.
private final class AudioPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let input: AVAssetWriterInput
    private let isCancelled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "minivu.slideshow-video.audio", qos: .userInitiated)
    private var finished = false
    private(set) var error: Error?

    init(music: SlideshowVideoMusic, input: AVAssetWriterInput, isCancelled: @escaping @Sendable () -> Bool) throws {
        let (reader, output) = try music.makeReader()
        self.reader = reader
        self.output = output
        self.input = input
        self.isCancelled = isCancelled
        guard reader.startReading() else {
            throw reader.error ?? SlideshowVideoWriter.Failure.cannotEncode("the music couldn’t be read")
        }
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished, pump() else { return }
                finished = true
                input.markAsFinished()
                if reader.status == .reading { reader.cancelReading() }
                continuation.resume()
            }
        }
    }

    private func pump() -> Bool {
        while input.isReadyForMoreMediaData {
            if isCancelled() { return true }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { error = reader.error }
                return true
            }
            guard input.append(sample) else {
                error = SlideshowVideoWriter.Failure.cannotEncode("the music was refused")
                return true
            }
        }
        return false
    }
}

/// The music as one track as long as the video: the songs one after
/// another, round and round, cut at the end, fading in over a second and
/// out over the last second and a half, as the live show's music does.
final class SlideshowVideoMusic {
    static let fadeIn = CMTime(value: 1, timescale: 1)
    static let fadeOut = CMTime(value: 3, timescale: 2)

    /// AAC, stereo, 48 kHz: what every player plays.
    static var encoderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
    }

    /// What the reader hands the encoder: plain 16-bit samples, already at
    /// the encoder's rate and channels.
    static var readerSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    let composition: AVMutableComposition
    let mix: AVAudioMix
    let duration: CMTime

    private init(composition: AVMutableComposition, mix: AVAudioMix, duration: CMTime) {
        self.composition = composition
        self.mix = mix
        self.duration = duration
    }

    /// The music for `duration`, or nil when no song can be read. Songs
    /// that can't be read are left out.
    static func make(_ urls: [URL], duration: CMTime) async throws -> SlideshowVideoMusic? {
        let composition = AVMutableComposition()
        guard duration > .zero,
              let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        // A track doesn't keep its asset alive, and inserting from a track
        // whose asset has gone fails, so the assets are kept too.
        var sources: [(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)] = []
        for url in urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange), range.duration > .zero else { continue }
            sources.append((asset, source, range))
        }
        guard !sources.isEmpty else { return nil }
        var cursor = CMTime.zero
        var next = 0
        while cursor < duration {
            try Task.checkCancellation()
            let source = sources[next % sources.count]
            let take = CMTimeMinimum(source.range.duration, duration - cursor)
            try track.insertTimeRange(CMTimeRange(start: source.range.start, duration: take), of: source.track,
                                      at: cursor)
            cursor = cursor + take
            next += 1
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let half = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                 timeRange: CMTimeRange(start: .zero, duration: CMTimeMinimum(fadeIn, half)))
        let out = CMTimeMinimum(fadeOut, half)
        parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: duration - out, duration: out))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return SlideshowVideoMusic(composition: composition, mix: mix, duration: duration)
    }

    func makeReader() throws -> (AVAssetReader, AVAssetReaderAudioMixOutput) {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio),
                                                 audioSettings: Self.readerSettings)
        output.audioMix = mix
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        guard reader.canAdd(output) else { throw SlideshowVideoWriter.Failure.cannotEncode("the music’s format") }
        reader.add(output)
        return (reader, output)
    }
}

/// The slides' textures: the one going away, the one arriving, and the next,
/// decoded ahead one at a time on a queue of its own. Anything further back
/// is let go as soon as a new slide arrives.
final class SlideshowVideoSlides: @unchecked Sendable {
    private let plan: SlideshowVideoPlan
    private let size: CGSize
    private let decode: SlideshowVideoWriter.Decode
    private let isCancelled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "minivu.slideshow-video.decode", qos: .userInitiated)
    private let condition = NSCondition()
    /// Decoded slides; nil for one that couldn't be, which shows as black.
    private var textures: [Int: ImageTexture?] = [:]
    private var requested: Set<Int> = []
    private var current = -1

    init(plan: SlideshowVideoPlan, size: CGSize, decode: @escaping SlideshowVideoWriter.Decode,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.plan = plan
        self.size = size
        self.decode = decode
        self.isCancelled = isCancelled
    }

    private var peak = 0

    /// The most slides held at once, for tests.
    var peakHeld: Int {
        condition.lock()
        defer { condition.unlock() }
        return peak
    }

    /// Slide `index` is coming on: keeps it and the one before, and starts
    /// decoding the one after.
    func arriving(_ index: Int) {
        guard index != current else { return }
        current = index
        condition.lock()
        for key in textures.keys where key < index - 1 { textures[key] = nil }
        requested = requested.filter { $0 >= index - 1 }
        condition.unlock()
        request(index)
        request(index + 1)
    }

    /// The texture for slide `index`, waiting for its decode; nil if it
    /// couldn't be decoded.
    func texture(_ index: Int) -> ImageTexture? {
        request(index)
        condition.lock()
        defer { condition.unlock() }
        while !textures.keys.contains(index) { condition.wait() }
        return textures[index] ?? nil
    }

    /// Lets every texture go, once the video is written.
    func release() {
        condition.lock()
        textures.removeAll()
        condition.unlock()
    }

    private func request(_ index: Int) {
        guard plan.slides.indices.contains(index) else { return }
        condition.lock()
        let isNew = requested.insert(index).inserted && !textures.keys.contains(index)
        condition.unlock()
        guard isNew else { return }
        let url = plan.slides[index].url, size = size, settings = plan.display
        queue.async { [self] in
            let texture = isCancelled() ? nil : try? decode(url, size, settings)
            condition.lock()
            textures[index] = .some(texture)
            peak = max(peak, textures.count)
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Draws frames for the encoder: the slideshow's own Metal pass into a
/// half-float pixel buffer, converted by Core Image into the encoder's
/// buffer, with the caption drawn over it.
final class SlideshowVideoFrames {
    private let renderer: SlideshowRenderer
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let context: CIContext
    private let width: Int, height: Int
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!

    init(format: SlideshowVideoFormat, gpu: GPU) throws {
        width = format.width
        height = format.height
        renderer = try SlideshowRenderer(gpu: gpu)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, gpu.device, nil, &cache)
        guard let cache else { throw GPUError.allocationFailed("a Metal texture cache") }
        textureCache = cache
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
        guard let made else { throw GPUError.allocationFailed("a pixel buffer pool") }
        pool = made
        // Half float throughout, so nothing on the way clips before the
        // final conversion; no cache, since no two frames are alike.
        context = CIContext(mtlCommandQueue: gpu.queue, options: [
            .workingColorSpace: Self.linear,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    func draw(_ frame: SlideshowFrame, caption: String?, captionOpacity: CGFloat, into output: CVPixelBuffer) throws {
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        var metal: CVMetalTexture?
        guard let picture = made,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, picture, nil, SlideshowRenderer.pixelFormat,
                                                        width, height, 0, &metal) == kCVReturnSuccess,
              let metal, let target = CVMetalTextureGetTexture(metal)
        else { throw GPUError.allocationFailed("a frame texture") }
        // Waits for the GPU, so the picture is whole before Core Image reads it.
        renderer.draw(frame, into: target)
        let image = CIImage(cvPixelBuffer: picture, options: [.colorSpace: Self.linear])
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: Self.rec709)
        CVMetalTextureCacheFlush(textureCache, 0)
        if let caption, captionOpacity > 0 { drawCaption(caption, opacity: captionOpacity, into: output) }
    }

    /// The live caption (`SlideshowCaptionView`) at the video's scale: white
    /// medium text with a soft shadow in the bottom-left corner, 15 points
    /// on a 900-point screen, so it takes the same share of the picture.
    private func drawCaption(_ text: String, opacity: CGFloat, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: Self.rec709,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let scale = CGFloat(height) / 900
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        if let system = CTFontCreateUIFontForLanguage(.system, 15 * scale, nil) {
            // Medium, as the live caption's `.medium` system font.
            let medium = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system), [
                kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.23],
            ] as CFDictionary)
            attributes[NSAttributedString.Key(kCTFontAttributeName as String)] =
                CTFontCreateWithFontDescriptor(medium, 15 * scale, nil)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let margin = 32 * scale
        let room = Double(CGFloat(width) - 2 * margin)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, room, .middle, ellipsis) ?? line
        context.setAlpha(opacity)
        context.setShadow(offset: CGSize(width: 0, height: -scale), blur: 4 * scale,
                          color: CGColor(gray: 0, alpha: 0.85))
        context.textPosition = CGPoint(x: margin, y: 28 * scale)
        CTLineDraw(fitted, context)
    }
}
