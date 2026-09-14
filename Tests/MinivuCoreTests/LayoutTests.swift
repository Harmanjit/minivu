import Testing
import CoreGraphics
@testable import MinivuCore

/// The page geometry shared by Print and Contact Sheet.
@Suite struct LayoutTests {
    /// A 1000 × 1400 page with 100 margins leaves an 800 × 1200 printable
    /// area, which divides evenly with 20 spacing.
    func layout(columns: Int = 2, rows: Int? = 3, spacing: Double = 20, caption: Double = 0) -> PageLayout {
        PageLayout(pageSize: CGSize(width: 1000, height: 1400), margins: LayoutInsets(all: 100),
                   columns: columns, rows: rows, spacing: spacing, captionHeight: caption)
    }

    @Test func cellsTileTheContentInReadingOrder() {
        let page = layout()
        #expect(page.cellSize(forImageCount: 6) == CGSize(width: 390, height: 386.6666666666667))
        let cells = page.cells(onPage: 0, imageCount: 6)
        #expect(cells.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(cells[0].frame.origin == CGPoint(x: 100, y: 100))
        #expect(cells[1].frame.minX == 510)                  // 100 + 390 + 20
        #expect(abs(cells[2].frame.minY - 506.6666666666667) < 1e-9)
        #expect(abs(cells[5].frame.maxX - 900) < 1e-9 && abs(cells[5].frame.maxY - 1300) < 1e-9)
        #expect(cells.allSatisfy { $0.captionRect == nil && $0.imageArea == $0.frame })
    }

    @Test func marginsHeaderAndFooterShrinkTheContent() {
        var page = PageLayout(pageSize: CGSize(width: 600, height: 800),
                              margins: LayoutInsets(top: 10, left: 20, bottom: 30, right: 40))
        #expect(page.printableRect == CGRect(x: 20, y: 10, width: 540, height: 760))
        #expect(page.headerRect == nil && page.footerRect == nil)
        page.headerHeight = 50
        page.footerHeight = 25
        #expect(page.contentRect == CGRect(x: 20, y: 60, width: 540, height: 685))
        #expect(page.headerRect == CGRect(x: 20, y: 10, width: 540, height: 50))
        #expect(page.footerRect == CGRect(x: 20, y: 745, width: 540, height: 25))

        // Margins wider than the page leave nothing, never a negative size.
        let squeezed = PageLayout(pageSize: CGSize(width: 100, height: 100), margins: LayoutInsets(all: 80))
        #expect(squeezed.contentRect.size == .zero)
        #expect(squeezed.cellSize(forImageCount: 1) == .zero)
    }

    @Test func captionsTakeTheBottomOfEachCell() throws {
        let page = layout(columns: 1, rows: 1, caption: 40)
        let cell = try #require(page.cells(onPage: 0, imageCount: 1).first)
        #expect(cell.frame == CGRect(x: 100, y: 100, width: 800, height: 1200))
        #expect(cell.imageArea == CGRect(x: 100, y: 100, width: 800, height: 1160))
        #expect(cell.captionRect == CGRect(x: 100, y: 1260, width: 800, height: 40))
    }

    @Test func paginates() {
        let page = layout()                                  // 6 per page
        #expect(page.pageCount(forImageCount: 0) == 0)
        #expect(page.pageCount(forImageCount: 1) == 1)
        #expect(page.pageCount(forImageCount: 6) == 1)
        #expect(page.pageCount(forImageCount: 7) == 2)
        #expect(page.pageCount(forImageCount: 1000) == 167)
        #expect(page.indices(onPage: 1, imageCount: 14) == 6..<12)
        #expect(page.indices(onPage: 2, imageCount: 14) == 12..<14)
        #expect(page.indices(onPage: 3, imageCount: 14).isEmpty)
        #expect(page.cells(onPage: 2, imageCount: 14).map(\.index) == [12, 13])
        // The last page's cells are the same size and place as a full page's.
        #expect(page.cells(onPage: 2, imageCount: 14)[1].frame == page.cells(onPage: 0, imageCount: 14)[1].frame)
    }

    @Test func automaticRowsPutEverythingOnOnePage() {
        let page = layout(columns: 4, rows: nil)
        #expect(page.rowCount(forImageCount: 10) == 3)
        #expect(page.pageCount(forImageCount: 10) == 1)
        #expect(page.cells(onPage: 0, imageCount: 10).count == 10)
        #expect(page.rowCount(forImageCount: 0) == 1)
        #expect(page.pageCount(forImageCount: 1000) == 1)
    }

