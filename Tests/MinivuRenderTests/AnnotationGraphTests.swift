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

    /// The objects the seam tests draw: a turned, stroked rectangle with a
    /// shadow and outlined text across it.
    static func seamObjects() -> [Annotation] {
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
        return [rect, text]
    }

    /// Draws `objects` into one BGRA8 buffer covering `region`, in tiles of
    /// `tile` or in one piece, calling the provider exactly as Core Image
    /// does: a buffer and a row stride of its own for each tile.
    static func drawTiles(_ objects: [Annotation], size: CGSize, region: CGRect, tile: Int?) -> [UInt8] {
        let w = Int(region.width), h = Int(region.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let provider = AnnotationTileProvider(objects: objects, imageSize: size, region: region)
        let step = tile ?? max(w, h)
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let tw = min(step, w - x), th = min(step, h - y)
                var buffer = [UInt8](repeating: 0, count: tw * th * 4)
                buffer.withUnsafeMutableBytes {
                    provider.provideImageData($0.baseAddress!, bytesPerRow: tw * 4, origin: x, y, size: tw, th,
                                              userInfo: nil)
                }
                for row in 0..<th {
                    let source = row * tw * 4, destination = ((y + row) * w + x) * 4
                    out.replaceSubrange(destination..<(destination + tw * 4),
                                        with: buffer[source..<(source + tw * 4)])
                }
            }
        }
        return out
    }

    /// Tiles of a provider join without seams, shadows and text included.
    ///
    /// The provider is driven straight rather than through
    /// `AnnotationGraph.tileSize`, because Core Image treats
    /// `.providerTileSize` as a hint and macOS 15 ignores it: the provider is
    /// asked in 64 px tiles whatever we set, through `render(toBitmap:)` and
    /// `createCGImage` alike. Setting the hook and comparing renders therefore
    /// compares a render with itself and tests nothing at all on that release.
    ///
    /// Seamless does not mean the bitmaps match byte for byte. A path clipped
    /// to a small context rasterises its antialiased edge a little
    /// differently, measured here at up to 7 levels of coverage out of 255, so
    /// pixels along an outline move whether or not they are near a boundary.
    /// It means the two things a seam would break: tiling never changes a
    /// pixel that lies solidly inside or outside a shape, and the cut does not
    /// dominate where along an edge the coverage moves. A clip does cost the
    /// pixels it passes through something, measured here at twice the rate
    /// found elsewhere along the same outline, so the last bound is loose on
    /// purpose; a seam would be a step, not a rate.
    @Test func tilesJoinSeamlessly() {
        let size = CGSize(width: 300, height: 200)
        let objects = Self.seamObjects()
        let region = objects.reduce(CGRect.null) { $0.union($1.paintedBounds(in: size, includingShadow: false)) }
            .intersection(CGRect(origin: .zero, size: size)).integral
        let whole = Self.drawTiles(objects, size: size, region: region, tile: nil)
        let tiled = Self.drawTiles(objects, size: size, region: region, tile: 64)
        let w = Int(region.width), h = Int(region.height)

        // A pixel is on an edge when any neighbour differs from it in any
        // channel. Coverage alone will not do: the fill is 80% opaque, so
        // "not fully opaque" would count the whole inside of the rectangle,
        // and the boundary between the opaque stroke and the fill beneath it
        // changes colour at a constant alpha. A neighbour outside the region
        // counts as the same, so the region's own border is an edge only where
        // something is drawn against it. Calling the whole border an edge
        // instead would be worse than useless: it is transparent padding that
        // can never change, and 475 of its 896 pixels sit on a multiple of 64,
        // so it would pad the boundary count below with three fifths of
        // pixels that are certain to pass.
        func onAnEdge(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { offset in
                let (nx, ny) = (x + offset.0, y + offset.1)
                guard nx >= 0, ny >= 0, nx < w, ny < h else { return false }
                let j = (ny * w + nx) * 4
                return (0..<4).contains { whole[i + $0] != whole[j + $0] }
            }
        }
        var changed = 0, worstByte = 0
        var nearBoundary = (changed: 0, total: 0), elsewhere = (changed: 0, total: 0)
        var offTheEdges = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var differs = false
                for c in 0..<4 where whole[i + c] != tiled[i + c] {
                    differs = true
                    worstByte = max(worstByte, abs(Int(whole[i + c]) - Int(tiled[i + c])))
                }
                if differs { changed += 1 }
                guard onAnEdge(x, y) else {
                    if differs { offTheEdges += 1 }
                    continue
                }
                if x % 64 <= 1 || x % 64 >= 62 || y % 64 <= 1 || y % 64 >= 62 {
                    nearBoundary.total += 1; if differs { nearBoundary.changed += 1 }
                } else {
                    elsewhere.total += 1; if differs { elsewhere.changed += 1 }
                }
            }
        }
        let edges = nearBoundary.total + elsewhere.total
        // Nothing away from an edge may move at all: a tile that drew its
        // objects in the wrong place would put colour where there was none.
        #expect(offTheEdges == 0, "tiling changed \(offTheEdges) pixels that sit in flat colour")
        // Along an edge, coverage may land a level or two differently.
        // Measured at 6 of 255 on macOS 15.7.9; content misplaced by a whole
        // pixel moves an edge pixel by more than 200.
        #expect(worstByte <= 24, "an edge pixel moved by \(worstByte) of 255")
        #expect(changed * 4 <= edges,
                "\(changed) of \(edges) edge pixels changed, more than a quarter of the outline")
        // The seam itself: the cut may cost the edge it passes through, but it
        // must not be where the difference lives. Measured on macOS 15.7.9 at
        // 21% of edge pixels beside a boundary against 10% elsewhere, so a
        // fourfold rate is the point at which the cut has stopped being one
        // influence among several.
        #expect(nearBoundary.total > 100 && elsewhere.total > 100,
                "too few edge pixels to judge: \(nearBoundary.total) beside a boundary, \(elsewhere.total) elsewhere")
        let near = Double(nearBoundary.changed) / Double(max(nearBoundary.total, 1))
        let far = Double(elsewhere.changed) / Double(max(elsewhere.total, 1))
        #expect(near <= max(far * 4, 0.02),
                "beside a boundary \(Int(near * 100))% of edge pixels changed, elsewhere \(Int(far * 100))%")
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

        // Values a later version might add fall back to the kind's defaults
        // instead of failing the whole document.
        let future = try JSONDecoder().decode(Annotation.self, from: Data(
            #"{"kind":"arrow","dash":"wavy","arrowheads":"start","fontWeight":"black","alignment":"justified","opacity":0.5}"#.utf8))
        #expect(future.kind == .arrow && future.dash == .solid && future.arrowheads == .end)
        #expect(future.fontWeight == Annotation(kind: .arrow).fontWeight && future.alignment == .left && future.opacity == 0.5)
        let unknownKind = try JSONDecoder().decode(Annotation.self, from: Data(#"{"kind":"star"}"#.utf8))
        #expect(unknownKind.kind == .rectangle)
    }

    /// The painted bounds hold everything a turned text object can draw: its
    /// clip reaches a tenth of the font size past the box in the box's own
    /// axes, so at 45° the corners of that margin stick out further than the
    /// same margin added after turning.
    @Test func paintedBoundsHoldATurnedTextsClipMargin() {
        let size = CGSize(width: 1000, height: 1000)
        var text = Annotation(kind: .text)
        text.frame = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        text.fontSize = 0.1   // 100 px: a 10 px margin
        text.rotation = 45
        text.shadow = false
        let bounds = text.paintedBounds(in: size, includingShadow: false)
        let margin = text.fontPixelSize(in: size) * 0.1
        let box = text.localBox(in: size).insetBy(dx: -margin, dy: -margin)
        let t = text.boxTransform(in: size)
        for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)] {
            let p = corner.applying(t)
            #expect(bounds.insetBy(dx: 1.9, dy: 1.9).contains(p), "\(p) outside \(bounds)")
        }
    }

    /// An output wider than a Metal texture (and than many provider tiles)
    /// renders in pieces: a line with a shadow and a highlight running
    /// across all of them come out the same in every column, over SDR and
    /// HDR rows alike.
    @Test func outputsWiderThanATextureHaveNoSeams() {
        let width = 17000, height = 64
        var line = Annotation(kind: .line)
        line.start = CGPoint(x: 0.01, y: 0.25)
        line.end = CGPoint(x: 0.99, y: 0.25)
        line.strokeWidth = 0.1
        line.shadow = true
        var highlight = Annotation(kind: .highlight)
        highlight.frame = CGRect(x: 0.005, y: 0.55, width: 0.99, height: 0.3)
        // Solid colours rather than a bitmap: SDR on the top half, HDR below
        // (Core Image's y is up).
        func flat(_ v: CGFloat, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: F.space)!).cropped(to: rect)
        }
        let half = CGFloat(height / 2)
        let source = flat(0.5, CGRect(x: 0, y: half, width: CGFloat(width), height: half))
            .composited(over: flat(2, CGRect(x: 0, y: 0, width: CGFloat(width), height: half)))
        let p = render([.annotations([line, highlight])], source: source, fullSize: CGSize(width: width, height: height))
        var worst: Float = 0
        p.data.withUnsafeBufferPointer { data in
            for y in 0..<height {
                let reference = (y * width + 400) * 4
                for x in stride(from: 400, to: width - 400, by: 5) {
                    let i = (y * width + x) * 4
                    for c in 0..<4 { worst = max(worst, abs(data[i + c] - data[reference + c])) }
                }
            }
        }
        #expect(worst < 0.01, "worst difference along the rows \(worst)")
        // The highlight still multiplies the HDR rows without clamping.
        #expect(p[8000, 44].x > 1, "\(p[8000, 44])")
        // The line is there, and the rows above it are untouched.
        #expect(p[8000, 16].y < 0.1 && p[8000, 1] == SIMD4(0.5, 0.5, 0.5, 1), "\(p[8000, 16]) \(p[8000, 1])")
    }

    // MARK: - Timing

    /// 20 objects drawn into a 3024 px proxy's tile (the budget: 15 ms, the
    /// best of five draws), and, printed for reference, through the whole
    /// graph into a proxy texture and a 24 MP export. See `AnnotationGraph`
    /// for the figures.
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
        // The best of the five, as the benchmarks in this suite measure:
        // the first draw warms the fonts and the tile, and the others share
        // the machine with whatever else is running. Load can only make a
        // sample slower, so the quickest one is the honest cost, and the
        // budget can stay what the design says without a debug build or a
        // busy machine failing it. A draw that really grew past the budget
        // would have no quick sample left to hide behind.
        let best = times.min()!
        print(String(format: "annotations: 20 objects into 3024x2016, best %.1f ms of (%@)", best,
                     times.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        #expect(best < 15, "\(times)")

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


// MARK: - Temporary diagnostic

/// Records the tiles Core Image asks a provider for, so a run can say whether
/// this release honours `.providerTileSize` at all.
private final class CountingTileProvider: NSObject, @unchecked Sendable {
    let lock = NSLock()
    var calls: [(x: Int, y: Int, width: Int, height: Int)] = []

    override func provideImageData(_ data: UnsafeMutableRawPointer, bytesPerRow: Int, origin x: Int, _ y: Int,
                                   size width: Int, _ height: Int, userInfo info: Any?) {
        lock.lock()
        calls.append((x, y, width, height))
        lock.unlock()
        // Row by row, since only the first `width` pixels of each row are
        // ours: Core Image need not have allocated the padding after the last.
        for row in 0..<height { memset(data.advanced(by: row * bytesPerRow), 128, width * 4) }
    }
}
