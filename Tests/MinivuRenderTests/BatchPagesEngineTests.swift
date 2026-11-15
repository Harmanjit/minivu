import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuRender
@testable import MinivuCore

/// Batch Convert's pages (G17): every page of a multi-page original into
/// one TIFF or GIF, one file per page otherwise, and Extract Pages' ranges,
/// planned and converted.
@Suite struct BatchPagesEngineTests {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor func converter() -> BatchConverter {
        BatchConverter(renderer: EditRenderer.shared, displaySettings: DisplaySettings()) { [srgb] _, _, _ in srgb }
    }

    func folder() throws -> URL {
        let url = Fixtures.directory.appendingPathComponent("pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ width: Int = 40, _ height: Int = 30) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A file of several images: a multi-page TIFF, or an animated GIF with
    /// delays and a loop count.
    func write(_ images: [CGImage], to url: URL, type: UTType, delays: [Double] = [], loops: Int = 0) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
        if type == .gif {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]]
                as CFDictionary)
        }
        for (index, image) in images.enumerated() {
            let delay = delays.indices.contains(index) ? delays[index] : 0.1
            CGImageDestinationAddImage(destination, image, type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                   kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
                : nil)
        }
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    func centre(_ image: CGImage) -> [Int] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let i = ((h / 2) * w + w / 2) * 4
        return bytes[i..<i + 3].map(Int.init)
    }

    func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 8 } }

    // MARK: - Planning

    @Test func settingsFromBeforePagesStillLoad() throws {
        let old = try JSONDecoder().decode(BatchConvertSettings.self, from: Data(#"{"options":{"format":"tiff"}}"#.utf8))
        #expect(old.pages == .first)
        let extract = BatchConvertSettings(pages: .separate(PageRange(first: 2, last: 4)))
        #expect(try JSONDecoder().decode(BatchConvertSettings.self, from: JSONEncoder().encode(extract)) == extract)
    }

    /// First page: one output per file, as always. Every page: one output
    /// holding them all for TIFF and GIF, one per page (numbered after the
    /// name, or where the pattern says) for other formats. Separate pages:
    /// the range, and single-page files skipped.
    @Test func pagesAreExpandedIntoOutputs() {
        let doc = RenameSource(url: URL(fileURLWithPath: "/p/doc.pdf"))
        let photo = RenameSource(url: URL(fileURLWithPath: "/p/photo.jpg"))
        let counts = ["/p/doc.pdf": 12, "/p/photo.jpg": 1]
        let empty = BatchFileProbe(identity: { _ in nil }, isCaseSensitive: { _ in false })
        func plan(_ settings: BatchConvertSettings) -> [BatchOutput] {
            BatchOutputPlanner.plan([doc, photo], settings: settings, folder: nil, probe: empty,
                                    pageCount: { counts[$0.path] ?? 1 })
        }
        var settings = BatchConvertSettings(options: .defaults(for: .tiff))
        #expect(plan(settings).map(\.pages) == [.primary, .primary])

        settings.pages = .all
        var outputs = plan(settings)
        #expect(outputs.map(\.pages) == [.all(count: 12), .primary])
        #expect(outputs.map(\.destination.lastPathComponent) == ["doc.tif", "photo.tif"])

        settings.options = .defaults(for: .png)
        outputs = plan(settings)
        #expect(outputs.count == 13)
        #expect(outputs.prefix(3).map(\.destination.lastPathComponent) == ["doc-01.png", "doc-02.png", "doc-03.png"])
        #expect(outputs[11].pages == .page(index: 11, of: 12) && outputs[12].destination.lastPathComponent == "photo.png")

        settings.naming = .pattern(RenamePattern(text: "Page {page} of {name}"))
        #expect(plan(settings)[1].destination.lastPathComponent == "Page 02 of doc.png", "no suffix when the pattern numbers")

        settings.naming = .keep
        settings.pages = .separate(PageRange(first: 11, last: 20))
        outputs = plan(settings)
        #expect(outputs.map(\.destination.lastPathComponent) == ["doc-11.png", "doc-12.png", "photo.png"])
        #expect(outputs.last?.action == .skip(reason: "It has only one page."))
        settings.pages = .separate(PageRange(first: 13))
        #expect(plan(settings).first?.action == .skip(reason: "It has only 12 pages."))
    }

    /// A page never takes the name of the file it came from, even with
    /// Replace: it is numbered like a clash with another source.
    @Test func aPageNeverReplacesItsOriginal() {
        let original = BatchItemIdentity(device: 1, inode: 7, isDirectory: false)
        let probe = BatchFileProbe(identity: { $0.lastPathComponent == "scan-2.png" ? original : nil },
                                   isCaseSensitive: { _ in false })
        let settings = BatchConvertSettings(options: .defaults(for: .png), naming: .pattern(RenamePattern(text: "scan-{page}")),
                                            existingFiles: .replace, pages: .separate(.all))
        let outputs = BatchOutputPlanner.plan([RenameSource(url: URL(fileURLWithPath: "/p/scan-2.png"))], settings: settings,
                                              folder: nil, probe: probe, pageCount: { _ in 3 })
        #expect(outputs.map(\.destination.lastPathComponent) == ["scan-1.png", "scan-2 2.png", "scan-3.png"])
        #expect(outputs.allSatisfy { $0.action == .write })
        #expect(BatchReplacements(outputs).isEmpty)
    }

    // MARK: - Converting

    /// A page output decodes its own page; an every-page TIFF holds every
    /// page, each its own size, in order, written beside the destination.
    @Test func pagesAndEveryPageTIFF() async throws {
        let dir = try folder()
        let doc = write([solid(1, 0, 0, 40, 30), solid(0, 1, 0, 20, 50), solid(0, 0, 1, 30, 30)],
                        to: dir.appendingPathComponent("doc.tif"), type: .tiff)
        let converter = await converter()
        let settings = BatchConvertSettings(options: .defaults(for: .png), pages: .all)

        let second = BatchOutput(source: doc, destination: dir.appendingPathComponent("doc-2.png"), action: .write,
                                 pages: .page(index: 1, of: 3))
        guard case .data(let data) = try await converter.encoded(second, settings: settings) else {
            Issue.record("a page is encoded to data")
            return
        }
        let page = try #require(ImageEncoderTestDecode.image(data))
        #expect(page.width == 20 && page.height == 50 && near(centre(page), [0, 255, 0]))

        var tiffSettings = settings
        tiffSettings.options = .defaults(for: .tiff)
        tiffSettings.quarterTurns = 1
        let all = BatchOutput(source: doc, destination: dir.appendingPathComponent("doc copy.tif"), action: .write,
                              pages: .all(count: 3))
        guard case .file(let file) = try await converter.encoded(all, settings: tiffSettings) else {
            Issue.record("every page is written to a file")
            return
        }
        #expect(file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(file.lastPathComponent.hasPrefix("."), "a hidden temporary sibling")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let pages = (0..<3).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        #expect(pages.map { [$0.width, $0.height] } == [[30, 40], [50, 20], [30, 30]], "each page turned")
        #expect(near(centre(pages[2]), [0, 0, 255]))
        try FileManager.default.removeItem(at: file)
    }

    /// An every-page GIF keeps the original's frame delays and loop count.
    @Test func everyFrameGIFKeepsItsTiming() async throws {
        let dir = try folder()
        let gif = write([solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1)], to: dir.appendingPathComponent("a.gif"),
                        type: .gif, delays: [0.2, 0.4, 0.8], loops: 4)
        let settings = BatchConvertSettings(options: .defaults(for: .gif), resize: BatchResize(mode: .width, pixels: 20),
                                            pages: .all)
        let output = BatchOutput(source: gif, destination: dir.appendingPathComponent("b.gif"), action: .write,
                                 pages: .all(count: 3))
        guard case .file(let file) = try await converter().encoded(output, settings: settings) else {
            Issue.record("every frame is written to a file")
            return
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let frames = try #require(AnimationFrames(url: file))
        #expect(frames.frameCount == 3 && frames.loopCount == 4)
        #expect(frames.delays.map { ($0 * 10).rounded() } == [2, 4, 8])
        #expect(frames.pixelSize == CGSize(width: 20, height: 15), "resized")
        #expect(near(centre(try #require(frames.frame(at: 1, maxPixelSize: 20))), [0, 255, 0]))
    }

    /// Extracting every frame opens the animation once, not once per frame
    /// (each fresh source would composite frame N from the first again), and
    /// each frame still comes out as itself; the next file opens its own.
    @Test func extractedFramesShareOneSource() async throws {
        let dir = try folder()
        let gif = write([solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1)], to: dir.appendingPathComponent("a.gif"), type: .gif)
        let doc = write([solid(1, 0, 0), solid(0, 0, 1)], to: dir.appendingPathComponent("doc.tif"), type: .tiff)
        let converter = await converter()
        let settings = BatchConvertSettings(options: .defaults(for: .png), pages: .separate(.all))
        let sequences = PageSequences()
        var colours: [[Int]] = []
        for (source, index, count) in [(gif, 0, 3), (gif, 1, 3), (gif, 2, 3), (doc, 1, 2)] {
            let output = BatchOutput(source: source, destination: dir.appendingPathComponent("out-\(colours.count).png"),
                                     action: .write, pages: .page(index: index, of: count))
            guard case .data(let data) = try await converter.encoded(output, settings: settings, sequences: sequences) else {
                Issue.record("a page is encoded to data")
                return
            }
            colours.append(centre(try #require(ImageEncoderTestDecode.image(data))))
        }
        #expect(zip(colours, [[255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 0, 255]]).allSatisfy { near($0, $1) })
        #expect(sequences.opened == 2, "the GIF once for its later frames, then the TIFF")
    }

    /// Cancel set while every page is written stops before the next page
    /// and leaves no temporary file.
    @Test func cancellingEveryPageLeavesNothing() async throws {
        let dir = try folder()
        let doc = write([solid(1, 0, 0), solid(0, 1, 0)], to: dir.appendingPathComponent("doc.tif"), type: .tiff)
        let cancel = CancellationFlag()
        cancel.cancel()
        let output = BatchOutput(source: doc, destination: dir.appendingPathComponent("out.tif"), action: .write,
                                 pages: .all(count: 2))
        await #expect(throws: CancellationError.self) {
            _ = try await converter().encoded(output, settings: BatchConvertSettings(options: .defaults(for: .tiff)),
                                              cancel: cancel)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.tif"])
    }

    /// A GIF of every frame that wouldn't fit the budget is refused first.
    @Test func everyFrameGIFIsCheckedAgainstTheBudget() async throws {
        let dir = try folder()
        let doc = write((0..<3).map { _ in solid(1, 1, 1, 400, 300) }, to: dir.appendingPathComponent("doc.tif"), type: .tiff)
        let tight = await BatchConverter(renderer: EditRenderer(exportDecodeLimit: 400 * 300 * 4 * 3 * 2),
                                         displaySettings: DisplaySettings()) { [srgb] _, _, _ in srgb }
        let output = BatchOutput(source: doc, destination: dir.appendingPathComponent("out.gif"), action: .write,
                                 pages: .all(count: 3))
        await #expect(throws: MultiPageBuilder.Failure.self) {
            _ = try await tight.encoded(output, settings: BatchConvertSettings(options: .defaults(for: .gif), pages: .all))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.tif"])
    }
}

enum ImageEncoderTestDecode {
    static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
