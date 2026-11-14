import Foundation

/// Image files whose headers claim more than they hold. MinivuCoreTests
/// builds the same PNG (`TestImages.forgedPNG`); test targets can't share
/// helpers, so this is a copy.
enum ForgedImages {
    /// A PNG whose header claims `width` x `height` while the file holds
    /// only `rows` scanlines of black, stored uncompressed: what a file that
    /// costs kilobytes to keep and gigabytes to decode looks like. ImageIO
    /// won't describe a file whose pixel data is missing altogether, so it
    /// carries three rows by default (360 KB at 40000 px).
    @discardableResult
    static func png(width: Int, height: Int, rows: Int = 3, to url: URL) throws -> URL {
        let rowBytes = 1 + width * 3                            // a filter byte, then 8-bit RGB
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", be(UInt32(width)) + be(UInt32(height)) + [8, 2, 0, 0, 0])
        file += chunk("IDAT", zlibZeros(count: rowBytes * rows))
        file += chunk("IEND", [])
        try Data(file).write(to: url)
        return url
    }

    /// A PNG chunk: its payload's length, its type, the payload, and the
    /// CRC-32 over type and payload.
    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        return be(UInt32(payload.count)) + body + be(crc32(body))
    }

    private static func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// `count` zero bytes as a zlib stream of stored deflate blocks, so the
    /// fixture needs no compressor.
    private static func zlibZeros(count: Int) -> [UInt8] {
        var stream: [UInt8] = [0x78, 0x01]
        var written = 0
        while written < count {
            let n = min(65535, count - written)
            stream += [written + n == count ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8),
                       UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            stream += [UInt8](repeating: 0, count: n)
            written += n
        }
        // Adler-32 of a run of zeros: the running sum stays 1, and the sum
        // of those sums simply counts the bytes.
        return stream + be(UInt32(count % 65521) << 16 | 1)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
