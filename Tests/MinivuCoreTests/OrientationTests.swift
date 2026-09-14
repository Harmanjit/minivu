import Testing
import CoreGraphics
import ImageIO
@testable import MinivuCore

/// Each EXIF orientation must send the stored image's corners to the
/// displayed corners its definition names.
@Suite struct OrientationTests {
    // Stored image 4 wide, 2 tall. Displayed size depends on orientation.
    func map(_ o: CGImagePropertyOrientation, _ p: CGPoint) -> CGPoint {
        let W: CGFloat = o.swapsAxes ? 2 : 4, H: CGFloat = o.swapsAxes ? 4 : 2
        return p.applying(o.transform(width: W, height: H))
    }

    @Test func storedOriginLandsWhereExifSays() {
        // Where stored (0,0), the first pixel of row 0, is displayed.
        #expect(map(.up, .zero) == CGPoint(x: 0, y: 0))
        #expect(map(.upMirrored, .zero) == CGPoint(x: 4, y: 0))
        #expect(map(.down, .zero) == CGPoint(x: 4, y: 2))
        #expect(map(.downMirrored, .zero) == CGPoint(x: 0, y: 2))
        #expect(map(.leftMirrored, .zero) == CGPoint(x: 0, y: 0))
        #expect(map(.right, .zero) == CGPoint(x: 2, y: 0))
        #expect(map(.rightMirrored, .zero) == CGPoint(x: 2, y: 4))
        #expect(map(.left, .zero) == CGPoint(x: 0, y: 4))
    }

    @Test func storedEndOfFirstRowLandsWhereExifSays() {
        let p = CGPoint(x: 4, y: 0)
        #expect(map(.up, p) == CGPoint(x: 4, y: 0))
        #expect(map(.right, p) == CGPoint(x: 2, y: 4))   // row 0 is the right side, running down
        #expect(map(.left, p) == CGPoint(x: 0, y: 0))    // row 0 is the left side, running up
        #expect(map(.leftMirrored, p) == CGPoint(x: 0, y: 4))
        #expect(map(.rightMirrored, p) == CGPoint(x: 2, y: 0))
    }
}
