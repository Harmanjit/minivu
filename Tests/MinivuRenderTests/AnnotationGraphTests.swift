import Testing
import Foundation
import CoreGraphics
import CoreImage
import simd
@testable import MinivuRender

/// The drawing layer through `EditGraph`: objects land on the right pixels at
/// every scale and after earlier geometry, sizes follow the resolution,
/// highlights multiply, and nothing clamps HDR values.
@Suite(.serialized) struct AnnotationGraphTests {
    typealias F = EditFixtures

    static let clear = EditColor(red: 0, green: 0, blue: 0, alpha: 0)

    func box(_ frame: CGRect, kind: Annotation.Kind = .rectangle, fill: EditColor = .white,
             stroke: EditColor = clear, width: Double = 0) -> Annotation {
        var a = Annotation(kind: kind)
        a.frame = frame
        a.fillColor = fill
        a.strokeColor = stroke
        a.strokeWidth = width
        a.shadow = false
        return a
    }

    func render(_ ops: [EditOperation], source: CIImage, fullSize: CGSize, scale: Double = 1) -> F.Pixels {
        let image = EditGraph.image(source: source, sourceSize: fullSize, operations: ops, scale: scale)
        #expect(image.extent.origin == .zero)
        return F.pixels(image)
    }

    let grey = SIMD4<Float>(0.25, 0.25, 0.25, 1)

    // MARK: - Positions

    @Test func rectangleLandsOnItsNormalisedFrameAtEveryScale() {
        let rect = box(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let full = render([.annotations([rect])], source: F.flat(0.25, width: 64, height: 32),
                          fullSize: CGSize(width: 64, height: 32))
        #expect(nearly(full[16, 8], F.white) && nearly(full[47, 23], F.white))
        #expect(full[15, 8] == grey && full[48, 8] == grey && full[16, 7] == grey && full[16, 24] == grey)

        let half = render([.annotations([rect])], source: F.flat(0.25, width: 32, height: 16),
                          fullSize: CGSize(width: 64, height: 32), scale: 0.5)
        #expect(half.width == 32 && half.height == 16)
        #expect(nearly(half[8, 4], F.white) && nearly(half[23, 11], F.white))
        #expect(half[7, 4] == grey && half[24, 4] == grey && half[8, 3] == grey && half[8, 12] == grey)
    }

    /// Normalised coordinates are of the image as it is where the operation
    /// sits: after a crop to the right half, x 0...0.5 is the right quarter
    /// of the original.
    @Test func positionsAreRelativeToTheImageAfterEarlierOperations() {
        let ops: [EditOperation] = [.crop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
                                    .annotations([box(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))])]
        let full = render(ops, source: F.quadrants(), fullSize: CGSize(width: 64, height: 32))
        #expect(full.width == 32 && full.height == 32)
        #expect(nearly(full[0, 0], F.white) && nearly(full[15, 15], F.white))
        #expect(full[16, 0] == F.green && full[20, 4] == F.green && full[0, 16] == F.white)

        let rotated: [EditOperation] = [.rotate90(turns: 1),
                                        .annotations([box(CGRect(x: 0, y: 0, width: 0.5, height: 0.25))])]
        let turned = render(rotated, source: F.quadrants(), fullSize: CGSize(width: 64, height: 32))
        #expect(turned.width == 32 && turned.height == 64)
        #expect(nearly(turned[2, 2], F.white) && nearly(turned[15, 15], F.white))
        #expect(turned[16, 2] == F.red && turned[2, 16] == F.blue)

        let half = render(ops, source: F.quadrants(width: 32, height: 16), fullSize: CGSize(width: 64, height: 32),
                          scale: 0.5)
        #expect(half.width == 16 && half.height == 16)
        #expect(nearly(half[0, 0], F.white) && nearly(half[7, 7], F.white) && half[8, 2] == F.green)
    }

