import Testing
import CoreGraphics
@testable import MinivuCore

@Suite struct DecodeSizeTests {
    @Test func snapsToCodecFractions() {
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3000) == 3016)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3024) == 3016)   // within 3%
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 1400) == 1508)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 500) == 754)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3200) == 6032)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 101, needed: 20) == 26)        // rounds up
    }

    @Test func fitsTheImageIntoTheView() {
        func fit(_ iw: CGFloat, _ ih: CGFloat, _ vw: CGFloat, _ vh: CGFloat) -> Int {
            ImageDecoder.fittedLongEdge(imageSize: CGSize(width: iw, height: ih), in: CGSize(width: vw, height: vh))
        }
        // A 24 MP 3:2 photo on a 3420 px wide canvas: the height limits it.
        #expect(fit(6000, 4000, 3420, 2214) == 3321)
        #expect(fit(6000, 4000, 3420, 2000) == 3000)
        #expect(fit(6000, 4000, 3000, 3000) == 3000)   // a square view gives its side
        #expect(fit(4000, 6000, 3000, 3000) == 3000)
        // Portrait in a landscape view, and the same view turned.
        #expect(fit(4000, 6000, 3420, 2214) == 2214)
        #expect(fit(4000, 6000, 2214, 3420) == 3321)
        // Width-limited, exactly on a pixel despite a scale like 3420/6032.
        #expect(fit(6032, 4032, 3420, 3000) == 3420)
        #expect(fit(6032, 4032, 3420, 2048) == 3064)
        // Small images are enlarged to fit; callers cap at the image.
        #expect(fit(400, 200, 3000, 3000) == 3000)
        // Unknown image size: the view's long edge.
        #expect(fit(0, 0, 3420, 2214) == 3420)
    }

    @Test func wantedLongEdgeTakesTheSmallerLimit() {
        let image = CGSize(width: 6000, height: 4000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: nil, fitting: nil) == nil)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: 2000, fitting: nil) == 2000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: nil, fitting: CGSize(width: 3420, height: 2000)) == 3000)
        #expect(ImageDecoder.wantedLongEdge(imageSize: image, maxPixelSize: 2000, fitting: CGSize(width: 3420, height: 2000)) == 2000)
    }
}
