import Testing
import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender
@testable import Minivu

/// The decisions behind Save and Save As, with no panels.
@Suite struct SavePolicyTests {
    func format(_ name: String, kind: ImageKind = .raster, pages: Int = 1, animated: Bool = false) -> ExportFormat? {
        SavePolicy.inPlaceFormat(for: url(name), kind: kind, imageCount: pages, isAnimated: animated)
    }

    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func saveOverwritesOnlyWhatItCanWriteBack() {
        #expect(format("a.jpg") == .jpeg)
        #expect(format("a.TIF") == .tiff)
        #expect(format("a.png") == .png)
        // Formats minivu can't write, and RAW files, which are never modified.
        #expect(format("a.webp") == nil)
        #expect(format("a.nef", kind: .raw) == nil)
        #expect(format("a.tif", kind: .raw) == nil)
        // Writing one picture back would lose the rest.
        #expect(format("a.gif", pages: 12, animated: true) == nil)
        #expect(format("a.tif", pages: 3) == nil)
        #expect(format("a.ico", pages: 4) == nil)
        // A JPEG's second image is a gain map or stereo partner.
        #expect(format("a.jpg", pages: 2) == .jpeg)
        #expect(SavePolicy.inPlaceFormat(for: url("a.jpg"), info: nil) == nil)
    }

    @Test func renderColorSpaces() {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        func name(_ space: CGColorSpace) -> String { (space.name as String?) ?? "" }

        #expect(name(SavePolicy.renderColorSpace(source: srgb, isHDR: false, preferWideGamut: false)) == name(srgb))
        #expect(name(SavePolicy.renderColorSpace(source: srgb, isHDR: false, preferWideGamut: true)) == name(p3))
        #expect(name(SavePolicy.renderColorSpace(source: adobe, isHDR: false, preferWideGamut: true)) == name(adobe))
        #expect(name(SavePolicy.renderColorSpace(source: srgb, isHDR: true, preferWideGamut: false)) == name(p3))
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        #expect(name(SavePolicy.renderColorSpace(source: linear, isHDR: false, preferWideGamut: false)) == name(p3))
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        #expect(name(SavePolicy.renderColorSpace(source: gray, isHDR: false, preferWideGamut: true)) == name(srgb))
        #expect(name(SavePolicy.renderColorSpace(source: nil, isHDR: false, preferWideGamut: false)) == name(srgb))
        #expect(SavePolicy.namedColorSpace(.original) == nil)
        #expect(SavePolicy.namedColorSpace(.adobeRGB).map(name) == name(adobe))
    }

    @Test func inPlaceOptionsKeepTheOriginalsDepthSpaceAndMetadata() {
        var remembered = ExportOptions(format: .png, quality: 0.5, colorProfile: .sRGB, keepMetadata: false)
        var options = SavePolicy.inPlaceOptions(remembered: remembered, sourceBitDepth: 16)
        #expect(options.colorProfile == .original && options.keepMetadata && options.sixteenBit)
        #expect(options.quality == 0.5)
        options = SavePolicy.inPlaceOptions(remembered: remembered, sourceBitDepth: 8)
        #expect(!options.sixteenBit)
        remembered.format = .bmp
        options = SavePolicy.inPlaceOptions(remembered: remembered, sourceBitDepth: 16)
        #expect(!options.keepMetadata && !options.sixteenBit)
    }

    @Test func formatChangesTheExtension() {
        #expect(SaveAsNaming.renamed("photo.jpg", to: .tiff) == "photo.tif")
        #expect(SaveAsNaming.renamed("photo.jpeg", to: .jpeg) == "photo.jpg")
        #expect(SaveAsNaming.renamed("DSC_0001.NEF", to: .jpeg) == "DSC_0001.jpg")
        #expect(SaveAsNaming.renamed("Trip.final", to: .png) == "Trip.final.png")
        #expect(SaveAsNaming.renamed("scan", to: .jpeg2000) == "scan.jp2")
        #expect(SaveAsNaming.renamed(".png", to: .gif) == ".png.gif")
        #expect(SaveAsNaming.renamed("  ", to: .heic) == "Untitled.heic")
    }

