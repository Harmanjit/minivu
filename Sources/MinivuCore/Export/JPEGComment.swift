import Foundation

/// Reads and writes the JPEG COM (comment) segment, which FastStone and many
/// older tools use for captions. ImageIO neither reports nor writes it, so
/// this walks the file's segments by hand.
///
/// A JPEG file is a list of segments, each `FF xx` (the marker) followed,
/// for most markers, by a two-byte big-endian length that counts itself
/// and the payload:
///
///     FF D8                  SOI, start of image
///     FF E0 len "JFIF"...    APP0..APP15: JFIF, EXIF, ICC, XMP, MPF...
///     FF FE len text         COM
///     FF DB len ...          quantisation tables, then Huffman tables, frame header
///     FF DA len ...          SOS, start of scan: compressed data follows up to FF D9
///
/// Writing only rebuilds the part before the first SOS and copies
/// everything from SOS to the end of the file unchanged, so the compressed
/// image is never decoded or touched. Comments after the first scan (a
/// progressive file can technically have them between scans) are left alone.
public enum JPEGComment {
    public enum Error: Swift.Error, Equatable {
        /// The file doesn't start with a JPEG SOI marker.
        case notJPEG
        /// The segments before the image data are truncated or corrupt.
        case malformed
    }

    /// The largest payload one COM segment holds: the length field is 16
    /// bits and counts its own two bytes.
    static let maxPayload = 65_533

    /// The comment text, or nil if the file has none (or isn't a JPEG).
    /// A long comment we split over several segments reads back exactly as
    /// written; separate comments (several tools each adding their own) are
    /// joined with line breaks, each decoded on its own, so one Latin-1
    /// comment doesn't garble a UTF-8 one next to it.
    public static func read(from url: URL) -> String? {
        guard let data = headerData(at: url) else { return nil }
        let text = joined(commentPayloads(in: data))
        return text.isEmpty ? nil : text
    }

