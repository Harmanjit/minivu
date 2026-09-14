import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

@Suite struct DocumentDecodeTests {
    typealias F = DocumentFixtures

    // MARK: - Render sizes

    @Test func vectorRenderSizes() {
        // An A4 page at 144 dpi (1684 px): full resolution is raised to 4096.
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 1684, maxPixelSize: nil) == (4096, true))
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 1684, maxPixelSize: 2880) == (2880, false))
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 1684, maxPixelSize: 5000) == (4096, true))
        // A poster larger than 4096 renders at its own size, up to Metal's limit.
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 6740, maxPixelSize: nil) == (6740, true))
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 40000, maxPixelSize: nil) == (16384, true))
        // A tiny icon: no point rendering beyond the canvas's 32x zoom.
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 32, maxPixelSize: nil) == (1024, true))
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 32, maxPixelSize: 2880) == (1024, true))
        #expect(ImageDecoder.vectorRenderEdge(longEdge: 32, maxPixelSize: 256) == (256, false))
    }

    // MARK: - PDF

    @Test func pdfInfoIsTheFirstPageAt144DPI() throws {
        let info = try #require(ImageDecoder.info(for: F.twoPagePDF()))
        #expect(info.kind == .pdf)
        #expect(info.pixelSize == CGSize(width: 400, height: 200))   // the 200 x 100 pt crop box
        #expect(info.pageCount == 2)
        #expect(info.documentPageCount == 2)
    }

    @Test func pdfPagesKeepTheirPlaceAtAnySize() throws {
        let url = F.twoPagePDF()
        // Page 1, cropped: red top-left quarter, and the blue outside the
        // crop box never shows. Downscaled (to 100 px) and upscaled (1000 px).
        for edge in [100, 1000] {
            let decoded = try ImageDecoder.decode(url, maxPixelSize: edge, page: 0)
            #expect(decoded.imageSize == CGSize(width: 400, height: 200))
            #expect(decoded.image.width == edge && decoded.image.height == edge / 2)
            #expect(!decoded.isFullResolution)
            let px = F.Pixels(decoded.image)
            let (w, h) = (px.width, px.height)
            #expect(px.isNear(w / 8, h / 4, F.red), "edge \(edge)")
            #expect(px.isNear(w * 3 / 8, h / 4, F.white), "edge \(edge)")
            #expect(px.isNear(w / 8, h * 3 / 4, F.white), "edge \(edge)")
            #expect(px.isNear(1, h / 2, F.white), "edge \(edge)")
            #expect(px.isNear(w - 2, h - 2, F.white), "edge \(edge)")
        }
        // Page 2, turned 90° clockwise: upright 1:2, block now top right.
        for edge in [100, 1000] {
            let decoded = try ImageDecoder.decode(url, maxPixelSize: edge, page: 1)
            #expect(decoded.imageSize == CGSize(width: 200, height: 400))
            #expect(decoded.image.width == edge / 2 && decoded.image.height == edge)
            let px = F.Pixels(decoded.image)
            let (w, h) = (px.width, px.height)
            #expect(px.isNear(w * 3 / 4, h / 8, F.red), "edge \(edge)")
            #expect(px.isNear(w / 4, h / 8, F.white), "edge \(edge)")
            #expect(px.isNear(w * 3 / 4, h * 3 / 8, F.white), "edge \(edge)")
            #expect(px.isNear(w / 4, h * 7 / 8, F.white), "edge \(edge)")
        }
    }

    @Test func pdfFullResolutionRendersLargerThanActualSize() throws {
        let decoded = try ImageDecoder.decode(F.twoPagePDF(), maxPixelSize: nil, page: 1)
        #expect(decoded.isFullResolution)
        #expect(decoded.imageSize == CGSize(width: 200, height: 400))
        #expect(decoded.image.height == 4096 && decoded.image.width == 2048)
    }

    @Test func pdfTransformsForEveryRotation() {
        // A 200 x 100 box at (10, 20) into a render of its displayed size.
        let box = CGRect(x: 10, y: 20, width: 200, height: 100)
        func map(_ rotation: Int, _ p: CGPoint) -> CGPoint {
            let size = rotation % 180 == 0 ? (200, 100) : (100, 200)
            return p.applying(ImageDecoder.pdfTransform(cropBox: box, rotation: rotation,
                                                        width: size.0, height: size.1))
        }
        let topLeft = CGPoint(x: 10, y: 120)   // y points up in PDF space
        #expect(map(0, topLeft) == CGPoint(x: 0, y: 100))
        #expect(map(90, topLeft) == CGPoint(x: 100, y: 200))   // top right
        #expect(map(180, topLeft) == CGPoint(x: 200, y: 0))    // bottom right
        #expect(map(270, topLeft) == CGPoint(x: 0, y: 0))      // bottom left
    }

    // MARK: - SVG

    @Test func svgActualSizeIsRetinaAndTheBackgroundStaysClear() throws {
        let url = F.halfRedSVG()
        let info = try #require(ImageDecoder.info(for: url))
        #expect(info.pixelSize == CGSize(width: 200, height: 100))
        #expect(info.documentPageCount == 1)

        let decoded = try ImageDecoder.decode(url, maxPixelSize: 800)
        #expect(decoded.imageSize == CGSize(width: 200, height: 100))
        #expect(decoded.image.width == 800 && decoded.image.height == 400)
        #expect(!decoded.isFullResolution)
        let px = F.Pixels(decoded.image)
        #expect(px.isNear(200, 200, F.red))
        #expect(px.isNear(600, 200, F.clear))
        // Crisp: the edge between red and clear is at most a pixel wide.
        #expect(px.isNear(398, 200, F.red))
        #expect(px.isNear(402, 200, F.clear))

        let full = try ImageDecoder.decode(url, maxPixelSize: nil)
        #expect(full.isFullResolution && full.image.width == 4096)
    }

    // MARK: - Multi-page TIFF

    @Test func tiffPagesDecodeWithTheirOwnSize() throws {
        let url = F.multiPageTIFF()
        let info = try #require(ImageDecoder.info(for: url))
        #expect(info.documentPageCount == 2)
        let first = try ImageDecoder.decode(url, page: 0)
        #expect(first.imageSize == CGSize(width: 40, height: 20) && first.isFullResolution)
        let second = try ImageDecoder.decode(url, page: 1)
        #expect(second.imageSize == CGSize(width: 30, height: 60) && second.isFullResolution)
        #expect(F.Pixels(second.image).isNear(15, 30, F.blue))
        #expect(ImageDecoder.thumbnail(for: url, maxPixelSize: 64).map { F.Pixels($0).isNear(5, 5, F.red) } == true)
    }
}
