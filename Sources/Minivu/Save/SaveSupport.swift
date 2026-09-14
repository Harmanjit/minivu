import AppKit
import ImageIO
import MinivuCore
import MinivuRender

/// The decisions behind Save and Save As, as plain functions so they can
/// be tested without panels or files.
nonisolated enum SavePolicy {
    /// The format Save (⌘S) writes over the original in, or nil when it must
    /// fall back to Save As: formats minivu can't write (camera RAW, WebP,
    /// AVIF, JPEG XL, PDF, SVG, PSD), animations, and files with more than
    /// one image (a multi-page TIFF, an icon with several sizes, a HEIC
    /// collection), which writing one picture back would silently shrink.
    /// JPEGs are the exception to that last rule: their second "image" is an
    /// MPF gain map or stereo partner, which Save As couldn't keep either.
    static func inPlaceFormat(for url: URL, info: ImageInfo?) -> ExportFormat? {
        guard let info else { return nil }
        return inPlaceFormat(for: url, kind: info.kind, imageCount: info.pageCount, isAnimated: info.isAnimated)
    }

    static func inPlaceFormat(for url: URL, kind: ImageKind, imageCount: Int, isAnimated: Bool) -> ExportFormat? {
        guard let format = ExportFormat.format(for: url), kind == .raster, !isAnimated else { return nil }
        if format != .jpeg, imageCount > 1 { return nil }
        return format
    }

    /// The colour space an edit is rendered into for saving with the
    /// "Keep original" profile.
    ///
    /// - The source's own space when it is an ordinary SDR RGB space, so an
    ///   sRGB JPEG saved in place stays sRGB.
    /// - Display P3 for HDR, linear or extended-range sources: an 8- or 16-bit
    ///   file can't hold values above 1.0, and P3 keeps the gamut the edit
    ///   was made in.
    /// - Display P3 too when `preferWideGamut` (Save As of an edited image)
    ///   and the source isn't already a known wide-gamut space: a saturation
    ///   boost can push colours past sRGB, and P3 keeps them.
    /// - sRGB for grey, CMYK, Lab and indexed sources. Core Image can only
    ///   render RGB with alpha into a CGImage, and sRGB is what every reader
    ///   assumes for converted colours.
    static func renderColorSpace(source: CGColorSpace?, isHDR: Bool, preferWideGamut: Bool) -> CGColorSpace {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if isHDR { return p3 }
        guard let source else { return preferWideGamut ? p3 : srgb }
        guard source.model == .rgb else { return srgb }
        let name = (source.name as String?) ?? ""
        if CGColorSpaceUsesExtendedRange(source) || CGColorSpaceUsesITUR_2100TF(source) || source.isHDR()
            || name.localizedCaseInsensitiveContains("linear") {
            return p3
        }
        // By exact name: "kCGColorSpaceSRGB" contains "aces", so a substring
        // test would take sRGB for ACES.
        let wideNames: [CFString] = [CGColorSpace.displayP3, CGColorSpace.dcip3, CGColorSpace.adobeRGB1998,
                                     CGColorSpace.rommrgb, CGColorSpace.itur_2020, CGColorSpace.acescgLinear]
        let knownWide = wideNames.contains { ($0 as String) == name }
        return preferWideGamut && !knownWide ? p3 : source
    }

    /// The named space for an explicit profile choice; nil for "Keep original".
    static func namedColorSpace(_ profile: ExportColorProfile) -> CGColorSpace? {
        switch profile {
        case .original: nil
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)
        }
    }

    /// The colour space of the primary image as stored, read from the header
    /// without decoding pixels (ImageIO creates the image lazily).
    static func sourceColorSpace(of url: URL) -> CGColorSpace? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                          [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return image.colorSpace
    }

    /// The confirmation's explanation. The quality is named because it is
    /// the one last chosen in Save As, which may have been a small copy for
    /// the web: overwriting a photo at quality 30 should not be a surprise.
    static func overwriteDetail(_ options: ExportOptions) -> String {
        let format = options.format
        let encoding = format.supportsQuality
            ? "\(format.title) at quality \(Int((options.quality * 100).rounded()))"
            : format.title
        return "The edited image is saved over the file as \(encoding). This can’t be undone."
    }

    /// Save's options: the ones remembered for the format, in the original's
    /// colour space and depth, and always keeping metadata, because
    /// overwriting a photo must never quietly strip its EXIF.
    static func inPlaceOptions(remembered: ExportOptions, sourceBitDepth: Int) -> ExportOptions {
        var options = remembered
        options.colorProfile = .original
        options.keepMetadata = options.format.supportsMetadata
        options.sixteenBit = options.format.supports16Bit && sourceBitDepth > 8
        return options
    }
}

/// File names in the save panel.
nonisolated enum SaveAsNaming {
    /// `name` with its image extension replaced by `format`'s. An extension
    /// that isn't an image type ("Trip.final") is part of the name and stays.
    static func renamed(_ name: String, to format: ExportFormat) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        let ext = ns.pathExtension.lowercased()
        let isImageExtension = !ext.isEmpty
            && (ImageFormats.allExtensions.contains(ext) || ExportFormat.format(for: URL(fileURLWithPath: trimmed)) != nil)
        var base = isImageExtension ? ns.deletingPathExtension : trimmed
        if base.isEmpty { base = "Untitled" }
        return base + "." + format.fileExtension
    }
}

/// Byte counts as the dialogs show them.
nonisolated enum SaveSizeText {
    /// "2.4 MB": decimal units, as Finder shows file sizes.
    static func file(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// Uncompressed pixels, in binary units as Activity Monitor counts memory.
    static func memory(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .memory))
    }
}

// MARK: - Pixels

