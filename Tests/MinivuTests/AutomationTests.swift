import Testing
import AppKit
import AppIntents
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// The Shortcuts actions (G12): the engine in `Automation` on real files,
    /// the shortcut's files as `AutomationInput` takes them, and each intent
    /// run the way Shortcuts runs it (`perform()`). Converted files go to a
    /// scratch folder, never the app's own, and ratings to a catalog in memory.
    @MainActor @Suite(.serialized, .batchToolsReset) struct AutomationTests {
        let catalog = Catalog.inMemory()
        let output: ScratchFolder

        init() throws {
            output = try ScratchFolder()
            Automation.outputRoot = output.url.appendingPathComponent("Automation", isDirectory: true)
            Automation.catalog = catalog
        }

        func pixelSize(_ url: URL) -> CGSize? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return CGSize(width: image.width, height: image.height)
        }

        func type(_ url: URL) -> String? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
        }

        func properties(_ url: URL) -> [CFString: Any] {
            CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        }

        /// A JPEG that says where it was taken.
        func locatedJPEG(_ t: ScratchFolder, _ name: String) throws -> URL {
            let plain = try t.jpeg("plain-" + name, width: 40, height: 20)
            let url = t.url.appendingPathComponent(name)
            let source = try #require(CGImageSourceCreateWithURL(plain as CFURL, nil))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            let properties: [CFString: Any] = [
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "London", kCGImagePropertyIPTCKeywords: ["bridge"]],
            ]
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            try FileManager.default.removeItem(at: plain)
            return url
        }

        func runFolders() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: Automation.outputRoot, includingPropertiesForKeys: nil)) ?? []
        }

        // MARK: - Convert and resize

        @Test func convertSettingsFollowTheIntentsParameters() {
            var settings = Automation.convertSettings(format: .heic, quality: 70, longSide: nil, removeLocation: true)
            #expect(settings.options.format == .heic && settings.options.quality == 0.7)
            #expect(settings.options.keepMetadata && settings.options.removeLocation)
            #expect(settings.resize.mode == .none)
            settings = Automation.convertSettings(format: .png, quality: 500, longSide: 1600, removeLocation: false)
            #expect(settings.options.quality == 1 && !settings.options.removeLocation)
            #expect(settings.resize.mode == .longSide && settings.resize.pixels == 1600 && settings.resize.doesNotEnlarge)
            #expect(Automation.convertSettings(format: .jpeg, quality: 0, longSide: 99_999, removeLocation: true).resize.pixels
                == BatchResize.maximumSide)
        }

        /// Every format minivu writes is offered, under the same raw value,
        /// so `exportFormat` never falls back to JPEG.
        @Test func everyWritableFormatIsOffered() {
            #expect(AutomationFormat.allCases.map(\.exportFormat.rawValue) == AutomationFormat.allCases.map(\.rawValue))
            #expect(Set(AutomationFormat.allCases.map(\.exportFormat)) == Set(ExportFormat.allCases))
        }

        /// Converted files land in a run folder of minivu's own, in the order
        /// given, named after their originals; two of one name are numbered.
        /// The originals are untouched.
        @Test func convertWritesNewFilesAndLeavesTheOriginals() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 64, height: 48)
            let other = try t.folder("other")
            let b = other.appendingPathComponent("a.jpg")
            try FileManager.default.copyItem(at: a, to: b)
            let before = try Data(contentsOf: a)

            let settings = Automation.convertSettings(format: .png, quality: 90, longSide: 32, removeLocation: true)
            let converted = try await Automation.convert([a, b], settings: settings)
            #expect(converted.map(\.lastPathComponent) == ["a.png", "a 2.png"])
            #expect(converted.allSatisfy { type($0) == UTType.png.identifier })
            #expect(converted.allSatisfy { pixelSize($0) == CGSize(width: 32, height: 24) })
            #expect(Set(converted.map { $0.deletingLastPathComponent().standardizedFileURL })
                == Set(runFolders().map(\.standardizedFileURL)), "one run folder, under the output root")
            #expect(try Data(contentsOf: a) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted() == ["a.jpg", "other"])
        }

        /// A file that won't convert fails the action with its name, and the
        /// files that did convert are not left behind.
        @Test func aFailedFileFailsTheWholeAction() async throws {
            let t = try ScratchFolder()
            let good = try t.jpeg("good.jpg", width: 20, height: 10)
            let broken = try t.file("broken.jpg", bytes: 100)
            let settings = Automation.convertSettings(format: .png, quality: 90, longSide: nil, removeLocation: true)
            await #expect {
                try await Automation.convert([good, broken], settings: settings)
            } throws: { error in
                guard case .conversionFailed(let detail) = error as? Automation.Failure else { return false }
                return detail.contains("broken.jpg") && detail.contains("No files were converted.")
            }
            #expect(runFolders().isEmpty)
        }

        /// Remove location reaches the encoder: off, the GPS position comes along.
        @Test func removeLocationLeavesOutTheGPSPosition() async throws {
            let t = try ScratchFolder()
            let located = try locatedJPEG(t, "located.jpg")
            #expect(properties(located)[kCGImagePropertyGPSDictionary] != nil)
            let removed = try await Automation.convert(
                [located], settings: Automation.convertSettings(format: .jpeg, quality: 80, longSide: nil, removeLocation: true))
            #expect(properties(removed[0])[kCGImagePropertyGPSDictionary] == nil)
            let iptc = properties(removed[0])[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["bridge"] && iptc?[kCGImagePropertyIPTCCity] == nil)
            let kept = try await Automation.convert(
                [located], settings: Automation.convertSettings(format: .jpeg, quality: 80, longSide: nil, removeLocation: false))
            #expect((properties(kept[0])[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 51.5)
        }

        /// Resize keeps each file's own format, in the order given.
        @Test func resizeKeepsEachFilesFormat() async throws {
            let t = try ScratchFolder()
            let jpeg = try t.jpeg("photo.jpg", width: 80, height: 40)
            let png = t.url.appendingPathComponent("chart.png")
            let source = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
            let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            try #require(CGImageDestinationFinalize(destination))

            let resize = ResizeImagesIntent.resize(mode: .width, size: 20, enlarges: false)
            let resized = try await Automation.resize([png, jpeg], resize: resize, removeLocation: true)
            #expect(resized.map(\.lastPathComponent) == ["chart.png", "photo.jpg"])
            #expect(resized.map(type) == [UTType.png.identifier, UTType.jpeg.identifier])
            #expect(resized.allSatisfy { pixelSize($0) == CGSize(width: 20, height: 10) })
            #expect(pixelSize(jpeg) == CGSize(width: 80, height: 40), "the original keeps its size")

            // Percentages, and never enlarging unless asked.
            #expect(ResizeImagesIntent.resize(mode: .percent, size: 50, enlarges: false).targetSize(for: CGSize(width: 80, height: 40))! == (40, 20))
            #expect(ResizeImagesIntent.resize(mode: .longSide, size: 200, enlarges: false).targetSize(for: CGSize(width: 80, height: 40)) == nil)
            #expect(ResizeImagesIntent.resize(mode: .longSide, size: 160, enlarges: true).targetSize(for: CGSize(width: 80, height: 40))! == (160, 80))
        }

        /// Runs a day old are cleared when the next run starts; newer ones stay.
        @Test func oldRunFoldersAreRemoved() throws {
            let old = try Automation.makeRunFolder(in: Automation.outputRoot)
            let recent = try Automation.makeRunFolder(in: Automation.outputRoot)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -2 * Automation.outputLifetime)],
                                                  ofItemAtPath: old.path)
            let new = try Automation.makeRunFolder(in: Automation.outputRoot)
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: recent.path) && FileManager.default.fileExists(atPath: new.path))
        }

        // MARK: - Rename

        /// Renamed in place with the pattern and counter, in order; stars follow.
        @Test func renameUsesThePatternAndStarsFollow() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 30, height: 20)
            let b = try t.jpeg("b.jpg", width: 10, height: 20)
            catalog.setRating(4, for: [b])
            let renamed = try await Automation.rename([b, a], pattern: RenamePattern(text: "trip-{##}-{width}", counterStart: 7))
            #expect(renamed.map(\.lastPathComponent) == ["trip-07-10.jpg", "trip-08-30.jpg"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted() == ["trip-07-10.jpg", "trip-08-30.jpg"])
            #expect(catalog.marks(for: renamed[0]).rating == 4)
            #expect(BatchTools.renamesRunning == 0)
        }

        /// The sheet's checks, before anything moves: an unknown token, or two
        /// files getting one name, and nothing is renamed.
        @Test func aBadPatternRenamesNothing() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 10, height: 10)
            let b = try t.jpeg("b.jpg", width: 10, height: 10)
            await #expect(throws: Automation.Failure.unknownTokens(["{nmae}"])) {
                try await Automation.rename([a, b], pattern: RenamePattern(text: "{nmae}"))
            }
            await #expect {
                try await Automation.rename([a, b], pattern: RenamePattern(text: "same"))
            } throws: { error in
                guard case .renameProblems(let lines) = error as? Automation.Failure else { return false }
                return lines.count == 2
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted() == ["a.jpg", "b.jpg"])
        }

        /// A folder minivu may not change, among others it may: nothing is
        /// renamed anywhere, rather than half the set. (Read-only by its
        /// permissions here; in the sandboxed app, a folder minivu was only
        /// handed single files in answers the same.)
        @Test func aFolderMinivuMayNotChangeRenamesNothing() async throws {
            let t = try ScratchFolder()
            let open = try t.folder("open"), closed = try t.folder("closed")
            let a = open.appendingPathComponent("a.jpg"), b = closed.appendingPathComponent("b.jpg")
            try FileManager.default.moveItem(at: try t.jpeg("a.jpg", width: 10, height: 10), to: a)
            try FileManager.default.moveItem(at: try t.jpeg("b.jpg", width: 10, height: 10), to: b)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: closed.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }

            await #expect(throws: Automation.Failure.foldersNotWritable([closed.standardizedFileURL.path])) {
                try await Automation.rename([a, b], pattern: RenamePattern(text: "trip-{#}"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: open.path) == ["a.jpg"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: closed.path) == ["b.jpg"])
            #expect(Automation.unwritableFolders([a, a, b, b]) == [closed.standardizedFileURL])
        }

        /// A shortcut's rename waits for a rename already under way (a
        /// window's, or another shortcut's), so two never move files at once.
        @Test func aShortcutsRenameWaitsItsTurn() async throws {
            @MainActor final class Gate {
                var waiting: CheckedContinuation<Void, Never>?
            }
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 10, height: 10)
            let gate = Gate()
            let first = Task { await BatchTools.queueRename { await withCheckedContinuation { gate.waiting = $0 } } }
            await TestTiming.waitUntil { gate.waiting != nil }
            let rename = Task { try await Automation.rename([a], pattern: RenamePattern(text: "late")) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(FileManager.default.fileExists(atPath: a.path), "not renamed while another rename runs")
            gate.waiting?.resume()
            await first.value
            #expect(try await rename.value.map(\.lastPathComponent) == ["late.jpg"])
        }

        // MARK: - Rating

        @Test func setRatingWritesTheCatalogBeforeReturning() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 10, height: 10)
            let b = try t.jpeg("b.jpg", width: 10, height: 10)
            await Automation.setRating(3, for: [a, b])
            #expect(catalog.marks(for: a).rating == 3 && catalog.marks(for: b).rating == 3)
            await Automation.setRating(0, for: [a])
            #expect(catalog.marks(for: a) == .none)
        }

        // MARK: - The shortcut's files

        /// A file with no place on disk is copied for Convert under its own
        /// name and removed afterwards; Rename and Set Rating refuse it.
        @Test func filesThatComeAsDataOnly() async throws {
            let t = try ScratchFolder()
            let jpeg = try Data(contentsOf: try t.jpeg("x.jpg", width: 10, height: 10))
            let file = IntentFile(data: jpeg, filename: "From Mail.jpg", type: .jpeg)

            let input = try await AutomationInput.make([file, file], originalsOnly: false)
            #expect(input.urls.map(\.lastPathComponent) == ["From Mail.jpg", "From Mail 2.jpg"])
            #expect(try Data(contentsOf: input.urls[0]) == jpeg)
            input.finish()
            #expect(!FileManager.default.fileExists(atPath: input.urls[0].deletingLastPathComponent().path))

            await #expect(throws: Automation.Failure.notAFileOnDisk("From Mail.jpg")) {
                try await AutomationInput.make([file], originalsOnly: true)
            }
            await #expect(throws: Automation.Failure.noImages) { try await AutomationInput.make([], originalsOnly: false) }
        }

        /// Files from Finder are used where they are, not copied.
        @Test func filesOnDiskAreUsedWhereTheyAre() async throws {
            let t = try ScratchFolder()
            let url = try t.jpeg("x.jpg", width: 10, height: 10)
            let input = try await AutomationInput.make([IntentFile(fileURL: url)], originalsOnly: true)
            #expect(input.urls == [url])
            input.finish()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        /// Internal storage only: a file `VolumePolicy` refuses fails the
        /// whole action before anything reads or rates it. A path with no
        /// volume to ask about stands in for a memory card here; the policy
        /// refuses what it can't place.
        @Test func filesNotOnInternalStorageAreRefused() async throws {
            let t = try ScratchFolder()
            let good = try t.jpeg("good.jpg", width: 10, height: 10)
            let elsewhere = URL(fileURLWithPath: "/Volumes/minivu-no-such-card-\(UUID().uuidString)/DCIM/IMG_0001.JPG")
            #expect(!VolumePolicy.isAllowed(elsewhere))
            await #expect(throws: Automation.Failure.notOnInternalStorage("IMG_0001.JPG")) {
                try await AutomationInput.make([IntentFile(fileURL: good), IntentFile(fileURL: elsewhere)],
                                               originalsOnly: false)
            }

            let rating = SetRatingIntent()
            rating.images = [IntentFile(fileURL: good), IntentFile(fileURL: elsewhere)]
            rating.rating = 4
            await #expect(throws: Automation.Failure.notOnInternalStorage("IMG_0001.JPG")) { try await rating.perform() }
            #expect(catalog.marks(for: good) == .none, "nothing rated, the good file included")

            let convert = ConvertImagesIntent()
            convert.images = [IntentFile(fileURL: elsewhere)]
            convert.format = .png
            convert.quality = 90
            convert.longSide = nil
            convert.removeLocation = true
            await #expect(throws: Automation.Failure.notOnInternalStorage("IMG_0001.JPG")) { try await convert.perform() }
            #expect(runFolders().isEmpty)
        }

        // MARK: - The intents, as Shortcuts runs them

        @Test func convertImagesIntentHandsOnTheConvertedFiles() async throws {
            let t = try ScratchFolder()
            let url = try t.jpeg("a.jpg", width: 40, height: 20)
            let intent = ConvertImagesIntent()
            intent.images = [IntentFile(fileURL: url)]
            intent.format = .heic
            intent.quality = 50
            intent.longSide = 10
            intent.removeLocation = true
            let result = try await intent.perform()
            let files = try #require(result.value)
            #expect(files.map(\.filename) == ["a.heic"])
            let converted = try #require(files.first?.fileURL)
            #expect(type(converted) == UTType.heic.identifier && pixelSize(converted) == CGSize(width: 10, height: 5))
            #expect(files.first?.removedOnCompletion == true, "Shortcuts removes the file once it has taken it")
        }

        @Test func resizeRenameAndRatingIntents() async throws {
            let t = try ScratchFolder()
            let url = try t.jpeg("a.jpg", width: 40, height: 20)

            let resize = ResizeImagesIntent()
            resize.images = [IntentFile(fileURL: url)]
            resize.mode = .height
            resize.size = 10
            resize.enlarges = false
            resize.removeLocation = true
            let resized = try #require(try await resize.perform().value?.first?.fileURL)
            #expect(pixelSize(resized) == CGSize(width: 20, height: 10) && resized.pathExtension == "jpg")

            let rating = SetRatingIntent()
            rating.images = [IntentFile(fileURL: url)]
            rating.rating = 2
            #expect(try await rating.perform().value?.map(\.fileURL) == [url])
            #expect(catalog.marks(for: url).rating == 2)

            let rename = RenameImagesIntent()
            rename.images = [IntentFile(fileURL: url)]
            rename.pattern = "{name}-{#}"
            rename.counterStart = 3
            let renamed = try #require(try await rename.perform().value?.first?.fileURL)
            #expect(renamed.lastPathComponent == "a-3.jpg" && FileManager.default.fileExists(atPath: renamed.path))
            #expect(catalog.marks(for: renamed).rating == 2, "the rating followed the rename")

            // A file with no place on disk can't be rated.
            rating.images = [IntentFile(data: Data(), filename: "x.jpg")]
            await #expect(throws: Automation.Failure.notAFileOnDisk("x.jpg")) { try await rating.perform() }
        }

        /// Open in minivu brings the app forward; the others run in the background.
        @Test func onlyOpenInMinivuOpensTheApp() {
            #expect(OpenInMinivuIntent.openAppWhenRun)
            #expect(!ConvertImagesIntent.openAppWhenRun && !ResizeImagesIntent.openAppWhenRun)
            #expect(!RenameImagesIntent.openAppWhenRun && !SetRatingIntent.openAppWhenRun)
        }
    }
}
