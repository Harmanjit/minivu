import Foundation
import CoreGraphics
import Vision

/// What an image looks like, as Vision's feature print: a vector that lands
/// near another image's when the pictures look alike (G5). Computed on the
/// device from a thumbnail-sized decode, never from the full image.
///
/// Kept as plain floats rather than the `VNFeaturePrintObservation`, so the
/// cache stores a few kilobytes of bytes and comparing two thousand images
/// is one matrix product (`SimilarityIndex`) instead of four million calls
/// into Vision. The distance is Vision's own: the Euclidean distance between
/// the vectors (`computeDistance` agrees, which the tests check).
public struct FeaturePrint: Sendable, Equatable {
    /// Vision's revision of the request that made it. Prints of different
    /// revisions can't be compared, so the cache keeps the revision too.
    public var revision: Int
    public var vector: [Float]

    public init(revision: Int, vector: [Float]) {
        self.revision = revision
        self.vector = vector
    }

    /// The long edge of the decode a print is made from: the browser's small
    /// thumbnail tier, so a folder already browsed costs no decode at all,
    /// and more than the network looks at (it scales its input down further).
    public static let decodeSize = 256

    /// The request's revision this minivu uses: the newest the system has.
    public static var currentRevision: Int {
        VNGenerateImageFeaturePrintRequest.currentRevision
    }

    /// The Euclidean distance between two prints, or nil when they can't be
    /// compared (another revision or length).
    public func distance(to other: FeaturePrint) -> Float? {
        guard revision == other.revision, vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var sum: Float = 0
        for i in vector.indices {
            let d = vector[i] - other.vector[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// The print of `image`, nil when Vision can't make one.
    public static func make(from image: CGImage) -> FeaturePrint? {
        BlockingWork.expectOffCooperativePool("FeaturePrint.make(from:)")
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return FeaturePrint(observation: observation, revision: request.revision)
    }

    /// The print of the image file: the thumbnail cache's small tier if it
    /// holds a current one, else a thumbnail-sized decode (embedded RAW
    /// previews included, as for the browser's thumbnails).
    public static func make(for entry: FolderEntry, thumbnails: ThumbnailStore?) -> FeaturePrint? {
        let image = autoreleasepool { () -> CGImage? in
            for tier in ThumbnailService.tiers {
                if let cached = thumbnails?.image(for: entry.url, modified: entry.modified,
                                                  fileSize: entry.fileSize, tier: tier) {
                    return cached
                }
            }
            return ImageDecoder.thumbnail(for: entry.url, maxPixelSize: decodeSize)
        }
        guard let image else { return nil }
        return autoreleasepool { make(from: image) }
    }

    init?(observation: VNFeaturePrintObservation, revision: Int) {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        let data = observation.data
        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return nil }
            vector = Self.floats(data, count: count)
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return nil }
            var doubles = [Double](repeating: 0, count: count)
            _ = doubles.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            vector = doubles.map { Float($0) }
        default:
            return nil
        }
        self.revision = revision
    }

    // MARK: - Storage

    /// The vector as little-endian bytes, for the cache.
    var bytes: Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    init?(revision: Int, bytes: Data) {
        let count = bytes.count / MemoryLayout<Float>.size
        guard count > 0, bytes.count == count * MemoryLayout<Float>.size else { return nil }
        self.revision = revision
        vector = Self.floats(bytes, count: count)
    }

    /// Copied rather than bound: a blob's bytes needn't be aligned for Float.
    private static func floats(_ data: Data, count: Int) -> [Float] {
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }
}
