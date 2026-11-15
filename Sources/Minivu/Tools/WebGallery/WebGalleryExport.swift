import AppKit
import MinivuCore
import MinivuRender

/// Where Create Web Gallery's choices live: one key in a defaults store the
/// caller picks, so tests never touch the user's.
final class WebGallerySettingsStore {
    nonisolated static let key = "webGallerySettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: WebGallerySettings {
        get {
            defaults.data(forKey: Self.key)
                .flatMap { try? JSONDecoder().decode(WebGallerySettings.self, from: $0) } ?? WebGallerySettings()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: Self.key) }
        }
    }
}

/// Making a web gallery: planning it, writing every file off the main
/// thread into a scratch folder on the destination's volume, and moving the
/// finished gallery folder into place in one rename through
/// `FileWriteQueue`.
///
/// So the chosen folder only ever gains a whole gallery: Cancel, a failure
/// or a quit part way leaves nothing there (the scratch folder is the
/// system's item-replacement folder, which the sandbox allows beside a
/// folder the open panel granted, and which is removed afterwards). The
/// gallery's folder never replaces anything: a name already taken is
/// numbered ("Trip 2"), and the final rename is exclusive.
///
/// Pictures are made one at a time (so at most one camera RAW render is in
/// hand), through Batch Convert's own converter: the same decode, the same
/// resize, the same encoder and metadata rules as Save As, always SDR and
/// sRGB. A picture that can't be made is left out and named afterwards;
/// the gallery is made of the rest.
///
/// Original files, when included, are copied as they are, except where
/// each photo was taken: unless the large pictures keep their location, it
/// is removed from each copy with the lossless metadata writer (no pixel
/// re-encoded), and an original it can't be removed from (a camera raw,
/// which minivu never modifies, or a format it can't rewrite) is left out
/// of originals/ and named afterwards, so the gallery never shares a
/// location the dialog said it would leave out.
///
/// The chosen folder must be on the Mac's internal storage (`VolumePolicy`,
/// DESIGN.md 1), as Batch Convert's output folder must.
enum WebGalleryExport {
    /// A picture left out, and why.
    struct Skipped: Equatable, Sendable {
        var name: String
        var reason: String
    }

    struct Outcome: Sendable {
        /// The gallery's folder, holding index.html.
        var folder: URL
        var items: [WebGalleryItem]
        var skipped: [Skipped]
        /// Pictures whose original file was left out of originals/, its
        /// location not removable; their large pictures are in the gallery.
        var withheldOriginals: [String] = []
    }

