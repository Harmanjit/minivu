import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import MinivuCore

// Remove Background and Copy Subject (G8): Vision's subject mask, found
// once on a small rendering of the picture and stored with the operation,
// so every render, at any scale, cuts along the same edge.

/// Where the subject of a picture is: Vision's foreground mask as 8-bit
/// coverage (255 inside the subject, 0 outside, soft along the edge), at
/// the size it was found at, and stored as PNG.
///
/// A mask covers the whole picture it was found in, so at render time it is
/// simply stretched over the image whatever its working size: a proxy and
/// the saved file cut along the same edge. Vision's own mask is 512 px
/// square (measured on macOS 27) and scaled to the picture analysed, so a
/// mask of 1536 px holds everything it has; a soft edge stretched further
/// stays soft.
///
/// A class so the decoded mask is made once and shared by every copy of the
/// operation (a document's history, an export's snapshot): equality is by
/// value, the decoded image by reference. Immutable apart from that cache,
/// which a lock guards.
///
/// Operations are compared on the main thread whenever a tool checks for a
/// change, and a mask is up to a few hundred KB of PNG, so each mask hashes
/// its bytes once when made (`digest`): two different masks tell each other
/// apart by that alone, and only masks with the same digest compare bytes.
public final class SubjectMask: Codable, Hashable, @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// The coverage, as an 8-bit greyscale PNG with no colour profile.
    public let png: Data
    /// The subject's bounding box in the picture, normalised, top-left
    /// origin: where more than half of a pixel is subject.
    public let bounds: CGRect
    /// The PNG's hash, taken once (see the type's notes).
    let digest: Int

    private let lock = NSLock()
    private var decoded: CIImage?

    /// A mask from coverage values, rows top first; nil when nothing in it
    /// is subject.
    public convenience init?(coverage: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, coverage.count >= width * height else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where coverage[row + x] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, let png = Self.encode(coverage, width: width, height: height) else {
            return nil
        }
        let bounds = CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        self.init(width: width, height: height, png: png, bounds: bounds)
    }

    init(width: Int, height: Int, png: Data, bounds: CGRect) {
        self.width = width
        self.height = height
        self.png = png
        self.bounds = bounds
        var hasher = Hasher()
        hasher.combine(png)
        digest = hasher.finalize()
    }

    private enum CodingKeys: String, CodingKey { case width, height, png, bounds }

    public convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  png: try c.decode(Data.self, forKey: .png),
                  bounds: try c.effectsValue(.bounds, default: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(png, forKey: .png)
        try c.encode(bounds, forKey: .bounds)
    }

    public static func == (a: SubjectMask, b: SubjectMask) -> Bool {
        a === b || (a.digest == b.digest && a.width == b.width && a.height == b.height && a.png == b.png)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(digest)
    }

    /// Nothing to cut along: a mask that can't be decoded.
    public var isEmpty: Bool { width <= 0 || height <= 0 || png.isEmpty }

    /// The coverage as a Core Image image, extent at the origin, values as
    /// stored (no colour management: coverage is not a colour). Decoded once.
    var image: CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let decoded { return decoded }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width == width, cgImage.height == height else { return nil }
        decoded = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        return decoded
    }

    private static func encode(_ coverage: [UInt8], width: Int, height: Int) -> Data? {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(coverage.prefix(width * height)) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Everything but the subject made transparent, or filled with a colour.
public struct RemoveBackground: Codable, Hashable, Sendable {
    public var mask: SubjectMask
    /// What takes the background's place: alpha 0 (the default) leaves it
    /// transparent, which only formats with alpha keep (others flatten it
    /// when saving, as Save As's background option says).
    public var fill = EditColor(red: 1, green: 1, blue: 1, alpha: 0)

    public init(mask: SubjectMask, fill: EditColor = EditColor(red: 1, green: 1, blue: 1, alpha: 0)) {
        self.mask = mask
        self.fill = fill
    }

    private enum CodingKeys: String, CodingKey { case mask, fill }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mask = try c.decode(SubjectMask.self, forKey: .mask)
        fill = try c.effectsValue(.fill, default: EditColor(red: 1, green: 1, blue: 1, alpha: 0))
    }

    public var isIdentity: Bool { mask.isEmpty }
}

/// Finds the subject of a picture with Vision's foreground instance mask
/// (`VNGenerateForegroundInstanceMaskRequest`, the request behind "Copy
/// Subject" across macOS), on device. Every instance it finds counts: a
/// person and the dog beside them are lifted together.
public enum SubjectDetector {
    /// The subject of `image` as a mask at its size, or nil when Vision finds
    /// none (a landscape, a texture) or can't run (a Mac without the model).
    /// Synchronous, a few hundred milliseconds: call it off the main thread.
    public static func mask(in image: CGImage) -> SubjectMask? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                       from: handler) else { return nil }
        return mask(from: buffer)
    }

    /// A one-channel float or byte pixel buffer as coverage.
    static func mask(from buffer: CVPixelBuffer) -> SubjectMask? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    let v = row[x].isFinite ? min(max(row[x], 0), 1) : 0
                    coverage[y * width + x] = UInt8((v * 255).rounded())
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { coverage[y * width + x] = row[x] }
            }
        default:
            return nil
        }
        return SubjectMask(coverage: coverage, width: width, height: height)
    }
}

// MARK: - Graph

enum SubjectGraph {
    /// The image where the mask is subject, `fill` (or transparency) where
    /// it isn't. The mask is stretched over the image's working size with
    /// bilinear sampling, so its edge lands in the same place at every scale;
    /// its own edge pixels repeat outward first, or the picture's border
    /// would blend half with nothing.
    ///
    /// `CIBlendWithMask` mixes per pixel without clamping, so HDR values in
    /// what remains stay above 1 (and the mask, a coverage between 0 and 1,
    /// loses nothing through the clamp's 8-bit buffer on macOS 27).
    static func removeBackground(_ image: CIImage, _ op: RemoveBackground) -> CIImage {
        guard let mask = op.mask.image else { return image }
        let extent = image.extent
        let stretch = CGAffineTransform(scaleX: extent.width / CGFloat(op.mask.width),
                                        y: extent.height / CGFloat(op.mask.height))
        let coverage = mask.clampedToExtent().transformed(by: stretch).cropped(to: extent)
        let background = op.fill.alpha > 0 ? op.fill.image.cropped(to: extent) : CIImage(color: .clear).cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: coverage,
        ]).cropped(to: extent)
    }
}

extension EditRenderer {
    /// The long edge Remove Background and Copy Subject analyse at: three
    /// times Vision's own mask, so nothing it finds is lost, and a fraction
    /// of a second.
    public nonisolated static let subjectPixelSize = 1536

    /// The subject of the picture `operations` make of the document (the
    /// committed ones when nil), found by Vision on a rendering of it no
    /// larger than `subjectPixelSize`; nil when there is none. Kept on the
    /// document for those operations, so asking again (the tool reopened,
    /// Copy Subject after Remove Background was looked at) costs nothing, and
    /// never found again per render: the mask goes into the operation.
    public func subjectMask(for document: EditDocument, operations: [EditOperation]? = nil) async throws -> SubjectMask? {
        let operations = operations ?? document.operations
        if let cached = document.subjectMaskCache, cached.operations == operations { return cached.mask }
        let image = try await renderForAnalysis(document, operations: operations, maxPixelSize: Self.subjectPixelSize)
        let mask = await BlockingWork.run { SubjectDetector.mask(in: image) }
        document.subjectMaskCache = (operations, mask)
        return mask
    }
}
