import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuRender
@testable import MinivuCore

/// Batch Convert's engine: settings, sizes, output names and clashes, and
/// real conversions through the export path.
@Suite struct BatchConvertEngineTests {
    // MARK: - Settings and sizes

    @Test func settingsDecodeWithDefaultsForMissingKeys() throws {
        let old = Data(#"{"options":{"format":"png"},"quarterTurns":1}"#.utf8)
        let settings = try JSONDecoder().decode(BatchConvertSettings.self, from: old)
        #expect(settings.options == ExportOptions.defaults(for: .png))
        #expect(settings.quarterTurns == 1)
        #expect(settings.destination == .besideOriginals && settings.naming == .keep)
        #expect(settings.existingFiles == .keepBoth && settings.resize == BatchResize())

        let full = BatchConvertSettings(options: .defaults(for: .heic), destination: .chosenFolder(bookmark: Data([1, 2])),
                                        naming: .pattern(RenamePattern(text: "x {#}")), existingFiles: .replace,
                                        resize: BatchResize(mode: .width, pixels: 800, filter: .mitchell),
                                        quarterTurns: 3, flipHorizontal: true)
        #expect(try JSONDecoder().decode(BatchConvertSettings.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func resizeSizesKeepProportions() {
        let size = CGSize(width: 6000, height: 4000)
        #expect(BatchResize(mode: .none).targetSize(for: size) == nil)
        #expect(BatchResize(mode: .longSide, pixels: 1500).targetSize(for: size)! == (1500, 1000))
        #expect(BatchResize(mode: .longSide, pixels: 1500).targetSize(for: CGSize(width: 3000, height: 4500))! == (1000, 1500))
        #expect(BatchResize(mode: .width, pixels: 900).targetSize(for: size)! == (900, 600))
        #expect(BatchResize(mode: .height, pixels: 500).targetSize(for: size)! == (750, 500))
        #expect(BatchResize(mode: .percent, percent: 25).targetSize(for: size)! == (1500, 1000))
        // Don't enlarge: smaller pictures stay as they are, unless allowed.
        #expect(BatchResize(mode: .longSide, pixels: 8000).targetSize(for: size) == nil)
        #expect(BatchResize(mode: .longSide, pixels: 9000, doesNotEnlarge: false).targetSize(for: size)! == (9000, 6000))
        #expect(BatchResize(mode: .percent, percent: 0).targetSize(for: size) == nil)
    }

    @Test func operationsTurnThenFlipThenResize() {
        let settings = BatchConvertSettings(resize: BatchResize(mode: .width, pixels: 300, filter: .catmullRom),
                                            quarterTurns: 1, flipVertical: true)
        #expect(settings.operations(sourceSize: CGSize(width: 600, height: 400)) == [
            .rotate90(turns: 1), .flip(horizontal: false), .resize(width: 300, height: 450, filter: .catmullRom),
        ], "the width is the turned picture's")
        #expect(BatchConvertSettings().operations(sourceSize: CGSize(width: 10, height: 10)).isEmpty)
    }

    // MARK: - Planning outputs

    final class FakeDisk: @unchecked Sendable {
        var items: [String: BatchItemIdentity] = [:]
        private var next: UInt64 = 1

        func add(_ path: String, directory: Bool = false) {
            items[path.lowercased()] = BatchItemIdentity(device: 1, inode: next, isDirectory: directory)
            next += 1
        }

        var probe: BatchFileProbe {
            BatchFileProbe(identity: { [self] url in items[url.path.lowercased()] }, isCaseSensitive: { _ in false })
        }
    }

    func sources(_ names: [String], in folder: String = "/p") -> [RenameSource] {
        names.map { RenameSource(url: URL(fileURLWithPath: "\(folder)/\($0)")) }
    }

    @Test func planningSettlesEveryClashUpFront() {
        let disk = FakeDisk()
        for name in ["a.png", "a.tif", "b.jpg", "c.heic", "c.jpg", "d.png"] { disk.add("/p/\(name)") }
        disk.add("/p/e.jpg", directory: true)
        disk.add("/p/e.png")

        var settings = BatchConvertSettings(options: .defaults(for: .jpeg), existingFiles: .keepBoth)
        var outputs = BatchOutputPlanner.plan(sources(["a.png", "a.tif", "b.jpg", "c.heic", "d.png"]), settings: settings,
                                              folder: nil, probe: disk.probe)
        #expect(outputs.map(\.destination.lastPathComponent) == ["a.jpg", "a 2.jpg", "b 2.jpg", "c 2.jpg", "d.jpg"])
        #expect(outputs.allSatisfy { $0.action == .write })

        // Replace: the second output of a name is still numbered; an existing
        // unrelated file is replaced; the output's own source is marked.
        settings.existingFiles = .replace
        outputs = BatchOutputPlanner.plan(sources(["a.png", "a.tif", "b.jpg", "c.heic"]), settings: settings,
                                          folder: nil, probe: disk.probe)
        #expect(outputs.map(\.destination.lastPathComponent) == ["a.jpg", "a 2.jpg", "b.jpg", "c.jpg"])
        #expect(outputs.map(\.action) == [.write, .write, .replace(original: true), .replace(original: false)])

        // An output never lands on another source of the batch, even with Replace.
        outputs = BatchOutputPlanner.plan(sources(["c.heic", "c.jpg"]), settings: settings, folder: nil, probe: disk.probe)
        #expect(outputs.map(\.destination.lastPathComponent) == ["c 2.jpg", "c.jpg"])
        #expect(outputs.map(\.action) == [.write, .replace(original: true)])

        // Skip, and a folder in the way.
        settings.existingFiles = .skip
        outputs = BatchOutputPlanner.plan(sources(["b.jpg", "c.heic", "e.png"]), settings: settings, folder: nil,
                                          probe: disk.probe)
        #expect(outputs.map(\.action) == [.skip(reason: "It would replace the original."),
                                          .skip(reason: "An item named “c.jpg” already exists."),
                                          .skip(reason: "An item named “e.jpg” already exists.")])
        settings.existingFiles = .replace
        outputs = BatchOutputPlanner.plan(sources(["e.png"]), settings: settings, folder: nil, probe: disk.probe)
        #expect(outputs.map(\.action) == [.fail(reason: "A folder named “e.jpg” is in the way.")])

        // Into a chosen folder, named by a pattern with its extension case.
        settings.naming = .pattern(RenamePattern(text: "Trip {##}", extensionCase: .upper))
        outputs = BatchOutputPlanner.plan(sources(["a.png", "b.jpg"]), settings: settings,
                                          folder: URL(fileURLWithPath: "/out"), probe: disk.probe)
        #expect(outputs.map(\.destination.path) == ["/out/Trip 01.JPG", "/out/Trip 02.JPG"])
        settings.naming = .pattern(RenamePattern(text: "a/b"))
        outputs = BatchOutputPlanner.plan(sources(["a.png"]), settings: settings, folder: nil, probe: disk.probe)
        #expect(outputs.map(\.action) == [.fail(reason: "The name can’t contain “/” or “:”.")])
    }

    // MARK: - Converting

    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor func converter() -> BatchConverter {
        BatchConverter(renderer: EditRenderer.shared, displaySettings: DisplaySettings()) { [srgb] _, _, _ in srgb }
    }

    func folder() throws -> URL {
        let url = Fixtures.directory.appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    func colour(_ p: [Int]) -> String {
        switch (p[0] > 180, p[1] > 180, p[2] > 180) {
        case (true, false, false): "red"
        case (false, true, false): "green"
        case (false, false, true): "blue"
        case (true, true, true): "white"
        default: "\(p)"
        }
    }

    func decode(_ data: Data) throws -> (CGImage, [CFString: Any], String?) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties, CGImageSourceGetType(source) as String?)
    }

    /// EXIF orientation 6, then a turn and a resize, as PNG: the output is
    /// upright in its new size, tagged orientation 1, quadrants where the
    /// operations put them.
    @Test func convertsWithOrientationTurnAndResize() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("turned.jpg")
        // Stored 80 × 40 with orientation 6: shown 40 wide and 80 tall, the
        // stored top-left red at the top right.
        try BatchFixtures.writeJPEG(to: url, width: 80, height: 40, orientation: .right, dateTaken: "2022:01:02 03:04:05")
        var settings = BatchConvertSettings(options: .defaults(for: .png),
                                            resize: BatchResize(mode: .longSide, pixels: 40, filter: .lanczos3),
                                            quarterTurns: 1)
        settings.options.keepMetadata = true
        let converter = await converter()
        let data = try await converter.encodedData(for: url, settings: settings)
        let (image, properties, type) = try decode(data)
        #expect(type == UTType.png.identifier)
        // Shown 40 × 80, turned right: 80 × 40, long side 40: 40 × 20.
        #expect(image.width == 40 && image.height == 20)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        // Upright red at the top right; a further turn right brings it to the bottom right.
        #expect(colour(rgb(image, 34, 17)) == "red")
        #expect(colour(rgb(image, 5, 2)) == "white")
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2022:01:02 03:04:05", "metadata kept")

        // Stripped: no EXIF date, still upright.
        settings.options.keepMetadata = false
        settings.quarterTurns = 0
        settings.resize = BatchResize()
        settings.options.format = .jpeg
        let stripped = try await converter.encodedData(for: url, settings: settings)
        let (plain, plainProperties, plainType) = try decode(stripped)
        #expect(plainType == UTType.jpeg.identifier)
        #expect(plain.width == 40 && plain.height == 80, "the format-only path bakes the orientation in")
        #expect((plainProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect((plainProperties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(colour(rgb(plain, 35, 5)) == "red")
    }

    @Test func aFileThatIsNotAnImageFails() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("broken.jpg")
        try Data("not a picture".utf8).write(to: url)
        let converter = await converter()
        await #expect(throws: (any Error).self) {
            _ = try await converter.encodedData(for: url, settings: BatchConvertSettings())
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Users/harman/latent/TestAssets/HSB_6548.NEF")))
    func convertsACameraRaw() async throws {
        let raw = URL(fileURLWithPath: "/Users/harman/latent/TestAssets/HSB_6548.NEF")
        let settings = BatchConvertSettings(options: .defaults(for: .jpeg),
                                            resize: BatchResize(mode: .longSide, pixels: 1200))
        let converter = await BatchConverter(renderer: EditRenderer.shared,
                                             displaySettings: DisplaySettings(rawDecoding: .fullRaw)) { _, _, _ in
            CGColorSpace(name: CGColorSpace.displayP3)!
        }
        let data = try await converter.encodedData(for: raw, settings: settings)
        let (image, properties, _) = try decode(data)
        #expect(max(image.width, image.height) == 1200)
        #expect(properties[kCGImagePropertyExifDictionary] != nil, "the camera's EXIF is carried over")
    }

    /// Work run with the batch executor as its preference, the renderer's
    /// async export included, is on GCD's threads, not Swift's cooperative pool.
    @Test func batchWorkRunsOnDispatchThreads() async {
        let label = await withTaskExecutorPreference(BatchWorkExecutor.shared) {
            await Self.queueLabel()
        }
        #expect(!label.contains("cooperative"), "ran on \(label)")
        #expect(label.contains("user-initiated"))
    }

    /// From the main actor too: the conversion itself leaves it.
    @MainActor @Test func batchWorkLeavesTheMainActor() async {
        let label = await withTaskExecutorPreference(BatchWorkExecutor.shared) {
            await Self.queueLabel()
        }
        #expect(label.contains("user-initiated") && !label.contains("cooperative") && !label.contains("main"),
                "ran on \(label)")
    }

    nonisolated static func queueLabel() async -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }
}

enum BatchFixtures {
    /// A JPEG with red top-left, green top-right, blue bottom-left and white
    /// bottom-right quadrants as stored, an EXIF orientation and optionally
    /// a date taken.
    static func writeJPEG(to url: URL, width: Int, height: Int, orientation: CGImagePropertyOrientation = .up,
                          dateTaken: String? = nil) throws {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h, width: w, height: h))
        fill(0, 1, 0, CGRect(x: w, y: h, width: w, height: h))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w, height: h))
        fill(1, 1, 1, CGRect(x: w, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue,
                                           kCGImageDestinationLossyCompressionQuality: 1.0]
        if let dateTaken {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTaken]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }
}
