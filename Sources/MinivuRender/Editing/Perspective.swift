import Foundation
import CoreGraphics
import Vision
import MinivuCore

/// The four corners of what should be a rectangle (a building's face, a
/// document, a painting shot from an angle), which perspective correction
/// pulls out to fill an upright rectangle.
///
/// Corners are normalised to the image as it is at the operation's place in
/// the list, top-left origin, like a crop, so they need no scaling on a
/// proxy. Every field decodes with its default (the image's own corner)
/// when missing.
public struct PerspectiveQuad: Codable, Hashable, Sendable {
    public var topLeft = CGPoint(x: 0, y: 0)
    public var topRight = CGPoint(x: 1, y: 0)
    public var bottomRight = CGPoint(x: 1, y: 1)
    public var bottomLeft = CGPoint(x: 0, y: 1)

    public init() {}

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    private enum CodingKeys: String, CodingKey { case topLeft, topRight, bottomRight, bottomLeft }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PerspectiveQuad()
        topLeft = try c.effectsValue(.topLeft, default: d.topLeft)
        topRight = try c.effectsValue(.topRight, default: d.topRight)
        bottomRight = try c.effectsValue(.bottomRight, default: d.bottomRight)
        bottomLeft = try c.effectsValue(.bottomLeft, default: d.bottomLeft)
    }

    /// Clockwise from the top left, the order the overlay's handles use.
    public var corners: [CGPoint] {
        get { [topLeft, topRight, bottomRight, bottomLeft] }
        set {
            guard newValue.count == 4 else { return }
            topLeft = newValue[0]; topRight = newValue[1]; bottomRight = newValue[2]; bottomLeft = newValue[3]
        }
    }

    /// Every corner finite and on the image (a corner off the image would
    /// sample nothing there).
    var sanitized: PerspectiveQuad {
        var q = self
        q.corners = corners.map {
            CGPoint(x: EffectsMath.clamp(Double($0.x), 0...1), y: EffectsMath.clamp(Double($0.y), 0...1))
        }
        return q
    }

    /// A quadrilateral the warp can fill a rectangle from: convex, corners
    /// in clockwise order, and not vanishingly small. A crossed or folded
    /// one has no sensible correction.
    public var isValid: Bool {
        let p = sanitized.corners
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = Double((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
            guard abs(cross) > 1e-9 else { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        // Clockwise on screen (y down) is a positive cross product.
        return sign > 0 && area > 1e-4
    }

    /// The area as a share of the image (the shoelace formula).
    var area: Double {
        let p = sanitized.corners
        var sum = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// The image's own corners (nothing to correct), or a quadrilateral that
    /// can't be corrected.
    public var isIdentity: Bool {
        guard isValid else { return true }
        return zip(sanitized.corners, PerspectiveQuad().corners).allSatisfy { a, b in
            abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
        }
    }

    /// The size of the corrected image for a `width` x `height` input: the
    /// longer of each pair of opposite edges, in its pixels, so no detail
    /// along an edge is squeezed. The true proportions of the rectangle
    /// photographed can't be known without the lens's focal length, and the
    /// longer edges are the usual estimate.
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let p = sanitized.corners.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }
        let w = max(length(p[0], p[1]), length(p[3], p[2]))
        let h = max(length(p[0], p[3]), length(p[1], p[2]))
        func side(_ v: Double) -> Int { min(max(1, Int(v.rounded())), CanvasSize.maximumSide) }
        return (side(w), side(h))
    }

    /// The projective map taking the unit square's corners (0,0), (1,0),
    /// (1,1) and (0,1) to `p0`...`p3`, as the eight free entries of its
    /// 3 x 3 matrix by rows (the ninth is 1): x = (m0 u + m1 v + m2) / w and
    /// y = (m3 u + m4 v + m5) / w with w = m6 u + m7 v + 1. Heckbert's
    /// closed form, exact for any convex quadrilateral.
    static func squareToQuad(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> [Double] {
        let x0 = Double(p0.x), y0 = Double(p0.y), x1 = Double(p1.x), y1 = Double(p1.y)
        let x2 = Double(p2.x), y2 = Double(p2.y), x3 = Double(p3.x), y3 = Double(p3.y)
        let dx3 = x0 - x1 + x2 - x3, dy3 = y0 - y1 + y2 - y3
        if abs(dx3) < 1e-12 && abs(dy3) < 1e-12 {
            // A parallelogram: the map is affine.
            return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0]
        }
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let det = dx1 * dy2 - dx2 * dy1
        guard abs(det) > 1e-12 else { return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0] }
        let g = (dx3 * dy2 - dx2 * dy3) / det
        let h = (dx1 * dy3 - dx3 * dy1) / det
        return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h]
    }
}

/// Proposes perspective corners for the tool's Auto button.
///
/// Vision's rectangle detector finds the most prominent four-sided shape
/// (a document, a screen, a window, a building's face when it stands out).
/// It runs on a small rendering of the edit as it stands
/// (`EditRenderer.renderForAnalysis`), in some tens of milliseconds.
public enum PerspectiveDetector {
    /// The detected quadrilateral in the image's normalised top-left
    /// coordinates, or nil when nothing four-sided stands out. Synchronous:
    /// call it off the main thread.
    public static func detect(in image: CGImage) -> PerspectiveQuad? {
        BlockingWork.expectOffCooperativePool("PerspectiveDetector.detect(in:)")
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        // Any proportions, any size above a fifth of the picture, and
        // corners up to 30 degrees off square: a facade shot from the street
        // converges strongly.
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1
        request.minimumSize = 0.2
        request.quadratureTolerance = 30
        request.minimumConfidence = 0.5
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let found = request.results?.first else { return nil }
        // Vision's points are normalised with the origin at the bottom left.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        let quad = PerspectiveQuad(topLeft: flip(found.topLeft), topRight: flip(found.topRight),
                                   bottomRight: flip(found.bottomRight), bottomLeft: flip(found.bottomLeft))
        return quad.isValid ? quad.sanitized : nil
    }
}
