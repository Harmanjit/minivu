import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuRender
@testable import MinivuCore

/// G6: batch presets in the engine. Which edit steps a preset carries
/// (`BatchEdits`), the order Batch Convert applies edits, resize and
/// watermark in, Auto Enhance measured on each image, HDR kept as a gain map,
/// and the memory budget checked before anything is decoded.
@Suite struct BatchPresetEngineTests {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor func converter(limit: Int? = nil) -> BatchConverter {
        let renderer = limit.map { EditRenderer(exportDecodeLimit: $0) } ?? EditRenderer.shared
        return BatchConverter(renderer: renderer, displaySettings: DisplaySettings()) { [srgb] _, _, _ in srgb }
    }

    func folder() throws -> URL {
        let url = Fixtures.directory.appendingPathComponent("preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func decode(_ data: Data) throws -> (image: CGImage, source: CGImageSource) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), source)
    }

    /// An 8-bit sRGB pixel of `image`, top row first.
    func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }

    // MARK: - What a preset carries

    @Test func portableStepsAndTheOnesLeftOut() {
        var stamp = Watermark()
        stamp.text = "© 2026"
        var measured = AutoEnhance()
        measured.filters = [AutoEnhance.Filter(name: "CIVibrance", numbers: ["inputAmount": 0.4])]
        let operations: [EditOperation] = [
            .lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0),
            .resize(width: 800, height: 600, filter: .lanczos3),
            .autoEnhance(measured),
            .crop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            .retouch([RetouchStroke(mode: .clone, points: [CGPoint(x: 0.5, y: 0.5)], sourceOffset: CGVector(dx: 0.05, dy: 0))]),
            .redEye([RedEyeSpot(center: CGPoint(x: 0.3, y: 0.3), radius: 0.01)]),
            .annotations([Annotation(kind: .text)]),
            .canvasSize(CanvasSize(width: 1000, height: 1000, anchor: .center, fill: .white)),
            .sharpen(amount: 0, radius: 2),           // identity: dropped without a word
            .vignette(amount: 0.5, radius: 0.5, feather: 0.5),
            .watermark(stamp),
            .rotate90(turns: 1),
            .flip(horizontal: true),
            .rawDevelop(RawDevelop()),
        ]
        let portable = BatchEdits.portable(operations)
        #expect(portable.operations == [
            .lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0),
            .autoEnhance(AutoEnhance()),
            .crop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            .vignette(amount: 0.5, radius: 0.5, feather: 0.5),
            .watermark(stamp),
            .rotate90(turns: 1),
            .flip(horizontal: true),
            .rawDevelop(RawDevelop()),
        ], "Auto Enhance travels without the values measured on this photo")
        #expect(portable.leftOut.map(\.title) == ["Resize", "Clone Stamp", "Red-Eye Removal", "Drawing", "Canvas Size"])
        #expect(portable.leftOut.allSatisfy { !$0.reason.isEmpty })
        #expect(BatchEdits.note(for: .autoEnhance(AutoEnhance())) != nil)
        #expect(BatchEdits.note(for: .rawDevelop(RawDevelop())) != nil)
        #expect(BatchEdits.note(for: .grayscale) == nil)

        #expect(BatchEdits.portable([.resize(width: 10, height: 10, filter: .box)]).isEmpty)
    }

    /// A crop or perspective measured on the canvas a left-out Canvas Size
    /// made would land elsewhere on a bare photo, so it stays behind too;
    /// one after a left-out resize (each side scaled) still travels.
    @Test func framedStepsAfterALeftOutCanvasSizeStayBehind() {
        let crop = EditOperation.crop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let quad = EditOperation.perspective(PerspectiveQuad(topLeft: CGPoint(x: 0.05, y: 0), topRight: CGPoint(x: 0.95, y: 0),
                                                             bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1)))
        let portable = BatchEdits.portable([
            .resize(width: 800, height: 300, filter: .lanczos3), crop,
            .canvasSize(CanvasSize(width: 1000, height: 1000, anchor: .center, fill: .white)),
            .grayscale, crop, quad,
        ])
        #expect(portable.operations == [crop, .grayscale])
        #expect(portable.leftOut.map(\.title) == ["Resize", "Canvas Size", "Crop", "Perspective"])
        #expect(portable.leftOut.suffix(2).allSatisfy { $0.reason == BatchEdits.afterCanvasSize })
    }

    // MARK: - Settings

    /// Settings remembered before presets existed load unchanged, with no
    /// edits, no watermark and HDR kept; the new fields round-trip.
    @Test func settingsFromBeforePresetsStillLoad() throws {
        let old = Data(#"{"options":{"format":"png"},"quarterTurns":1,"flipVertical":true}"#.utf8)
        let settings = try JSONDecoder().decode(BatchConvertSettings.self, from: old)
        #expect(settings.edits.isEmpty && settings.watermark == nil && settings.keepsHDR)
        #expect(settings.quarterTurns == 1 && settings.flipVertical && settings.options.format == .png)

        var watermark = Watermark()
        watermark.text = "© minivu"
        watermark.tiled = true
        let full = BatchConvertSettings(options: .defaults(for: .heic), quarterTurns: 2,
                                        edits: [.grayscale, .autoEnhance(AutoEnhance()), .sharpen(amount: 1, radius: 2)],
                                        watermark: watermark, keepsHDR: false)
        #expect(try JSONDecoder().decode(BatchConvertSettings.self, from: JSONEncoder().encode(full)) == full)
    }

    /// Edits first, then turn, flip and resize (sized from the edited and
    /// turned picture), then the watermark at the output's size.
    @Test func editsComeBeforeTheResizeAndTheWatermarkAfter() {
        var watermark = Watermark()
        watermark.text = "x"
        let settings = BatchConvertSettings(resize: BatchResize(mode: .width, pixels: 100, filter: .catmullRom),
                                            quarterTurns: 1,
                                            edits: [.crop(CGRect(x: 0, y: 0, width: 0.5, height: 1)), .grayscale],
                                            watermark: watermark)
        // 600 × 400, cropped to 300 × 400, turned to 400 × 300, width 100.
        #expect(settings.operations(sourceSize: CGSize(width: 600, height: 400)) == [
            .crop(CGRect(x: 0, y: 0, width: 0.5, height: 1)), .grayscale, .rotate90(turns: 1),
            .resize(width: 100, height: 75, filter: .catmullRom), .watermark(watermark),
        ])
        var empty = Watermark()
        empty.text = ""
        #expect(BatchConvertSettings(watermark: empty).operations(sourceSize: CGSize(width: 10, height: 10)).isEmpty,
                "a watermark that draws nothing adds no step")
    }

    // MARK: - Converting

    /// A preset's edit reaches every output: Negative turns the white
    /// quadrant black and the red one cyan, through the renderer.
    @Test func editsAreAppliedToEveryImage() async throws {
        let dir = try folder()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try BatchFixtures.writeJPEG(to: a, width: 64, height: 32)
        try BatchFixtures.writeJPEG(to: b, width: 32, height: 64)
        let settings = BatchConvertSettings(options: .defaults(for: .png), edits: [.negative])
        let converter = await converter()
        for url in [a, b] {
            let (image, _) = try decode(try await converter.encodedData(for: url, settings: settings))
            let white = rgb(image, image.width * 3 / 4, image.height * 3 / 4)
            let red = rgb(image, image.width / 4, image.height / 4)
            #expect(white.allSatisfy { $0 < 40 }, "\(url.lastPathComponent) white became \(white)")
            #expect(red[0] < 60 && red[1] > 190 && red[2] > 190, "\(url.lastPathComponent) red became \(red)")
        }
    }

    /// The watermark stamped in the batch lands where it was placed, at the
    /// output's size: the bottom-right corner changes, the top left doesn't.
    @Test func aWatermarkAddedInTheBatchIsStampedLast() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("plain.png")
        let white = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        white.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        white.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(white.makeImage()), nil)
        try #require(CGImageDestinationFinalize(dest))

        var watermark = Watermark()
        watermark.text = "MMMM"
        watermark.color = .black
        watermark.opacity = 1
        watermark.size = 0.2
        watermark.position = .bottomRight
        let settings = BatchConvertSettings(options: .defaults(for: .png),
                                            resize: BatchResize(mode: .longSide, pixels: 200, filter: .lanczos3),
                                            watermark: watermark)
        let (image, _) = try decode(try await converter().encodedData(for: url, settings: settings))
        #expect(image.width == 200 && image.height == 150)
        var darkInCorner = 0
        for y in 100..<150 { for x in 120..<200 where rgb(image, x, y)[0] < 128 { darkInCorner += 1 } }
        #expect(darkInCorner > 50, "the text is drawn bottom right (\(darkInCorner) dark pixels)")
        #expect(rgb(image, 10, 10) == [255, 255, 255], "the rest is untouched")
    }

    /// A gradient from `low` to `high` grey, as a JPEG.
    func greyRamp(_ url: URL, low: CGFloat, high: CGFloat) throws {
        let ctx = try #require(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<256 {
            let v = low + (high - low) * CGFloat(x) / 255
            ctx.setFillColor(CGColor(srgbRed: v, green: v * 0.9, blue: v * 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 128))
        }
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        try #require(CGImageDestinationFinalize(dest))
    }

    /// Auto Enhance in a preset is measured on each photo, not carried from
    /// the photo the preset was made on: a dark, flat photo and a bright one
    /// get different adjustments, each what the viewer's Auto Enhance would
    /// measure on that photo's rendering.
    @Test func autoEnhanceIsMeasuredOnEachImage() async throws {
        let dir = try folder()
        let dark = dir.appendingPathComponent("dark.jpg"), bright = dir.appendingPathComponent("bright.jpg")
        try greyRamp(dark, low: 0.05, high: 0.3)
        try greyRamp(bright, low: 0.5, high: 0.95)
        let settings = BatchConvertSettings(options: .defaults(for: .png), edits: [.autoEnhance(AutoEnhance())])
        let converter = await converter()
        let darkJob = try converter.prepare(dark, settings: settings, keepingHDR: false)
        let brightJob = try converter.prepare(bright, settings: settings, keepingHDR: false)
        guard case .autoEnhance(let forDark) = darkJob.operations.first,
              case .autoEnhance(let forBright) = brightJob.operations.first else {
            Issue.record("Auto Enhance was dropped")
            return
        }
        #expect(!forDark.isIdentity, "a dark, flat photo needs something")
        #expect(forDark != forBright, "each photo gets its own measurement")

        // The same measurement the viewer makes on the photo itself.
        let small = try ImageDecoder.decode(dark, maxPixelSize: EditRenderer.analysisPixelSize, allowHDR: false).image
        #expect(AutoEnhance.analyse(CIImage(cgImage: small)).filters.map(\.name) == forDark.filters.map(\.name))

        // And it renders: the dark photo comes out brighter in the middle.
        let (plain, _) = try decode(try await converter.encodedData(for: dark, settings: BatchConvertSettings(options: .defaults(for: .png))))
        let (enhanced, _) = try decode(try await converter.encodedData(for: dark, settings: settings))
        #expect(rgb(enhanced, 128, 64)[0] > rgb(plain, 128, 64)[0])
    }

    // MARK: - HDR

    func gainMap(_ data: Data) throws -> Bool {
        let (_, source) = try decode(data)
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    func hdrHeadroom(_ data: Data) throws -> Float {
        let (_, source) = try decode(data)
        let hdr = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
        return hdr?.contentHeadroom ?? 1
    }

    /// The brightest value of the file decoded for HDR, in extended linear
    /// Display P3: above 1 only if the highlights really came through (the
    /// headroom alone is a number in the file, which a clipped render would
    /// still carry).
    func brightest(_ data: Data) throws -> Float {
        let (_, source) = try decode(data)
        let hdr = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
        let w = hdr.width, h = hdr.height
        var values = [Float](repeating: 0, count: w * h * 4)
        try values.withUnsafeMutableBytes { buffer in
            let ctx = try #require(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 32,
                                             bytesPerRow: w * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                 | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.draw(hdr, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return values.max() ?? 0
    }

    static var gainMapFormats: [ExportFormat] { [.jpeg, .heic] + (ExportFormat.avif.isWritable ? [.avif] : []) }

    /// An HDR original keeps its highlights in every format that holds a
    /// gain map, with a preset's edits and a resize as well as without; off,
    /// or in PNG, it is written SDR.
    @Test(arguments: gainMapFormats)
    func hdrOriginalsKeepAGainMap(_ format: ExportFormat) async throws {
        let url = try Fixtures.gainMapHEIC(width: 256, height: 64)
        let converter = await converter()
        var settings = BatchConvertSettings(options: .defaults(for: format))
        let plain = try await converter.encodedData(for: url, settings: settings)
        #expect(try gainMap(plain), "\(format): format change only")
        #expect(try hdrHeadroom(plain) > 2 && brightest(plain) > 2, "\(format)")

        settings.edits = [.colors(hue: 0, saturation: 0.2, lightness: 0, temperature: 0, tint: 0)]
        settings.resize = BatchResize(mode: .longSide, pixels: 128, filter: .lanczos3)
        let edited = try await converter.encodedData(for: url, settings: settings)
        #expect(try gainMap(edited) && hdrHeadroom(edited) > 2, "\(format): edited and resized")
        #expect(try brightest(edited) > 2, "\(format): the highlights survive the edit and the Lanczos resize")
        #expect(try decode(edited).image.width == 128)

        settings.keepsHDR = false
        let sdr = try await converter.encodedData(for: url, settings: settings)
        #expect(try !gainMap(sdr) && brightest(sdr) <= 1.01, "\(format): HDR off")
    }

    /// A gain map's base is always Display P3 at 8 bits, so an explicit
    /// sRGB or Adobe RGB profile, or the deeper bit depth, writes the HDR
    /// original SDR as chosen instead of a gain map that ignores the choice;
    /// Display P3 and Keep original keep HDR.
    @Test(arguments: gainMapFormats)
    func anExplicitProfileOrDepthWritesSDRAsChosen(_ format: ExportFormat) async throws {
        let url = try Fixtures.gainMapHEIC(width: 256, height: 64)
        let converter = await converter()
        var settings = BatchConvertSettings(options: .defaults(for: format))
        settings.options.colorProfile = .sRGB
        let srgb = try await converter.encodedData(for: url, settings: settings)
        #expect(try !gainMap(srgb), "\(format): sRGB asked for")
        #expect(try decode(srgb).image.colorSpace?.name == CGColorSpace.sRGB, "\(format): tagged sRGB, as chosen")

        settings.options.colorProfile = .displayP3
        #expect(try gainMap(try await converter.encodedData(for: url, settings: settings)), "\(format): Display P3 keeps HDR")
        settings.options.colorProfile = .original
        #expect(try gainMap(try await converter.encodedData(for: url, settings: settings)), "\(format): Keep original keeps HDR")

        if format.supports16Bit {
            settings.options.sixteenBit = true
            let deep = try await converter.encodedData(for: url, settings: settings)
            #expect(try !gainMap(deep), "\(format): the deeper depth asked for")
            let properties = CGImageSourceCopyPropertiesAtIndex(try decode(deep).source, 0, nil) as? [CFString: Any]
            #expect((properties?[kCGImagePropertyDepth] as? Int ?? 8) > 8, "\(format): written at the depth chosen")
        }
    }

    @Test func pngAndPQOriginals() async throws {
        let converter = await converter()
        let gainMapped = try Fixtures.gainMapHEIC(width: 256, height: 64)
        let png = try await converter.encodedData(for: gainMapped, settings: BatchConvertSettings(options: .defaults(for: .png)))
        #expect(try !gainMap(png), "PNG holds no gain map: SDR")
        // A PQ original keeps HDR as a gain map too: the format changes, the
        // highlights stay.
        let pq = try Fixtures.pqHEIC()
        let heic = try await converter.encodedData(for: pq, settings: BatchConvertSettings(options: .defaults(for: .heic)))
        #expect(try gainMap(heic) && hdrHeadroom(heic) > 2 && brightest(heic) > 2)
    }

    // MARK: - Memory

    func isTooLarge(_ work: () async throws -> Data) async -> Bool {
        do {
            _ = try await work()
            return false
        } catch DecodeError.tooLarge {
            return true
        } catch {
            return false
        }
    }

    /// An output the Mac couldn't hold is refused before anything is
    /// decoded: a 64 × 48 photo enlarged ten times needs 3072 × 2304 pixels,
    /// over a limit that holds the photo itself with room to spare, while
    /// the same photo turned converts. A preset's edits that grow the
    /// picture (a frame) count too.
    @Test func outputsOverTheExportBudgetAreRefused() async throws {
        let dir = try folder()
        let photo = dir.appendingPathComponent("photo.jpg")
        try BatchFixtures.writeJPEG(to: photo, width: 64, height: 48)
        let limit = 64 * 48 * 4 * 20
        let converter = await converter(limit: limit)
        var settings = BatchConvertSettings(options: .defaults(for: .png),
                                            resize: BatchResize(mode: .percent, percent: 1000, doesNotEnlarge: false))
        #expect(await isTooLarge { try await converter.encodedData(for: photo, settings: settings) })
        settings.resize = BatchResize()
        settings.quarterTurns = 1
        let (turned, _) = try decode(try await converter.encodedData(for: photo, settings: settings))
        #expect(turned.width == 48 && turned.height == 64)

        // 64 × 48 framed by a quarter of the short side is 88 × 72; at 16
        // bits that is 50 688 bytes, past a limit of 24 576 that the photo
        // itself (12 288 bytes decoded) is well within.
        let small = await self.converter(limit: 64 * 48 * 8)
        var frame = FrameStyle()
        frame.width = 0.25
        settings = BatchConvertSettings(options: .defaults(for: .png), edits: [.frame(frame)])
        settings.options.sixteenBit = true
        #expect(EditGraph.outputSize(source: CGSize(width: 64, height: 48), operations: settings.edits) == CGSize(width: 88, height: 72))
        #expect(await isTooLarge { try await small.encodedData(for: photo, settings: settings) })
        settings.edits = []
        let (whole, _) = try decode(try await small.encodedData(for: photo, settings: settings))
        #expect(whole.width == 64 && whole.height == 48)
    }
}
