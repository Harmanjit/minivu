import Foundation

/// Clears the bytes of a TIFF file that nothing in it refers to.
///
/// ImageIO rewrites a TIFF's metadata in the old file's layout: a record
/// that got shorter is written over the old one and the rest of the old one
/// stays where it was, no longer part of any tag but still in the file. A
/// title the user cleared, or the city Remove location was meant to take
/// out, can be read back with a hex editor (measured on macOS 27). This
/// walks every directory, marks every byte a tag points at, and zeroes the
/// rest; readers never look there, so the file reads exactly as before.
///
/// Followed: the chain of image directories, SubIFDs and the EXIF, GPS and
/// Interoperability directories; every value stored outside its entry;
/// strips, tiles and an old-style JPEG thumbnail through their offset and
/// byte-count tags. FreeOffsets is deliberately not followed: it names
/// space that is unused by definition. A maker note is kept as the blob its
/// tag names; one that points outside itself (rare outside camera raw
/// files, which minivu never writes) would lose what lies outside.
enum TIFFScrubber {
    /// Zeroes everything outside the header, the directories and what they
    /// point at. False, with `data` untouched, when the structure can't be
    /// followed (BigTIFF, an unknown value type, an offset past the end):
    /// the caller then refuses the write rather than guess.
    static func zeroUnreferencedBytes(in data: inout Data) -> Bool {
        guard let used = referencedRanges(in: data) else { return false }
        // The gaps between the ranges, merged in order: no per-byte map,
        // since a 16-bit TIFF of a large photo is hundreds of megabytes.
        data.withUnsafeMutableBytes { bytes in
            var cursor = 0
            for range in used.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if range.lowerBound > cursor {
                    for i in cursor..<range.lowerBound { bytes[i] = 0 }
                }
                cursor = max(cursor, range.upperBound)
            }
            for i in cursor..<bytes.count { bytes[i] = 0 }
        }
        return true
    }

    /// Every byte range the file's structure refers to, or nil if it can't
    /// be followed.
    static func referencedRanges(in data: Data) -> [Range<Int>]? {
        data.withUnsafeBytes { referencedRanges(in: $0) }
    }

    static func referencedRanges(in b: UnsafeRawBufferPointer) -> [Range<Int>]? {
        guard b.count >= 8 else { return nil }
        let little: Bool
        switch (b[0], b[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ o: Int) -> Int { little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                   : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        guard u16(2) == 42 else { return nil }   // 43 is BigTIFF

        var ranges: [Range<Int>] = [0..<8]
        var visited: Set<Int> = []
        var pending = [u32(4)]
        let pointerTags: Set<Int> = [330, 34665, 34853, 40965]   // SubIFDs, EXIF, GPS, Interoperability
        let dataPairs = [(273, 279), (324, 325), (513, 514)]       // strips, tiles, JPEG thumbnail

        func size(ofType type: Int) -> Int? {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12: 8
            default: nil
            }
        }

        while let ifd = pending.popLast() {
            guard ifd != 0 else { continue }
            guard !visited.contains(ifd) else { continue }
            visited.insert(ifd)
            guard ifd + 2 <= b.count else { return nil }
            let count = u16(ifd)
            let end = ifd + 2 + count * 12 + 4
            guard end <= b.count else { return nil }
            ranges.append(ifd..<end)
            var values: [Int: [Int]] = [:]
            for i in 0..<count {
                let entry = ifd + 2 + i * 12
                let tag = u16(entry), type = u16(entry + 2), n = u32(entry + 4)
                guard let unit = size(ofType: type) else { return nil }
                let total = unit * n
                let location: Int
                if total > 4 {
                    location = u32(entry + 8)
                    guard location + total <= b.count else { return nil }
                    ranges.append(location..<location + total)
                } else {
                    location = entry + 8
                }
                // The numbers of the tags that point somewhere.
                if pointerTags.contains(tag) || dataPairs.contains(where: { $0.0 == tag || $0.1 == tag }) {
                    guard unit == 2 || unit == 4 else { return nil }
                    values[tag] = (0..<n).map { unit == 2 ? u16(location + $0 * 2) : u32(location + $0 * 4) }
                }
            }
            for tag in pointerTags { pending += values[tag] ?? [] }
            for (offsets, counts) in dataPairs {
                guard let starts = values[offsets] else { continue }
                let lengths = values[counts] ?? []
                guard lengths.count == starts.count else { return nil }
                for (start, length) in zip(starts, lengths) where length > 0 {
                    guard start + length <= b.count else { return nil }
                    ranges.append(start..<start + length)
                }
            }
            pending.append(u32(end - 4))
        }
        return ranges
    }
}