    @Test func centresAPartialPage() {
        var page = layout()                                  // 2 × 3
        page.centersPartialPages = true
        let cells = page.cells(onPage: 1, imageCount: 9)     // 3 images: a full row and one alone
        let size = page.cellSize(forImageCount: 9)
        let usedHeight = 2 * size.height + 20
        #expect(abs(cells[0].frame.minY - (100 + (1200 - usedHeight) / 2)) < 1e-9)
        #expect(cells[0].frame.minX == 100 && cells[1].frame.minX == 510)
        #expect(abs(cells[2].frame.midX - 500) < 1e-9)       // alone in its row, centred
        // A full page doesn't move.
        #expect(page.cells(onPage: 0, imageCount: 9)[0].frame.origin == CGPoint(x: 100, y: 100))
    }

    @Test func fitKeepsTheWholeImageCentred() {
        let page = PageLayout(pageSize: CGSize(width: 1000, height: 1000))
        let area = CGRect(x: 0, y: 0, width: 400, height: 400)
        let wide = page.placement(for: CGSize(width: 6000, height: 4000), in: area)
        #expect(wide.drawRect.minX == 0 && wide.drawRect.width == 400)
        #expect(abs(wide.drawRect.height - 800.0 / 3) < 1e-9 && abs(wide.drawRect.midY - 200) < 1e-9)
        #expect(wide.visibleRect == wide.drawRect)
        #expect(!wide.isRotated)
        #expect(wide.pixelsNeeded(pixelsPerUnit: 300.0 / 72) == 1667)
    }

    @Test func fillCoversTheAreaAndCropsEvenly() {
        let page = PageLayout(pageSize: CGSize(width: 1000, height: 1000), scaling: .fill)
        let area = CGRect(x: 50, y: 50, width: 400, height: 400)
        let wide = page.placement(for: CGSize(width: 6000, height: 4000), in: area)
        #expect(wide.visibleRect == area)
        #expect(wide.drawRect == CGRect(x: -50, y: 50, width: 600, height: 400))
        #expect(wide.drawRect.midX == area.midX)
        #expect(wide.pixelsNeeded(pixelsPerUnit: 1) == 600)
    }

    @Test func autoRotateTurnsImagesThatCoverMoreOnTheirSide() {
        var page = PageLayout(pageSize: CGSize(width: 1000, height: 1000), autoRotate: true)
        let tall = CGRect(x: 0, y: 0, width: 200, height: 300)
        let landscape = page.placement(for: CGSize(width: 3000, height: 2000), in: tall)
        #expect(landscape.isRotated)
        #expect(landscape.drawRect == tall)                  // 3:2 turned is exactly 2:3
        #expect(!page.placement(for: CGSize(width: 2000, height: 3000), in: tall).isRotated)
        #expect(!page.placement(for: CGSize(width: 500, height: 500), in: tall).isRotated)

        page.scaling = .fill
        let filled = page.placement(for: CGSize(width: 4000, height: 2000), in: tall)
        #expect(filled.isRotated && filled.visibleRect == tall)
        #expect(filled.drawRect.size == CGSize(width: 200, height: 400))

        page.autoRotate = false
        #expect(!page.placement(for: CGSize(width: 3000, height: 2000), in: tall).isRotated)
    }

    @Test func emptyImagesAndAreasPlaceNothing() {
        let page = PageLayout(pageSize: CGSize(width: 100, height: 100))
        let area = CGRect(x: 10, y: 10, width: 50, height: 50)
        #expect(page.placement(for: .zero, in: area).drawRect.size == .zero)
        #expect(page.placement(for: CGSize(width: 10, height: 10), in: CGRect(x: 5, y: 5, width: 0, height: 20))
            .visibleRect.size == .zero)
    }

    @Test func imagesPerPagePresetsMakeNearlySquareCells() {
        let portrait = CGSize(width: 595, height: 842)
        let expected: [Int: (Int, Int)] = [1: (1, 1), 2: (1, 2), 4: (2, 2), 6: (2, 3), 9: (3, 3), 12: (3, 4),
                                           20: (4, 5), 30: (5, 6)]
        for count in PageLayout.imagesPerPageChoices {
            let grid = PageLayout.grid(imagesPerPage: count, pageSize: portrait)
            #expect(grid.columns == expected[count]!.0 && grid.rows == expected[count]!.1, "\(count)")
            let turned = PageLayout.grid(imagesPerPage: count, pageSize: CGSize(width: 842, height: 595))
            #expect(turned.columns == expected[count]!.1 && turned.rows == expected[count]!.0, "\(count) landscape")
        }
    }

    @Test func flipsForCoreGraphics() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(PageLayout.flipped(rect, pageHeight: 100) == CGRect(x: 10, y: 40, width: 30, height: 40))
        #expect(PageLayout.flipped(PageLayout.flipped(rect, pageHeight: 100), pageHeight: 100) == rect)
    }
}
