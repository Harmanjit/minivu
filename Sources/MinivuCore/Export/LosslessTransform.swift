import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rotates and flips photos without re-encoding them, by changing only the
/// EXIF orientation tag that says how the stored pixels should be shown.
/// A JPEG rotated this way a hundred times is still bit-for-bit the photo
/// the camera wrote, which a decode, rotate and re-encode can't promise.
public enum LosslessTransform {
    public enum Kind: Sendable, CaseIterable {
        case rotateClockwise, rotateCounterclockwise, rotate180, flipHorizontal, flipVertical
    }

    public enum Error: Swift.Error, Equatable {
        /// Not a format whose orientation can change without re-encoding,
        /// or a camera raw file, which we never modify.
        case unsupportedFormat
        case unreadable
        /// ImageIO's copy failed; the file is unchanged.
        case copyFailed(String)
    }

    /// Formats whose orientation tag can be changed without re-encoding
    /// pixels: JPEG, HEIC/HEIF, TIFF and PNG. Camera RAW files are excluded:
    /// they are the negatives and are never modified (and several RAW
    /// formats are TIFF inside, which ImageIO would happily rewrite). GIF,
    /// BMP and the rest have no orientation tag at all. Decided by
    /// extension, so it is cheap enough to validate a menu for a large
    /// selection; `apply` checks the actual contents.
    public static func canApply(to url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif", "heic", "heif", "hif", "tif", "tiff", "png": true
        default: false
        }
    }

    /// Composes the new orientation with the existing one and writes it with
    /// `CGImageDestinationCopyImageSource`; atomic; pixel data unchanged.
    ///
    /// The orientation goes in through `kCGImageDestinationOrientation`
    /// rather than a metadata object merged with
    /// `kCGImageDestinationMergeMetadata`. Both are ImageIO's lossless path,
    /// but measured on macOS 15 the merge left HEIC and PNG orientation
    /// unchanged and dropped JPEG COM segments (it re-serialises the
    /// header), while the orientation key patches the tag in place: a JPEG
    /// that already has the tag changes by one byte. Other metadata, ICC
    /// profiles and HDR gain maps survive either way.
    ///
    /// Only the primary image's orientation changes; the other pages of a
    /// multi-page TIFF keep theirs.
    public static func apply(_ kind: Kind, to url: URL) throws {
        guard canApply(to: url) else { throw Error.unsupportedFormat }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            throw Error.unreadable
        }
        guard let type = UTType(typeIdentifier as String), isSupported(type),
              !(type.conforms(to: .tiff) && isCameraRawTIFF(url)) else { throw Error.unsupportedFormat }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let current = (properties?[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let next = orientation(current, applying: kind)

        try SafeFileWriter.replace(url) { temp in
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, typeIdentifier, CGImageSourceGetCount(source), nil) else {
                throw Error.copyFailed("no destination for \(typeIdentifier)")
            }
            var error: Unmanaged<CFError>?
            // CopyImageSource finalizes the destination itself.
            let options = [kCGImageDestinationOrientation: next.rawValue] as CFDictionary
            guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
                let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
                throw Error.copyFailed(reason)
            }
        }
    }

    /// The content type check behind `apply`: a .jpg may really be a PNG
    /// (which is fine) or a GIF (which isn't).
    static func isSupported(_ type: UTType) -> Bool {
        guard !type.conforms(to: .rawImage) else { return false }
        return [UTType.jpeg, .heic, .heif, .tiff, .png].contains { type.conforms(to: $0) }
    }

    /// Most camera raw formats (NEF, DNG, CR2, ARW, PEF...) are TIFF files
    /// underneath, and ImageIO decides between "raw" and "TIFF" by the
    /// extension: a NEF renamed .tif is reported as `public.tiff`, and its
    /// small first image would be rewritten happily (measured). So TIFF
    /// files get a look at their first directory, which is a few hundred
    /// bytes at the start of the file. Signs of a raw:
    /// - "CR" after the header (Canon CR2);
    /// - a DNGVersion tag, or Sony's SR2 private data;
    /// - SubIFDs, where raws keep the sensor data (ordinary TIFFs from
    ///   scanners and photo software use one plain directory per page);
    /// - a first image marked "reduced resolution", i.e. a preview;
    /// - colour filter array or linear raw photometric interpretation.
    static func isCameraRawTIFF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return false }
        let h = [UInt8](header)
        let little: Bool
        switch (h[0], h[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return false
        }
        func u16(_ b: [UInt8], _ o: Int) -> Int { little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ b: [UInt8], _ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                   : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        guard u16(h, 2) == 42 else { return false }   // 43 is BigTIFF, which no camera writes
        if h.count >= 10, h[8] == 0x43, h[9] == 0x52 { return true }   // "CR"

        let ifd = u32(h, 4)
        guard (try? handle.seek(toOffset: UInt64(ifd))) != nil,
              let countBytes = try? handle.read(upToCount: 2), countBytes.count == 2 else { return false }
        let count = min(u16([UInt8](countBytes), 0), 512)
        guard let entryBytes = try? handle.read(upToCount: count * 12), entryBytes.count == count * 12 else { return false }
        let entries = [UInt8](entryBytes)
        for i in 0..<count {
            let e = i * 12
            let tag = u16(entries, e)
            let type = u16(entries, e + 2)
            // SHORT values sit in the first two bytes of the value field, LONG in all four.
            let value = type == 3 ? u16(entries, e + 8) : u32(entries, e + 8)
            switch tag {
            case 330, 50706, 50740: return true                             // SubIFDs, DNGVersion, SR2Private
            case 254 where value & 1 == 1: return true                       // NewSubfileType: reduced resolution
            case 262 where value == 32803 || value == 34892: return true     // CFA, LinearRaw
            default: continue
            }
        }
        return false
    }

    /// The orientation that shows the image as it is shown now, with `kind`
    /// applied on top. Each orientation is the linear part of the map from
    /// stored to displayed coordinates (y down); the transform is applied
    /// after it, and the result is looked up among the eight.
    public static func orientation(_ current: CGImagePropertyOrientation, applying kind: Kind) -> CGImagePropertyOrientation {
        let result = current.transform(width: 0, height: 0).concatenating(kind.transform)
        return allOrientations.first { $0.transform(width: 0, height: 0) == result } ?? current
    }

    static let allOrientations: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
    ]
}

extension LosslessTransform.Kind {
    /// The transform in displayed coordinates, y pointing down (so a
    /// clockwise turn takes the right-pointing x axis to the downward one).
    var transform: CGAffineTransform {
        switch self {
        case .rotateClockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)          // (x, y) -> (-y, x)
        case .rotateCounterclockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)   // (x, y) -> (y, -x)
        case .rotate180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case .flipHorizontal: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        case .flipVertical: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        }
    }
}
