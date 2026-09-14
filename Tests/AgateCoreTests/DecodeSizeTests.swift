import Testing
@testable import AgateCore

@Suite struct DecodeSizeTests {
    @Test func snapsToCodecFractions() {
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3000) == 3016)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3024) == 3016)   // within 3%
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 1400) == 1508)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 500) == 754)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 6032, needed: 3200) == 6032)
        #expect(ImageDecoder.scaledDecodeSize(longestEdge: 101, needed: 20) == 26)        // rounds up
    }
}