    /// Makes a gallery of `images` called `title` in a new folder inside
    /// `parent`, and returns it. `progress` gets (steps done, steps) on the
    /// main actor: one step a picture, and one for the pages. Throws
    /// `CancellationError` if `cancel` is set before the gallery is placed,
    /// and `ExternalVolumeError` for a folder `isAllowedVolume` refuses,
    /// before anything is written.
    static func export(images: [FolderEntry], title: String, settings: WebGallerySettings, into parent: URL,
                       cancel: CancellationFlag, converter: BatchConverter = BatchConvertJob.makeConverter(),
                       isAllowedVolume: @escaping @Sendable (URL) -> Bool = VolumePolicy.isAllowed,
                       readFields: @escaping @Sendable (URL) -> MetadataFields = { MetadataFields.read(from: $0) },
                       formatDate: @escaping @Sendable (WebGalleryPlanner.Source) -> String
                           = { WebGalleryPlanner.dateText(for: $0) },
                       progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> Outcome {
        let settings = settings.validated
        let accessing = parent.startAccessingSecurityScopedResource()
        defer { if accessing { parent.stopAccessingSecurityScopedResource() } }
        guard await BlockingWork.run({ isAllowedVolume(parent) }) else { throw ExternalVolumeError(folder: parent) }

        // Headers only, never pixels, and only when a caption or the order
        // needs them.
        let planned = await BlockingWork.run { () -> [WebGalleryItem] in
            let sources = images.map { entry -> WebGalleryPlanner.Source in
                guard settings.needsMetadata else { return WebGalleryPlanner.Source(url: entry.url, modified: entry.modified) }
                let fields = readFields(entry.url)
                return WebGalleryPlanner.Source(url: entry.url, modified: entry.modified, title: fields.title,
                                                caption: fields.caption, dateTaken: fields.dateTaken)
            }
            return WebGalleryPlanner.items(sources, settings: settings, formatDate: formatDate)
        }
        guard !cancel.isCancelled else { throw CancellationError() }
        guard !planned.isEmpty else { throw CocoaError(.fileNoSuchFile) }

        let name = folderName(for: title)
        let scratch = try await BlockingWork.run {
            try ContactSheetExport.scratchFolder(for: parent.appendingPathComponent(name, isDirectory: true))
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gallery = scratch.appendingPathComponent(name, isDirectory: true)
        try await BlockingWork.run { try makeFolders(in: gallery, originals: settings.includesOriginals) }

        let steps = planned.count + 1
        progress(0, steps)
        var items: [WebGalleryItem] = []
        var skipped: [Skipped] = []
        var withheld: [String] = []
        var firstError: Error?
        for (index, item) in planned.enumerated() {
            guard !cancel.isCancelled else { throw CancellationError() }
            do {
                // On GCD threads, as Batch Convert's work: a render and two
                // encodes block for a long time.
                let made = try await withTaskExecutorPreference(BatchWorkExecutor.shared) {
                    try await writePictures(for: item, settings: settings, converter: converter, into: gallery)
                }
                items.append(made)
                if item.originalName != nil, made.originalName == nil { withheld.append(item.fileName) }
            } catch {
                firstError = firstError ?? error
                skipped.append(Skipped(name: item.fileName, reason: SaveAlert.message(for: error)))
            }
            progress(index + 1, steps)
        }
        guard !cancel.isCancelled else { throw CancellationError() }
        // Nothing could be made: say why, rather than place an empty gallery.
        if items.isEmpty, let firstError { throw firstError }

        let pages = items
        try await BlockingWork.run { try writePages(title: title, items: pages, settings: settings, into: gallery) }
        progress(steps, steps)
        guard !cancel.isCancelled else { throw CancellationError() }

        let target = parent.appendingPathComponent(name, isDirectory: true)
        let job = FileWriteQueue.shared.enqueue(replacing: [target]) {
            try await BlockingWork.run { try place(gallery, in: parent, as: name) }
        }
        let placed = try await job.value.value
        return Outcome(folder: placed, items: items, skipped: skipped, withheldOriginals: withheld)
    }

    /// The gallery folder's name: the title made safe, "Web Gallery" when
    /// nothing usable is left.
    nonisolated static func folderName(for title: String) -> String {
        let safe = WebGalleryPlanner.safeName(title)
        return safe.isEmpty || BatchNameKey.problem(with: safe) != nil ? "Web Gallery" : safe
    }

    nonisolated static func makeFolders(in gallery: URL, originals: Bool) throws {
        var folders = [WebGalleryHTML.pagesFolder, WebGalleryHTML.imagesFolder, WebGalleryHTML.thumbnailsFolder]
        if originals { folders.append(WebGalleryHTML.originalsFolder) }
        for folder in folders {
            try FileManager.default.createDirectory(at: gallery.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    /// Writes one picture's large picture and thumbnail (and copies its
    /// original), returning the item with the pictures' sizes, and without
    /// its original's name when that was left out (`copyOriginal`).
    nonisolated static func writePictures(for item: WebGalleryItem, settings: WebGallerySettings,
                                          converter: BatchConverter, into gallery: URL) async throws -> WebGalleryItem {
        var convert = BatchConvertSettings(options: settings.exportOptions)
        convert.resize = BatchResize(mode: .longSide, pixels: settings.largeSize, doesNotEnlarge: true)
        let large = try await converter.image(for: item.source, settings: convert)
        let thumbnail = try scaled(large, longSide: settings.thumbnailPixels)

        let format = settings.format, ext = settings.format.fileExtension
        let largeData = try encode(large, format: format, options: settings.exportOptions, metadataSource: item.source)
        let thumbnailData = try encode(thumbnail, format: format, options: settings.thumbnailOptions, metadataSource: nil)
        try largeData.write(to: gallery.appendingPathComponent(WebGalleryHTML.imagesFolder)
            .appendingPathComponent(item.stem + "." + ext), options: .withoutOverwriting)
        try thumbnailData.write(to: gallery.appendingPathComponent(WebGalleryHTML.thumbnailsFolder)
            .appendingPathComponent(item.stem + "." + ext), options: .withoutOverwriting)

        var made = item
        if let original = item.originalName {
            let copy = gallery.appendingPathComponent(WebGalleryHTML.originalsFolder).appendingPathComponent(original)
            if try !copyOriginal(item.source, to: copy, keepingLocation: settings.originalsKeepLocation) {
                made.originalName = nil
            }
        }
        made.largeWidth = large.width
        made.largeHeight = large.height
        // The thumbnail is drawn at half its pixels, for Retina screens.
        made.thumbnailWidth = max(1, (thumbnail.width + 1) / 2)
        made.thumbnailHeight = max(1, (thumbnail.height + 1) / 2)
        return made
    }

    /// Copies `source` to `copy`, then, unless `keepingLocation`, removes
    /// where the photo was taken from the copy in place, without
    /// re-encoding. False, with nothing left at `copy`, when a location is
    /// there and can't be removed: a camera raw (the writer would only add
    /// a sidecar, leaving the raw's own GPS), a format the writer can't
    /// rewrite, or a write that failed or didn't take.
    nonisolated static func copyOriginal(_ source: URL, to copy: URL, keepingLocation: Bool) throws -> Bool {
        try FileManager.default.copyItem(at: source, to: copy)
        guard !keepingLocation, MetadataFields.read(from: copy, includingSidecar: false).hasLocation else { return true }
        var sidecar: URL?
        if MetadataWriter.method(for: copy) == .inPlace {
            // A raw named as a JPEG gets a sidecar, not a change in the file.
            let outcome = try? MetadataWriter.apply(MetadataEdit(removeLocation: true), to: copy)
            if outcome?.usedSidecar == true { sidecar = outcome?.written }
            if sidecar == nil, !MetadataFields.read(from: copy, includingSidecar: false).hasLocation { return true }
        }
        try? FileManager.default.removeItem(at: copy)
        if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
        return false
    }

    nonisolated static func encode(_ image: CGImage, format: WebGalleryFormat, options: ExportOptions,
                                   metadataSource: URL?) throws -> Data {
        switch format {
        case .jpeg, .heic:
            try ImageEncoder.encode(image, options: options, metadataSource: metadataSource)
        case .avif:
            try ImageEncoder.encode(image, typeIdentifier: format.typeIdentifier, options: options,
                                    metadataSource: metadataSource)
        }
    }

    /// `image` with its long side at most `longSide`, drawn smaller in sRGB
    /// with Core Graphics' best interpolation; the large picture is already
    /// close in size, so this is a modest step down.
    nonisolated static func scaled(_ image: CGImage, longSide: Int) throws -> CGImage {
        let scale = Double(longSide) / Double(max(image.width, image.height, 1))
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else {
            throw ExportError.cannotConvertPixels
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.cannotConvertPixels }
        return result
    }

    /// index.html, a page per picture, and the style sheet.
    nonisolated static func writePages(title: String, items: [WebGalleryItem], settings: WebGallerySettings,
                                       into gallery: URL) throws {
        func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        }
        try write(WebGalleryHTML.indexPage(title: title, items: items, settings: settings),
                  to: gallery.appendingPathComponent(WebGalleryHTML.indexName))
        try write(WebGalleryHTML.styleSheet(settings: settings),
                  to: gallery.appendingPathComponent(WebGalleryHTML.styleSheetName))
        let pages = gallery.appendingPathComponent(WebGalleryHTML.pagesFolder, isDirectory: true)
        for index in items.indices {
            try write(WebGalleryHTML.picturePage(at: index, title: title, items: items, settings: settings),
                      to: pages.appendingPathComponent(items[index].stem + ".html"))
        }
    }

    /// Moves the finished gallery into `parent` as `name`, or the next free
    /// numbered name if another item has it: renames that never replace.
    nonisolated static func place(_ gallery: URL, in parent: URL, as name: String) throws -> URL {
        var target = parent.appendingPathComponent(FileOperations.uniqueName(for: name, in: parent, isDirectory: true),
                                                   isDirectory: true)
        for _ in 0..<20 {
            do {
                try FileOperations.moveExclusively(gallery, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                target = parent.appendingPathComponent(
                    FileOperations.uniqueName(for: target.lastPathComponent, in: parent, isDirectory: true),
                    isDirectory: true)
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
    }

    // MARK: - Choosing where

    /// Asks for the folder the gallery's folder goes in, with an open panel
    /// as a sheet on `window`; calls `completion` with nil when cancelled.
    /// Tests replace it, so no panel opens.
    static var chooseFolder: (_ title: String, _ startFolder: URL?, _ window: NSWindow,
                              _ completion: @escaping (URL?) -> Void) -> Void = { title, startFolder, window, completion in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Gallery"
        panel.message = "Choose where to put the folder “\(folderName(for: title))”."
        if let startFolder { panel.directoryURL = startFolder }
        // The panel holds its delegate weakly; the completion keeps it.
        let delegate = InternalVolumesOnly()
        panel.delegate = delegate
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(delegate) {}
            completion(response == .OK ? panel.url : nil)
        }
    }
}
