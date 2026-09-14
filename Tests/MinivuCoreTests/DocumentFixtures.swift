import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Documents and animations made on the fly, so the tests need no files
/// checked in.
enum DocumentFixtures {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-core-documents-\(getpid())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    // MARK: - Reading pixels

    /// RGBA bytes of an image drawn into sRGB, rows top first.
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            bytes = data
        }

        /// (r, g, b, a) at column x, row y from the top.
        subscript(x: Int, y: Int) -> [UInt8] {
            let i = (y * width + x) * 4
            return Array(bytes[i..<i + 4])
        }

        func isNear(_ x: Int, _ y: Int, _ rgba: [UInt8], tolerance: Int = 12) -> Bool {
            zip(self[x, y], rgba).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
        }
    }

    static let red: [UInt8] = [255, 0, 0, 255]
    static let white: [UInt8] = [255, 255, 255, 255]
    static let blue: [UInt8] = [0, 0, 255, 255]
    static let clear: [UInt8] = [0, 0, 0, 0]

    // MARK: - PDF

    /// Two pages, each with a red block in the top-left corner of what the
    /// page shows:
    ///
    /// 1. 300 x 200 pt media box cropped to the 200 x 100 pt rectangle at
    ///    (50, 50). The red block covers the left quarter and top half of
    ///    the crop box; a blue strip lies outside it, at the far left.
    /// 2. 200 x 100 pt, red block in the left quarter and top half, and
    ///    /Rotate 90: displayed 100 x 200 pt with the block turned into the
    ///    top-right corner.
    static func twoPagePDF() -> URL {
        let url = url("pages.pdf")
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &media, nil)!

        var crop = CGRect(x: 50, y: 50, width: 200, height: 100)
        let first: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData,
            kCGPDFContextCropBox: Data(bytes: &crop, count: MemoryLayout<CGRect>.size) as CFData,
        ]
        ctx.beginPDFPage(first as CFDictionary)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 100, width: 50, height: 50))
        ctx.endPDFPage()

        var small = CGRect(x: 0, y: 0, width: 200, height: 100)
        let second: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &small, count: MemoryLayout<CGRect>.size) as CFData,
        ]
        ctx.beginPDFPage(second as CFDictionary)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
        ctx.endPDFPage()
        ctx.closePDF()

        // Core Graphics can't write /Rotate; PDFKit can.
        let document = PDFDocument(data: data as Data)!
        document.page(at: 1)!.rotation = 90
        precondition(document.write(to: url))
        return url
    }

    // MARK: - SVG

    /// 100 x 50 pt: red on the left half; on the right, a blue bar along the
    /// top 10 pt (so an upside-down render shows) and nothing below it.
    static func halfRedSVG() -> URL {
        let url = url("half.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50">
          <rect x="0" y="0" width="50" height="50" fill="#ff0000"/>
          <rect x="50" y="0" width="50" height="10" fill="#0000ff"/>
        </svg>
        """
        try! Data(svg.utf8).write(to: url)
        return url
    }

    // MARK: - Rasters

    static func solid(_ rgb: (CGFloat, CGFloat, CGFloat), width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A TIFF whose pages have different sizes and colours.
    static func multiPageTIFF() -> URL {
        let url = url("pages.tiff")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(dest, solid((1, 0, 0), width: 40, height: 20), nil)
        CGImageDestinationAddImage(dest, solid((0, 0, 1), width: 30, height: 60), nil)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    /// An animated GIF written by ImageIO: full frames of solid colours.
    static func animatedGIF(colors: [(CGFloat, CGFloat, CGFloat)], delays: [Double], loopCount: Int?,
                            width: Int = 40, height: Int = 30) -> URL {
        let url = url("anim.gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil)!
        var gif: [CFString: Any] = [:]
        if let loopCount { gif[kCGImagePropertyGIFLoopCount] = loopCount }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        for (color, delay) in zip(colors, delays) {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(dest, solid(color, width: width, height: height), props as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    /// An animated PNG written by ImageIO.
    static func animatedPNG(colors: [(CGFloat, CGFloat, CGFloat)], delays: [Double]) -> URL {
        let url = url("anim.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, colors.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
            as CFDictionary)
        for (color, delay) in zip(colors, delays) {
            let props = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(dest, solid(color, width: 20, height: 20), props as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    /// A 16 x 16 GIF written byte by byte, whose later frames are small
    /// patches over the first (which ImageIO's own encoder never writes):
    /// frame 0 is white, frame 1 adds a 4 x 4 red square at the top left,
    /// frame 2 a 4 x 4 blue square at the bottom right. Every frame keeps
    /// what came before ("do not dispose"), so the composited frame 2 shows
    /// both squares.
    static func patchedGIF() -> URL {
        var bytes: [UInt8] = Array("GIF89a".utf8)
        func le16(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        le16(16); le16(16)
        bytes += [0xF1, 0, 0]                 // 4-colour global table, background 0
        bytes += [255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 255]   // white, red, green, blue
        bytes += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]   // loop forever

        func frame(x: Int, y: Int, width: Int, height: Int, color: UInt8) {
            bytes += [0x21, 0xF9, 4, 0x04, 5, 0, 0, 0]   // do not dispose, 50 ms
            bytes += [0x2C]; le16(x); le16(y); le16(width); le16(height); bytes += [0]
            bytes += [2]   // LZW minimum code size: codes start 3 bits wide
            // Uncompressed LZW: a clear code before every two pixels keeps
            // the code table (and so the code width) from ever growing.
            var codes: [Int] = []
            let pixels = width * height
            for i in 0..<pixels {
                if i % 2 == 0 { codes.append(4) }
                codes.append(Int(color))
            }
            codes.append(5)
            var packed: [UInt8] = []
            var buffer = 0, bits = 0
            for code in codes {
                buffer |= code << bits
                bits += 3
                while bits >= 8 { packed.append(UInt8(buffer & 0xFF)); buffer >>= 8; bits -= 8 }
            }
            if bits > 0 { packed.append(UInt8(buffer & 0xFF)) }
            var offset = 0
            while offset < packed.count {
                let chunk = packed[offset..<min(offset + 255, packed.count)]
                bytes.append(UInt8(chunk.count))
                bytes += chunk
                offset += chunk.count
            }
            bytes.append(0)
        }
        frame(x: 0, y: 0, width: 16, height: 16, color: 0)
        frame(x: 0, y: 0, width: 4, height: 4, color: 1)
        frame(x: 12, y: 12, width: 4, height: 4, color: 3)
        bytes.append(0x3B)

        let url = url("patched.gif")
        try! Data(bytes).write(to: url)
        return url
    }
}