    /// Rewrites (or inserts, or removes when empty) the COM segment without
    /// touching compressed image data; atomic; the rest of the file is
    /// byte-identical, with one necessary exception: in a file with an MPF
    /// index (an HDR gain map, a stereo pair) the offsets to the secondary
    /// images are moved by the change in size, because they count from a
    /// point before the comment. (ImageIO still finds a gain map behind a
    /// stale index, measured, but readers that follow the index don't.)
    ///
    /// Every existing COM segment is replaced by the new one, placed right
    /// after the APPn segments at the start of the file (JFIF and EXIF must
    /// come first). Writing the comment a file already has doesn't touch it.
    public static func write(_ comment: String, to url: URL) throws {
        // Mapped, not read: only the header pages are faulted in to parse,
        // and the rest streams straight from the page cache into the new file.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let rewrite = try rewrittenHeader(of: data, commentPayloads: payloads(of: comment)) else { return }
        try SafeFileWriter.replace(url) { temp in
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
            }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: rewrite.header)
            try handle.write(contentsOf: data[(data.startIndex + rewrite.scanStart)...])
        }
        OwnWrites.record(url)
    }

    /// The same edit in memory, with raw payloads, which keeps comments in
    /// an unknown encoding byte for byte (the lossless rotate puts them back
    /// this way).
    static func replacingComments(in data: Data, withPayloads payloads: [Data]) throws -> Data {
        guard let rewrite = try rewrittenHeader(of: data, commentPayloads: payloads) else { return data }
        var result = rewrite.header
        result.append(data[(data.startIndex + rewrite.scanStart)...])
        return result
    }

    /// The raw bytes of each COM segment before the first scan, in file
    /// order. Lenient: a damaged header yields the comments found before
    /// the damage. MetadataReader uses this to show comments.
    static func commentPayloads(in data: Data) -> [Data] {
        data.withUnsafeBytes { raw -> [Data] in
            guard let header = header(of: raw) else { return [] }
            return header.segments.filter { $0.marker == 0xFE }.map { Data(raw[$0.payloadStart..<$0.end]) }
        }
    }

    /// Comment payloads as text, per segment. Comments have no declared
    /// encoding: modern tools write UTF-8, old Windows ones Latin-1, and
    /// every byte sequence is valid Latin-1, so that is the fallback.
    static func commentTexts(at url: URL) -> [String] {
        guard let data = headerData(at: url) else { return [] }
        return commentPayloads(in: data).map(decode)
    }

    static func decode(_ payload: Data) -> String {
        String(data: payload, encoding: .utf8) ?? String(data: payload, encoding: .isoLatin1) ?? ""
    }

    /// Payloads back to one string. A payload within 3 bytes of the limit is
    /// a piece `chunks(of:)` cut (it backs up at most 3 bytes to a character
    /// boundary), so the next one continues it directly; anything shorter
    /// ended a comment of its own.
    static func joined(_ payloads: [Data]) -> String {
        var text = ""
        var previousWasFull = false
        for (index, payload) in payloads.enumerated() {
            let piece = decode(payload).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if index > 0, !previousWasFull, !piece.isEmpty, !text.isEmpty { text += "\n" }
            text += piece
            previousWasFull = payload.count >= maxPayload - 3
        }
        return text
    }

    /// The start of the file up to and including the first SOS marker,
    /// read in growing pieces rather than mapped: browsing calls this for
    /// every JPEG, and a mapped file that another program truncates (or a
    /// network volume that goes away) crashes the reader with SIGBUS the
    /// moment a vanished page is touched, where a read just fails. Most
    /// headers fit in the first 64 KB; big ICC profiles or XMP take a
    /// second read. Nil if the file can't be read or isn't a JPEG.
    static func headerData(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        var chunk = 64 * 1024
        while true {
            guard let more = try? handle.read(upToCount: chunk) else { return data.isEmpty ? nil : data }
            data.append(more)
            guard let parsed = data.withUnsafeBytes({ header(of: $0) }) else { return nil }
            if parsed.scanStart != nil || !parsed.truncated || more.count < chunk { return data }
            chunk *= 2
        }
    }

    // MARK: - Segments

    struct Segment: Equatable {
        var marker: UInt8
        /// Offset of the first 0xFF, including any fill bytes before the marker.
        var start: Int
        /// Offset of the payload, after the length field.
        var payloadStart: Int
        /// Offset just past the segment.
        var end: Int
    }

    struct Header {
        /// Segments between SOI and the first SOS.
        var segments: [Segment]
        /// Offset of the first SOS marker, or nil if the header is damaged
        /// or the file ends before any image data.
        var scanStart: Int?
        /// The bytes ran out in the middle of the header (as opposed to
        /// the header being damaged), so reading more of the file may help.
        var truncated = false
    }

    /// Walks the segments from SOI to the first SOS. Nil if the bytes don't
    /// start with SOI.
    static func header(of bytes: UnsafeRawBufferPointer) -> Header? {
        let count = bytes.count
        guard count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var segments: [Segment] = []
        var pos = 2
        while pos < count {
            guard bytes[pos] == 0xFF else { break }
            let start = pos
            // Any number of 0xFF fill bytes may pad a marker. They are kept
            // as part of the segment that follows, so a kept segment is
            // copied exactly as it was, padding included.
            while pos < count, bytes[pos] == 0xFF { pos += 1 }
            guard pos < count else { return Header(segments: segments, scanStart: nil, truncated: true) }
            let marker = bytes[pos]
            pos += 1
            switch marker {
            case 0xDA:
                return Header(segments: segments, scanStart: start)
            case 0xD9, 0x00:
                // End of image before any scan, or a stuffed zero that only
                // belongs inside compressed data: nothing to trust here.
                return Header(segments: segments, scanStart: nil)
            case 0x01, 0xD0...0xD7:
                // TEM and RSTn stand alone, with no length field.
                segments.append(Segment(marker: marker, start: start, payloadStart: pos, end: pos))
            default:
                guard pos + 2 <= count else { return Header(segments: segments, scanStart: nil, truncated: true) }
                let length = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
                guard length >= 2 else { return Header(segments: segments, scanStart: nil) }
                guard pos + length <= count else { return Header(segments: segments, scanStart: nil, truncated: true) }
                segments.append(Segment(marker: marker, start: start, payloadStart: pos + 2, end: pos + length))
                pos += length
            }
        }
        return Header(segments: segments, scanStart: nil, truncated: pos >= count)
    }

    /// The new bytes before the first SOS, and where SOS was in the
    /// original. Nil when the new header is identical to the old one.
    static func rewrittenHeader(of data: Data, commentPayloads: [Data]) throws -> (header: Data, scanStart: Int)? {
        try data.withUnsafeBytes { raw -> (header: Data, scanStart: Int)? in
            guard let parsed = header(of: raw) else { throw Error.notJPEG }
            guard let scanStart = parsed.scanStart else { throw Error.malformed }

            let kept = parsed.segments.filter { $0.marker != 0xFE }
            var insertAt = 0
            while insertAt < kept.count, (0xE0...0xEF).contains(kept[insertAt].marker) { insertAt += 1 }

            var pieces = kept[..<insertAt].map(Piece.segment)
            pieces += commentPayloads.map { .bytes(comSegment($0)) }
            pieces += kept[insertAt...].map(Piece.segment)
            let out = assemble(pieces, from: raw, scanStart: scanStart)
            return out.elementsEqual(raw[0..<scanStart]) ? nil : (out, scanStart)
        }
    }

    /// One part of a rebuilt header: a segment copied from the original
    /// file, or new bytes (a whole segment, marker included).
    enum Piece {
        case segment(Segment)
        case bytes(Data)
    }

    /// A COM segment around a payload of at most `maxPayload` bytes.
    static func comSegment(_ payload: Data) -> Data {
        let length = payload.count + 2
        var segment = Data([0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)])
        segment.append(payload)
        return segment
    }

    static func payloads(of comment: String) -> [Data] {
        chunks(of: comment).map { Data($0) }
    }

    /// SOI plus `pieces`: the new bytes that replace everything before the
    /// original's first scan at `scanStart`. Everything from there on is
    /// copied unchanged by the caller, so if an MPF index is among the
    /// copied segments, its offsets to the secondary images (an HDR gain
    /// map, a stereo pair) are corrected here. They count from the MP
    /// header, 4 bytes into the MPF payload. The images sit after the scan,
    /// which moves by the total change in header size; the MP header moves
    /// by the change in size before it.
    static func assemble(_ pieces: [Piece], from raw: UnsafeRawBufferPointer, scanStart: Int) -> Data {
        var out = Data(capacity: scanStart + 1024)
        out.append(contentsOf: [0xFF, 0xD8])
        var mpf: (segment: Segment, newStart: Int)?
        for piece in pieces {
            switch piece {
            case .segment(let segment):
                if mpf == nil, isMPF(segment, in: raw) { mpf = (segment, out.count) }
                out.append(contentsOf: raw[segment.start..<segment.end])
            case .bytes(let bytes):
                out.append(bytes)
            }
        }
        if let mpf {
            let headerOffset = mpf.segment.payloadStart - mpf.segment.start + 4
            let movedHeader = mpf.newStart - mpf.segment.start
            let movedImages = out.count - scanStart
            let shift = movedImages - movedHeader
            if shift != 0 {
                patchMPFOffsets(in: &out, header: mpf.newStart + headerOffset,
                                end: mpf.newStart + (mpf.segment.end - mpf.segment.start), shift: shift)
            }
        }
        return out
    }

    /// Splits UTF-8 text into segment-sized pieces, never inside a
    /// multi-byte character, so each piece is valid UTF-8 on its own for
    /// readers that decode segments separately.
    static func chunks(of comment: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(comment.utf8)
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        while start < bytes.count {
            var end = min(start + maxPayload, bytes.count)
            // 10xxxxxx is a continuation byte: back up to the character's start.
            if end < bytes.count {
                while end > start + 1, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            }
            result.append(bytes[start..<end])
            start = end
        }
        return result
    }

    static func isMPF(_ segment: Segment, in raw: UnsafeRawBufferPointer) -> Bool {
        segment.marker == 0xE2 && segment.end - segment.payloadStart >= 12
            && raw[segment.payloadStart..<segment.payloadStart + 4].elementsEqual([0x4D, 0x50, 0x46, 0x00])   // "MPF\0"
    }

    /// Adds `shift` to every non-zero image offset in the MP Entry table
    /// (tag 0xB002) of an MPF segment. The MP header is a little TIFF file:
    /// byte order, magic, offset of the first IFD, then 12-byte IFD entries.
    /// Each MP entry is 16 bytes: attributes, size, offset, two dependents.
    /// The first image's offset is 0 by definition and stays 0. Anything out
    /// of bounds leaves the segment as it was.
    static func patchMPFOffsets(in data: inout Data, header: Int, end: Int, shift: Int) {
        data.withUnsafeMutableBytes { p in
            guard header >= 0, end <= p.count, end - header >= 8 else { return }
            let little: Bool
            switch (p[header], p[header + 1]) {
            case (0x49, 0x49): little = true    // "II"
            case (0x4D, 0x4D): little = false   // "MM"
            default: return
            }
            func u16(_ o: Int) -> Int {
                little ? Int(p[o]) | Int(p[o + 1]) << 8 : Int(p[o]) << 8 | Int(p[o + 1])
            }
            func u32(_ o: Int) -> Int {
                little ? Int(p[o]) | Int(p[o + 1]) << 8 | Int(p[o + 2]) << 16 | Int(p[o + 3]) << 24
                       : Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3])
            }
            func put32(_ o: Int, _ v: Int) {
                let b = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
                for i in 0..<4 { p[o + i] = little ? b[3 - i] : b[i] }
            }
            let ifd = header + u32(header + 4)
            guard ifd >= header, ifd + 2 <= end else { return }
            for i in 0..<u16(ifd) {
                let entry = ifd + 2 + i * 12
                guard entry + 12 <= end else { return }
                guard u16(entry) == 0xB002 else { continue }
                let byteCount = u32(entry + 4)
                let table = header + u32(entry + 8)
                guard byteCount % 16 == 0, table >= header, table + byteCount <= end else { return }
                for field in stride(from: table + 8, to: table + byteCount, by: 16) {
                    let offset = u32(field)
                    let moved = offset + shift
                    if offset != 0, moved > 0, moved <= Int(UInt32.max) { put32(field, moved) }
                }
            }
        }
    }
}
