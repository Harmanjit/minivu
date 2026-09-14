import Testing
import AppKit
import ImageIO
import MinivuCore
@testable import Minivu

/// Thumbnails straight from the files, delivered on the next turn of the
/// main queue, without the app's thumbnail cache.
final class FileThumbnails: MontageThumbnailProviding {
    func thumbnail(for entry: FolderEntry, pixelSize: Int,
                   completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> () -> Void {
        let box = ImageDecoder.thumbnail(for: entry.url, maxPixelSize: pixelSize).map(ImageBox.init)
        DispatchQueue.main.async { completion(box?.image) }
        return {}
    }
}

@MainActor @Suite struct MontageTests {
    func withSettings(_ body: (MontageSettingsStore) async throws -> Void) async rethrows {
        let scratchDefaults = ScratchDefaults("minivu-montage-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        try await body(MontageSettingsStore(defaults: defaults))
    }

    func entries(_ count: Int, in folder: ScratchFolder, width: Int = 60, height: Int = 40) throws -> [FolderEntry] {
        try (0..<count).map { index in
            try #require(FolderEntry(url: try folder.jpeg("photo \(index).jpg", width: width, height: height)))
        }
    }

    let display = MontageModel.Display(id: 0, displayID: 1, name: "Test Display",
                                       points: CGSize(width: 400, height: 250), scale: 2)

    @Test func settingsAreRemembered() async {
        await withSettings { settings in
            #expect(settings.style == .grid && settings.spacing == 8)
            settings.style = .scattered
            settings.spacing = 20
            settings.background = ExportColor(red: 1, green: 0, blue: 0)
            #expect(settings.style == .scattered && settings.spacing == 20)
            #expect(settings.background == ExportColor(red: 1, green: 0, blue: 0))
        }
    }

    @Test func usesAtMost200ImagesAndSaysSo() async throws {
        await withSettings { settings in
            let many = (0..<340).map { index in
                FolderEntry(url: URL(fileURLWithPath: "/tmp/m/\(index).jpg"), name: "\(index).jpg", isDirectory: false,
                            kind: .raster, fileSize: 1, modified: .distantPast, created: .distantPast)
            }
            let selected = MontageModel(images: many, fromSelection: true, displays: [display], preferredDisplay: 0,
                                        settings: settings, thumbnails: FileThumbnails())
            #expect(selected.entries.count == MontageLayout.maximumImages)
            #expect(selected.limitNote == "A montage uses at most 200 photos: the first 200 of the 340 selected.")
            let shown = MontageModel(images: Array(many.prefix(5)), fromSelection: false, displays: [display],
                                     preferredDisplay: 0, settings: settings, thumbnails: FileThumbnails())
            #expect(shown.limitNote == nil)
        }
    }

    @Test func displayChoices() async {
        await withSettings { settings in
            let second = MontageModel.Display(id: 1, displayID: 2, name: "Side", points: CGSize(width: 1920, height: 1080),
                                              scale: 1)
            let model = MontageModel(images: [], fromSelection: false, displays: [display, second], preferredDisplay: 1,
                                     settings: settings, thumbnails: FileThumbnails())
            #expect(model.targets == [second])
            #expect(second.title == "Side (1920 × 1080)")
            model.displayChoice = MontageModel.allDisplays
            #expect(model.targets == [display, second])
            #expect(model.previewDisplay == display)
            // Spacing is in points: twice the pixels on a Retina display.
            #expect(display.pixelSize == CGSize(width: 800, height: 500))
        }
    }

    @Test func rendersAtTheCanvasSize() async throws {
        let folder = try ScratchFolder()
        let files = try entries(5, in: folder).map(\.url)
        let canvas = CGSize(width: 320, height: 200)
        for style in MontageStyle.allCases {
            let aspects = Array(repeating: 1.5, count: files.count)
            let tiles = MontageLayout.layout(style, aspectRatios: aspects, canvas: canvas, spacing: 4, seed: 3)
            let box = try await MontageRenderer.render(tiles: tiles, canvas: canvas,
                                                       look: .init(style: style, background: .black),
                                                       files: files, aspectRatios: aspects, concurrency: 2)
            #expect(box.image.width == 320 && box.image.height == 200)
            #expect(box.image.colorSpace?.name == CGColorSpace.displayP3)
        }
    }

    @Test func renderingDecodesEachPhotoAtItsNeededSize() async throws {
        let files = (0..<3).map { URL(fileURLWithPath: "/tmp/montage/\($0).jpg") }
        let tiles = [MontageTile(image: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                     MontageTile(image: 1, frame: CGRect(x: 100, y: 0, width: 50, height: 100)),
                     MontageTile(image: 0, frame: CGRect(x: 150, y: 0, width: 50, height: 50))]
        let requests = LockedRequests()
        let box = try await MontageRenderer.render(tiles: tiles, canvas: CGSize(width: 200, height: 100),
                                                   look: .init(style: .grid, background: .white), files: files,
                                                   aspectRatios: [1.5, 1.5, 1.5], concurrency: 1) { url, size in
            requests.append(url.lastPathComponent, size)
            return nil
        }
        #expect(box.image.width == 200)
        // Photo 0 is decoded once, at the size its largest tile needs; photo 2 is never used.
        #expect(requests.sorted == ["0.jpg@150", "1.jpg@150"])
    }

    @Test func renderingStopsWhenCancelled() async throws {
        let files = [URL(fileURLWithPath: "/tmp/montage/0.jpg")]
        let tiles = (0..<20).map { MontageTile(image: 0, frame: CGRect(x: $0 * 10, y: 0, width: 10, height: 10)) }
        let task = Task {
            try await MontageRenderer.render(tiles: tiles, canvas: CGSize(width: 200, height: 10),
                                             look: .init(style: .grid, background: .white), files: files,
                                             aspectRatios: [1], concurrency: 1) { _, _ in nil }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// The whole Set as Wallpaper path short of the desktop: thumbnails give
    /// the shapes, each display gets a JPEG at its pixel size, named by time.
    @Test func makesAJPEGPerDisplay() async throws {
        try await withSettings { settings in
            let folder = try ScratchFolder()
            let photos = try entries(4, in: folder, width: 90, height: 60)
            let side = MontageModel.Display(id: 1, displayID: 2, name: "Side", points: CGSize(width: 300, height: 200),
                                            scale: 1)
            let model = MontageModel(images: photos, fromSelection: true, displays: [display, side],
                                     preferredDisplay: 0, settings: settings, thumbnails: FileThumbnails(), seed: 5)
            model.start()
            defer { model.stop() }
            model.displayChoice = MontageModel.allDisplays
            model.style = .mosaic
            let output = folder.url.appendingPathComponent("minivu Wallpapers")
            let date = Date(timeIntervalSince1970: 1_789_381_805)
            let written = try await model.makeMontages(in: output, date: date)
            #expect(written.count == 2)
            #expect(model.loadedCount == 4)
            #expect(model.aspectRatios.allSatisfy { abs($0 - 1.5) < 0.01 })
            let stamp = MontageOutput.timestamp(date)
            #expect(written.map(\.url.lastPathComponent) == ["Montage \(stamp) (1).jpg", "Montage \(stamp) (2).jpg"])
            for (url, target) in written {
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                #expect(properties[kCGImagePropertyPixelWidth] as? Int == Int(target.pixelSize.width))
                #expect(properties[kCGImagePropertyPixelHeight] as? Int == Int(target.pixelSize.height))
            }
            #expect(model.phase == .editing)
            // A second montage in the same second doesn't replace the first.
            model.displayChoice = 0
            let again = try await model.makeMontages(in: output, date: date)
            #expect(again.map(\.url.lastPathComponent) == ["Montage \(stamp).jpg"])
            let third = try await model.makeMontages(in: output, date: date)
            #expect(third.map(\.url.lastPathComponent) == ["Montage \(stamp) 2.jpg"])
        }
    }

    /// Cancel pressed while the montage waits in the write queue: the write
    /// can't be stopped, so the file it made is removed again and nothing
    /// is left in minivu Wallpapers.
    @Test func cancellingDuringTheWriteLeavesNoFile() async throws {
        try await withSettings { settings in
            let folder = try ScratchFolder()
            let photos = try entries(3, in: folder, width: 90, height: 60)
            let model = MontageModel(images: photos, fromSelection: true, displays: [display], preferredDisplay: 0,
                                     settings: settings, thumbnails: FileThumbnails(), seed: 9)
            model.start()
            defer { model.stop() }
            let output = folder.url.appendingPathComponent("minivu Wallpapers")

            // Holds the write queue until the montage's write is waiting in it.
            let gate = Gate()
            let queue = FileWriteQueue.shared
            queue.enqueue { await gate.wait() }
            let task = Task { try await model.makeMontages(in: output, date: Date(timeIntervalSince1970: 1_789_381_805)) }
            let deadline = Date().addingTimeInterval(30)   // as generous, for the same reason
            while model.writesQueued == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.writesQueued == 1, "the montage is queued behind the gate")
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            await queue.waitUntilIdle()
            let left = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
            #expect(left.isEmpty, "\(left)")
            #expect(model.phase == .editing)
        }
    }

    @Test func previewIsSmallAndFollowsTheDisplayShape() async throws {
        try await withSettings { settings in
            let folder = try ScratchFolder()
            let model = MontageModel(images: try entries(3, in: folder), fromSelection: false, displays: [display],
                                     preferredDisplay: 0, settings: settings, thumbnails: FileThumbnails())
            model.start()
            defer { model.stop() }
            await model.waitForThumbnails()
            // Generous: under the full test run the main actor is shared by
            // every window test, and this only waits as long as it must.
            let deadline = Date().addingTimeInterval(30)
            while model.preview == nil || model.previewWork == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            await model.previewWork?.value
            let preview = try #require(model.preview)
            #expect(CGFloat(preview.width) == MontageModel.previewLongEdge)
            #expect(preview.height == 650)
        }
    }
}

final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ name: String, _ size: Int) { lock.withLock { values.append("\(name)@\(size)") } }
    var sorted: [String] { lock.withLock { values.sorted() } }
}

/// A one-shot latch: `wait()` suspends until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
