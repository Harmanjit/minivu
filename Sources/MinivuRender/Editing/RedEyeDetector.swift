import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Finds red eyes for the red-eye tool's Auto button.
///
/// Vision's face landmarks give each eye's outline and pupil; the circle
/// proposed is centred on the pupil and sized from the eye's width, and it
/// is proposed only when the pupil area really is red by the same measure
/// the correction uses (`RedEyeTuning`), so a brown or dark eye in a group
/// photo is never darkened just because it is an eye.
///
/// Works on a small rendering of the edited image (`EditRenderer
/// .renderForAnalysis`): faces large enough to show red eyes are found at
/// 1600 px, and Vision runs in tens of milliseconds there.
public enum RedEyeDetector {
    /// The proposed circle's radius, as a fraction of the eye's width. An
    /// iris is about half an eye across, so this circle holds the whole
    /// pupil with a margin; the correction only touches red pixels inside.
    static let radiusPerEyeWidth = 0.28
    /// A pupil counts as red when this share of the pixels in the middle of
    /// its circle is red.
    static let redShare = 0.08

    /// Spots for the red eyes in `image`, in its normalised top-left
    /// coordinates; radii are fractions of its short side. Synchronous and a
    /// few tens of milliseconds: call it off the main thread.
    public static func detect(in image: CGImage) -> [RedEyeSpot] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let size = CGSize(width: image.width, height: image.height)
        var candidates: [(center: CGPoint, radius: Double)] = []
        for face in request.results ?? [] {
            guard let landmarks = face.landmarks else { continue }
            for (eye, pupil) in [(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)] {
                // Vision's points are in pixels with the origin at the bottom left.
                guard let outline = eye?.pointsInImage(imageSize: size), outline.count >= 2 else { continue }
                let xs = outline.map(\.x), ys = outline.map(\.y)
                let eyeWidth = Double(xs.max()! - xs.min()!)
                let centre = pupil?.pointsInImage(imageSize: size).first
                    ?? CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
                guard eyeWidth > 2 else { continue }
                candidates.append((CGPoint(x: centre.x, y: size.height - centre.y), eyeWidth * radiusPerEyeWidth))
            }
        }
        return redSpots(candidates, in: image)
    }

    /// The candidates (pixel centres, top-left origin, radii in pixels) whose
    /// pupil area is red, as spots.
    static func redSpots(_ candidates: [(center: CGPoint, radius: Double)], in image: CGImage) -> [RedEyeSpot] {
        let shortSide = Double(min(image.width, image.height))
        guard shortSide > 0 else { return [] }
        return candidates.compactMap { candidate in
            guard redFraction(in: image, center: candidate.center, radius: candidate.radius * 0.6) >= redShare
            else { return nil }
            return RedEyeSpot(center: CGPoint(x: candidate.center.x / Double(image.width),
                                              y: candidate.center.y / Double(image.height)),
                              radius: candidate.radius / shortSide)
        }
    }

    /// The share of pixels within `radius` of `center` (pixels, top-left
    /// origin) that are red by the correction's measure, in linear light.
    static func redFraction(in image: CGImage, center: CGPoint, radius: Double) -> Double {
        let r = max(radius, 1)
        let box = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !box.isNull, box.width >= 1, box.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 0 }
        let width = Int(box.width), height = Int(box.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                          bytesPerRow: width * 16, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.floatComponents.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            // Place the image so the box's top-left pixel lands at the context's top-left.
            context.draw(image, in: CGRect(x: -box.minX, y: box.maxY - CGFloat(image.height),
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return 0 }
        var red = 0, total = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = box.minX + Double(x) + 0.5 - center.x, dy = box.minY + Double(y) + 0.5 - center.y
                guard dx * dx + dy * dy <= r * r else { continue }
                total += 1
                let i = (y * width + x) * 4
                let alpha = max(Double(pixels[i + 3]), 1e-6)
                let r = Double(pixels[i]) / alpha, g = Double(pixels[i + 1]) / alpha, b = Double(pixels[i + 2]) / alpha
                if RedEyeTuning.isPupilRed(red: r, green: g, blue: b), r > 0.02 { red += 1 }
            }
        }
        return total > 0 ? Double(red) / Double(total) : 0
    }
}

extension EditRenderer {
    /// The committed edit (no preview) rendered small, 8-bit sRGB, for
    /// analysis such as face detection: the long edge at most
    /// `maxPixelSize`, from the proxy when it has enough pixels. HDR values
    /// are clipped, which detection doesn't mind.
    public func renderForAnalysis(_ document: EditDocument, maxPixelSize: Int) async throws -> CGImage {
        try await prepare(document)
        guard let source = document.source else { throw EditRenderError.renderFailed }
        let operations = document.operations
        let proxy = document.proxy
        let context = self.context
        return try await Task.detached(priority: .userInitiated) {
            let output = EditGraph.outputSize(source: source.size, operations: operations)
            let long = max(output.width, output.height)
            let maximum = Self.maximumScale(outputSize: output, sourceScale: source.scale)
            let scale = long > 0 ? min(maximum, Double(maxPixelSize) / long) : maximum
            let working = Self.workingImage(source: source, proxy: proxy, scale: scale)
            let image = EditGraph.image(source: working, sourceSize: source.size, operations: operations, scale: scale)
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
            else { throw EditRenderError.renderFailed }
            return result
        }.value
    }
}
