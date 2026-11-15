import Foundation
import Accelerate

/// The pairs of images whose feature prints are close, from which groups of
/// similar images are drawn at any threshold up to `maximumDistance` (G5).
///
/// Built once per run: every print is compared with every other by one
/// matrix product a block of rows at a time (Accelerate), using
/// |a - b|² = |a|² + |b|² - 2a·b, so 10,000 images cost seconds rather than
/// the minutes fifty million separate comparisons would. Each image keeps at
/// most `neighbours` pairs, its nearest, so memory stays proportional to the
/// number of images whatever the pictures. Moving the threshold only joins
/// the pairs under it (`groups(threshold:)`), which is instant.
///
/// Groups are joined through any chain of close pairs (single linkage): if
/// A is like B and B like C, all three are one group, as a burst of shots
/// should be.
public struct SimilarityIndex: Sendable {
    public struct Pair: Sendable, Equatable {
        public var first: Int
        public var second: Int
        public var distance: Float
    }

    /// The number of prints indexed; groups name them by position.
    public let count: Int
    public let maximumDistance: Float
    /// Closest first.
    public let pairs: [Pair]

    /// The thresholds the user can choose between, as Vision distances, and
    /// where the slider starts. Measured with revision 2 prints
    /// (DuplicateFinderTests): a resized or re-encoded copy of a picture
    /// lands 0.05 to 0.42 from the original (a PNG of the same pixels 0.05
    /// to 0.08), while different pictures of the same kind land 0.56 and
    /// more apart. 0.45 joins the copies and keeps the rest apart; stricter
    /// finds only near-identical copies, looser finds variations (a burst,
    /// a crop).
    public static let thresholdRange: ClosedRange<Float> = 0.05...0.8
    public static let defaultThreshold: Float = 0.45

    /// Rows of the distance matrix computed at once: 256 × 20,000 floats is
    /// 20 MB.
    static let blockRows = 256

    /// - Parameters:
    ///   - prints: one per image; a print of another revision or length than
    ///     the first is left unpaired.
    ///   - maximumDistance: the loosest threshold the user can choose.
    ///   - neighbours: pairs kept per image at most.
    ///   - isCancelled: asked between blocks; a cancelled index has the pairs
    ///     found so far.
    public init(prints: [FeaturePrint], maximumDistance: Float, neighbours: Int = 16,
                isCancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) {
        count = prints.count
        self.maximumDistance = maximumDistance
        guard let reference = prints.first, prints.count > 1 else {
            pairs = []
            return
        }
        let dimension = reference.vector.count
        let usable = prints.indices.filter {
            prints[$0].revision == reference.revision && prints[$0].vector.count == dimension
        }
        let n = usable.count
        guard n > 1, dimension > 0 else {
            pairs = []
            return
        }
        // Rows of the matrix are the prints; the transpose holds them as
        // columns for the product.
        var rows = [Float](repeating: 0, count: n * dimension)
        for (row, index) in usable.enumerated() {
            rows.replaceSubrange(row * dimension..<(row + 1) * dimension, with: prints[index].vector)
        }
        var columns = [Float](repeating: 0, count: n * dimension)
        vDSP_mtrans(rows, 1, &columns, 1, vDSP_Length(dimension), vDSP_Length(n))
        var norms = [Float](repeating: 0, count: n)
        for row in 0..<n {
            rows.withUnsafeBufferPointer { buffer in
                vDSP_svesq(buffer.baseAddress! + row * dimension, 1, &norms[row], vDSP_Length(dimension))
            }
        }

        let limit = maximumDistance * maximumDistance
        var found: [Pair] = []
        var block = [Float](repeating: 0, count: Self.blockRows * n)
        var start = 0
        while start < n, !isCancelled() {
            let height = min(Self.blockRows, n - start)
            rows.withUnsafeBufferPointer { a in
                vDSP_mmul(a.baseAddress! + start * dimension, 1, columns, 1, &block, 1,
                          vDSP_Length(height), vDSP_Length(n), vDSP_Length(dimension))
            }
            for r in 0..<height {
                let i = start + r
                var nearest: [(j: Int, d2: Float)] = []
                for j in (i + 1)..<max(i + 1, n) {
                    let d2 = max(0, norms[i] + norms[j] - 2 * block[r * n + j])
                    guard d2 <= limit else { continue }
                    nearest.append((j, d2))
                }
                if nearest.count > neighbours {
                    nearest.sort { $0.d2 < $1.d2 }
                    nearest.removeLast(nearest.count - neighbours)
                }
                for (j, d2) in nearest {
                    found.append(Pair(first: usable[i], second: usable[j], distance: d2.squareRoot()))
                }
            }
            start += height
            progress(start, n)
        }
        pairs = found.sorted { ($0.distance, $0.first, $0.second) < ($1.distance, $1.first, $1.second) }
    }

    /// The groups of two or more images joined by pairs no further apart
    /// than `threshold`: each group's positions in ascending order, the
    /// groups in the order of their first image.
    public func groups(threshold: Float) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for pair in pairs {
            if pair.distance > threshold { break }
            let a = root(pair.first), b = root(pair.second)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        var members: [Int: [Int]] = [:]
        for i in 0..<count {
            members[root(i), default: []].append(i)
        }
        return members.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }
}
