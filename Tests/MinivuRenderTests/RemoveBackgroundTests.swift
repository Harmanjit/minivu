import Testing
import Foundation
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
@testable import MinivuRender
@testable import MinivuCore

/// Remove Background (G8): the stored subject mask, the graph that cuts
/// along it at any scale, and Vision finding it.
@MainActor @Suite(.serialized) struct RemoveBackgroundTests {
    typealias F = EditFixtures
    let renderer = EditRenderer.shared

    /// A mask whose subject is the left `fraction` of a `width` x `height`
    /// picture, with a one-pixel soft edge.
    static func leftMask(width: Int = 64, height: Int = 32, fraction: Double = 0.5) -> SubjectMask {
        let edge = Int(Double(width) * fraction)
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                coverage[y * width + x] = x < edge ? 255 : (x == edge ? 128 : 0)
            }
        }
        return SubjectMask(coverage: coverage, width: width, height: height)!
    }

    /// A red disc and a blue block on a plain light background, the kind of
    /// picture Vision lifts a subject from.
    static func discPicture(width: Int = 800, height: Int = 600) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Laid out on an 800 x 600 grid, scaled to the size asked for.
        context.scaleBy(x: CGFloat(width) / 800, y: CGFloat(height) / 600)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 360, y: 60, width: 80, height: 120))
        return context.makeImage()!
    }

    // MARK: - The mask

    @Test func maskKeepsItsCoverageAndBounds() throws {
        let mask = Self.leftMask()
        #expect(mask.width == 64 && mask.height == 32)
        #expect(mask.bounds == CGRect(x: 0, y: 0, width: 33.0 / 64, height: 1))
        let image = try #require(mask.image)
        #expect(image.extent == CGRect(x: 0, y: 0, width: 64, height: 32))
        // Read back as stored: no colour conversion of a coverage.
        let p = F.pixels(image)
        #expect(p[10, 5].x == 1 && p[50, 5].x == 0)
        #expect(abs(p[32, 5].x - 128.0 / 255) < 1e-3, "edge \(p[32, 5].x)")
        // Nothing to lift: no mask.
        #expect(SubjectMask(coverage: [UInt8](repeating: 20, count: 16), width: 4, height: 4) == nil)
    }

    @Test func operationRoundTrips() throws {
        let op = EditOperation.removeBackground(RemoveBackground(mask: Self.leftMask(),
                                                                 fill: EditColor(red: 0, green: 0.5, blue: 1)))
        let decoded = try JSONDecoder().decode(EditOperation.self, from: JSONEncoder().encode(op))
        #expect(decoded == op)
        #expect(op.title == "Remove Background")
        #expect(!op.isIdentity && !op.changesGeometry)
        guard case .removeBackground(let back) = decoded else { Issue.record("not decoded"); return }
        #expect(back.mask.bounds == Self.leftMask().bounds)
        #expect(back.mask.image != nil)
    }

    // MARK: - The graph

    /// What remains keeps its values, HDR included; the rest is transparent,
    /// or the fill.
    @Test func backgroundGoesTransparentOrTakesTheFill() {
        let source = F.flat(3, width: 64, height: 32)
        let transparent = EditGraph.image(source: source, sourceSize: source.extent.size,
                                          operations: [.removeBackground(RemoveBackground(mask: Self.leftMask()))],
                                          scale: 1)
        let p = F.pixels(transparent)
        #expect(nearly(p[8, 16], SIMD4(3, 3, 3, 1)), "subject \(p[8, 16])")
        #expect(nearly(p[56, 16], SIMD4(0, 0, 0, 0)), "background \(p[56, 16])")
        // The picture's own border stays whole: no half-transparent rim.
        #expect(nearly(p[0, 0], SIMD4(3, 3, 3, 1)), "corner \(p[0, 0])")

        let white = EditOperation.removeBackground(RemoveBackground(mask: Self.leftMask(), fill: .white))
        let filled = F.pixels(EditGraph.image(source: source, sourceSize: source.extent.size, operations: [white],
                                              scale: 1))
        #expect(nearly(filled[56, 16], SIMD4(1, 1, 1, 1)), "fill \(filled[56, 16])")
        #expect(nearly(filled[8, 16], SIMD4(3, 3, 3, 1)))
    }

    /// The cut falls in the same place on a proxy as in the saved file,
    /// whatever size the mask was found at.
    @Test func theEdgeLinesUpAtEveryScale() {
        let mask = Self.leftMask(width: 100, height: 50, fraction: 0.3)
        let op = EditOperation.removeBackground(RemoveBackground(mask: mask))
        for (width, height, scale) in [(1000, 500, 1.0), (1000, 500, 0.37), (1000, 500, 0.1)] {
            let w = EditGraph.workingLength(width, scale: scale), h = EditGraph.workingLength(height, scale: scale)
            let source = F.flat(0.5, width: w, height: h)
            let p = F.pixels(EditGraph.image(source: source, sourceSize: CGSize(width: width, height: height),
                                             operations: [op], scale: scale))
            // Where alpha crosses one half along the middle row.
            let row = h / 2
            let crossing = (0..<w).first { p[$0, row].w < 0.5 } ?? w
            let fraction = Double(crossing) / Double(w)
            #expect(abs(fraction - 0.3) < 0.015 + 1.5 / Double(w), "scale \(scale): edge at \(fraction)")
        }
    }

    // MARK: - Vision

    @Test func visionFindsTheSubject() throws {
        let mask = try #require(SubjectDetector.mask(in: Self.discPicture()))
        #expect(mask.width == 800 && mask.height == 600)
        // The disc and the block together, in top-left coordinates.
        let expected = CGRect(x: 250.0 / 800, y: 150.0 / 600, width: 300.0 / 800, height: 390.0 / 600)
        let b = mask.bounds
        #expect(abs(b.minX - expected.minX) < 0.04 && abs(b.maxX - expected.maxX) < 0.04, "bounds \(b)")
        #expect(abs(b.minY - expected.minY) < 0.05 && abs(b.maxY - expected.maxY) < 0.05, "bounds \(b)")
        let p = F.pixels(try #require(mask.image))
        #expect(p[400, 300].x > 0.9 && p[50, 50].x < 0.1)
    }

    /// Found once per picture and kept on the document; a step that changes
    /// the picture asks again.
    @Test func theMaskIsFoundOncePerPicture() async throws {
        let url = Fixtures.write(Self.discPicture(), name: "subject-\(UUID()).png", type: .png)
        let doc = EditDocument(entry: FolderEntry(url: url)!)
        let first = try #require(try await renderer.subjectMask(for: doc))
        let again = try await renderer.subjectMask(for: doc)
        #expect(again === first)
        doc.apply(.crop(CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.7)))
        let cropped = try #require(try await renderer.subjectMask(for: doc))
        #expect(cropped !== first)
        #expect(cropped.bounds.width > first.bounds.width, "the subject fills more of the cropped picture")
        // The operations it was found for may be passed: a preview's.
        let shown = doc.operations + [.grayscale]
        let previewed = try await renderer.subjectMask(for: doc, operations: shown)
        #expect(previewed != nil && previewed !== cropped)
        renderer.release(doc)
    }

    /// The renderer applies the stored mask at preview and full size alike.
    @Test func previewAndFullResolutionCutAlike() async throws {
        let url = Fixtures.write(Self.discPicture(width: 1600, height: 1200), name: "subject-\(UUID()).png", type: .png)
        let doc = EditDocument(entry: FolderEntry(url: url)!)
        try await renderer.prepare(doc, proxyPixelSize: 500)
        let mask = try #require(try await renderer.subjectMask(for: doc))
        doc.apply(.removeBackground(RemoveBackground(mask: mask)))
        let small = await withCheckedContinuation { c in renderer.renderPreview(doc, pixelSize: 500) { c.resume(returning: $0) } }
        let full = await withCheckedContinuation { c in renderer.renderFullResolution(doc) { c.resume(returning: $0) } }
        let a = F.pixels(small.texture), b = F.pixels(full.texture)
        for (fx, fy) in [(0.5, 0.5), (0.05, 0.05), (0.95, 0.9), (0.33, 0.5), (0.68, 0.5)] {
            #expect(abs(a.at(fx, fy).w - b.at(fx, fy).w) < 0.1, "alpha at \(fx), \(fy): \(a.at(fx, fy).w) vs \(b.at(fx, fy).w)")
        }
        #expect(a.at(0.5, 0.5).w > 0.9 && a.at(0.05, 0.05).w < 0.1)
        renderer.release(doc)
    }
}
