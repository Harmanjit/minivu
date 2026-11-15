import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// How a file is decoded.
public enum ImageKind: Sendable, Equatable {
    /// Anything ImageIO decodes: JPEG, PNG, HEIC, WebP, JXL, TIFF, PSD...
    case raster
    /// A camera raw file (also ImageIO, but slow to decode in full).
    case raw
    case pdf
    case svg
    /// A movie AVFoundation plays (G18). The browser and viewer show it
    /// among the photos and play it; nothing edits or converts it.
    case video
}

/// The single list of file types the browser shows (DESIGN.md 3).
public enum ImageFormats {
    /// Extensions for ImageIO raster formats.
    public static let rasterExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "heic", "heif", "hif", "avif",
        "webp", "jxl", "jp2", "j2k", "jpf", "jpx", "tif", "tiff", "bmp", "dib", "tga",
        "ico", "cur", "psd", "exr", "icns",
    ]

    /// Camera raw extensions. Apple's RAW engine decodes these; its camera
    /// list decides which bodies actually work.
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "pef", "raf", "rwl", "mrw", "orf", "srw",
        "arw", "sr2", "srf", "rw2", "dng", "3fr", "fff", "iiq", "erf", "raw", "rwz",
    ]

    /// Movie extensions the browser lists: the common ones a Mac plays,
    /// each kept only if AVFoundation itself reports its type as one it
    /// opens (`videoExtensions`). Deliberately not everything AVFoundation
    /// reports: its list also holds subtitle files (vtt, scc), audio
    /// (mpa, m1a) and "ts", which in a developer's folder is far more often
    /// TypeScript than a transport stream; AVI is left out because
    /// AVFoundation opens the container but plays almost none of its codecs.
    public static let videoCandidates: Set<String> = [
        "mov", "qt", "mp4", "mpg4", "m4v", "3gp", "3gpp", "3g2", "3gp2", "mts", "m2ts", "mpg", "mpeg", "dv",
    ]

    /// `videoCandidates` that this Mac's AVFoundation reports it opens,
    /// worked out once. `AVURLAsset.audiovisualTypes()` is what the system
    /// itself says, so a type a future macOS drops leaves the browser too.
    public static let videoExtensions: Set<String> = {
        var reported: Set<String> = []
        for type in AVURLAsset.audiovisualTypes() {
            guard let uti = UTType(type.rawValue), uti.conforms(to: .movie) else { continue }
            reported.formUnion((uti.tags[.filenameExtension] ?? []).map { $0.lowercased() })
        }
        return videoCandidates.intersection(reported)
    }()

    public static let allExtensions: Set<String> = rasterExtensions.union(rawExtensions).union(["pdf", "svg"])
        .union(videoExtensions)

    /// The kind of a file by extension, or nil if the browser ignores it.
    public static func kind(of url: URL) -> ImageKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ext == "svg" { return .svg }
        if rawExtensions.contains(ext) { return .raw }
        if rasterExtensions.contains(ext) { return .raster }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Anything the browser lists, videos included: "image" is the app's
    /// word for an item of a folder that isn't a folder.
    public static func isImage(_ url: URL) -> Bool { kind(of: url) != nil }

    public static func isVideo(_ url: URL) -> Bool { kind(of: url) == .video }

    /// Content types for open panels and drag and drop.
    public static let contentTypes: [UTType] = [.image, .rawImage, .pdf, .svg, .movie]
}
