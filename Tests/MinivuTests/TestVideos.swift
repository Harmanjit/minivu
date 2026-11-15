import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Small silent movies made for the test that needs them (G18), so no test
/// depends on a video file somewhere on disk. H.264 in a QuickTime or MPEG-4
/// container, ten frames a second, no audio track: nothing can play aloud.
///
/// The first frame is black and every later one is a flat colour, which is
/// what tells a thumbnail taken "a little in" from one taken at the start.
/// The same helper is in MinivuCoreTests (a test target can't share files).
enum TestVideos {
    struct WriteError: Error {}

    static let framesPerSecond: Int32 = 10

    /// Writes the movie at `url` (its extension picks the container) and
    /// returns `url`. `portrait` stores the frames landscape with a quarter
    /// turn in the track, as a phone held upright does.
    @discardableResult
    static func make(at url: URL, width: Int = 160, height: Int = 96, seconds: Double = 3,
                     color: (red: UInt8, green: UInt8, blue: UInt8) = (230, 20, 20),
                     portrait: Bool = false) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let type: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 5],
        ])
        input.expectsMediaDataInRealTime = false
        if portrait { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw WriteError() }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? WriteError() }
        writer.startSession(atSourceTime: .zero)

        let frames = max(Int((seconds * Double(framesPerSecond)).rounded()), 2)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let buffer = try pixelBuffer(width: width, height: height,
                                         color: index == 0 ? (0, 0, 0) : color)
            let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? WriteError() }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WriteError() }
        return url
    }

    private static func pixelBuffer(width: Int, height: Int,
                                    color: (red: UInt8, green: UInt8, blue: UInt8)) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        guard let buffer = made else { throw WriteError() }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw WriteError() }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels + y * rowBytes + x * 4
                p[0] = color.blue; p[1] = color.green; p[2] = color.red; p[3] = 255
            }
        }
        return buffer
    }

    /// The colour at the image's centre, as 8-bit sRGB.
    static func centreColor(of image: CGImage) -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // The centre pixel lands on the one-pixel context.
            context?.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                                            width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