/// Which pixels a render for saving produces. Everything that changes them:
/// the colour space and depth for an edit (the encoder converts anything
/// else itself), nothing at all for a decoded original.
nonisolated struct SaveRenderKey: Hashable, Sendable {
    var profile: ExportColorProfile
    var bitsPerComponent: Int

    /// Formats without an embedded profile are always written as sRGB, so an
    /// edit for them is rendered straight into sRGB.
    static func forEdit(_ options: ExportOptions) -> SaveRenderKey {
        let format = options.format
        return SaveRenderKey(profile: format.supportsColorProfile ? options.colorProfile : .sRGB,
                             bitsPerComponent: format.supports16Bit && options.sixteenBit ? 16 : 8)
    }

    static let decodedOriginal = SaveRenderKey(profile: .original, bitsPerComponent: 0)
}

/// The full-resolution image a Save As writes, made once and kept while the
/// panel is open, so the size estimate, the quality comparison and the
/// final write share it.
///
/// An edit (committed operations) is rendered by `EditRenderer` for the
/// chosen colour space and depth. An unedited image is decoded from the file
/// by ImageIO, oriented, with no Core Image round trip, so an 8-bit JPEG
/// converted to PNG keeps exactly its pixels; an HDR photo is decoded as
/// its SDR rendition, since the formats written here are all SDR. Camera RAW
/// files are the exception: they go through `EditRenderer` like an edit
/// with no operations, so the file looks as the viewer showed it (Apple's
/// RAW engine on the GPU, following the RAW settings) and renders in a
/// fraction of the time ImageIO's CPU decode takes.
@MainActor final class SaveImageSource {
    enum Origin: Sendable {
        case edit(EditDocument.Snapshot)
        /// A file and the page of it on screen (a multi-page TIFF's third
        /// page converts the third page).
        case original(URL, page: Int)
    }

    let origin: Origin
    private var cached: (key: SaveRenderKey, image: CGImage)?
    private var inflight: (key: SaveRenderKey, task: Task<CGImage, Error>)?

    init(entry: FolderEntry, document: EditDocument?) {
        if let document, !document.operations.isEmpty {
            origin = .edit(document.snapshot())
        } else if entry.kind == .raw {
            // The viewer's document, when there is one, may hold the decoded
            // RAW already, which spares a second render of the sensor data.
            origin = .edit((document ?? EditDocument(entry: entry)).snapshot())
        } else {
            origin = .original(entry.url, page: document?.page ?? 0)
        }
    }

    func key(for options: ExportOptions) -> SaveRenderKey {
        switch origin {
        case .edit: .forEdit(options)
        case .original: .decodedOriginal
        }
    }

    /// The render for `options` if it is already made, without waiting.
    func cachedImage(for options: ExportOptions) -> CGImage? {
        guard let cached, cached.key == key(for: options) else { return nil }
        return cached.image
    }

    /// The pixels to encode with `options`, rendered in the background.
    /// Requests for the same pixels share one render; only the newest
    /// render is kept, since a 16-bit 24 MP image is 190 MB.
    func image(for options: ExportOptions) async throws -> CGImage {
        let key = key(for: options)
        if let cached, cached.key == key { return cached.image }
        if let inflight, inflight.key == key { return try await inflight.task.value }
        let origin = self.origin
        let renderer = EditRenderer.shared
        let task = Task.detached(priority: .userInitiated) {
            try await Self.render(origin, key: key, renderer: renderer)
        }
        inflight = (key, task)
        defer { if inflight?.key == key { inflight = nil } }
        let image = try await task.value
        cached = (key, image)
        return image
    }

    nonisolated static func render(_ origin: Origin, key: SaveRenderKey, renderer: EditRenderer) async throws -> CGImage {
        switch origin {
        case .original(let url, let page):
            return try ImageDecoder.decode(url, maxPixelSize: nil, page: page, allowHDR: false).image
        case .edit(let snapshot):
            let space = SavePolicy.namedColorSpace(key.profile) ?? SavePolicy.renderColorSpace(
                source: snapshot.kind == .raw ? nil : SavePolicy.sourceColorSpace(of: snapshot.url),
                isHDR: snapshot.kind == .raw ? false : (ImageDecoder.info(for: snapshot.url)?.isHDR ?? false),
                preferWideGamut: true)
            return try await renderer.renderForExport(snapshot, colorSpace: space, bitsPerComponent: key.bitsPerComponent)
        }
    }
}

// MARK: - Progress and errors

/// A small sheet saying a save is under way, shown only if the save takes
/// long enough to notice (a 100 MP edit, a RAW render), so ordinary saves
/// don't flash a panel.
@MainActor final class SaveProgress {
    static let delay: Duration = .milliseconds(400)

    private weak var parent: NSWindow?
    private var sheet: NSWindow?
    private var pending: Task<Void, Never>?

    init(on parent: NSWindow, title: String) {
        self.parent = parent
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.show(title)
        }
    }

    private func show(_ title: String) {
        guard let parent, parent.isVisible else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = stack
        sheet = window
        parent.beginSheet(window)
    }

    func finish() {
        pending?.cancel()
        pending = nil
        if let sheet, let parent {
            parent.endSheet(sheet)
        }
        sheet = nil
    }
}

enum SaveAlert {
    /// The error as a sheet on `window`, or as a modal alert when the window
    /// has gone away meanwhile.
    static func show(_ error: Error, title: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(for: error)
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// minivu's own errors describe themselves (`DecodeError` and
    /// `EditRenderError` through `description`); Cocoa's file errors have a
    /// localized sentence ("You don't have permission to save…").
    nonisolated static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        if let error = error as? DecodeError { return error.description }
        if let error = error as? EditRenderError { return error.description }
        return error.localizedDescription
    }
}
