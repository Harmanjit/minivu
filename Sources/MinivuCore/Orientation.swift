import CoreGraphics
import ImageIO

extension CGImagePropertyOrientation {
    /// True for the four orientations that turn the image sideways, where
    /// the displayed width is the stored height.
    public var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }

    /// Maps stored-image coordinates to displayed-image coordinates, both
    /// with a top-left origin and y pointing down. `width` and `height` are
    /// the displayed (oriented) size.
    ///
    /// Derived from the EXIF definitions, e.g. `.right` (6): "row 0 is the
    /// visual right-hand side, column 0 is the visual top", so a stored point
    /// (x, y) is displayed at (width - y, x).
    public func transform(width W: CGFloat, height H: CGFloat) -> CGAffineTransform {
        switch self {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case .leftMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: W, ty: 0)
        case .rightMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H)
        case .left: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: H)
        @unknown default: .identity
        }
    }
}
