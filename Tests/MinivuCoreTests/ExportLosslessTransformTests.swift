import Testing
import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers
@testable import MinivuCore

@Suite struct ExportLosslessTransformTests {
    typealias F = ExportFixtures
    typealias Kind = LosslessTransform.Kind

    /// Worked out by hand from the EXIF definitions, one row per starting
    /// orientation 1...8, columns: clockwise, counterclockwise, 180°,
    /// flip horizontal, flip vertical. E.g. 6 ("rotate 90° CW to view")
    /// turned clockwise again is 3 (180°), and mirrored left-right is 5.
    static let table: [UInt32: [UInt32]] = [
        1: [6, 8, 3, 2, 4],
        2: [7, 5, 4, 1, 3],
        3: [8, 6, 1, 4, 2],
        4: [5, 7, 2, 3, 1],
        5: [2, 4, 7, 6, 8],
        6: [3, 1, 8, 5, 7],
        7: [4, 2, 5, 8, 6],
        8: [1, 3, 6, 7, 5],
    ]
    static let kinds: [Kind] = [.rotateClockwise, .rotateCounterclockwise, .rotate180, .flipHorizontal, .flipVertical]

    @Test func compositionTable() {
        for (start, expected) in Self.table {
            let orientation = CGImagePropertyOrientation(rawValue: start)!
            let actual = Self.kinds.map { LosslessTransform.orientation(orientation, applying: $0).rawValue }
            #expect(actual == expected, "orientation \(start)")
        }
    }

    @Test func inversesUndoEachOther() {
        for orientation in LosslessTransform.allOrientations {
            let there = LosslessTransform.orientation(orientation, applying: .rotateClockwise)
            #expect(LosslessTransform.orientation(there, applying: .rotateCounterclockwise) == orientation)
            let flipped = LosslessTransform.orientation(orientation, applying: .flipHorizontal)
            #expect(LosslessTransform.orientation(flipped, applying: .flipHorizontal) == orientation)
            var spun = orientation
            for _ in 0..<4 { spun = LosslessTransform.orientation(spun, applying: .rotateClockwise) }
            #expect(spun == orientation)
        }
    }

    /// The table agrees with how ImageIO displays the result: for every
    /// starting orientation and kind, the upright image after the change
    /// is the upright image before it, rotated or flipped.
    @Test func displayedPixelsMatchImageIO() throws {
        let t = try TemporaryFolder()
        // A 6 x 4 grid of different colours, so any wrong turn shows; each
        // cell `cell` pixels wide.
        func grid(cell: Int) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: 6 * cell, height: 4 * cell, bitsPerComponent: 8, bytesPerRow: 0, space: F.sRGB,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            for y in 0..<4 { for x in 0..<6 {
                ctx.setFillColor(CGColor(srgbRed: CGFloat(x * 40) / 255, green: CGFloat(y * 60) / 255, blue: CGFloat((x + y) * 20) / 255, alpha: 1))
                ctx.fill(CGRect(x: x * cell, y: (3 - y) * cell, width: cell, height: cell))
            }}
            return try #require(ctx.makeImage())
        }

        func displayed(_ url: URL, size: Int) throws -> (w: Int, h: Int, px: [UInt8]) {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
            return (image.width, image.height, F.pixels(of: image))
        }
        func transformed(_ before: (w: Int, h: Int, px: [UInt8]), _ kind: Kind) -> (w: Int, h: Int, px: [UInt8]) {
            let (bw, bh) = (before.w, before.h)
            let swap = kind == .rotateClockwise || kind == .rotateCounterclockwise
            let (nw, nh) = swap ? (bh, bw) : (bw, bh)
            var out = [UInt8](repeating: 0, count: nw * nh * 4)
            for y in 0..<nh { for x in 0..<nw {
                let (sx, sy): (Int, Int) = switch kind {
                case .rotateClockwise: (y, bh - 1 - x)
                case .rotateCounterclockwise: (bw - 1 - y, x)
                case .rotate180: (bw - 1 - x, bh - 1 - y)
                case .flipHorizontal: (bw - 1 - x, y)
                case .flipVertical: (x, bh - 1 - y)
                }
                for c in 0..<4 { out[(y * nw + x) * 4 + c] = before.px[(sy * bw + sx) * 4 + c] }
            }}
            return (nw, nh, out)
        }

