import Testing
import AppKit
import ImageIO
import MinivuCore
@testable import Minivu

/// Records desktop pictures instead of setting them: a test must never
/// change the tester's wallpaper.
final class FakeDesktop: DesktopPictureSetting {
    var set: [(url: URL, screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any])] = []
    var current: [ObjectIdentifier: URL] = [:]

    func setDesktopImageURL(_ url: URL, for screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        set.append((url, screen, options))
        current[ObjectIdentifier(screen)] = url
    }

    func desktopImageURL(for screen: NSScreen) -> URL? { current[ObjectIdentifier(screen)] }
}

@MainActor @Suite struct DesktopPictureTests {
    let pictures = URL(fileURLWithPath: "/Users/someone/Pictures")
    let screenPixels = CGSize(width: 3024, height: 1964)

    func decide(_ path: String, edits: Bool = false, alpha: Bool = false) -> DesktopPicturePolicy.Decision {
        DesktopPicturePolicy.decide(file: URL(fileURLWithPath: path), hasUnsavedEdits: edits, hasAlpha: alpha,
                                    picturesFolder: pictures, screenPixels: screenPixels)
    }

    @Test func formatsTheWallpaperAgentReadsAreUsedAsTheyAre() {
        for name in ["a.jpg", "b.JPEG", "c.png", "d.heic", "e.tif", "f.tiff", "g.heif"] {
            #expect(decide("/Users/someone/Pictures/Trip/\(name)") == .useFile, "\(name)")
        }
        let copy = DesktopPicturePolicy.Decision.exportCopy(format: .jpeg, maxPixelSize: 6048)
        for name in ["a.NEF", "b.webp", "c.avif", "d.pdf", "e.gif", "f.jxl", "g.psd", "h.svg"] {
            #expect(decide("/Users/someone/Pictures/Trip/\(name)") == copy, "\(name)")
        }
    }

    @Test func filesOutsidePicturesAreCopied() {
        #expect(decide("/Users/someone/Desktop/a.jpg") == .exportCopy(format: .jpeg, maxPixelSize: 6048))
        // A folder whose name only starts like Pictures is outside it.
        #expect(decide("/Users/someone/Pictures Old/a.jpg") != .useFile)
        #expect(decide("/Users/someone/Pictures/a.jpg") == .useFile)
    }

