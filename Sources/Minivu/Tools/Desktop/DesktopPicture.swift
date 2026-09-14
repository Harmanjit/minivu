import AppKit
import MinivuCore
import MinivuRender

/// Sets and reads desktop pictures. `NSWorkspace` in the app; tests pass a
/// fake, because a test must never change the tester's wallpaper.
protocol DesktopPictureSetting: AnyObject {
    func setDesktopImageURL(_ url: URL, for screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws
    func desktopImageURL(for screen: NSScreen) -> URL?
}

extension NSWorkspace: DesktopPictureSetting {}

/// A `CGImage` handed between the main actor and background work. Core
/// Graphics images are immutable once made, so sharing one is safe; the
/// type only says so to the compiler.
nonisolated struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

/// Whether a photo can be the desktop picture as it is, or needs a copy.
///
/// The desktop picture is drawn by the system's wallpaper agent, which
/// opens the file itself, later and in its own process, and keeps opening
/// it after every restart. So the file has to be something it reads, in a
/// place it can read for good, and hold the pixels the user sees:
///
/// - JPEG, PNG, HEIC and TIFF are read everywhere; RAW, WebP, AVIF, PDF and
///   the rest are exported first.
/// - Inside the Pictures folder. A photo elsewhere (a folder the user opened
///   in minivu, a drive) may move, or be out of the agent's reach.
/// - With unsaved edits the file doesn't have them, so the edited render is
///   exported.
///
/// Copies go to Pictures/minivu Wallpapers, no larger than twice the
/// screen's pixels (a full-size 100 MP TIFF would only cost the agent memory).
nonisolated enum DesktopPicturePolicy {
    enum Decision: Equatable {
        case useFile
        case exportCopy(format: ExportFormat, maxPixelSize: Int)
    }

    /// Extensions the wallpaper agent reads directly.
    static let directExtensions: Set<String> = ["jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff"]

    static func decide(file: URL, hasUnsavedEdits: Bool, hasAlpha: Bool, picturesFolder: URL,
                       screenPixels: CGSize) -> Decision {
        let usable = directExtensions.contains(file.pathExtension.lowercased())
            && isInside(file, folder: picturesFolder) && !hasUnsavedEdits
        if usable { return .useFile }
        return .exportCopy(format: copyFormat(hasAlpha: hasAlpha), maxPixelSize: maxPixelSize(screenPixels: screenPixels))
    }

    /// HEIC keeps transparency (a JPEG would put the image on white); JPEG
    /// otherwise, which every Mac decodes quickest.
    static func copyFormat(hasAlpha: Bool) -> ExportFormat {
        hasAlpha ? .heic : .jpeg
    }

    /// Twice the screen's long edge, so the copy stays sharp if the picture
    /// is shown on a larger display later.
    static func maxPixelSize(screenPixels: CGSize) -> Int {
        Int(max(screenPixels.width, screenPixels.height) * 2)
    }

    /// Whether `url` is inside `folder`, by real path: a symbolic link into
    /// Pictures from elsewhere counts as where it points.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        var base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !base.hasSuffix("/") { base += "/" }
        return file.hasPrefix(base)
    }
}

/// Set as Desktop Picture, for the browser's lead image and the viewer's
/// image: decides whether a copy is needed, makes it, and hands the file to
/// the system for one screen.
@MainActor final class DesktopPictureSetter {
    static let shared = DesktopPictureSetter()

    var workspace: DesktopPictureSetting = NSWorkspace.shared
    /// Pictures; tests use a scratch folder.
    var picturesFolder: URL = BookmarkStore.picturesFolder
    var now: () -> Date = Date.init
    /// Copies of desktop pictures minivu keeps; older ones are removed.
    var keptCopies = 10
    /// The job in flight, for tests to await.
    private(set) var work: Task<Void, Never>?

