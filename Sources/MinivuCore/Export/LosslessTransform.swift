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
    /// unchanged, while the orientation key works for all four formats.
    ///
    /// JPEGs need one more step. When the file already has an orientation
    /// tag ImageIO patches it in place, but when it has none (most edited,
    /// scanned and exported JPEGs) or the header is unusual, ImageIO writes
    /// the header afresh and silently drops COM comments and APPn segments
    /// it doesn't know, and leaves an MPF gain-map index pointing at the
    /// wrong bytes (all measured). So the copy is made in memory, and only
    /// its EXIF and XMP segments, where the orientation lives, are spliced
    /// into the original header; every other byte of the file stays as it
    /// was. The copy's image data is compared with the original's first,
    /// so a JPEG is never silently re-encoded.
    ///
    /// Only the primary image's orientation changes; the other pages of a
    /// multi-page TIFF keep theirs.
    public static func apply(_ kind: Kind, to url: URL) throws {
        guard canApply(to: url) else { throw Error.unsupportedFormat }
        guard !isCameraRaw(url) else { throw Error.unsupportedFormat }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            throw Error.unreadable
        }
        guard let type = UTType(typeIdentifier as String), isSupported(type) else { throw Error.unsupportedFormat }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let current = (properties?[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let next = orientation(current, applying: kind)
        let options = [kCGImageDestinationOrientation: next.rawValue] as CFDictionary

        func copy(into destination: CGImageDestination, from source: CGImageSource) throws {
            var error: Unmanaged<CFError>?
            // CopyImageSource finalizes the destination itself.
            guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
                let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
                throw Error.copyFailed(reason)
            }
        }

        if type.conforms(to: .jpeg) {
            // Read, not mapped: the file is about to be replaced. The source
            // is made from these same bytes, so both sides of the splice agree.
            let original = try Data(contentsOf: url)
            guard let jpegSource = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw Error.unreadable
            }
            let copied = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(copied, typeIdentifier, CGImageSourceGetCount(jpegSource), nil) else {
                throw Error.copyFailed("no destination for \(typeIdentifier)")
            }
            try copy(into: destination, from: jpegSource)
            let spliced = try splicedHeader(from: copied as Data, into: original)
            try SafeFileWriter.replace(url) { temp in
                guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
                }
                let handle = try FileHandle(forWritingTo: temp)
                do {
                    try handle.write(contentsOf: spliced.header)
                    try handle.write(contentsOf: original[(original.startIndex + spliced.scanStart)...])
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                // The file about to replace the original must say what
                // ImageIO's copy says, or the original stays.
                let written = CGImageSourceCreateWithURL(temp as CFURL, nil)
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, CGImageSourceGetPrimaryImageIndex($0), nil) as? [CFString: Any] }
                guard (written?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1 == next.rawValue else {
                    throw Error.copyFailed("the orientation didn't take")
                }
            }
            return
        }

        try SafeFileWriter.replace(url) { temp in
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, typeIdentifier, CGImageSourceGetCount(source), nil) else {
                throw Error.copyFailed("no destination for \(typeIdentifier)")
            }
            try copy(into: destination, from: source)
        }
    }

    /// The original JPEG's header (everything before its first scan) with
    /// the EXIF and XMP segments replaced by those of ImageIO's `rewritten`
    /// copy, and where the original's scan starts; the caller appends the
    /// original from there. Everything from the first scan on must be
    /// identical in both files, or this throws: that is the promise that
    /// the image data is untouched. An EXIF or XMP segment the copy gained
    /// goes after the JFIF segment, which must stay first. An MPF index is
    /// kept from the original and its offsets corrected for the new size.
    static func splicedHeader(from rewritten: Data, into original: Data) throws -> (header: Data, scanStart: Int) {
        try original.withUnsafeBytes { o -> (header: Data, scanStart: Int) in
            try rewritten.withUnsafeBytes { r -> (header: Data, scanStart: Int) in
                guard let oldHeader = JPEGComment.header(of: o), let oldScan = oldHeader.scanStart,
                      let newHeader = JPEGComment.header(of: r), let newScan = newHeader.scanStart else {
                    throw Error.copyFailed("unreadable JPEG header")
                }
                let tail = o.count - oldScan
                guard tail == r.count - newScan, memcmp(o.baseAddress! + oldScan, r.baseAddress! + newScan, tail) == 0 else {
                    throw Error.copyFailed("the image data would have changed")
                }
                func bytes(_ segment: JPEGComment.Segment) -> Data { Data(r[segment.start..<segment.end]) }
                var exif = newHeader.segments.first { isEXIF($0, in: r) }.map(bytes)
                var xmp = newHeader.segments.first { isXMP($0, in: r) }.map(bytes)

                var pieces: [JPEGComment.Piece] = []
                for segment in oldHeader.segments {
                    if isEXIF(segment, in: o), let replacement = exif {
                        pieces.append(.bytes(replacement))
                        exif = nil
                    } else if isXMP(segment, in: o), let replacement = xmp {
                        pieces.append(.bytes(replacement))
                        xmp = nil
                    } else {
                        pieces.append(.segment(segment))
                    }
                }
                let afterJFIF = pieces.prefix {
                    if case .segment(let segment) = $0 { segment.marker == 0xE0 } else { false }
                }.count
                pieces.insert(contentsOf: [exif, xmp].compactMap { $0 }.map(JPEGComment.Piece.bytes), at: afterJFIF)
                return (JPEGComment.assemble(pieces, from: o, scanStart: oldScan), oldScan)
            }
        }
    }

    static func isEXIF(_ segment: JPEGComment.Segment, in raw: UnsafeRawBufferPointer) -> Bool {
        hasSignature(segment, marker: 0xE1, Array("Exif\0".utf8), in: raw)
    }

    static func isXMP(_ segment: JPEGComment.Segment, in raw: UnsafeRawBufferPointer) -> Bool {
        hasSignature(segment, marker: 0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8), in: raw)
    }

    static func hasSignature(_ segment: JPEGComment.Segment, marker: UInt8, _ signature: [UInt8], in raw: UnsafeRawBufferPointer) -> Bool {
        segment.marker == marker && segment.end - segment.payloadStart >= signature.count
            && raw[segment.payloadStart..<segment.payloadStart + signature.count].elementsEqual(signature)
    }

    /// The content type check behind `apply`: a .jpg may really be a PNG
    /// (which is fine) or a GIF (which isn't).
    static func isSupported(_ type: UTType) -> Bool {
        guard !type.conforms(to: .rawImage) else { return false }
        return [UTType.jpeg, .heic, .heif, .tiff, .png].contains { type.conforms(to: $0) }
    }

    /// Whether the file's contents are a camera raw, whatever its name.
    /// ImageIO decides between "raw" and an ordinary type by the extension:
    /// a NEF renamed .jpg, .png, .heic or .tif is reported as `public.tiff`,
    /// and its small first image would be rewritten happily (measured). So
    /// every file gets a look at its first bytes before anything is written.
    static func isCameraRaw(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16) else { return false }
        return hasRawSignature([UInt8](head)) || isCameraRawTIFF(url)
    }

    /// Raw formats that aren't plain TIFF, recognised by their magic bytes:
    /// Fujifilm RAF, Canon CR3 (an ISO media file of brand "crx ") and CRW,
    /// Olympus ORF, Panasonic RW2, Sigma X3F and Minolta MRW.
    static func hasRawSignature(_ bytes: [UInt8]) -> Bool {
        func at(_ offset: Int, _ signature: [UInt8]) -> Bool {
            bytes.count >= offset + signature.count && bytes[offset..<offset + signature.count].elementsEqual(signature)
        }
        return at(0, Array("FUJIFILMCCD-RAW".utf8))
            || at(4, Array("ftypcrx ".utf8))
            || at(6, Array("HEAPCCDR".utf8))
            || at(0, [0x49, 0x49, 0x52, 0x4F]) || at(0, [0x49, 0x49, 0x52, 0x53]) || at(0, [0x4D, 0x4D, 0x4F, 0x52])
            || at(0, [0x49, 0x49, 0x55, 0x00])
            || at(0, Array("FOVb".utf8))
            || at(0, [0x00, 0x4D, 0x52, 0x4D])
    }

    /// Most camera raw formats (NEF, DNG, CR2, ARW, PEF...) are TIFF files
    /// underneath, so TIFF-structured files get a look at their first
    /// directory, which is a few hundred bytes at the start of the file.
    /// Signs of a raw:
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