    @Test func unsavedEditsAndTransparencyDecideTheCopy() {
        #expect(decide("/Users/someone/Pictures/a.jpg", edits: true) == .exportCopy(format: .jpeg, maxPixelSize: 6048))
        #expect(decide("/Users/someone/Pictures/a.png", edits: true, alpha: true)
            == .exportCopy(format: .heic, maxPixelSize: 6048))
        #expect(DesktopPicturePolicy.maxPixelSize(screenPixels: CGSize(width: 1920, height: 1200)) == 3840)
    }

    @Test func aLinkIntoPicturesCountsAsWhereItPoints() throws {
        let scratch = try ScratchFolder()
        let folder = try scratch.folder("Pictures")
        let inside = try scratch.file("a.jpg", in: folder)
        let link = scratch.url.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        #expect(DesktopPicturePolicy.isInside(link, folder: folder))
        #expect(!DesktopPicturePolicy.isInside(try scratch.file("b.jpg"), folder: folder))
    }

    @Test func copiesAreNamedAndPrunedOldestFirst() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_789_381_805)
        #expect(DesktopPictureCopies.fileName(base: "HSB_2615", date: date, format: .jpeg, timeZone: utc)
            == "Desktop 2026-09-14 at 10.30.05 HSB_2615.jpg")
        #expect(DesktopPictureCopies.isCopy("Desktop 2026-09-14 at 10.30.05 HSB_2615.heic"))
        #expect(DesktopPictureCopies.isCopy("Desktop 2026-09-14 at 10.30.05 HSB_2615 2.jpg"))
        #expect(!DesktopPictureCopies.isCopy("Montage 2026-09-14 at 10.30.05.jpg"))
        #expect(!DesktopPictureCopies.isCopy("Desktop.jpg"))
        #expect(!DesktopPictureCopies.isCopy("My Desktop 2026-09-14 at 10.30.05 x.jpg"))

        let names = (1...13).map { "Desktop 2026-09-\(String(format: "%02d", $0)) at 10.00.00 x.jpg" }
            + ["Montage 2026-09-01 at 10.00.00.jpg", "notes.txt"]
        let removed = DesktopPictureCopies.namesToRemove(names.shuffled(), keeping: 10)
        #expect(removed == Array(names.prefix(3)))
        #expect(DesktopPictureCopies.namesToRemove(names, keeping: 20).isEmpty)
    }

    func setter(pictures: URL, desktop: FakeDesktop) -> DesktopPictureSetter {
        let setter = DesktopPictureSetter()
        setter.workspace = desktop
        setter.picturesFolder = pictures
        return setter
    }

    @Test func aJPEGInPicturesIsSetDirectly() async throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("photo.jpg", width: 80, height: 60)
        let desktop = FakeDesktop()
        let setter = setter(pictures: scratch.url, desktop: desktop)
        let result = try await setter.set(url: photo, edits: nil, screen: screen)
        #expect(result == photo)
        #expect(desktop.set.count == 1 && desktop.set[0].url == photo && desktop.set[0].screen === screen)
        #expect(desktop.set[0].options[.allowClipping] as? Bool == true)
        #expect(desktop.set[0].options[.imageScaling] as? UInt == NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        #expect(!FileManager.default.fileExists(atPath: setter.wallpapersFolder.path), "no copy made")
    }

    @Test func otherFilesAreExportedIntoWallpapersAndOldCopiesPruned() async throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let scratch = try ScratchFolder()
        let pictures = try scratch.folder("Pictures")
        let outside = try scratch.folder("Elsewhere")
        let photo = outside.appendingPathComponent("big.jpg")
        try FileManager.default.moveItem(at: try scratch.jpeg("big.jpg", width: 400, height: 300), to: photo)
        let desktop = FakeDesktop()
        let setter = setter(pictures: pictures, desktop: desktop)
        setter.keptCopies = 2
        setter.now = { Date(timeIntervalSince1970: 1_789_381_805) }

        // Older copies, one of them still on a screen.
        let wallpapers = setter.wallpapersFolder
        try FileManager.default.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        let old = ["Desktop 2026-09-01 at 10.00.00 a.jpg", "Desktop 2026-09-02 at 10.00.00 b.jpg",
                   "Desktop 2026-09-03 at 10.00.00 c.jpg", "Montage 2026-09-01 at 10.00.00.jpg"]
        for name in old { try Data([1]).write(to: wallpapers.appendingPathComponent(name)) }
        for other in NSScreen.screens where other !== screen {
            desktop.current[ObjectIdentifier(other)] = wallpapers.appendingPathComponent(old[0])
        }

        let result = try await setter.set(url: photo, edits: nil, screen: screen)
        #expect(result.deletingLastPathComponent().standardizedFileURL == wallpapers.standardizedFileURL)
        #expect(result.lastPathComponent == "Desktop \(MontageOutput.timestamp(setter.now())) big.jpg")
        #expect(desktop.set.map(\.url) == [result])
        #expect(FileManager.default.fileExists(atPath: photo.path), "the original is untouched")
        let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: wallpapers.path))
        #expect(left.contains(result.lastPathComponent))
        #expect(left.contains("Desktop 2026-09-03 at 10.00.00 c.jpg"))
        #expect(left.contains("Montage 2026-09-01 at 10.00.00.jpg"), "montages are never pruned")
        #expect(!left.contains("Desktop 2026-09-02 at 10.00.00 b.jpg"))
        // The oldest is still shown on another screen, when there is one.
        #expect(left.contains(old[0]) == (NSScreen.screens.count > 1))
    }

    /// The copy is decoded no larger than twice the screen (the limit itself
    /// is checked in `unsavedEditsAndTransparencyDecideTheCopy`).
    @Test func aFormatTheAgentCantReadIsCopiedAsJPEG() async throws {
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("wide.jpg", width: 900, height: 300)
        let url = photo.deletingPathExtension().appendingPathExtension("bmp")
        // A BMP isn't read by the wallpaper agent, so it is copied.
        let image = try #require(ImageDecoder.thumbnail(for: photo, maxPixelSize: 900))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.microsoft.bmp" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))

        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let desktop = FakeDesktop()
        let setter = setter(pictures: scratch.url, desktop: desktop)
        let limit = DesktopPicturePolicy.maxPixelSize(screenPixels: MontageOutput.pixelSize(
            points: screen.frame.size, backingScale: screen.backingScaleFactor))
        let result = try await setter.set(url: url, edits: nil, screen: screen)
        let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        #expect(width == min(900, limit))
        #expect(result.pathExtension == "jpg")
    }

    /// A wallpaper copy waiting in the write queue names its folder, so a
    /// wait on minivu Wallpapers comes back only once the copy is on disk.
    @Test func waitingOnTheWallpapersFolderWaitsForAQueuedCopy() async throws {
        let scratch = try ScratchFolder()
        let photo = try scratch.jpeg("photo.jpg", width: 40, height: 30)
        let image = ImageBox(image: try #require(ImageDecoder.thumbnail(for: photo, maxPixelSize: 40)))
        let setter = setter(pictures: scratch.url, desktop: FakeDesktop())
        setter.now = { Date(timeIntervalSince1970: 1_789_381_805) }
        let copied = Task { try await setter.writeCopy(image, format: .jpeg, base: "photo") }
        // One turn of the main actor is enough: the write takes its place in
        // the queue before it suspends.
        await Task.yield()
        await FileWriteQueue.shared.waitForWrites(to: [setter.wallpapersFolder])
        let expected = setter.wallpapersFolder.appendingPathComponent(
            DesktopPictureCopies.fileName(base: "photo", date: setter.now(), format: .jpeg))
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(try await copied.value == expected)
    }

    @Test func downscalingKeepsTheShape() throws {
        let context = try #require(CGContext(data: nil, width: 1000, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let box = ImageBox(image: try #require(context.makeImage()))
        let small = ToolImages.downscaled(box, maxLongEdge: 400)
        #expect(small.image.width == 400 && small.image.height == 100)
        #expect(ToolImages.downscaled(box, maxLongEdge: 2000).image === box.image)
    }

    @Test func commandsAreImplemented() {
        #expect(BrowserWindowController.instancesRespond(to: .setAsDesktopPicture))
        #expect(ViewerWindowController.instancesRespond(to: .setAsDesktopPicture))
        #expect(BrowserWindowController.instancesRespond(to: .makeMontage))
    }
}