    /// Scale to fill the screen, keeping the photo's shape and cropping what
    /// overflows: how a photo looks best as a wallpaper.
    static let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]

    enum SetError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” couldn’t be read."
            }
        }
    }

    var wallpapersFolder: URL {
        picturesFolder.appendingPathComponent(MontageOutput.wallpapersFolderName, isDirectory: true)
    }

    /// Sets `url` (or its edited render, when `edits` is given) as the
    /// desktop picture of `screen`, and explains a failure as a sheet on
    /// `window`.
    func run(url: URL, edits: EditDocument.Snapshot?, screen: NSScreen, window: NSWindow?) {
        work = Task { [weak window] in
            do {
                _ = try await set(url: url, edits: edits, screen: screen)
            } catch {
                Self.explain(error, name: url.lastPathComponent, on: window)
            }
        }
    }

    private static func explain(_ error: Error, name: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” couldn’t be set as the desktop picture."
        alert.informativeText = error.localizedDescription
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Returns the file the desktop now shows.
    func set(url: URL, edits: EditDocument.Snapshot?, screen: NSScreen) async throws -> URL {
        let pixels = MontageOutput.pixelSize(points: screen.frame.size, backingScale: screen.backingScaleFactor)
        let info = await BlockingWork.run { ImageDecoder.info(for: url) }
        guard let info else { throw SetError.unreadable(url.lastPathComponent) }
        let decision = DesktopPicturePolicy.decide(file: url, hasUnsavedEdits: edits != nil, hasAlpha: info.hasAlpha,
                                                   picturesFolder: picturesFolder, screenPixels: pixels)
        var target = url
        if case .exportCopy(let format, let maxPixelSize) = decision {
            let image = try await render(url: url, edits: edits, maxPixelSize: maxPixelSize)
            target = try await writeCopy(image, format: format, base: url.deletingPathExtension().lastPathComponent)
        }
        try workspace.setDesktopImageURL(target, for: screen, options: Self.options)
        if case .exportCopy = decision { await pruneCopies() }
        return target
    }

    /// The pixels to copy: the edited render, or the file decoded at no more
    /// than `maxPixelSize` (upright, SDR: the agent draws SDR).
    private func render(url: URL, edits: EditDocument.Snapshot?, maxPixelSize: Int) async throws -> ImageBox {
        if let edits {
            let space = CGColorSpace(name: CGColorSpace.displayP3)!
            let image = try await EditRenderer.shared.renderForExport(edits, colorSpace: space, bitsPerComponent: 8)
            let box = ImageBox(image: image)
            return await BlockingWork.run { ToolImages.downscaled(box, maxLongEdge: maxPixelSize) }
        }
        return try await BlockingWork.run {
            ImageBox(image: try ImageDecoder.decode(url, maxPixelSize: maxPixelSize, allowHDR: false).image)
        }
    }

    /// Writes the copy into minivu Wallpapers under a name nothing has yet,
    /// in line with every other image write.
    private func writeCopy(_ image: ImageBox, format: ExportFormat, base: String) async throws -> URL {
        let folder = wallpapersFolder
        let name = DesktopPictureCopies.fileName(base: base, date: now(), format: format)
        let options = { var o = ExportOptions.defaults(for: format); o.keepMetadata = false; return o }()
        let job = FileWriteQueue.shared.enqueue {
            try await BlockingWork.run {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(FileOperations.uniqueName(for: name, in: folder))
                try ImageEncoder.write(image.image, to: url, options: options, metadataSource: nil)
                return url
            }
        }
        return try await job.value.value
    }

    /// Removes all but the newest `keptCopies` desktop picture copies, never
    /// one a screen still shows. Montages are the user's own work and stay.
    func pruneCopies() async {
        let inUse = Set(NSScreen.screens.compactMap { workspace.desktopImageURL(for: $0)?.standardizedFileURL.path })
        let folder = wallpapersFolder, keep = keptCopies
        await BlockingWork.run(qos: .utility) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in DesktopPictureCopies.namesToRemove(names, keeping: keep) {
                let url = folder.appendingPathComponent(name)
                guard !inUse.contains(url.standardizedFileURL.path) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// The copies Set as Desktop Picture makes, named so they can be told from
/// montages and anything the user put in the folder.
nonisolated enum DesktopPictureCopies {
    /// "Desktop 2026-09-14 at 10.30.05 HSB_2615.jpg": the timestamp first,
    /// so names sort oldest to newest.
    static func fileName(base: String, date: Date, format: ExportFormat, timeZone: TimeZone = .current) -> String {
        "Desktop \(MontageOutput.timestamp(date, timeZone: timeZone)) \(base).\(format.fileExtension)"
    }

    static func isCopy(_ name: String) -> Bool {
        name.wholeMatch(of: /Desktop \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2} .+\.(jpg|heic)/) != nil
    }

    /// The copies beyond the newest `keeping`, oldest first. The timestamp
    /// leads the name, so name order is age order; "… 2.jpg" made in the
    /// same second sorts after its twin.
    static func namesToRemove(_ names: [String], keeping: Int) -> [String] {
        let copies = names.filter(isCopy).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Array(copies.dropLast(max(keeping, 0)))
    }
}

/// Small pixel helpers shared by the Tools.
nonisolated enum ToolImages {
    /// `box` no larger than `maxLongEdge`, drawn with Core Graphics' high
    /// quality filter into 8-bit Display P3; the same image if already small.
    static func downscaled(_ box: ImageBox, maxLongEdge: Int) -> ImageBox {
        let image = box.image
        let longest = max(image.width, image.height)
        guard longest > maxLongEdge, maxLongEdge > 0 else { return box }
        let scale = Double(maxLongEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return box }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(ImageBox.init) ?? box
    }
}
