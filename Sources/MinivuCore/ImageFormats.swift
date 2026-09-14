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

    public static let allExtensions: Set<String> = rasterExtensions.union(rawExtensions).union(["pdf", "svg"])

    /// The kind of a file by extension, or nil if the browser ignores it.
    public static func kind(of url: URL) -> ImageKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ext == "svg" { return .svg }
        if rawExtensions.contains(ext) { return .raw }
        if rasterExtensions.contains(ext) { return .raster }
        return nil
    }

    public static func isImage(_ url: URL) -> Bool { kind(of: url) != nil }

    /// Content types for open panels and drag and drop.
    public static let contentTypes: [UTType] = [.image, .rawImage, .pdf, .svg]
}
