import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// G17's engine: the streaming TIFF writer, the page reader, the
/// multi-page writer and builder (TIFF, PDF, GIF, animated HEIC), image
/// strips and the `{page}` name token.
@Suite(.offCooperativePool) struct MultiPageTests {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int, height: Int,
                      space: CGColorSpace = sRGB) -> CGImage {
        ExportFixtures.solid(CGColor(colorSpace: space, components: [red, green, blue, 1])!, width: width,
                             height: height, space: space)
    }

    /// The colour at the middle of `image`, in sRGB.
    static func centre(_ image: CGImage) -> [Int] {
        let bytes = ExportFixtures.pixels(of: image)
        return ExportFixtures.pixel(bytes, width: image.width, x: image.width / 2, y: image.height / 2)
    }

    static func close(_ a: [Int], _ b: [Int], tolerance: Int = 6) -> Bool {
        zip(a.prefix(3), b.prefix(3)).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func source(_ url: URL) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    static func image(_ source: CGImageSource, _ index: Int) throws -> CGImage {
        try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
    }

    /// Pseudo-random pixels, which no lossless scheme can squeeze much.
    static func noise(width: Int, height: Int) -> CGImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in bytes.indices where i % 4 != 3 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 56)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A multi-page TIFF written by ImageIO, for reading tests.
    static func tiff(_ pages: [CGImage], at url: URL) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, pages.count, nil)!
        for page in pages { CGImageDestinationAddImage(destination, page, nil) }
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    /// An animated GIF with the given delays and loop count.
    static func gif(_ frames: [CGImage], delays: [Double], loops: Int, at url: URL) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]]
            as CFDictionary)
        for (frame, delay) in zip(frames, delays) {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - TIFF pages

    /// Pages appended one at a time read back as one TIFF: in order, each
    /// with its own size, compression and colour profile, pixels intact.
    @Test func tiffPagesAreJoinedInOrder() throws {
        let t = try TemporaryFolder()
        let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        let pages = [Self.solid(1, 0, 0, width: 40, height: 30),
                     Self.solid(0, 1, 0, width: 25, height: 50, space: adobe),
                     Self.solid(0, 0, 1, width: 64, height: 16)]
        let compressions: [TIFFCompression] = [.none, .lzw, .packBits]
        let url = t.url.appendingPathComponent("joined.tif")
        let writer = try TIFFPageWriter(url: url)
        for (page, compression) in zip(pages, compressions) {
            var options = ExportOptions(format: .tiff, keepMetadata: false)
            options.tiffCompression = compression
            try writer.append(ImageEncoder.encode(page, options: options, metadataSource: nil))
        }
        try writer.finish()
        #expect(writer.pageCount == 3)

        let source = try Self.source(url)
        #expect(CGImageSourceGetType(source) as String? == UTType.tiff.identifier)
        #expect(CGImageSourceGetCount(source) == 3)
        let sizes = try (0..<3).map { index in let i = try Self.image(source, index); return [i.width, i.height] }
        #expect(sizes == [[40, 30], [25, 50], [64, 16]])
        #expect(Self.close(Self.centre(try Self.image(source, 0)), [255, 0, 0]))
        #expect(Self.close(Self.centre(try Self.image(source, 2)), [0, 0, 255]))
        let second = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any] ?? [:]
        #expect((second[kCGImagePropertyProfileName] as? String)?.contains("Adobe") == true, "the page keeps its profile")
        let tiffProps = second[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect((tiffProps[kCGImagePropertyTIFFCompression] as? Int) == 5, "LZW on page 2")
        // The temporary-sibling convention: nothing but the file itself.
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["joined.tif"])
    }

    /// A page that would push the file past 4 GB, or isn't a TIFF, is
    /// refused rather than written wrong.
    @Test func tiffWriterRefusesWhatItCantJoin() throws {
        let page = try ImageEncoder.encode(Self.solid(1, 1, 1, width: 8, height: 8),
                                           options: ExportOptions(format: .tiff, keepMetadata: false), metadataSource: nil)
        #expect(throws: TIFFPageWriter.Failure.tooLarge) {
            try TIFFPageWriter.relocate(page, toOffset: Int(UInt32.max) - 17)
        }
        #expect(throws: TIFFPageWriter.Failure.unreadablePage) {
            try TIFFPageWriter.relocate(Data("not a tiff at all".utf8), toOffset: 8)
        }
        let moved = try TIFFPageWriter.relocate(page, toOffset: 1000)
        #expect(moved.body.count == page.count - 8)
        #expect(moved.firstDirectory > 1000 && moved.firstDirectory % 2 == 0)
    }

    // MARK: - Reading pages

    @Test func pageSequencesReadDocumentsAnimationsAndSinglePictures() throws {
        let t = try TemporaryFolder()
        let document = Self.tiff([Self.solid(1, 0, 0, width: 30, height: 20), Self.solid(0, 0, 1, width: 10, height: 40)],
                                 at: t.url.appendingPathComponent("doc.tif"))
        let pages = try #require(PageSequence(url: document))
        #expect(pages.kind == .document && pages.count == 2)
        #expect(pages.pixelSize(ofPage: 1) == CGSize(width: 10, height: 40))
        let second = try pages.page(1)
        #expect(second.width == 10 && second.height == 40)
        #expect(Self.close(Self.centre(second), [0, 0, 255]))
        #expect(pages.delay(ofPage: 0) == nil)

        let animation = Self.gif([Self.solid(1, 0, 0, width: 20, height: 20), Self.solid(0, 1, 0, width: 20, height: 20),
                                  Self.solid(0, 0, 1, width: 20, height: 20)],
                                 delays: [0.2, 0.5, 1], loops: 3, at: t.url.appendingPathComponent("anim.gif"))
        let frames = try #require(PageSequence(url: animation))
        #expect(frames.kind == .animation && frames.count == 3 && frames.loopCount == 3)
        #expect(frames.delays.map { ($0 * 100).rounded() } == [20, 50, 100])
        #expect(Self.close(Self.centre(try frames.page(2)), [0, 0, 255]))

        // A PDF's pages, rendered as the viewer renders them.
        let pdf = t.url.appendingPathComponent("doc.pdf")
        let writer = try MultiPageWriter(url: pdf, settings: MultiPageSettings(format: .pdf, pdfLossless: true),
                                         expectedPages: 2)
        try writer.add(Self.solid(1, 0, 0, width: 200, height: 100))
        try writer.add(Self.solid(0, 1, 0, width: 100, height: 200))
        try writer.finish()
        let pdfPages = try #require(PageSequence(url: pdf))
        #expect(pdfPages.kind == .document && pdfPages.count == 2)
        let rendered = try pdfPages.page(1, maxPixelSize: 400)
        #expect(rendered.height > rendered.width && Self.close(Self.centre(rendered), [0, 255, 0]))

        let photo = TestImages.write(Self.solid(0.5, 0.5, 0.5, width: 12, height: 9), to: t.url.appendingPathComponent("p.jpg"))
        #expect(PageSequence(url: photo)?.kind == .single)
        #expect(PageSequence.pageCount(of: photo) == 1 && PageSequence.pageCount(of: document) == 2)
        #expect(PageSequence.pageCount(of: t.url.appendingPathComponent("missing.jpg")) == 1)
        #expect(throws: DecodeError.self) { try pages.page(2) }
    }

    @Test func pageRanges() {
        #expect(PageRange.all.indices(count: 5) == 0..<5)
        #expect(PageRange(first: 2, last: 3).indices(count: 5) == 1..<3)
        #expect(PageRange(first: 4, last: 9).indices(count: 5) == 3..<5, "past the end is left out")
        #expect(PageRange(first: 7).indices(count: 5).isEmpty)
        #expect(PageRange(first: 0).problem != nil && PageRange(first: 3, last: 2).problem != nil)
        #expect(PageRange(first: 2, last: 2).problem == nil && !PageRange(first: 2).isAll && PageRange.all.isAll)
    }

    // MARK: - Writing

    /// A PDF page is the picture's size at the resolution its file records
    /// (72 dpi when none), or the paper turned to the picture's shape.
    @Test func pdfPagesTakeThePictureOrThePaperSize() throws {
        let t = try TemporaryFolder()
        let wide = Self.solid(1, 0, 0, width: 300, height: 150), tall = Self.solid(0, 1, 0, width: 100, height: 200)
        func boxes(_ url: URL) throws -> [CGSize] {
            let document = try #require(CGPDFDocument(url as CFURL))
            return (1...document.numberOfPages).compactMap { document.page(at: $0)?.getBoxRect(.mediaBox).size }
        }
        let own = t.url.appendingPathComponent("own.pdf")
        let writer = try MultiPageWriter(url: own, settings: MultiPageSettings(format: .pdf), expectedPages: 2)
        try writer.add(wide)
        try writer.add(tall, dpi: 144)
        try writer.finish()
        #expect(try boxes(own) == [CGSize(width: 300, height: 150), CGSize(width: 50, height: 100)])

        let paper = t.url.appendingPathComponent("a4.pdf")
        let a4 = try MultiPageWriter(url: paper, settings: MultiPageSettings(format: .pdf, pdfPageSize: .a4), expectedPages: 2)
        try a4.add(wide)
        try a4.add(tall)
        try a4.finish()
        let sizes = try boxes(paper).map { [Int($0.width.rounded()), Int($0.height.rounded())] }
        #expect(sizes == [[842, 595], [595, 842]], "landscape paper for the wide picture")

        // Lossless keeps every pixel and costs more bytes than JPEG pages.
        let photo = Self.noise(width: 300, height: 200)
        func written(lossless: Bool) throws -> Int {
            let url = t.url.appendingPathComponent("q\(lossless).pdf")
            let w = try MultiPageWriter(url: url, settings: MultiPageSettings(format: .pdf, pdfLossless: lossless),
                                        expectedPages: 1)
            try w.add(photo)
            try w.finish()
            return try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        }
        #expect(try written(lossless: true) > written(lossless: false))
        #expect(MultiPageWriter.pageSize(pixels: CGSize(width: 40000, height: 20000), dpi: nil).width == 14_400)
    }

    /// GIF frames: one size, fitted and centred; each frame's delay (an
    /// animation frame's own, or the settings'); the loop count.
    @Test func gifFramesKeepTheirTimingAndShareOneSize() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("anim.gif")
        let settings = MultiPageSettings(format: .gif, frameDelay: 0.25, loopCount: 2, frameSize: 100)
        let writer = try MultiPageWriter(url: url, settings: settings, expectedPages: 3)
        try writer.add(Self.solid(1, 0, 0, width: 400, height: 200))
        try writer.add(Self.solid(0, 1, 0, width: 50, height: 50), delay: 0.1)
        try writer.add(Self.solid(0, 0, 1, width: 200, height: 400))
        try writer.finish()

        let frames = try #require(AnimationFrames(url: url))
        #expect(frames.frameCount == 3 && frames.loopCount == 2)
        #expect(frames.pixelSize == CGSize(width: 100, height: 50), "the first picture fitted into 100 px")
        #expect(frames.delays.map { ($0 * 100).rounded() } == [25, 10, 25])
        // The tall third frame is fitted into the canvas: blue in the middle,
        // transparent at the sides.
        let third = try #require(frames.frame(at: 2, maxPixelSize: 100))
        let bytes = ExportFixtures.pixels(of: third)
        #expect(Self.close(ExportFixtures.pixel(bytes, width: third.width, x: 50, y: 25), [0, 0, 255], tolerance: 40))
        #expect(ExportFixtures.pixel(bytes, width: third.width, x: 2, y: 25)[3] == 0)
        #expect(settings.frameCanvas(first: CGSize(width: 40, height: 30)) == (40, 30), "never enlarged")
    }

    /// Animated HEIC, where ImageIO writes HEIC sequences: the frames come
    /// back and the browser's reader sees an animation. Measured on macOS
    /// 27, and pinned here so a change shows: every frame's delay is kept
    /// but the last, which reads back as the one before it, and no loop
    /// count is recorded (it reads back as 1, playing once), which is why
    /// the sheet offers no loop choice for HEIC.
    @Test(.enabled(if: MultiPageFormat.heics.isWritable)) func animatedHEIC() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("anim.heic")
        let settings = MultiPageSettings(format: .heics, frameDelay: 0.5, loopCount: 0, frameSize: nil)
        let writer = try MultiPageWriter(url: url, settings: settings, expectedPages: 3)
        try writer.add(Self.solid(1, 0, 0, width: 64, height: 48))
        try writer.add(Self.solid(0, 1, 0, width: 64, height: 48), delay: 0.2)
        try writer.add(Self.solid(0, 0, 1, width: 64, height: 48), delay: 1)
        try writer.finish()
        let info = try #require(ImageDecoder.info(for: url))
        #expect(info.isAnimated && info.pageCount == 3)
        let frames = try #require(AnimationFrames(url: url))
        #expect(frames.delays.map { ($0 * 10).rounded() } == [5, 2, 2])
        #expect(frames.loopCount == 1)
        #expect(Self.close(Self.centre(try #require(frames.frame(at: 2, maxPixelSize: 64))), [0, 0, 255], tolerance: 20))
    }

    /// AVIF sequences aren't offered: ImageIO can't write them here.
    @Test func noAnimatedAVIF() {
        #expect(MultiPageFormat.allCases.map(\.rawValue) == ["tiff", "pdf", "gif", "heics"])
        let types = ExportFormat.writableTypeIdentifiers
        #expect(!types.contains("public.avis"))
    }

    // MARK: - Building

    /// Pages go in the order given; every page of a multi-page file with
    /// `everyPage`; a picture that can't be read is left out and named.
    @Test func builderFollowsTheOrderAndLeavesOutUnreadablePictures() throws {
        let t = try TemporaryFolder()
        let red = TestImages.write(Self.solid(1, 0, 0, width: 30, height: 20), to: t.url.appendingPathComponent("r.png"), type: .png)
        let doc = Self.tiff([Self.solid(0, 1, 0, width: 30, height: 20), Self.solid(0, 0, 1, width: 30, height: 20)],
                            at: t.url.appendingPathComponent("gb.tif"))
        let broken = try t.file("broken.jpg", bytes: 100)
        #expect(MultiPageBuilder.pages(of: [doc, red], everyPage: false).map(\.index) == [0, 0])
        let pages = MultiPageBuilder.pages(of: [doc, broken, red], everyPage: true)
        #expect(pages.map(\.url) == [doc, doc, broken, red] && pages.map(\.index) == [0, 1, 0, 0])

        let url = t.url.appendingPathComponent("out.tif")
        var reported: [Int] = []
        let failures = try MultiPageBuilder.write(pages, settings: MultiPageSettings(format: .tiff), to: url,
                                                  byteLimit: 1 << 30, cancel: CancellationFlag()) { reported.append($0) }
        #expect(failures.map(\.0.url) == [broken])
        #expect(reported == [1, 2, 3, 4])
        let source = try Self.source(url)
        #expect(CGImageSourceGetCount(source) == 3)
        let colours = try (0..<3).map { Self.centre(try Self.image(source, $0)) }
        #expect(Self.close(colours[0], [0, 255, 0]) && Self.close(colours[1], [0, 0, 255]) && Self.close(colours[2], [255, 0, 0]))

        // Nothing readable: nothing written.
        let none = t.url.appendingPathComponent("none.tif")
        #expect(throws: MultiPageBuilder.Failure.nothingToWrite) {
            try MultiPageBuilder.write([.init(url: broken)], settings: MultiPageSettings(), to: none, byteLimit: 1 << 30,
                                       cancel: CancellationFlag())
        }
        #expect(!FileManager.default.fileExists(atPath: none.path))
    }

    /// Cancel stops before the next page and leaves no file.
    @Test func cancellingLeavesNoFile() throws {
        let t = try TemporaryFolder()
        let urls = try (0..<4).map { i in
            TestImages.write(Self.solid(CGFloat(i) / 4, 0, 0, width: 20, height: 20), to: t.url.appendingPathComponent("\(i).png"),
                             type: .png)
        }
        for format in [MultiPageFormat.tiff, .pdf, .gif] {
            let url = t.url.appendingPathComponent("out.\(format.fileExtension)")
            let cancel = CancellationFlag()
            var done = 0
            #expect(throws: CancellationError.self) {
                try MultiPageBuilder.write(MultiPageBuilder.pages(of: urls, everyPage: true),
                                           settings: MultiPageSettings(format: format), to: url, byteLimit: 1 << 30,
                                           cancel: cancel) { count in
                    done = count
                    if count == 2 { cancel.cancel() }
                }
            }
            #expect(done == 2, "stopped at the next page")
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(format) left nothing")
        }
    }

    /// An animation whose frames wouldn't fit the budget is refused before
    /// anything is decoded; TIFF and PDF aren't limited by their length.
    @Test func animationsAreCheckedAgainstTheBudget() throws {
        let settings = MultiPageSettings(format: .gif, frameSize: 1000)
        let first = CGSize(width: 4000, height: 3000)
        #expect(throws: MultiPageBuilder.Failure.tooManyFrames(frames: 100, width: 1000, height: 750)) {
            try MultiPageBuilder.checkBudget(pageCount: 100, first: first, settings: settings, byteLimit: 512 << 20)
        }
        #expect(throws: Never.self) {
            try MultiPageBuilder.checkBudget(pageCount: 10, first: first, settings: settings, byteLimit: 512 << 20)
            try MultiPageBuilder.checkBudget(pageCount: 10_000, first: first, settings: MultiPageSettings(format: .tiff),
                                             byteLimit: 1)
        }
        #expect(MultiPageSettings(format: .gif, frameDelay: 0.001).problem != nil)
        #expect(MultiPageSettings(format: .gif, frameSize: 10).problem != nil)
        #expect(MultiPageSettings(format: .gif).problem == nil)
    }

    /// Settings saved before an option existed still load.
    @Test func settingsDecodeWithDefaults() throws {
        let decoded = try JSONDecoder().decode(MultiPageSettings.self, from: Data(#"{"format":"gif","frameSize":null}"#.utf8))
        #expect(decoded.format == .gif && decoded.frameSize == nil && decoded.loopCount == 0 && decoded.background == nil)
        let empty = try JSONDecoder().decode(MultiPageSettings.self, from: Data("{}".utf8))
        #expect(empty == MultiPageSettings())
        let strip = try JSONDecoder().decode(ImageStripSettings.self, from: Data(#"{"arrangement":"grid"}"#.utf8))
        #expect(strip.arrangement == .grid && strip.size == 1080 && strip.background == .white)
    }

    // MARK: - Image strips

    @Test func stripLayouts() {
        let sizes = [CGSize(width: 400, height: 200), CGSize(width: 100, height: 100), .zero, CGSize(width: 300, height: 600)]
        var settings = ImageStripSettings(arrangement: .horizontal, size: 100, spacing: 10, margin: 5)
        var layout = ImageStripLayout.make(sizes: sizes, settings: settings)
        #expect(layout.frames == [CGRect(x: 5, y: 5, width: 200, height: 100), CGRect(x: 215, y: 5, width: 100, height: 100),
                                  .zero, CGRect(x: 325, y: 5, width: 50, height: 100)])
        #expect(layout.width == 380 && layout.height == 110)

        settings.arrangement = .vertical
        layout = ImageStripLayout.make(sizes: sizes, settings: settings)
        #expect(layout.frames[0] == CGRect(x: 5, y: 5, width: 100, height: 50))
        #expect(layout.frames[3] == CGRect(x: 5, y: 175, width: 100, height: 200))
        #expect(layout.width == 110 && layout.height == 380)

        settings = ImageStripSettings(arrangement: .grid, size: 100, columns: 2, spacing: 4, margin: 0)
        layout = ImageStripLayout.make(sizes: sizes, settings: settings)
        // Middle shape of 2:1, 1:1 and 1:2 is 1:1: 100 px cells.
        #expect(layout.width == 204 && layout.height == 204)
        #expect(layout.frames[0] == CGRect(x: 0, y: 25, width: 100, height: 50), "fitted and centred in its cell")
        #expect(layout.frames[3] == CGRect(x: 25, y: 104, width: 50, height: 100))

        let long = ImageStripLayout.make(sizes: Array(repeating: CGSize(width: 4000, height: 1000), count: 10),
                                         settings: ImageStripSettings(size: 1000))
        #expect(long.width == 40000)
        #expect(long.problem(byteLimit: 1 << 34)?.contains("32,768") == true)
        let fits = ImageStripLayout.make(sizes: [CGSize(width: 2000, height: 1000)], settings: ImageStripSettings(size: 1000))
        #expect(fits.problem(byteLimit: 1 << 30) == nil)
        #expect(fits.problem(byteLimit: 1_000_000) != nil, "past the memory budget")
    }

    /// The strip's pictures land in their frames, over the background or
    /// transparency; a picture that can't be read leaves its frame empty.
    @Test func stripsRenderEachPictureInItsFrame() throws {
        let t = try TemporaryFolder()
        let red = TestImages.write(Self.solid(1, 0, 0, width: 80, height: 40), to: t.url.appendingPathComponent("r.png"), type: .png)
        let blue = TestImages.write(Self.solid(0, 0, 1, width: 40, height: 40), to: t.url.appendingPathComponent("b.png"), type: .png)
        let broken = try t.file("x.jpg", bytes: 10)
        let urls = [red, broken, blue]
        var settings = ImageStripSettings(arrangement: .horizontal, size: 20, spacing: 4, margin: 2, background: nil,
                                          options: .defaults(for: .png))
        let sizes = ImageStripRenderer.sizes(of: urls)
        #expect(sizes[1] == .zero)
        let strip = try ImageStripRenderer.render(urls, sizes: sizes, settings: settings, byteLimit: 1 << 30,
                                                  cancel: CancellationFlag())
        #expect(strip.failed.isEmpty, "an unreadable file takes no room rather than failing")
        #expect(strip.image.width == 2 + 40 + 4 + 20 + 2 && strip.image.height == 24)
        let bytes = ExportFixtures.pixels(of: strip.image)
        let w = strip.image.width
        #expect(Self.close(ExportFixtures.pixel(bytes, width: w, x: 20, y: 12), [255, 0, 0], tolerance: 10))
        #expect(Self.close(ExportFixtures.pixel(bytes, width: w, x: 56, y: 12), [0, 0, 255], tolerance: 10))
        #expect(ExportFixtures.pixel(bytes, width: w, x: 44, y: 12)[3] == 0, "transparent spacing")

        settings.background = .white
        let opaque = try ImageStripRenderer.render(urls, sizes: sizes, settings: settings, byteLimit: 1 << 30,
                                                   cancel: CancellationFlag())
        #expect(ExportFixtures.pixel(ExportFixtures.pixels(of: opaque.image), width: w, x: 44, y: 12) == [255, 255, 255, 255])

        let cancel = CancellationFlag()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            try ImageStripRenderer.render(urls, sizes: sizes, settings: settings, byteLimit: 1 << 30, cancel: cancel)
        }
        #expect(throws: ImageStripRenderer.Failure.self) {
            try ImageStripRenderer.render(urls, sizes: sizes, settings: settings, byteLimit: 100, cancel: CancellationFlag())
        }
    }

    // MARK: - Names

    /// `{page}` is the page number padded to the file's page count; Batch
    /// Rename, which renames whole files, refuses it.
    @Test func pageNumberToken() {
        let pattern = RenamePattern(text: "{name} p{page}")
        #expect(pattern.usesPageNumber && RenamePattern(text: "{frame}").usesPageNumber)
        let namer = RenameNamer(pattern: pattern)
        let source = RenameSource(url: URL(fileURLWithPath: "/a/scan.tif"), page: 3, pageCount: 12)
        #expect(namer.name(for: source, index: 0, newExtension: "png") == "scan p03.png")
        #expect(namer.name(for: RenameSource(url: URL(fileURLWithPath: "/a/one.jpg")), index: 0) == "one p.jpg")
        #expect(RenameNamer.pageLabel(7, of: 100) == "007" && RenameNamer.pageLabel(12, of: 9) == "12")
        let plan = RenamePlanner.plan([RenameSource(url: URL(fileURLWithPath: "/a/one.jpg"))], pattern: pattern)
        #expect(plan.unknownTokens == ["{page}"] && !plan.canRename)
    }
}
