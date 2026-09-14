import Testing
import Foundation
import CoreGraphics
import ImageIO
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
        let w = 6, h = 4
        // Every pixel a different colour, so any wrong turn shows.
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: F.sRGB,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<h { for x in 0..<w {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x * 40) / 255, green: CGFloat(y * 60) / 255, blue: CGFloat((x + y) * 20) / 255, alpha: 1))
            ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
        }}
        let stored = try #require(ctx.makeImage())

        func displayed(_ url: URL) throws -> (w: Int, h: Int, px: [UInt8]) {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h),
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

        for orientation in LosslessTransform.allOrientations {
            for kind in Self.kinds {
                let url = TestImages.write(stored, to: t.url.appendingPathComponent("o\(orientation.rawValue)-\(kind).tif"), type: .tiff,
                                           properties: [kCGImagePropertyOrientation: orientation.rawValue])
                let before = try displayed(url)
                try LosslessTransform.apply(kind, to: url)
                let after = try displayed(url)
                let expected = transformed(before, kind)
                #expect(after.w == expected.w && after.h == expected.h && after.px == expected.px, "orientation \(orientation.rawValue), \(kind)")
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
