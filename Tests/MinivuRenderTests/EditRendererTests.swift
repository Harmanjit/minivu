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

    /// A preview cancelled while its render runs never reaches the screen:
    /// the render of the state without it is already on its way.
    @Test func aCancelledPreviewIsNeverShown() async throws {
        let doc = document(quadrantFile(width: 1600, height: 800))
        try await renderer.prepare(doc, proxyPixelSize: 400)
        var shown: [Float] = []
        func record(_ texture: ImageTexture) { shown.append(F.pixels(texture.texture).at(0.1, 0.1).x) }

        for full in [true, false] {
            shown = []
            doc.preview = .rgbAdjust(red: -1, green: 0, blue: 0)
            if full {
                renderer.renderFullResolution(doc) { record($0) }
            } else {
                renderer.renderPreview(doc, pixelSize: 400) { record($0) }
            }
            // Once it has taken its snapshot of the document, and before it
            // can deliver (that needs the main actor, which this holds):
            let lane = full ? doc.fullLane : doc.previewLane
            while lane.runningRevision == nil { await Task.yield() }
            doc.preview = nil
            renderer.renderPreview(doc, pixelSize: 400) { record($0) }
            await waitUntilIdle(doc)
            #expect(!shown.isEmpty)
            #expect(shown.allSatisfy { $0 > 0.7 }, "full \(full): \(shown)")
        }
    }

    @Test func overtakenStates() {
        let brighter = EditOperation.lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0)
        let darker = EditOperation.lighting(brightness: -0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0)
        let red = EditOperation.rgbAdjust(red: 0.3, green: 0, blue: 0)
        func overtaken(_ c: [EditOperation], _ p: EditOperation?, by c2: [EditOperation], _ p2: EditOperation?) -> Bool {
            EditRenderer.isOvertaken(committed: c, preview: p, by: c2, preview: p2)
        }
        #expect(!overtaken([], brighter, by: [], darker), "a slider still moving")
        #expect(overtaken([], brighter, by: [], nil), "cancelled")
        #expect(overtaken([], brighter, by: [darker], nil), "applied at another value")
        #expect(overtaken([brighter], red, by: [brighter, red], .grayscale), "another tool since")
        #expect(overtaken([.grayscale], nil, by: [], nil), "undone")
        #expect(overtaken([], brighter, by: [], red), "a Colors section switched")
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

    // MARK: - Stages

    /// After a downsizing resize, slider renders start from the resized
    /// image rendered once, and show the same pixels as a render from the
    /// original.
    @Test func rendersAfterADownsizingResizeStartFromAStage() async throws {
        let doc = document(quadrantFile(width: 1600, height: 800))
        try await renderer.prepare(doc, proxyPixelSize: 800)
        doc.apply(.rotate(degrees: 3, autoCrop: true))
        doc.apply(.resize(width: 400, height: 190, filter: .lanczos3))
        doc.apply(.blur(radius: 3))
        let lighting = { (b: Double) in EditOperation.lighting(brightness: b, contrast: 0.2, gamma: 1, shadows: 0, highlights: 0) }

        doc.preview = lighting(0.1)
        _ = await preview(doc, 1000)
        let stage = try #require(doc.previewLane.stage)
        #expect(stage.operations.count == 2 && stage.size == CGSize(width: 400, height: 190))
        #expect(stage.texture.width == 400 && stage.texture.height == 190)

        doc.preview = lighting(0.3)
        let staged = await preview(doc, 1000)
        #expect(doc.previewLane.stage === stage, "the same stage for the next frame")

        let source = try #require(doc.source)
        let direct = EditGraph.image(source: source.image, sourceSize: source.size,
                                     operations: doc.renderedOperations, scale: 1)
        let expected = F.pixels(try EditRenderer.renderTexture(direct, context: renderer.context, gpu: renderer.gpu))
        let got = F.pixels(staged.texture)
        #expect(got.width == expected.width && got.height == expected.height)
        var worst: Float = 0
        for y in 0..<got.height {
            for x in 0..<got.width {
                let a = got[x, y], b = expected[x, y]
                for c in 0..<4 { worst = max(worst, abs(a[c] - b[c])) }
            }
        }
        #expect(worst < 2e-3, "largest difference \(worst)")

        // Undoing the resize drops the stage with the next render.
        doc.preview = nil
        doc.undo()
        doc.undo()
        _ = await preview(doc, 1000)
        #expect(doc.previewLane.stage == nil)
    }

    @Test func stageLengths() {
        let size = CGSize(width: 6000, height: 4000)
        let smaller = EditOperation.resize(width: 1500, height: 1000, filter: .lanczos3)
        let larger = EditOperation.resize(width: 9000, height: 6000, filter: .lanczos3)
        func length(_ ops: [EditOperation], committed: Int? = nil) -> Int? {
            EditRenderer.stageLength(operations: ops, committed: committed ?? ops.count, sourceSize: size)
        }
        #expect(length([smaller, .grayscale]) == 1)
        #expect(length([.grayscale, smaller, .grayscale], committed: 2) == 2, "a preview after it")
        #expect(length([smaller]) == nil, "nothing after it")
        #expect(length([.grayscale, smaller], committed: 1) == nil, "the resize is only a preview")
        #expect(length([larger, .grayscale]) == nil, "more pixels, not fewer")
        #expect(length([.crop(CGRect(x: 0, y: 0, width: 0.1, height: 0.1)), larger, .grayscale]) == nil)
        let smallest = EditOperation.resize(width: 750, height: 500, filter: .box)
        #expect(length([smaller, .blur(radius: 2), smallest, .grayscale]) == 3, "the last one")
        #expect(length([smaller, .blur(radius: 2), larger, .grayscale]) == 1, "the last one that shrinks")
        #expect(length([smaller, smaller, .grayscale]) == 1, "the same size again shrinks nothing")
        #expect(length([.grayscale]) == nil)
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

    /// Every kind of tool keeps an HDR original's highlights, in previews
    /// made from the screen proxy (Lanczos, then an intermediate texture) as
    /// at full resolution: the texture for the canvas is flagged HDR and
    /// still reaches past 2.5 in the ramp's bright end, which each tool here
    /// leaves alone.
    @Test(arguments: ["geometry", "resize", "adjustment", "effect", "retouch", "drawing"])
    func hdrHighlightsSurviveEveryKindOfTool(kind: String) async throws {
        let url = try Fixtures.gainMapHEIC(width: 2400, height: 1200)
        let doc = document(url)
        try await renderer.prepare(doc, proxyPixelSize: 900)
        #expect(doc.proxy != nil)
        var line = Annotation(kind: .line)
        line.start = CGPoint(x: 0.1, y: 0.5)
        line.end = CGPoint(x: 0.5, y: 0.5)
        let operations: [EditOperation] = switch kind {
        case "geometry": [.rotate90(turns: 1), .crop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))]
        case "resize": [.resize(width: 1200, height: 600, filter: .lanczos3), .rotate90(turns: 2)]
        case "adjustment": [.colors(hue: 0, saturation: 0, lightness: 0, temperature: 0.3, tint: 0)]
        case "effect": [.dropShadow(DropShadow())]
        case "retouch": [.retouch([RetouchStroke(mode: .clone, points: [CGPoint(x: 0.2, y: 0.5)], radius: 0.05,
                                                 sourceOffset: CGVector(dx: 0.05, dy: 0))])]
        default: [.annotations([line])]
        }
        for op in operations.dropLast() { doc.apply(op) }
        doc.preview = operations.last
        for texture in [await preview(doc, 700), await fullResolution(doc)] {
            let peak = F.pixels(texture.texture).data.max() ?? 0
            #expect(texture.isHDR && texture.contentHeadroom > 3, "\(kind): flagged SDR")
            #expect(peak > 2.5, "\(kind), \(texture.isFullResolution ? "full" : "preview"): brightest \(peak)")
        }
        renderer.release(doc)
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

    /// A Save over the original puts the edits into the file. If the document
    /// then had to decode the file again (after `release`, or for an original
    /// too large to keep), it would apply every edit a second time. Both the
    /// decode for editing and the decode for export must refuse instead.
    @Test func aFileChangedAfterEditingBeganIsNotEditedAgain() async throws {
        let url = quadrantFile(width: 64, height: 32)
        let doc = document(url)
        try await renderer.prepare(doc, proxyPixelSize: 64)
        doc.apply(.rotate90(turns: 1))
        renderer.release(doc)

        // Simulate the save: the file is rewritten with the rotated pixels.
        try await Task.sleep(for: .milliseconds(20))
        let rotated = Fixtures.write(Fixtures.quadrants(width: 32, height: 64), name: "rotated-\(UUID()).tiff")
        _ = try FileManager.default.replaceItemAt(url, withItemAt: rotated)

        await #expect(throws: EditRenderError.self) { try await renderer.prepare(doc, proxyPixelSize: 64) }
        let snapshot = doc.snapshot()
        await #expect(throws: EditRenderError.self) {
            _ = try await renderer.renderForExport(snapshot, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitsPerComponent: 8)
        }

        // A fresh document for the saved file edits it normally.
        let fresh = document(url)
        try await renderer.prepare(fresh, proxyPixelSize: 64)
        #expect(fresh.sourceSize == CGSize(width: 32, height: 64))
        renderer.release(fresh)
    }
}