    @Test func renderKeys() {
        var options = ExportOptions(format: .bmp, colorProfile: .displayP3, sixteenBit: true)
        #expect(SaveRenderKey.forEdit(options) == SaveRenderKey(profile: .sRGB, bitsPerComponent: 8))
        options.format = .png
        #expect(SaveRenderKey.forEdit(options) == SaveRenderKey(profile: .displayP3, bitsPerComponent: 16))
        options.format = .jpeg
        #expect(SaveRenderKey.forEdit(options) == SaveRenderKey(profile: .displayP3, bitsPerComponent: 8))
    }

    @Test func overwriteConfirmationNamesTheEncoding() {
        #expect(SavePolicy.overwriteDetail(ExportOptions(format: .jpeg, quality: 0.3))
            == "The edited image is saved over the file as JPEG at quality 30. This can’t be undone.")
        #expect(SavePolicy.overwriteDetail(.defaults(for: .png))
            == "The edited image is saved over the file as PNG. This can’t be undone.")
        #expect(SavePolicy.overwriteDetail(ExportOptions(format: .heic, quality: 0.9), hdr: .gainMap)
            == "The edited image is saved over the file as HEIC at quality 90, in HDR with a new gain map. This can’t be undone.")
        #expect(SavePolicy.overwriteDetail(ExportOptions(format: .heic, quality: 0.9), hdr: .toneMapped)
            == "The edited image is saved over the file as HEIC at quality 90, in SDR: minivu can’t write this kind "
            + "of HDR file, so its highlights are tone mapped. This can’t be undone.")
    }

    /// Gain-map photos stay HDR where ImageIO writes gain maps; other HDR
    /// forms are tone mapped, and the confirmation says so.
    @Test func hdrOriginalsSavedInPlace() {
        #expect(SavePolicy.inPlaceHDR(format: .jpeg, isHDR: false, hasGainMap: false) == .none)
        #expect(SavePolicy.inPlaceHDR(format: .jpeg, isHDR: true, hasGainMap: true) == .gainMap)
        #expect(SavePolicy.inPlaceHDR(format: .heic, isHDR: true, hasGainMap: true) == .gainMap)
        #expect(SavePolicy.inPlaceHDR(format: .heic, isHDR: true, hasGainMap: false) == .toneMapped, "PQ or HLG")
        #expect(SavePolicy.inPlaceHDR(format: .png, isHDR: true, hasGainMap: false) == .toneMapped)
        #expect(SavePolicy.inPlaceHDR(format: .tiff, isHDR: true, hasGainMap: true) == .toneMapped)
    }

    @Test func errorMessages() {
        #expect(SaveAlert.message(for: ExportError.encodingFailed(.png)) == "The image couldn't be encoded as PNG.")
        #expect(SaveAlert.message(for: DecodeError.noImage(URL(fileURLWithPath: "/tmp/x.jpg"))).hasPrefix("x.jpg"))
        let denied = CocoaError(.fileWriteNoPermission)
        #expect(SaveAlert.message(for: denied) == denied.localizedDescription)
    }
}

