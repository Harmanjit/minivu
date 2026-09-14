import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// Vectors and pages through the loader and cache, as the viewer uses them.
@MainActor @Suite(.serialized) struct DocumentLoadingTests {
    func makeLoader() -> ImageLoader {
        ImageLoader(cache: TextureCache(budgetBytes: 512 << 20))
    }

    func entry(_ url: URL) throws -> FolderEntry {
        try #require(FolderEntry(url: url))
    }

    func load(_ loader: ImageLoader, _ entry: FolderEntry, page: Int = 0, pixelSize: Int?) async throws -> ImageTexture {
        try await withCheckedContinuation { done in
            if let pixelSize {
                loader.load(entry, page: page, pixelSize: pixelSize) { done.resume(returning: $0) }
            } else {
                loader.loadFullResolution(entry, page: page) { done.resume(returning: $0) }
            }
        }.get()
    }

    /// A 100 x 50 pt SVG: 200 x 100 px actual size.
    func writeSVG() throws -> URL {
        let url = Fixtures.directory.appendingPathComponent("vector-\(UUID()).svg")
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><circle cx="25" cy="25" r="20" fill="red"/></svg>"#
        try Data(svg.utf8).write(to: url)
        return url
    }

    /// Two US Letter pages.
    func writePDF() throws -> URL {
        let url = Fixtures.directory.appendingPathComponent("pages-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.fillEllipse(in: CGRect(x: 100, y: 100, width: 200, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// The bug this fixes: a vector rendered for a window larger than its
    /// actual size used to count as full resolution, so zooming in never
    /// asked for (or got) anything sharper.
    @Test func zoomingIntoASmallSVGGetsASharperRender() async throws {
        let loader = makeLoader(), svg = try entry(writeSVG())
        let screen = try await load(loader, svg, pixelSize: 2880)
        #expect(screen.imageSize == CGSize(width: 200, height: 100))
        #expect(screen.texture.width == 2880)
        #expect(!screen.isFullResolution)

        // At 1600% the 2880 px texture is magnified: the canvas asks...
        #expect(CanvasInteraction.needsHigherResolution(isFullResolution: screen.isFullResolution, currentZoom: 16,
                                                        imageLongEdge: 200, textureLongEdge: 2880))
        // ...and full resolution is a larger render, not the texture showing.
        let full = try await load(loader, svg, pixelSize: nil)
        #expect(full !== screen)
        #expect(full.isFullResolution && full.texture.width == 4096)
        #expect(!CanvasInteraction.needsHigherResolution(isFullResolution: full.isFullResolution, currentZoom: 32,
                                                         imageLongEdge: 200, textureLongEdge: 4096))
        // From now on every request is answered by the sharp texture.
        var hit: ImageTexture?
        loader.load(svg, pixelSize: 1000) { hit = try? $0.get() }
        #expect(hit === full)
    }

    @Test func pdfPagesAreCachedApartAndPrefetchedByPage() async throws {
        let loader = makeLoader(), pdf = try entry(writePDF())
        let first = try await load(loader, pdf, page: 0, pixelSize: 1000)
        #expect(first.imageSize == CGSize(width: 1224, height: 1584))
        #expect(first.texture.height == 1000 && !first.isFullResolution)

        loader.prefetch(pages: [(pdf, 1)], pixelSize: 1000)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == 2)
        var second: ImageTexture?
        loader.load(pdf, page: 1, pixelSize: 1000) { second = try? $0.get() }
        #expect(second != nil && second !== first)
        #expect(loader.decodeCount == 2)

        // Zoomed in on the page: its full-resolution render, 4096 px tall.
        let full = try await load(loader, pdf, page: 0, pixelSize: nil)
        #expect(full.isFullResolution && full.texture.height == 4096 && full.imageSize == first.imageSize)
    }
}