        // All four formats: each stores orientation its own way (TIFF tag,
        // EXIF in a JPEG APP1, PNG eXIf chunk, HEIF item properties). The
        // stored pixels never change, so TIFF, PNG and even JPEG compare
        // exactly, one pixel per cell. ImageIO's HEIC decoder upsamples
        // chroma differently for each orientation (up to 25 levels apart on
        // single pixels, measured), so HEIC gets 12 px cells and is compared
        // at the cell centres, which still tells every orientation apart.
        let cases: [(type: UTType, cell: Int)] = [(.tiff, 1), (.jpeg, 1), (.png, 1), (.heic, 12)]
        for (type, cell) in cases {
            let stored = try grid(cell: cell)
            for orientation in LosslessTransform.allOrientations {
                for kind in Self.kinds {
                    let name = "o\(orientation.rawValue)-\(kind).\(type.preferredFilenameExtension!)"
                    let url = TestImages.write(stored, to: t.url.appendingPathComponent(name), type: type,
                                               properties: [kCGImagePropertyOrientation: orientation.rawValue])
                    let before = try displayed(url, size: 6 * cell)
                    try LosslessTransform.apply(kind, to: url)
                    let after = try displayed(url, size: 6 * cell)
                    let expected = transformed(before, kind)
                    #expect(after.w == expected.w && after.h == expected.h, "\(name)")
                    guard after.w == expected.w, after.h == expected.h else { continue }
                    if cell == 1 {
                        #expect(after.px == expected.px, "\(name)")
                    } else {
                        var worst = 0
                        for cy in stride(from: cell / 2, to: after.h, by: cell) {
                            for cx in stride(from: cell / 2, to: after.w, by: cell) {
                                let a = F.pixel(after.px, width: after.w, x: cx, y: cy), e = F.pixel(expected.px, width: expected.w, x: cx, y: cy)
                                worst = max(worst, zip(a, e).map { abs($0 - $1) }.max()!)
                            }
                        }
                        #expect(worst <= 6, "\(name): \(worst)")
                    }
                }
            }
        }
    }

    @Test func jpegImageDataIsUntouched() throws {
        let t = try TemporaryFolder()
        let url = try F.taggedJPEG(in: t.url, orientation: .up, comment: "Keep me")
        let scan = try F.scanData(url)
        let original = try Data(contentsOf: url)
        let pixels = F.pixels(of: try #require(F.decode(url)))

        try LosslessTransform.apply(.rotateClockwise, to: url)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 6)
        #expect(try F.scanData(url) == scan)
        #expect(F.pixels(of: try #require(F.decode(url))) == pixels)
        #expect(JPEGComment.read(from: url) == "Keep me")
        #expect(MetadataReader.summary(for: url).pixelSize == CGSize(width: 48, height: 64))

        try LosslessTransform.apply(.rotateCounterclockwise, to: url)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(try Data(contentsOf: url) == original)   // the tag was patched in place, then back
    }

    /// A JPEG without an orientation tag: ImageIO rebuilds its header and,
    /// left to itself, drops COM comments and unknown APPn segments. Every
    /// segment but EXIF must come through byte for byte.
    @Test func jpegWithoutAnOrientationTagKeepsEveryOtherSegment() throws {
        let t = try TemporaryFolder()
        let url = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("untagged.jpg"),
                                   properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Maker"]])
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] == nil)
        var bytes = [UInt8](try Data(contentsOf: url))
        let jfifEnd = try #require(F.segments(url).first).bytes.count + 2
        let app3: [UInt8] = [0xFF, 0xE3, 0x00, 0x08] + Array("META".utf8) + [1, 2]
        let latin1Comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x07] + [0x43, 0x61, 0x66, 0xE9, 0x21]   // "Café!" in Latin-1
        bytes.insert(contentsOf: app3 + latin1Comment, at: jfifEnd)
        try Data(bytes).write(to: url)
        let before = try F.segments(url)
        let scan = try F.scanData(url)

        try LosslessTransform.apply(.rotateClockwise, to: url)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 6)
        let after = try F.segments(url)
        func notEXIF(_ s: (marker: UInt8, bytes: Data)) -> Bool { !(s.marker == 0xE1 && s.bytes.dropFirst(4).starts(with: Array("Exif".utf8))) }
        #expect(after.filter(notEXIF).map(\.bytes) == before.filter(notEXIF).map(\.bytes))
        #expect(after.map(\.marker) == before.map(\.marker))
        #expect(try F.scanData(url) == scan)
        #expect(JPEGComment.read(from: url) == "Café!")
        #expect((F.properties(url)[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String == "Maker")

        try LosslessTransform.apply(.rotateCounterclockwise, to: url)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(try F.segments(url).filter(notEXIF).map(\.bytes) == before.filter(notEXIF).map(\.bytes))
    }

    /// The TestAssets photo has EXIF but no orientation tag, and people
    /// caption their photos: the caption must survive a rotation.
    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleJPEG)))
    func realPhotoKeepsItsCommentWhenRotated() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: F.sampleJPEG, to: url)
        try JPEGComment.write("Harbour at dusk", to: url)
        let scan = try F.scanData(url)
        try LosslessTransform.apply(.rotateClockwise, to: url)
        #expect(JPEGComment.read(from: url) == "Harbour at dusk")
        #expect(try F.scanData(url) == scan)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 6)
    }

    /// An HDR gain map JPEG with a comment: ImageIO's own copy drops the
    /// comment and leaves the MPF index pointing 6 bytes past the gain map.
    @Test func gainMapJPEGKeepsItsIndexAndComment() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("gainmap.jpg")
        let base = CIImage(cgImage: TestImages.gradient(width: 256, height: 128))
        let gainMap = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        try CIContext().writeJPEGRepresentation(of: base, to: url, colorSpace: F.displayP3, options: [.hdrGainMapImage: gainMap])
        try JPEGComment.write("gm", to: url)
        func gainMapData() -> Data? {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [String: Any]
            return info?[kCGImageAuxiliaryDataInfoData as String] as? Data
        }
        let before = try #require(gainMapData())

        try LosslessTransform.apply(.rotateClockwise, to: url)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 6)
        #expect(JPEGComment.read(from: url) == "gm")
        #expect(gainMapData() == before)
        let data = try Data(contentsOf: url)
        let offsets = try #require(ExportJPEGCommentTests().mpfImageOffsets(in: data))
        #expect(offsets.count == 2)
        let position = offsets[1].headerPosition + offsets[1].offset
        #expect(data[position] == 0xFF && data[position + 1] == 0xD8)
    }

    @Test func splicingRefusesChangedImageData() throws {
        let t = try TemporaryFolder()
        let original = try Data(contentsOf: TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("a.jpg")))
        var reencoded = original
        reencoded[reencoded.count - 10] ^= 0xFF   // one byte of the scan differs
        #expect(throws: LosslessTransform.Error.copyFailed("the image data would have changed")) {
            try LosslessTransform.splicedHeader(from: reencoded, into: original)
        }
    }

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleJPEG)))
    func realPhotoRotatesAndRotatesBack() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: F.sampleJPEG, to: url)
        let scan = try F.scanData(url)
        let size = MetadataReader.summary(for: url).pixelSize
        try LosslessTransform.apply(.rotateCounterclockwise, to: url)
        #expect(try F.scanData(url) == scan)
        #expect(MetadataReader.summary(for: url).pixelSize == size.map { CGSize(width: $0.height, height: $0.width) })
        try LosslessTransform.apply(.rotateClockwise, to: url)
        #expect(try F.scanData(url) == scan)
        #expect(F.properties(url)[kCGImagePropertyOrientation as String] as? Int == 1)
    }

    @Test func heicPNGAndTIFFChangeOrientationWithIdenticalPixels() throws {
        let t = try TemporaryFolder()
        for type in [UTType.heic, .png, .tiff] {
            let url = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("image.\(type.preferredFilenameExtension!)"), type: type,
                                       properties: [kCGImagePropertyOrientation: 3,
                                                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Maker"]])
            let pixels = F.pixels(of: try #require(F.decode(url)))
            try LosslessTransform.apply(.flipHorizontal, to: url)
            let props = F.properties(url)
            #expect(props[kCGImagePropertyOrientation as String] as? Int == 4, "\(type)")
            #expect((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String == "Maker", "\(type)")
            #expect(F.pixels(of: try #require(F.decode(url))) == pixels, "\(type)")
            #expect(CGImageSourceGetType(CGImageSourceCreateWithURL(url as CFURL, nil)!) as String? == type.identifier)
        }
    }

    @Test func modificationDateIsUpdated() throws {
        let t = try TemporaryFolder()
        let url = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("image.jpg"))
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: url.path)
        try LosslessTransform.apply(.rotate180, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.modificationDate] as? Date ?? old).timeIntervalSinceNow > -60)
        #expect(attributes[.creationDate] as? Date == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["image.jpg"])
    }

    @Test func refusesRawGIFAndBMP() throws {
        let t = try TemporaryFolder()
        for name in ["a.nef", "a.NEF", "a.dng", "a.cr3", "a.gif", "a.bmp", "a.webp", "a.jp2"] {
            #expect(!LosslessTransform.canApply(to: URL(fileURLWithPath: "/x/" + name)), "\(name)")
        }
        for name in ["a.jpg", "a.JPEG", "a.heic", "a.HEIF", "a.tif", "a.tiff", "a.png"] {
            #expect(LosslessTransform.canApply(to: URL(fileURLWithPath: "/x/" + name)), "\(name)")
        }
        for (name, type) in [("image.gif", UTType.gif), ("image.bmp", .bmp)] {
            let url = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent(name), type: type)
            let bytes = try Data(contentsOf: url)
            #expect(throws: LosslessTransform.Error.unsupportedFormat) { try LosslessTransform.apply(.rotateClockwise, to: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }
        // Extensions can lie: a GIF named .png is still refused by content.
        let disguised = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("gif.png"), type: .gif)
        #expect(throws: LosslessTransform.Error.unsupportedFormat) { try LosslessTransform.apply(.rotateClockwise, to: disguised) }
    }

    /// Raw formats that aren't TIFF inside are caught by their first bytes,
    /// before ImageIO gets a chance to guess from the name.
    @Test func rawSignaturesAreRefusedWhateverTheName() throws {
        let t = try TemporaryFolder()
        let heads: [(String, [UInt8])] = [
            ("raf", Array("FUJIFILMCCD-RAW 0201".utf8)),
            ("cr3", [0, 0, 0, 0x18] + Array("ftypcrx ".utf8) + [0, 0, 0, 1]),
            ("crw", [0x49, 0x49, 0x1A, 0, 0, 0] + Array("HEAPCCDR".utf8)),
            ("orf", [0x49, 0x49, 0x52, 0x4F, 8, 0, 0, 0]),
            ("rw2", [0x49, 0x49, 0x55, 0x00, 0x18, 0, 0, 0]),
            ("x3f", Array("FOVb".utf8) + [0, 0, 2, 0]),
            ("mrw", [0x00, 0x4D, 0x52, 0x4D, 0, 0, 0, 0]),
        ]
        let jpeg = try Data(contentsOf: TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("real.jpg")))
        for (name, head) in heads {
            #expect(LosslessTransform.hasRawSignature(head), "\(name)")
            let url = t.url.appendingPathComponent("\(name).jpg")
            try (Data(head) + jpeg).write(to: url)
            let bytes = try Data(contentsOf: url)
            #expect(throws: LosslessTransform.Error.unsupportedFormat, "\(name)") { try LosslessTransform.apply(.rotateClockwise, to: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }
        #expect(!LosslessTransform.hasRawSignature(Array(jpeg.prefix(16))))
        #expect(!LosslessTransform.isCameraRaw(t.url.appendingPathComponent("real.jpg")))
    }

    @Test(.enabled(if: ExportFixtures.exists(ExportFixtures.sampleNEF)))
    func aRawFileNamedTIFFIsNeverModified() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("camera.tif")
        try FileManager.default.copyItem(at: F.sampleNEF, to: url)   // an APFS clone, instant
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(throws: LosslessTransform.Error.unsupportedFormat) { try LosslessTransform.apply(.rotateClockwise, to: url) }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        #expect(after[.systemFileNumber] as? Int == attributes[.systemFileNumber] as? Int)
        // Any other name ImageIO accepts reads it as TIFF too.
        for ext in ["jpg", "png", "heic"] {
            let renamed = t.url.appendingPathComponent("camera.\(ext)")
            try FileManager.default.copyItem(at: F.sampleNEF, to: renamed)
            #expect(throws: LosslessTransform.Error.unsupportedFormat) { try LosslessTransform.apply(.rotateClockwise, to: renamed) }
        }

        // The structural sniff: every camera file is caught, real TIFFs pass.
        let files = try FileManager.default.contentsOfDirectory(at: F.assets, includingPropertiesForKeys: nil)
        let raws = files.filter { $0.pathExtension.lowercased() == "nef" }
        #expect(!raws.isEmpty)
        for raw in raws { #expect(LosslessTransform.isCameraRawTIFF(raw), "\(raw.lastPathComponent)") }
        let tiff = F.assets.appendingPathComponent("HSB_6548.tif")
        if F.exists(tiff) { #expect(!LosslessTransform.isCameraRawTIFF(tiff)) }
        let written = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("plain.tif"), type: .tiff,
                                       properties: [kCGImagePropertyOrientation: 6])
        #expect(!LosslessTransform.isCameraRawTIFF(written))
        #expect(!LosslessTransform.isCameraRawTIFF(TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("p.jpg"))))
    }
}