@MainActor @Suite struct SaveOptionsStoreTests {
    func withStore(_ body: (SaveOptionsStore) throws -> Void) rethrows {
        let scratchDefaults = ScratchDefaults("minivu-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        try body(SaveOptionsStore(defaults: defaults))
    }

    @Test func remembersOptionsPerFormat() {
        withStore { store in
            #expect(store.options(for: .heic) == .defaults(for: .heic))
            #expect(!store.hasRemembered(.jpeg))
            store.remember(ExportOptions(format: .jpeg, quality: 0.72, progressive: true))
            store.remember(ExportOptions(format: .tiff, sixteenBit: true, tiffCompression: .packBits))
            #expect(store.hasRemembered(.jpeg))
            #expect(store.options(for: .jpeg).quality == 0.72)
            #expect(store.options(for: .jpeg).progressive)
            #expect(store.options(for: .tiff).tiffCompression == .packBits)
            #expect(store.options(for: .png) == .defaults(for: .png))
            #expect(store.lastFormat == .tiff)
        }
    }

    @Test func partialOptionsLoadWithDefaults() {
        withStore { store in
            store.defaults.set(Data(#"{"format":"png","quality":0.3}"#.utf8), forKey: SaveOptionsStore.Keys.options(.jpeg))
            let options = store.options(for: .jpeg)
            #expect(options.format == .jpeg)
            #expect(options.quality == 0.3)
            #expect(options.keepMetadata)
        }
    }

    @Test func lastFolderAndInitialFormat() {
        withStore { store in
            #expect(store.lastFolder == nil)
            store.lastFolder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
            #expect(store.lastFolder?.path == "/tmp/exports")
            #expect(store.initialFormat(for: URL(fileURLWithPath: "/a/b.tiff")) == .tiff)
            #expect(store.initialFormat(for: URL(fileURLWithPath: "/a/b.nef")) == .jpeg)
            store.remember(.defaults(for: .png))
            #expect(store.initialFormat(for: URL(fileURLWithPath: "/a/b.webp")) == .png)
        }
    }
}

@Suite struct SizeEstimatorTests {
    @Test func centreCropIsOnTheBlockGrid() {
        let crop = SizeEstimator.centreCrop(imageWidth: 6032, imageHeight: 4031)
        #expect(crop.width == 1024 && crop.height == 1024)
        #expect(Int(crop.minX) % 16 == 0 && Int(crop.minY) % 16 == 0)
        #expect(abs(crop.midX - 3016) <= 8 && abs(crop.midY - 2015.5) <= 8.5)
    }

    @Test func cropsStayInsideTheImage() {
        #expect(SizeEstimator.centreCrop(imageWidth: 500, imageHeight: 300) == CGRect(x: 0, y: 0, width: 500, height: 300))
        let corner = SizeEstimator.crop(imageWidth: 3000, imageHeight: 2000, centre: CGPoint(x: 2990, y: -50))
        #expect(corner.minY == 0)
        #expect(corner.maxX <= 3000 && Int(corner.minX) % 16 == 0)
        #expect(corner.minX == CGFloat((3000 - 1024) / 16 * 16))
    }

    @Test func extrapolation() {
        #expect(SizeEstimator.extrapolate(cropBytes: 100_000, cropPixels: 1024 * 1024, totalPixels: 4 * 1024 * 1024) == 400_000)
        #expect(SizeEstimator.extrapolate(cropBytes: 5, cropPixels: 0, totalPixels: 10) == 0)
    }

    @Test func approximateIsCloseToExactForUniformDetail() throws {
        let image = try #require(Self.noise(width: 3000, height: 2000))
        let options = ExportOptions(format: .png)
        let exact = try SizeEstimator.exactBytes(image, options: options, metadataSource: nil)
        let approximate = try SizeEstimator.approximateBytes(image, options: options)
        #expect(abs(Double(approximate) / Double(exact) - 1) < 0.1)
    }

    /// Repeatable noise, which compresses the same everywhere.
    static func noise(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var state: UInt32 = 12345
        for i in 0..<(context.bytesPerRow * height) {
            state = state &* 1_664_525 &+ 1_013_904_223
            data[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24) / 4 + 100
        }
        return context.makeImage()
    }
}

@Suite struct CompareViewportTests {
    @Test func startsCentredAndPansWithThePointer() {
        var viewport = CompareViewport(imageWidth: 4000, imageHeight: 3000)
        #expect(viewport.centre == CGPoint(x: 2000, y: 1500))
        // 10 points right on a Retina screen at 100% moves 20 image pixels.
        viewport.pan(by: CGSize(width: 10, height: -5), backingScale: 2)
        #expect(viewport.centre == CGPoint(x: 1980, y: 1510))
        viewport.zoom = 4
        viewport.pan(by: CGSize(width: 8, height: 0), backingScale: 2)
        #expect(viewport.centre.x == 1976)
        viewport.pan(by: CGSize(width: -100_000, height: 100_000), backingScale: 2)
        #expect(viewport.centre == CGPoint(x: 4000, y: 0))
    }

    @Test func cropFramesArePixelExact() {
        let viewport = CompareViewport(imageWidth: 4000, imageHeight: 3000)
        let viewSize = CGSize(width: 600, height: 400)
        let crop = viewport.crop(viewSize: viewSize, backingScale: 2)
        // 1200 visible pixels plus the margin, on the block grid.
        #expect(crop.width == 1712 && crop.height == 1712)
        #expect(!viewport.needsNewCrop(crop, viewSize: viewSize, backingScale: 2))
        let frame = viewport.frame(of: crop, viewSize: viewSize, backingScale: 2)
        #expect(frame.width == 856)   // one image pixel per display pixel
        #expect((frame.minX * 2).rounded() == frame.minX * 2)
        var zoomed = viewport
        zoomed.zoom = 2
        #expect(zoomed.frame(of: crop, viewSize: viewSize, backingScale: 2).width == 1712)
    }

    @Test func panningPastTheCropNeedsANewOne() {
        var viewport = CompareViewport(imageWidth: 8000, imageHeight: 6000)
        let viewSize = CGSize(width: 600, height: 400)
        let crop = viewport.crop(viewSize: viewSize, backingScale: 2)
        viewport.pan(by: CGSize(width: 100, height: 0), backingScale: 2)
        #expect(!viewport.needsNewCrop(crop, viewSize: viewSize, backingScale: 2))
        viewport.pan(by: CGSize(width: 200, height: 0), backingScale: 2)
        #expect(viewport.needsNewCrop(crop, viewSize: viewSize, backingScale: 2))
        // The side stays within bounds for huge panes.
        let big = viewport.crop(viewSize: CGSize(width: 3000, height: 2000), backingScale: 2)
        #expect(big.width == CGFloat(CompareViewport.maximumCropSide))
    }
}

@MainActor @Suite struct CommentEditorModelTests {
    @Test func byteCounts() {
        #expect(CommentEditorModel.byteCountText(1) == "1 byte")
        #expect(CommentEditorModel.byteCountText(0) == "0 bytes")
        #expect(CommentEditorModel.byteCountText(1204) == "1,204 bytes")
        #expect(CommentEditorModel.byteCountText(70_000) == "70,000 bytes (stored in 2 segments)")
        let model = CommentEditorModel(url: URL(fileURLWithPath: "/tmp/a.jpg"), comment: "Café")
        #expect(model.byteCount == 5)
        #expect(!model.hasChanges)
        model.text += "!"
        #expect(model.hasChanges)
    }

    @Test func savesTheComment() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("a.jpg", width: 32, height: 24)
        let model = CommentEditorModel(url: url, comment: JPEGComment.read(from: url) ?? "")
        model.text = "Pinnacles, dusk\nsecond line"
        try await model.save()
        #expect(JPEGComment.read(from: url) == "Pinnacles, dusk\nsecond line")
        #expect(!model.isSaving)
    }
}

@MainActor @Suite struct SaveAsModelTests {
    func withStore(_ body: (SaveOptionsStore) async throws -> Void) async rethrows {
        let scratchDefaults = ScratchDefaults("minivu-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        try await body(SaveOptionsStore(defaults: defaults))
    }

    func entry(_ url: URL) -> FolderEntry {
        FolderEntry(url: url, name: url.lastPathComponent, isDirectory: false, kind: ImageFormats.kind(of: url),
                    fileSize: 0, modified: .distantPast, created: .distantPast)
    }

    @Test func switchingFormatsKeepsWhatWasChosen() async {
        await withStore { store in
            store.remember(ExportOptions(format: .png, sixteenBit: true))
            let model = SaveAsModel(entry: entry(URL(fileURLWithPath: "/tmp/none.jpg")), document: nil, store: store)
            defer { model.cancel() }
            var formats: [ExportFormat] = []
            model.onFormatChange = { formats.append($0) }
            #expect(model.format == .jpeg)
            model.qualityPercent = 72.4
            #expect(model.options.quality == 0.72)
            #expect(model.formatDescription == "JPEG quality 72")

            model.format = .png
            #expect(model.options.sixteenBit)   // remembered for PNG
            #expect(model.formatDescription == "PNG")
            model.format = .jpeg
            #expect(model.options.quality == 0.72)   // this dialog's choice
            #expect(formats == [.png, .jpeg])

            model.qualityPercent = 0
            #expect(model.qualityPercent == 1)
        }
    }

    @Test func deepSourcesStartAt16Bits() async {
        await withStore { store in
            let model = SaveAsModel(entry: entry(URL(fileURLWithPath: "/tmp/none.tif")), document: nil, store: store)
            defer { model.cancel() }
            #expect(!model.options.sixteenBit)
            model.sourceInfoArrived(hasAlpha: true, bitDepth: 16)
            #expect(model.options.sixteenBit && model.sourceHasAlpha)
            model.format = .heic
            #expect(!model.options.sixteenBit)
            model.format = .png
            #expect(model.options.sixteenBit)

            // Options the user has saved with before win.
            store.remember(ExportOptions(format: .tiff, sixteenBit: false))
            let second = SaveAsModel(entry: entry(URL(fileURLWithPath: "/tmp/none.tif")), document: nil, store: store)
            defer { second.cancel() }
            second.sourceInfoArrived(hasAlpha: false, bitDepth: 16)
            #expect(!second.options.sixteenBit)
        }
    }

    /// The whole estimate path on a real file: decode, debounce, full
    /// encode, and the same number the encoder gives.
    @Test func estimatesTheExactFileSize() async throws {
        try await withStore { store in
            let t = try ScratchFolder()
            let url = try t.jpeg("photo.jpg", width: 640, height: 480)
            let model = SaveAsModel(entry: entry(url), document: nil, store: store)
            defer { model.cancel() }
            model.format = .png
            model.refreshEstimate()
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if case .exact = model.estimate { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .exact(let bytes) = model.estimate else {
                Issue.record("no estimate: \(model.estimate)")
                return
            }
            let image = try await model.source.image(for: model.options)
            #expect(image.width == 640 && image.height == 480)
            let expected = try ImageEncoder.encode(image, options: model.options, metadataSource: url).count
            #expect(bytes == Int64(expected))
            #expect(model.sizeText == SaveSizeText.file(bytes))
            #expect(!model.isEstimating)

            // A change keeps the old figure on screen but marks it as being
            // worked out, until the figure for the new options is in.
            model.options.keepMetadata.toggle()
            #expect(model.isEstimating)
            #expect(model.sizeText == SaveSizeText.file(bytes))
            let second = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < second, model.isEstimating {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!model.isEstimating)
            guard case .exact(let updated) = model.estimate else {
                Issue.record("no second estimate: \(model.estimate)")
                return
            }
            let reencoded = try ImageEncoder.encode(image, options: model.options, metadataSource: url).count
            #expect(updated == Int64(reencoded))
        }
    }

    /// Converting from the viewer converts the page on screen.
    @Test func convertsThePageOnScreen() async throws {
        let t = try ScratchFolder()
        let url = t.url.appendingPathComponent("pages.tif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 2, nil))
        for (width, height) in [(40, 30), (20, 10)] {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        let entry = try #require(FolderEntry(url: url))
        let second = SaveImageSource(entry: entry, document: EditDocument(entry: entry, page: 1))
        let image = try await second.image(for: .defaults(for: .png))
        #expect(image.width == 20 && image.height == 10)
        let first = try await SaveImageSource(entry: entry, document: nil).image(for: .defaults(for: .png))
        #expect(first.width == 40)
    }
}

/// Writes to image files run one at a time, in the order asked for.
@MainActor @Suite struct FileWriteQueueTests {
    actor Log {
        var items: [Int] = []
        func append(_ item: Int) { items.append(item) }
    }

    @Test func writesRunInOrderAndOnlyTheNewestSaveCounts() async throws {
        let queue = FileWriteQueue()
        let log = Log()
        let photo = URL(fileURLWithPath: "/tmp/minivu-queue/a.jpg")
        // The first save is slow; the comment and the second save asked for
        // after it must still wait for it.
        let first = queue.enqueue(replacing: [photo]) {
            try await Task.sleep(for: .milliseconds(80))
            await log.append(1)
            return 1
        }
        let comment = queue.enqueue { await log.append(2); return 2 }
        let second = queue.enqueue(replacing: [URL(fileURLWithPath: "/tmp/minivu-queue/../minivu-queue/a.jpg")]) {
            await log.append(3)
            return 3
        }
        #expect(queue.pendingCount == 3)
        let a = try await first.value, b = try await comment.value, c = try await second.value
        #expect(await log.items == [1, 2, 3])
        #expect((a.value, b.value, c.value) == (1, 2, 3))
        // The first save was overwritten by the second: it mustn't mark its
        // document saved. The comment doesn't supersede anything.
        #expect(!a.isNewest && b.isNewest && c.isNewest)

        // A failed write doesn't hold up the ones behind it.
        let failing = queue.enqueue(replacing: [photo]) { () async throws -> Int in throw CocoaError(.fileWriteOutOfSpace) }
        let after = queue.enqueue { 4 }
        await #expect(throws: CocoaError.self) { try await failing.value }
        #expect(try await after.value.value == 4)
        await queue.waitUntilIdle()
        #expect(queue.pendingCount == 0)

        // Once the newest has finished, the next save of the file is the newest again.
        #expect(try await queue.enqueue(replacing: [photo]) { 5 }.value.isNewest)
    }
}

/// The writes behind Save As and Save, without their panels.
@MainActor @Suite struct SaveWriteTests {
    func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func size(_ url: URL) throws -> (Int, Int) {
        let p = try properties(url)
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    @Test func saveAsConvertsTheOriginal() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("photo.jpg", width: 64, height: 48)
        let entry = try #require(FolderEntry(url: url))
        let source = SaveImageSource(entry: entry, document: nil)
        let output = t.url.appendingPathComponent("photo.png")
        try await SavePresenter.write(source, options: .defaults(for: .png), to: output, metadataSource: url)
        #expect(try size(output) == (64, 48))
        let type = CGImageSourceCreateWithURL(output as CFURL, nil).flatMap(CGImageSourceGetType) as String?
        #expect(type == "public.png")
    }

    @Test func anEditIsRenderedForTheChosenSpaceAndDepth() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("photo.jpg", width: 64, height: 48)
        let entry = try #require(FolderEntry(url: url))
        let document = EditDocument(entry: entry)
        document.apply(.resize(width: 32, height: 24, filter: .lanczos3))
        let source = SaveImageSource(entry: entry, document: document)

        let deep = try await source.image(for: ExportOptions(format: .png, sixteenBit: true))
        #expect(deep.width == 32 && deep.height == 24 && deep.bitsPerComponent == 16)
        // An edited sRGB photo keeps its colours in Display P3.
        #expect(deep.colorSpace?.name == CGColorSpace.displayP3)
        let bmp = try await source.image(for: ExportOptions(format: .bmp, colorProfile: .displayP3))
        #expect(bmp.bitsPerComponent == 8 && bmp.colorSpace?.name == CGColorSpace.sRGB)
        #expect(source.cachedImage(for: ExportOptions(format: .gif)) === bmp)
    }

    /// An HDR test photo: a ramp from black on the left to 4x SDR white on
    /// the right, with its content headroom, written by ImageIO as an SDR
    /// base and an ISO gain map.
    func gainMapPhoto(_ url: URL, type: UTType) throws {
        let width = 96, height = 32
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue))
        for x in 0..<width {
            let v = CGFloat(x) / CGFloat(width - 1) * 4
            context.setFillColor(CGColor(colorSpace: space, components: [v, v, v, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let ramp = try #require(context.makeImage())
        let image = try #require(CGImageCreateCopyWithContentHeadroom(4, ramp))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }

    /// Red channel at `fx` across the middle row, decoded for HDR.
    func hdrValue(_ url: URL, at fx: Double) throws -> (value: Float, headroom: Float) {
        let decoded = try ImageDecoder.decode(url, maxPixelSize: nil, page: 0, allowHDR: true)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        var pixel = [Float](repeating: 0, count: 4)
        let image = CIImage(cgImage: decoded.image)
        let x = (Double(decoded.image.width) - 1) * fx
        CIContext().render(image, toBitmap: &pixel, rowBytes: 16,
                           bounds: CGRect(x: x.rounded(), y: Double(decoded.image.height / 2), width: 1, height: 1),
                           format: .RGBAf, colorSpace: space)
        return (pixel[0], decoded.isHDR ? decoded.contentHeadroom : 1)
    }

    /// The same ramp as an HEIC with Apple's own gain map, as an iPhone
    /// stores HDR (Core Image writes that kind).
    func appleGainMapHEIC(_ url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let ramp = CIImage(color: CIColor(red: 0, green: 0, blue: 0, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 32))
            .applyingFilter("CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 96, y: 0),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, colorSpace: space)!,
                "inputColor1": CIColor(red: 4, green: 4, blue: 4, colorSpace: space)!,
            ]).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 32))
        let sdr = ramp.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4, "inputTargetHeadroom": 1])
        let data = try #require(CIContext().heifRepresentation(of: sdr, format: .RGBA8,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                               options: [.hdrImage: ramp]))
        try data.write(to: url)
    }

    /// Save of an edited gain-map JPEG or HEIC keeps it HDR: a new gain map
    /// that brings the edited highlights back.
    @Test(arguments: ["iso.jpg", "iso.heic", "apple.heic"])
    func savingAGainMapPhotoKeepsItHDR(name: String) async throws {
        let t = try ScratchFolder()
        let url = t.url.appendingPathComponent(name)
        switch name {
        case "iso.jpg": try gainMapPhoto(url, type: .jpeg)
        case "iso.heic": try gainMapPhoto(url, type: .heic)
        default: try appleGainMapHEIC(url)
        }
        #expect(SavePolicy.hasGainMap(url))
        #expect(try hdrValue(url, at: 0.95).value > 2)
        let format = try #require(SavePolicy.inPlaceFormat(for: url, info: ImageDecoder.info(for: url)))

        let document = EditDocument(entry: try #require(FolderEntry(url: url)))
        document.apply(.flip(horizontal: true))
        let options = SavePolicy.inPlaceOptions(remembered: .defaults(for: format), sourceBitDepth: 8)
        try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             options: options, to: url, renderer: .shared, gainMap: true)

        #expect(SavePolicy.hasGainMap(url))
        #expect(try size(url) == (96, 32))
        let bright = try hdrValue(url, at: 0.05), dark = try hdrValue(url, at: 0.95)
        #expect(bright.headroom > 2, "headroom \(bright.headroom)")
        #expect(bright.value > 2, "the flipped highlights, above SDR white: \(bright.value)")
        #expect(dark.value < 0.5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == [url.lastPathComponent])
    }

    @Test func saveWritesTheEditOverTheOriginal() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("photo.jpg", width: 64, height: 48)
        try JPEGComment.write("kept", to: url)
        let entry = try #require(FolderEntry(url: url))
        let document = EditDocument(entry: entry)
        document.apply(.resize(width: 32, height: 24, filter: .lanczos3))
        let options = SavePolicy.inPlaceOptions(remembered: .defaults(for: .jpeg), sourceBitDepth: 8)
        try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             options: options, to: url, renderer: .shared)
        #expect(try size(url) == (32, 24))
        #expect(JPEGComment.read(from: url) == "kept")
        // No stray temporary file left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(names == ["photo.jpg"])
    }

    /// Another application saving the file after editing began (not through
    /// External Editor, so no watcher saw it) must not lose its version to
    /// Save, even with "Don't ask again" ticked.
    @Test func saveNeverReplacesAVersionSavedElsewhere() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("photo.jpg", width: 64, height: 48)
        let document = EditDocument(entry: try #require(FolderEntry(url: url)))
        try await EditRenderer.shared.prepare(document)
        defer { EditRenderer.shared.release(document) }
        document.apply(.flip(horizontal: true))
        try await Task.sleep(for: .milliseconds(20))
        try t.jpeg("photo.jpg", width: 40, height: 40)
        let theirs = try Data(contentsOf: url)
        let options = SavePolicy.inPlaceOptions(remembered: .defaults(for: .jpeg), sourceBitDepth: 8)
        await #expect(throws: InPlaceSaveError.fileChanged("photo.jpg")) {
            try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 options: options, to: url, renderer: .shared)
        }
        #expect(try Data(contentsOf: url) == theirs)
        #expect(!document.snapshot().fileIsUnchangedSinceEditing())
    }

    /// minivu's own writes of the file are not "another application": a Save
    /// whose document was edited again while it ran, then Save again, and a
    /// comment written in between.
    @Test func saveAgainAfterMinivusOwnWrites() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("photo.jpg", width: 64, height: 48)
        let document = EditDocument(entry: try #require(FolderEntry(url: url)))
        try await EditRenderer.shared.prepare(document)
        defer { EditRenderer.shared.release(document) }
        let options = SavePolicy.inPlaceOptions(remembered: .defaults(for: .jpeg), sourceBitDepth: 8)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        document.apply(.resize(width: 32, height: 24, filter: .lanczos3))
        try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: sRGB, options: options, to: url,
                                             renderer: .shared)
        document.apply(.rotate90(turns: 1))
        #expect(document.snapshot().fileIsUnchangedSinceEditing())
        try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: sRGB, options: options, to: url,
                                             renderer: .shared)
        #expect(try size(url) == (24, 32), "both edits, each applied once, from the pixels first decoded")
        try JPEGComment.write("note", to: url)
        try await SavePresenter.writeInPlace(document.snapshot(), colorSpace: sRGB, options: options, to: url,
                                             renderer: .shared)
        #expect(JPEGComment.read(from: url) == "note")
    }
}
