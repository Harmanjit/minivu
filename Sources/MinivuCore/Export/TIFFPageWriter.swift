import Foundation

/// Writes a multi-page TIFF one page at a time, so a document of a hundred
/// scans never holds more than one page.
///
/// ImageIO can write a multi-page TIFF itself, but it keeps every page it is
/// given until the file is finalised and then decodes them all at once
/// (measured on macOS 27: eight 12 MP pages peak at 386 MB over the start,
/// eight times one page, and lazily decoded pages from files cost the
/// same). Instead each page is encoded on its own by ImageIO, as a complete
/// single-page TIFF (compression, colour profile and all), and appended
/// here: its bytes go to the end of the file with every offset inside them
/// moved by the distance they travelled, and the previous page's directory
/// is linked to the new one. Readers see one ordinary TIFF with a chain of
/// image directories.
///
/// Moved with a page: values stored outside their directory entry, strips,
/// tiles and an old-style JPEG thumbnail through their offset tags, and the
/// SubIFD, EXIF, GPS and Interoperability directories with everything they
/// point at (as `TIFFScrubber` follows them). A page's own second directory
/// (an embedded thumbnail, which minivu never writes) is dropped. Classic
/// TIFF only: a file past 4 GB is refused rather than written as BigTIFF,
/// which many readers can't open.
public final class TIFFPageWriter {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The encoder's page isn't a TIFF this writer can follow.
        case unreadablePage
        /// Pages written with different byte orders can't share a file.
        case mixedByteOrder
        /// The file would pass the 4 GB a classic TIFF can address.
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .unreadablePage: "A page couldn’t be added to the TIFF file."
            case .mixedByteOrder: "The pages couldn’t be joined into one TIFF file."
            case .tooLarge: "The TIFF file would be larger than 4 GB, the most a TIFF file can hold."
            }
        }
    }

    private let handle: FileHandle
    private var littleEndian: Bool?
    /// Bytes written so far.
    private var length = 0
    /// Where the offset of the next page's directory goes: the header's
    /// first-directory field, then each page's next-directory field.
    private var nextPointer = 4
    public private(set) var pageCount = 0

    /// Creates the file at `url`, which must not exist yet (the caller
    /// writes to a temporary file and puts it in place when it is whole).
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    /// Appends one page: `page` is a complete single-page TIFF, as
    /// `ImageEncoder.encode` makes with the TIFF format.
    public func append(_ page: Data) throws {
        if length == 0 {
            // The header goes in front of the first page, in its byte order;
            // the directory offset is filled in below like any other link.
            guard page.count >= 8 else { throw Failure.unreadablePage }
            try handle.write(contentsOf: page.prefix(4) + Data(count: 4))
            length = 8
        }
        // Directories start on a word boundary, so pages do too.
        if length % 2 != 0 {
            try handle.write(contentsOf: Data(count: 1))
            length += 1
        }
        let moved = try Self.relocate(page, toOffset: length)
        if let littleEndian, littleEndian != moved.littleEndian { throw Failure.mixedByteOrder }
        littleEndian = moved.littleEndian
        try handle.write(contentsOf: moved.body)
        try handle.seek(toOffset: UInt64(nextPointer))
        try handle.write(contentsOf: Self.bytes(UInt32(moved.firstDirectory), littleEndian: moved.littleEndian))
        length += moved.body.count
        try handle.seek(toOffset: UInt64(length))
        nextPointer = moved.nextPointer
        pageCount += 1
    }

    /// Flushes the file to disk and closes it. The file is complete after
    /// this; a writer abandoned before it leaves a file the caller deletes.
    public func finish() throws {
        guard pageCount > 0 else { throw Failure.unreadablePage }
        try handle.synchronize()
        try handle.close()
    }

    // MARK: - Relocation

    /// A page's bytes after its header, with every offset in them moved so
    /// they can sit at `base` in the joined file.
    struct Relocated {
        var body: Data
        var littleEndian: Bool
        /// The page's first directory, at its new place.
        var firstDirectory: Int
        /// Its next-directory field, at its new place (zeroed: the end of the
        /// chain until another page is linked there).
        var nextPointer: Int
    }

    static func relocate(_ page: Data, toOffset base: Int) throws -> Relocated {
        let source = [UInt8](page)
        let count = source.count
        guard count >= 8, base >= 8, base % 2 == 0 else { throw Failure.unreadablePage }
        let little: Bool
        switch (source[0], source[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: throw Failure.unreadablePage
        }
        func u16(_ o: Int) -> Int {
            little ? Int(source[o]) | Int(source[o + 1]) << 8 : Int(source[o]) << 8 | Int(source[o + 1])
        }
        func u32(_ o: Int) -> Int {
            little ? Int(source[o]) | Int(source[o + 1]) << 8 | Int(source[o + 2]) << 16 | Int(source[o + 3]) << 24
                   : Int(source[o]) << 24 | Int(source[o + 1]) << 16 | Int(source[o + 2]) << 8 | Int(source[o + 3])
        }
        guard u16(2) == 42 else { throw Failure.unreadablePage }   // 43 is BigTIFF
        let delta = base - 8
        guard base + count - 8 <= Int(UInt32.max) else { throw Failure.tooLarge }

        // Written in the page's own coordinates: body[i - 8] is source[i].
        var body = Array(source[8...])
        func put16(_ o: Int, _ value: Int) {
            let b = bytes(UInt16(value), littleEndian: little)
            body[o - 8] = b[0]; body[o - 7] = b[1]
        }
        func put32(_ o: Int, _ value: Int) {
            let b = bytes(UInt32(value), littleEndian: little)
            for i in 0..<4 { body[o - 8 + i] = b[i] }
        }

        let offsetTags: Set<Int> = [273, 324, 513]                  // strips, tiles, JPEG thumbnail
        let pointerTags: Set<Int> = [330, 34665, 34853, 40965]      // SubIFDs, EXIF, GPS, Interoperability
        let first = u32(4)
        var firstNext: Int?
        var pending = [first]
        var visited: Set<Int> = []
        while let directory = pending.popLast() {
            guard directory >= 8, directory % 2 == 0, directory + 2 <= count else { throw Failure.unreadablePage }
            guard visited.insert(directory).inserted else { continue }
            let entries = u16(directory)
            let next = directory + 2 + entries * 12
            guard next + 4 <= count else { throw Failure.unreadablePage }
            for index in 0..<entries {
                let entry = directory + 2 + index * 12
                let tag = u16(entry), type = u16(entry + 2), values = u32(entry + 4)
                guard let size = valueSize(type) else { throw Failure.unreadablePage }
                let (total, overflow) = size.multipliedReportingOverflow(by: values)
                guard !overflow else { throw Failure.unreadablePage }
                var at = entry + 8
                if total > 4 {
                    at = u32(entry + 8)
                    guard at >= 8, at + total <= count else { throw Failure.unreadablePage }
                    put32(entry + 8, at + delta)
                }
                guard offsetTags.contains(tag) || pointerTags.contains(tag) else { continue }
                for k in 0..<values {
                    let position = at + k * size
                    switch size {
                    case 2:
                        let moved = u16(position) + delta
                        if moved <= 0xFFFF {
                            put16(position, moved)
                        } else if values == 1 {
                            // A lone SHORT offset that no longer fits becomes a
                            // LONG in the same four bytes.
                            put16(entry + 2, 4)
                            put32(entry + 8, moved)
                        } else {
                            throw Failure.unreadablePage
                        }
                        if pointerTags.contains(tag) { pending.append(u16(position)) }
                    case 4:
                        put32(position, u32(position) + delta)
                        if pointerTags.contains(tag) { pending.append(u32(position)) }
                    default:
                        throw Failure.unreadablePage
                    }
                }
            }
            if directory == first {
                // The page's own chain (a thumbnail directory) ends here; the
                // next page will be linked in its place.
                put32(next, 0)
                firstNext = next
            } else if u32(next) != 0 {
                pending.append(u32(next))
                put32(next, u32(next) + delta)
            }
        }
        guard let firstNext else { throw Failure.unreadablePage }
        return Relocated(body: Data(body), littleEndian: little, firstDirectory: first + delta,
                         nextPointer: firstNext + delta)
    }

    /// The size of one value of a TIFF field type, or nil for a type this
    /// writer doesn't know (it then refuses rather than guess).
    static func valueSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: nil
        }
    }

    static func bytes(_ value: UInt32, littleEndian: Bool) -> [UInt8] {
        let v = littleEndian ? value.littleEndian : value.bigEndian
        return withUnsafeBytes(of: v) { Array($0) }
    }

    static func bytes(_ value: UInt16, littleEndian: Bool) -> [UInt8] {
        let v = littleEndian ? value.littleEndian : value.bigEndian
        return withUnsafeBytes(of: v) { Array($0) }
    }
}
