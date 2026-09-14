import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// `EditRenderer` end to end: files on disk -> prepare -> preview and full
/// renders -> textures, and exports -> CGImages.
@MainActor @Suite(.serialized) struct EditRendererTests {
    typealias F = EditFixtures
    let renderer = EditRenderer.shared

    func document(_ url: URL) -> EditDocument {
        EditDocument(entry: FolderEntry(url: url)!)
    }

    func quadrantFile(width: Int = 64, height: Int = 32, type: UTType = .tiff,
                      orientation: CGImagePropertyOrientation = .up) -> URL {
        Fixtures.write(Fixtures.quadrants(width: width, height: height),
                       name: "edit-\(width)x\(height)-\(UUID()).\(type.preferredFilenameExtension!)", type: type,
                       orientation: orientation)
    }

    func preview(_ doc: EditDocument, _ pixelSize: Int) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderPreview(doc, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    func fullResolution(_ doc: EditDocument) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderFullResolution(doc) { continuation.resume(returning: $0) }
        }
    }

    func waitUntilIdle(_ doc: EditDocument) async {
        while doc.previewLane.isRunning || doc.previewLane.pending != nil || doc.fullLane.isRunning
            || doc.fullLane.pending != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The dominant colour of a pixel from the sRGB quadrant fixture, which
    /// arrives as linear Display P3 (sRGB red is about (0.82, 0.03, 0.02)).
    func colour(_ p: SIMD4<Float>) -> String {
        if p.x > 0.9 && p.y > 0.9 && p.z > 0.9 { return "white" }
        if p.x > 0.7 && p.y < 0.1 && p.z < 0.1 { return "red" }
        if p.y > 0.7 && p.x < 0.3 && p.z < 0.3 { return "green" }
        if p.z > 0.7 && p.x < 0.1 && p.y < 0.1 { return "blue" }
        return "\(p)"
    }

    func quadrantColours(_ texture: ImageTexture) -> [String] {
        let p = F.pixels(texture.texture)
        return [p.at(0.25, 0.25), p.at(0.75, 0.25), p.at(0.25, 0.75), p.at(0.75, 0.75)].map(colour)
    }

    // MARK: - Previews

    @Test func smallImageRendersFromTheOriginal() async throws {
        let doc = document(quadrantFile())
        try await renderer.prepare(doc)
        #expect(doc.sourceSize == CGSize(width: 64, height: 32))
        #expect(doc.proxy == nil)   // smaller than any screen

        let plain = await preview(doc, 1000)
        #expect(plain.texture.width == 64 && plain.texture.height == 32 && plain.texture.mipmapLevelCount > 1)
        #expect(plain.imageSize == CGSize(width: 64, height: 32) && plain.isFullResolution)
        #expect(quadrantColours(plain) == ["red", "green", "blue", "white"])

        doc.apply(.rotate90(turns: 1))
        let turned = await preview(doc, 1000)
        #expect(turned.texture.width == 32 && turned.texture.height == 64 && turned.imageSize == doc.outputSize)
        #expect(quadrantColours(turned) == ["blue", "red", "white", "green"])

        doc.preview = .crop(CGRect(x: 0, y: 0.5, width: 1, height: 0.5))   // bottom half of the turned image
        let cropped = await preview(doc, 1000)
        #expect(cropped.texture.width == 32 && cropped.texture.height == 32)
        #expect(quadrantColours(cropped) == ["white", "green", "white", "green"])
    }

    @Test func previewsUseTheProxyAndGrowItForCrops() async throws {
        let doc = document(quadrantFile(width: 1600, height: 800))
        try await renderer.prepare(doc, proxyPixelSize: 400)
        #expect(doc.proxy?.scale == 0.25)
        #expect(doc.proxy?.texture.width == 400 && doc.proxy?.texture.height == 200)

        let whole = await preview(doc, 400)
        #expect(whole.texture.width == 400 && whole.texture.height == 200)
        #expect(whole.imageSize == CGSize(width: 1600, height: 800) && !whole.isFullResolution)
        #expect(quadrantColours(whole) == ["red", "green", "blue", "white"])
        // Lanczos from repeated edges: the proxy's border is opaque.
        let proxyPixels = F.pixels(whole.texture)
        #expect(abs(proxyPixels[0, 0].w - 1) < 1e-3 && abs(proxyPixels[399, 199].w - 1) < 1e-3)

        doc.apply(.crop(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        let crop = await preview(doc, 400)
        // The crop needs scale 0.5; the new proxy is a quarter larger, so a
        // crop dragged a little smaller doesn't rebuild it again.
        #expect(crop.texture.width == 500 && crop.texture.height == 250)
        #expect(crop.imageSize == CGSize(width: 800, height: 400))
        #expect(quadrantColours(crop) == ["white", "white", "white", "white"])
        #expect(doc.proxy?.scale == 0.625)   // grown for the crop

        doc.undo()
        let back = await preview(doc, 400)
        #expect(back.texture.width == 400 && back.texture.height == 200)
        #expect(doc.proxy?.scale == 0.625)   // proxies only grow

        let full = await fullResolution(doc)
        #expect(full.texture.width == 1600 && full.texture.height == 800 && full.isFullResolution)
        #expect(quadrantColours(full) == ["red", "green", "blue", "white"])
    }

    @Test func coalescedRequestsEndOnTheNewestState() async throws {
        let doc = document(quadrantFile())
        try await renderer.prepare(doc)
        var delivered: [ImageTexture] = []
        for i in 1...10 {
            doc.preview = .lighting(brightness: Double(i) / 20, contrast: 0, gamma: 1, shadows: 0, highlights: 0)
            renderer.renderPreview(doc, pixelSize: 64) { delivered.append($0) }
        }
        await waitUntilIdle(doc)
        #expect(!delivered.isEmpty && delivered.count <= 2, "\(delivered.count) deliveries")

        let expected = await preview(doc, 64)
        let last = F.pixels(delivered.last!.texture)
        #expect(nearly(last[5, 5], F.pixels(expected.texture)[5, 5], 1e-4))
        #expect(last[40, 25].x > 1.2)   // white lifted by brightness 0.5 is well above 1
    }

    @Test func deliveriesNeverGoBackToAnOlderState() async throws {
        let doc = document(quadrantFile(width: 1600, height: 800))
        try await renderer.prepare(doc, proxyPixelSize: 400)
        var shown: [Float] = []   // red channel of the top-left pixel of each delivery
        func record(_ texture: ImageTexture) { shown.append(F.pixels(texture.texture).at(0.1, 0.1).x) }

        doc.preview = .rgbAdjust(red: -1, green: 0, blue: 0)
        renderer.renderFullResolution(doc) { record($0) }
        try await Task.sleep(for: .milliseconds(1))   // let it take its snapshot of the document
        doc.preview = .rgbAdjust(red: 0, green: 0, blue: 0)
        renderer.renderPreview(doc, pixelSize: 400) { record($0) }
        await waitUntilIdle(doc)
        #expect(!shown.isEmpty)
        // Halved red (0.41) may come first, but never after full red (0.82).
        if let firstFull = shown.firstIndex(where: { $0 > 0.7 }) {
            #expect(shown[firstFull...].allSatisfy { $0 > 0.7 }, "\(shown)")
        }
        #expect(shown.last! > 0.7)
    }

    @Test func deliveryOrder() {
        func ok(_ revision: Int, _ full: Bool, after last: (Int, Bool)?) -> Bool {
            EditRenderer.shouldDeliver(revision: revision, full: full, after: last.map { (revision: $0.0, full: $0.1) })
        }
        #expect(ok(1, false, after: nil))
        #expect(ok(2, false, after: (1, true)))        // a newer state
        #expect(ok(2, true, after: (2, false)))        // sharper, same state
        #expect(ok(2, false, after: (2, false)))       // a larger preview of the same state
        #expect(!ok(1, true, after: (2, false)))       // full resolution of an older state
        #expect(!ok(2, false, after: (2, true)))       // blurrier, same state
    }

    // MARK: - Plans

    @Test func previewPlans() {
        let size = CGSize(width: 6000, height: 4000)
        // Proxy big enough: used as it is.
        #expect(EditRenderer.previewPlan(outputSize: size, pixelSize: 3000, proxyScale: 0.5)
                == .init(scale: 0.5, maximumScale: 1, useProxy: true, rebuildProxy: false))
        // Much smaller window: the proxy, resampled down first.
        #expect(EditRenderer.previewPlan(outputSize: size, pixelSize: 1200, proxyScale: 0.5)
                == .init(scale: 0.2, maximumScale: 1, useProxy: true, rebuildProxy: false))
        // A crop to a quarter needs twice the proxy's pixels: a new proxy.
        #expect(EditRenderer.previewPlan(outputSize: CGSize(width: 3000, height: 2000), pixelSize: 3000, proxyScale: 0.5)
                == .init(scale: 1, maximumScale: 1, useProxy: false, rebuildProxy: false))
        // Needs 0.5, the proxy has 0.25: rebuilt a quarter larger than needed.
        #expect(EditRenderer.previewPlan(outputSize: CGSize(width: 4800, height: 3200), pixelSize: 2400, proxyScale: 0.25)
                == .init(scale: 0.625, maximumScale: 1, useProxy: true, rebuildProxy: true))
        // ...but not past the point where the original serves instead.
        #expect(EditRenderer.previewPlan(outputSize: CGSize(width: 4800, height: 3200), pixelSize: 3300, proxyScale: 0.25)
                == .init(scale: 3300.0 / 4800, maximumScale: 1, useProxy: true, rebuildProxy: true))
        // Growing a crop 5% at a time rebuilds the proxy once, not every step.
        var proxy = 0.25, rebuilds = 0
        for step in 0..<6 {
            let plan = EditRenderer.previewPlan(outputSize: CGSize(width: 6000 - 250 * step, height: 4000),
                                                pixelSize: 1500, proxyScale: proxy)
            if plan.rebuildProxy { proxy = plan.scale; rebuilds += 1 }
        }
        #expect(rebuilds == 1, "\(rebuilds) rebuilds")
        // Enlarged past Metal's limit: capped.
        let huge = EditRenderer.fullResolutionPlan(outputSize: CGSize(width: 32768, height: 1000))
        #expect(huge.scale == 0.5 && huge.maximumScale == 0.5)
        #expect(EditRenderer.proxyScale(sourceSize: size, longEdge: 3000) == 0.5)
        #expect(EditRenderer.proxyScale(sourceSize: CGSize(width: 3200, height: 2000), longEdge: 3000) == nil)
        // An original past the texture limit (shown at half its size) caps
        // every render at the pixels it has.
        let wide = EditRenderer.fullResolutionPlan(outputSize: CGSize(width: 32768, height: 1000), sourceScale: 0.5)
        #expect(wide.scale == 0.5)
        #expect(EditRenderer.fullResolutionPlan(outputSize: CGSize(width: 4000, height: 1000), sourceScale: 0.5).scale == 0.5)
        #expect(EditRenderer.previewPlan(outputSize: CGSize(width: 32768, height: 1000), pixelSize: 16000, proxyScale: nil,
                                         sourceScale: 0.5) == .init(scale: 0.5, maximumScale: 0.5, useProxy: false,
                                                                    rebuildProxy: false))
        #expect(EditRenderer.proxyScale(sourceSize: CGSize(width: 32768, height: 1000), sourceScale: 0.5, longEdge: 14000) == nil)
    }

    // MARK: - Sources

    @Test func exifOrientedJPEGIsEditedUpright() async throws {
        // Orientation 6: displayed turned clockwise, so blue (stored bottom-left) shows top-left.
        let doc = document(quadrantFile(type: .jpeg, orientation: .right))
        try await renderer.prepare(doc)
        #expect(doc.sourceSize == CGSize(width: 32, height: 64))
        let texture = await preview(doc, 64)
        #expect(quadrantColours(texture) == ["blue", "red", "white", "green"])
    }

    @Test func hdrSourceKeepsItsHighlightsThroughColourOperations() async throws {
        let doc = document(try Fixtures.gainMapHEIC())
        try await renderer.prepare(doc)
        #expect(doc.source?.isHDR == true && doc.source?.texture?.pixelFormat == .rgba16Float)
        doc.apply(.colors(hue: 0, saturation: 0.1, lightness: 0, temperature: 0.1, tint: 0))
        doc.apply(.curves(ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)])))
        let texture = await preview(doc, 1000)
        #expect(texture.isHDR && texture.contentHeadroom > 3)
        let p = F.pixels(texture.texture)
        let bright = max(p[p.width - 2, p.height / 2].x, p[p.width - 2, p.height / 2].y)
        #expect(bright > 2.5, "bright end \(bright)")
    }

    @Test(.enabled(if: RawRendererTests.hasAssets))
    func rawFilePreparesAtSensorSize() async throws {
        let doc = document(RawRendererTests.portraitNEF)
        try await renderer.prepare(doc, proxyPixelSize: 1500)
        #expect(doc.sourceSize == CGSize(width: 4016, height: 6016))
        #expect(doc.proxy?.texture.height == 1500)
        let texture = await preview(doc, 1500)
        #expect(texture.texture.height == 1500 && texture.imageSize == CGSize(width: 4016, height: 6016))
        renderer.release(doc)
    }

    @Test(.enabled(if: RawRendererTests.hasAssets))
    func sixteenBitTIFFIsKeptInHalfFloat() async throws {
        let doc = document(RawRendererTests.folder.appendingPathComponent("HSB_6548.tif"))
        try await renderer.prepare(doc, proxyPixelSize: 1000)
        #expect(doc.source?.texture?.pixelFormat == .rgba16Float)
        #expect(doc.sourceSize.map { max($0.width, $0.height) } == 6032)
        doc.apply(.levels(Levels(master: LevelsChannel(inputBlack: 0.02, inputWhite: 0.98, gamma: 1.1,
                                                       outputBlack: 0, outputWhite: 1))))
        let texture = await preview(doc, 1000)
        #expect(max(texture.texture.width, texture.texture.height) == 1000)
        renderer.release(doc)
    }

    // MARK: - Export

    @Test func exportIsTopRowFirstInTheRequestedDepth() async throws {
        let doc = document(quadrantFile())
        doc.apply(.flip(horizontal: true))
        // Not prepared: the export decodes the file itself.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let image8 = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        #expect(image8.width == 64 && image8.height == 32 && image8.bitsPerComponent == 8)
        // Exact to a level: an sRGB original is kept in sRGB, so sRGB
        // primaries come back as they went in.
        #expect(near8(rgba8(image8, x: 0, y: 0), [0, 255, 0, 255]))      // green top-left
        #expect(near8(rgba8(image8, x: 63, y: 31), [0, 0, 255, 255]))    // blue bottom-right

        try await renderer.prepare(doc)
        doc.apply(.rotate90(turns: 1))
        doc.preview = .negative   // never exported
        let image16 = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 16)
        #expect(image16.width == 32 && image16.height == 64 && image16.bitsPerComponent == 16)
        #expect(near8(rgba8(image16, x: 0, y: 0), [255, 255, 255, 255]))  // flipped, then turned: the bottom-left white comes to the top-left

        await #expect(throws: EditRenderError.self) {
            _ = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 32)
        }
    }

    func near8(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    }

    /// A pixel of `image` drawn into an 8-bit sRGB bitmap, top row first.
    func rgba8(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return Array(bytes[i..<(i + 4)])
    }

    // MARK: - Memory

    @Test func releaseAndDroppedDocumentsFreeTheirPixels() async throws {
        weak var releasedDoc: EditDocument?
        weak var releasedSource: EditSource?
        weak var releasedProxy: EditProxy?
        weak var droppedDoc: EditDocument?
        weak var droppedSource: EditSource?
        do {
            let doc = document(quadrantFile(width: 1600, height: 800))
            try await renderer.prepare(doc, proxyPixelSize: 400)
            _ = await preview(doc, 400)
            releasedDoc = doc
            releasedSource = doc.source
            releasedProxy = doc.proxy
            #expect(releasedSource != nil && releasedProxy != nil)
            renderer.release(doc)
            #expect(doc.source == nil && doc.proxy == nil)
            #expect(releasedSource == nil && releasedProxy == nil, "release keeps the pixels alive")

            let other = document(quadrantFile(width: 1600, height: 800))
            try await renderer.prepare(other, proxyPixelSize: 400)
            _ = await fullResolution(other)
            droppedDoc = other
            droppedSource = other.source
        }
        for _ in 0..<50 where droppedDoc != nil || droppedSource != nil || releasedDoc != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(releasedDoc == nil && droppedDoc == nil && droppedSource == nil)
    }
}