    @Test func strokeWidthIsAFractionOfTheShortSide() {
        var outline = box(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), fill: Self.clear, stroke: .white, width: 0.05)
        outline.dash = .solid
        // White over black: the row's summed coverage is the stroke's width.
        func measuredWidth(_ w: Int, _ h: Int) -> Float {
            let p = render([.annotations([outline])], source: F.flat(0, width: w, height: h),
                           fullSize: CGSize(width: w, height: h))
            return (0..<(w / 2)).reduce(0) { $0 + p[$1, h / 2].x }
        }
        #expect(abs(measuredWidth(200, 100) - 5) < 0.1, "\(measuredWidth(200, 100))")
        #expect(abs(measuredWidth(400, 200) - 10) < 0.1, "\(measuredWidth(400, 200))")
        #expect(abs(measuredWidth(200, 400) - 10) < 0.1, "\(measuredWidth(200, 400))")
    }

    @Test func textIsDrawnInsideItsFrame() {
        var text = Annotation(kind: .text)
        text.text = "Hello"
        text.textColor = .white
        text.shadow = false
        text.fontSize = 0.2
        text.frame = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let p = render([.annotations([text])], source: F.flat(0, width: 400, height: 200),
                       fullSize: CGSize(width: 400, height: 200))
        var inside = 0, outside = 0
        for y in 0..<200 {
            for x in 0..<400 where p[x, y].x > 0.5 {
                if x >= 40 && x < 360 && y >= 20 && y < 120 { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside > 1000, "text pixels \(inside)")
        #expect(outside == 0)
        // The first letter starts at the left, inside the padding.
        let firstColumn = (0..<400).first { x in (0..<200).contains { p[x, $0].x > 0.5 } } ?? -1
        #expect(firstColumn >= 40 && firstColumn < 60, "first column \(firstColumn)")
    }

    // MARK: - Colour

    /// A mid-grey highlight (sRGB 0.5, linear 0.214) multiplies SDR and HDR
    /// values alike; below it the HDR value stays above 1.
    @Test func highlightMultipliesWithoutClamping() {
        let source = F.image(width: 64, height: 32) { x, _ in x < 32 ? SIMD4(0.5, 0.5, 0.5, 1) : SIMD4(2, 2, 2, 1) }
        let highlight = box(CGRect(x: 0, y: 0, width: 1, height: 0.5), kind: .highlight,
                            fill: EditColor(red: 0.5, green: 0.5, blue: 0.5))
        let p = render([.annotations([highlight])], source: source, fullSize: CGSize(width: 64, height: 32))
        let g = F.decode(0.5)
        #expect(nearly(p[8, 4], SIMD4(0.5 * g, 0.5 * g, 0.5 * g, 1), 3e-3), "\(p[8, 4])")
        #expect(nearly(p[40, 4], SIMD4(2 * g, 2 * g, 2 * g, 1), 6e-3), "\(p[40, 4])")
        #expect(p[8, 24] == SIMD4(0.5, 0.5, 0.5, 1))
        #expect(p[40, 24] == SIMD4(2, 2, 2, 1))

        let white = box(CGRect(x: 0, y: 0, width: 1, height: 1), kind: .highlight, fill: .white)
        let unchanged = render([.annotations([white])], source: source, fullSize: CGSize(width: 64, height: 32))
        #expect(nearly(unchanged[8, 4], SIMD4(0.5, 0.5, 0.5, 1)) && nearly(unchanged[40, 20], SIMD4(2, 2, 2, 1), 4e-3))
    }

    @Test func sourceOverConvertsSRGBAndLeavesHDRAlone() {
        let source = F.flat(3, width: 64, height: 32)
        var red = box(CGRect(x: 0, y: 0, width: 0.25, height: 0.5), fill: EditColor(red: 1, green: 0, blue: 0))
        red.opacity = 1
        var half = box(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), fill: EditColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        half.opacity = 1
        let p = render([.annotations([red, half])], source: source, fullSize: CGSize(width: 64, height: 32))
        // sRGB red in linear Display P3.
        #expect(nearly(p[4, 4], SIMD4(0.8224, 0.0332, 0.0171, 1), 3e-3), "\(p[4, 4])")
        #expect(p[24, 24] == SIMD4(3, 3, 3, 1))
        // Half-transparent white over 3.0: 1 * 0.5 + 3 * 0.5.
        #expect(nearly(p[48, 16], SIMD4(2, 2, 2, 1), 6e-3), "\(p[48, 16])")
    }

    /// Runs of different blends stack in list order.
    @Test func objectsStackInOrderAcrossBlends() {
        let white = box(CGRect(x: 0, y: 0, width: 1, height: 1))
        let highlight = box(CGRect(x: 0, y: 0, width: 0.5, height: 1), kind: .highlight,
                            fill: EditColor(red: 0.5, green: 0.5, blue: 0.5))
        let black = box(CGRect(x: 0, y: 0, width: 0.25, height: 1), fill: .black)
        #expect(AnnotationGraph.groups([white, highlight, black], in: CGSize(width: 64, height: 32)).map(\.multiplies)
                == [false, true, false])
        let p = render([.annotations([white, highlight, black])], source: F.flat(0.1, width: 64, height: 32),
                       fullSize: CGSize(width: 64, height: 32))
        let g = F.decode(0.5)
        #expect(nearly(p[4, 16], SIMD4(0, 0, 0, 1)))
        #expect(nearly(p[24, 16], SIMD4(g, g, g, 1), 3e-3), "\(p[24, 16])")
        #expect(nearly(p[48, 16], F.white))
    }

    /// A shadow darkens the picture below and to the right of its object, not
    /// above or to the left, and falls on objects drawn before it.
    @Test func shadowsFallDownAndRightInOrder() {
        var rect = box(CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), fill: .white)
        rect.shadow = true
        let below = box(CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), fill: .white)
        let p = render([.annotations([below, rect])], source: F.flat(0.5, width: 400, height: 400),
                       fullSize: CGSize(width: 400, height: 400))
        let geometry = rect.shadowGeometry(in: CGSize(width: 400, height: 400))
        #expect(geometry.offset.height > 0)
        // Just past the bottom-right edge (on the grey), and on the white box below.
        let edge = 240 + Int(geometry.offset.height) + 1
        #expect(p[160, edge].x < 0.45, "\(p[160, edge])")
        #expect(p[242, 220].x < 0.95, "on the box below: \(p[242, 220])")
        // Above and left of the object the shadow is thinner than below and right.
        #expect(p[160, 118].x > p[160, edge].x + 0.02, "above \(p[160, 118]) below \(p[160, edge])")
        #expect(nearly(p[200, 200], F.white))
        #expect(nearly(p[20, 20], SIMD4(0.5, 0.5, 0.5, 1)))
    }

    // MARK: - Resolution

    /// A mixed drawing on a proxy at half scale matches the full-resolution
    /// render averaged down 2 x 2, within antialiasing.
    @Test func proxyMatchesFullResolution() {
        var arrow = Annotation(kind: .arrow)
        arrow.start = CGPoint(x: 0.1, y: 0.8)
        arrow.end = CGPoint(x: 0.45, y: 0.3)
        arrow.strokeWidth = 0.02
        var oval = Annotation(kind: .oval)
        oval.frame = CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.35)
        oval.rotation = 20
        oval.dash = .dashed
        oval.shadow = true
        var callout = Annotation(kind: .callout)
        callout.frame = CGRect(x: 0.5, y: 0.55, width: 0.45, height: 0.3)
        callout.tailPoint = CGPoint(x: 0.35, y: 0.95)
        callout.text = "Look here"
        callout.fontSize = 0.08
        var highlight = Annotation(kind: .highlight)
        highlight.frame = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.1)
        let ops: [EditOperation] = [.annotations([highlight, arrow, oval, callout])]

        let full = render(ops, source: F.flat(0.3, width: 600, height: 400), fullSize: CGSize(width: 600, height: 400))
        let proxy = render(ops, source: F.flat(0.3, width: 300, height: 200), fullSize: CGSize(width: 600, height: 400),
                           scale: 0.5)
        var total: Float = 0, largeErrors = 0, drawn = 0
        for y in 0..<200 {
            for x in 0..<300 {
                let average = (full[2 * x, 2 * y] + full[2 * x + 1, 2 * y] + full[2 * x, 2 * y + 1]
                               + full[2 * x + 1, 2 * y + 1]) / 4
                let d: SIMD4<Float> = simd.abs(average - proxy[x, y])
                let e = max(d.x, d.y, d.z)
                total += e
                if e > 0.25 { largeErrors += 1 }
                if abs(proxy[x, y].x - 0.3) > 0.05 { drawn += 1 }
            }
        }
        let mean = total / Float(300 * 200)
        #expect(drawn > 5000, "drawn \(drawn)")
        #expect(mean < 0.01, "mean difference \(mean)")
        #expect(largeErrors < 600, "large errors \(largeErrors)")
    }

    /// Tiles of a provider join without seams, shadows and text included.
    @Test func tilesJoinSeamlessly() {
        var rect = Annotation(kind: .rectangle)
        rect.frame = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        rect.rotation = 30
        rect.shadow = true
        rect.fillColor = EditColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.8)
        var text = Annotation(kind: .text)
        text.text = "Across the seams"
        text.fontSize = 0.12
        text.frame = CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.3)
        text.textOutlineColor = .black
        let ops: [EditOperation] = [.annotations([rect, text])]
        let source = F.flat(0.4, width: 300, height: 200)
        let whole = render(ops, source: source, fullSize: CGSize(width: 300, height: 200))
        let saved = AnnotationGraph.tileSize
        AnnotationGraph.tileSize = 64
        defer { AnnotationGraph.tileSize = saved }
        let tiled = render(ops, source: source, fullSize: CGSize(width: 300, height: 200))
        var worst: Float = 0
        for (a, b) in zip(whole.all, tiled.all) {
            let d: SIMD4<Float> = simd.abs(a - b)
            worst = max(worst, d.x, d.y, d.z)
        }
        #expect(worst < 0.01, "worst difference \(worst)")
    }

    // MARK: - Codable

    @Test func jsonRoundTripsAndMissingKeysTakeTheKindsDefaults() throws {
        var callout = Annotation(kind: .callout)
        callout.text = "Hi “there”"
        callout.rotation = 12
        callout.dash = .dotted
        callout.fontFamily = "Georgia"
        callout.fontWeight = .bold
        callout.textOutlineColor = EditColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let op = EditOperation.annotations([callout, Annotation(kind: .arrow)])
        let data = try JSONEncoder().encode(op)
        #expect(try JSONDecoder().decode(EditOperation.self, from: data) == op)

        let sparse = try JSONDecoder().decode(Annotation.self, from: Data(#"{"kind":"arrow","start":[0.1,0.2]}"#.utf8))
        #expect(sparse.kind == .arrow && sparse.arrowheads == .end)
        #expect(sparse.start == CGPoint(x: 0.1, y: 0.2) && sparse.end == Annotation(kind: .arrow).end)
        let empty = try JSONDecoder().decode(Annotation.self, from: Data("{}".utf8))
        #expect(empty.kind == .rectangle && empty.opacity == 1)
    }

    // MARK: - Timing

    /// 20 objects drawn into a 3024 px proxy's tile (the budget: 15 ms), and,
    /// printed for reference, through the whole graph into a proxy texture and
    /// a 24 MP export. See `AnnotationGraph` for the figures.
    @MainActor @Test func twentyObjectsDrawWithinBudget() {
        let size = CGSize(width: 3024, height: 2016)
        var objects: [Annotation] = []
        for i in 0..<20 {
            let kind = Annotation.Kind.allCases[i % Annotation.Kind.allCases.count]
            var a = Annotation(kind: kind)
            let t = Double(i) / 20
            a.frame = CGRect(x: 0.05 + t * 0.7, y: 0.1 + t * 0.6, width: 0.2, height: 0.12)
            a.start = CGPoint(x: a.frame.minX, y: a.frame.maxY)
            a.end = CGPoint(x: a.frame.maxX, y: a.frame.minY)
            a.text = kind.hasText ? "Label \(i)" : ""
            a.shadow = i % 3 == 0
            objects.append(a)
        }
        let provider = AnnotationTileProvider(objects: objects, imageSize: size,
                                              region: CGRect(origin: .zero, size: size))
        let bytesPerRow = 3024 * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * 2016, alignment: 16)
        defer { data.deallocate() }
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<5 {
            let d = clock.measure {
                provider.provideImageData(data, bytesPerRow: bytesPerRow, origin: 0, 0, size: 3024, 2016, userInfo: nil)
            }
            times.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let median = times.sorted()[2]
        print(String(format: "annotations: 20 objects into 3024x2016, median %.1f ms (%@)", median,
                     times.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        #expect(median < 15)

        // The whole graph (GPU shadows, composite, mip chain) into a proxy
        // texture, and a 24 MP export into an 8-bit sRGB CGImage.
        func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        let renderer = EditRenderer.shared
        let proxySource = F.flat(0.3, width: 3024, height: 2016)
        // The source as a GPU texture, as the editor's proxy is; a bitmap
        // source would be uploaded again in every render.
        let proxyTexture = try! EditRenderer.renderTexture(proxySource, context: renderer.context, gpu: renderer.gpu)
        let proxyImage = CIImage(mtlTexture: proxyTexture, options: [.colorSpace: F.space])!
        var baseTimes: [Double] = []
        for _ in 0..<5 {
            baseTimes.append(ms(clock.measure {
                _ = try? EditRenderer.renderTexture(proxyImage, context: renderer.context, gpu: renderer.gpu)
            }))
        }
        var graphTimes: [Double] = []
        for _ in 0..<5 {
            let image = EditGraph.image(source: proxyImage, sourceSize: CGSize(width: 6048, height: 4032),
                                        operations: [.annotations(objects)], scale: 0.5)
            graphTimes.append(ms(clock.measure {
                _ = try? EditRenderer.renderTexture(image, context: renderer.context, gpu: renderer.gpu)
            }))
        }
        let exportSource = F.flat(0.3, width: 6048, height: 4032)
        var exportTimes: [Double] = []
        for _ in 0..<3 {
            let image = EditGraph.image(source: exportSource, sourceSize: CGSize(width: 6048, height: 4032),
                                        operations: [.annotations(objects)], scale: 1)
            exportTimes.append(ms(clock.measure {
                _ = renderer.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
            }))
        }
        var exportBase: [Double] = []
        for _ in 0..<2 {
            exportBase.append(ms(clock.measure {
                _ = renderer.context.createCGImage(exportSource, from: exportSource.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
            }))
        }
        print(String(format: "annotations: proxy texture alone %@ ms; with the drawing %@ ms; 24 MP export alone %@ ms, with the drawing %@ ms",
                     baseTimes.map { String(format: "%.1f", $0) }.joined(separator: ", "),
                     graphTimes.map { String(format: "%.1f", $0) }.joined(separator: ", "),
                     exportBase.map { String(format: "%.1f", $0) }.joined(separator: ", "),
                     exportTimes.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
    }
}
