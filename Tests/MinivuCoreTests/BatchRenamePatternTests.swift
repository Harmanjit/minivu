import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Rename patterns: tokens, counters, dates, find and replace, letter case,
/// and the plan's problems, all before anything is renamed.
@Suite struct BatchRenamePatternTests {
    let utc = TimeZone(identifier: "UTC")!

    func name(_ pattern: RenamePattern, _ source: RenameSource, index: Int = 0, newExtension: String? = nil) -> String {
        RenameNamer(pattern: pattern, timeZone: utc).name(for: source, index: index, newExtension: newExtension)
    }

    func source(_ name: String, modified: Date? = nil, taken: Date? = nil, width: Int? = nil, height: Int? = nil) -> RenameSource {
        RenameSource(url: URL(fileURLWithPath: "/tmp/batch/\(name)"), modified: modified, dateTaken: taken,
                     pixelWidth: width, pixelHeight: height)
    }

    /// 2024-05-06 07:08:09 UTC.
    let may6 = Date(timeIntervalSince1970: 1_714_979_289)

    // MARK: - Tokens

    @Test func nameCounterAndLiterals() {
        let photo = source("IMG_2034.JPG")
        #expect(name(RenamePattern(), photo) == "IMG_2034.JPG", "the default pattern keeps the name")
        #expect(name(RenamePattern(text: "Trip {name}"), photo) == "Trip IMG_2034.JPG")
        #expect(name(RenamePattern(text: "Trip {#}"), photo, index: 0) == "Trip 1.JPG")
        #expect(name(RenamePattern(text: "Trip {###}"), photo, index: 9) == "Trip 010.JPG")
        // The digits setting is a minimum; the token's own count also is.
        #expect(name(RenamePattern(text: "{#}", counterDigits: 4), photo, index: 2) == "0003.JPG")
        #expect(name(RenamePattern(text: "{###}", counterDigits: 2), photo, index: 2) == "003.JPG")
        // Start and step.
        let stepped = RenamePattern(text: "{##}", counterStart: 10, counterStep: 5)
        #expect((0..<3).map { name(stepped, photo, index: $0) } == ["10.JPG", "15.JPG", "20.JPG"])
        #expect(name(RenamePattern(text: "{##}", counterStart: 1, counterStep: -2), photo, index: 2) == "-03.JPG")
        // A counter that passes its digits simply grows.
        #expect(name(RenamePattern(text: "{##}", counterStart: 99), photo, index: 1) == "100.JPG")
        #expect(name(RenamePattern(text: "{Name}_{EXT}"), photo) == "IMG_2034_JPG.JPG", "keywords in any case")
    }

    @Test func unknownTokensAndStrayBraces() {
        let pattern = RenamePattern(text: "{nmae} {date:yyyy} {width:3} {")
        let parsed = pattern.tokens
        #expect(parsed.unknown == ["{nmae}", "{width:3}"])
        let namer = RenameNamer(pattern: pattern, timeZone: utc)
        #expect(namer.unknownTokens == ["{nmae}", "{width:3}"])
        #expect(namer.name(for: source("a.jpg", taken: may6), index: 0) == "{nmae} 2024 {width:3} {.jpg",
                "unknown tokens and a lone brace stay as text in the preview")
        #expect(RenamePattern(text: "{name}}{").tokens.unknown.isEmpty)
    }

    @Test func datesSizesAndFallbacks() {
        let modified = Date(timeIntervalSince1970: 1_600_000_000)   // 2020-09-13 12:26:40 UTC
        let photo = source("a.heic", modified: modified, taken: may6, width: 4032, height: 3024)
        #expect(name(RenamePattern(text: "{date}"), photo) == "2024-05-06.heic")
        #expect(name(RenamePattern(text: "{date:yyyyMMdd-HHmmss}"), photo) == "20240506-070809.heic")
        #expect(name(RenamePattern(text: "{modified}"), photo) == "2020-09-13.heic")
        #expect(name(RenamePattern(text: "{modified:HH.mm}"), photo) == "12.26.heic")
        #expect(name(RenamePattern(text: "{width}x{height}"), photo) == "4032x3024.heic")
        // No date taken: the modification date stands in.
        let scan = source("scan.png", modified: modified)
        #expect(name(RenamePattern(text: "{date}"), scan) == "2020-09-13.png")
        #expect(name(RenamePattern(text: "{width}"), scan) == ".png", "unknown size is empty")
        // A camera's own zone: the time on its clock, wherever the Mac is.
        var abroad = photo
        abroad.dateTakenTimeZone = TimeZone(secondsFromGMT: 9 * 3600)
        #expect(name(RenamePattern(text: "{date:HH.mm}"), abroad) == "16.08.heic")
        #expect(RenamePattern(text: "{date} {#}").needsImageMetadata)
        #expect(!RenamePattern(text: "{name} {modified} {#}").needsImageMetadata)
    }

    @Test func findReplaceAndLetterCase() {
        let photo = source("IMG_Beach img.JPG")
        #expect(name(RenamePattern(find: "img", replacement: "Photo"), photo) == "Photo_Beach Photo.JPG")
        #expect(name(RenamePattern(find: "img", replacement: "Photo", matchesCase: true), photo) == "IMG_Beach Photo.JPG")
        #expect(name(RenamePattern(find: ".", replacement: "-"), source("a.b.c.jpg")) == "a-b-c.jpg",
                "plain text, not a regular expression; the extension isn't touched")
        #expect(name(RenamePattern(nameCase: .lower), photo) == "img_beach img.JPG")
        #expect(name(RenamePattern(nameCase: .upper, extensionCase: .lower), photo) == "IMG_BEACH IMG.jpg")
        #expect(name(RenamePattern(text: "summer in rome", nameCase: .title), photo) == "Summer In Rome.JPG")
        #expect(name(RenamePattern(extensionCase: .upper), source("a.heic")) == "a.HEIC")
        // The converter's extension replaces the original's, in the extension case.
        #expect(name(RenamePattern(extensionCase: .upper), source("a.NEF"), newExtension: "jpg") == "a.JPG")
        #expect(name(RenamePattern(text: "{name}"), source("README")) == "README")
        #expect(RenameNamer.split(".profile") == (".profile", ""))
        #expect(RenameNamer.split("photo.") == ("photo.", ""))
    }

    @Test func decodingFillsMissingOptions() throws {
        let saved = Data(#"{"text":"Trip {##}","counterStart":5}"#.utf8)
        let pattern = try JSONDecoder().decode(RenamePattern.self, from: saved)
        #expect(pattern == RenamePattern(text: "Trip {##}", counterStart: 5))
        let roundTrip = RenamePattern(text: "x", counterStep: 3, find: "a", replacement: "b", matchesCase: true,
                                      nameCase: .title, extensionCase: .upper)
        #expect(try JSONDecoder().decode(RenamePattern.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }

    /// The date taken comes from EXIF, and the size as displayed.
    @Test func readsMetadataFromTheFile() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("exif.jpg")
        try BatchFixtures.writeJPEG(to: url, width: 40, height: 20, orientation: .right,
                                    dateTaken: "2023:12:24 18:30:00")
        let read = RenameSource(url: url).withImageMetadata()
        #expect(read.pixelWidth == 20 && read.pixelHeight == 40, "orientation 6 turns the picture on its side")
        #expect(read.modified != nil)
        let local = RenameNamer(pattern: RenamePattern(text: "{date:yyyy-MM-dd HH.mm}"), timeZone: .current)
        #expect(local.name(for: read, index: 0) == "2023-12-24 18.30.jpg")
        let many = RenameSource.withImageMetadata([RenameSource(url: url), RenameSource(url: url)])
        #expect(many.map(\.pixelWidth) == [20, 20])
    }

    // MARK: - Plans

    /// A pretend file system: names that exist, by folder, with identities.
    final class FakeDisk: @unchecked Sendable {
        var items: [String: BatchItemIdentity] = [:]
        var caseSensitive = false
        private var next: UInt64 = 1

        func add(_ path: String, directory: Bool = false) {
            items[key(path)] = BatchItemIdentity(device: 1, inode: next, isDirectory: directory)
            next += 1
        }

        func key(_ path: String) -> String { caseSensitive ? path : path.lowercased() }

        var probe: BatchFileProbe {
            BatchFileProbe(identity: { [self] url in items[key(url.path)] }, isCaseSensitive: { [self] _ in caseSensitive })
        }
    }

    func plan(_ names: [String], _ pattern: RenamePattern, disk: FakeDisk) -> RenamePlan {
        let sources = names.map { source($0) }
        return RenamePlanner.plan(sources, pattern: pattern, probe: disk.probe)
    }

    @Test func planFlagsEveryProblemBeforeRenaming() {
        let disk = FakeDisk()
        for name in ["a.jpg", "b.jpg", "c.jpg", "outside.jpg"] { disk.add("/tmp/batch/\(name)") }

        // Two files, one name.
        var p = plan(["a.jpg", "b.jpg"], RenamePattern(text: "same"), disk: disk)
        #expect(p.items.map(\.problem) == [.duplicate, .duplicate])
        #expect(!p.canRename)

        // Names differing only in case clash on a case-insensitive volume…
        p = plan(["a.jpg", "b.jpg"], RenamePattern(text: "{#}", counterStart: 1, find: "2", replacement: "1",
                                                   nameCase: .unchanged, extensionCase: .unchanged), disk: disk)
        #expect(p.items.map(\.newName) == ["1.jpg", "1.jpg"])
        #expect(p.problemCount == 2)
        let cases = RenamePlanner.plan([source("a.jpg"), source("b.jpg")],
                                       pattern: RenamePattern(text: "{name}", find: "b", replacement: "A"), probe: disk.probe)
        #expect(cases.items.map(\.newName) == ["a.jpg", "A.jpg"])
        #expect(cases.items.map(\.problem) == [.duplicate, .duplicate])

        // A name held by a file outside the batch.
        p = plan(["a.jpg", "b.jpg"], RenamePattern(text: "{name}", find: "a", replacement: "outside"), disk: disk)
        #expect(p.items[0].problem == .taken)
        #expect(p.items[1].problem == nil && p.items[1].isUnchanged)

        // Invalid names.
        p = plan(["a.jpg", "b.jpg", "c.jpg"], RenamePattern(text: "{name}", find: "a", replacement: "x/y"), disk: disk)
        #expect(p.items[0].problem == .invalidName("The name can’t contain “/” or “:”."))
        p = plan(["a.jpg"], RenamePattern(text: ".hidden"), disk: disk)
        #expect(p.items[0].problem == .invalidName("Names that begin with a dot “.” are reserved for the system."))
        p = plan(["a.jpg"], RenamePattern(text: "{name}", find: "a", replacement: String(repeating: "é", count: 200)),
                 disk: disk)
        #expect(p.items[0].problem == .invalidName("The name is too long."))

        // A source that has gone.
        p = plan(["gone.jpg"], RenamePattern(text: "x"), disk: disk)
        #expect(p.items[0].problem == .missing)

        // An unchanged name renaming onto another unchanged file is a clash.
        p = plan(["a.jpg", "b.jpg"], RenamePattern(text: "{name}", find: "a", replacement: "b"), disk: disk)
        #expect(p.items.map(\.problem) == [.duplicate, .duplicate])

        // Unknown tokens block renaming even with no file problems.
        p = plan(["a.jpg"], RenamePattern(text: "{nmae}"), disk: disk)
        #expect(p.problemCount == 0 && !p.canRename)
    }

    @Test func swapsChainsAndCaseOnlyRenamesPlanCleanly() {
        let disk = FakeDisk()
        for name in ["a.jpg", "b.jpg", "1.jpg", "2.jpg", "IMG.JPG"] { disk.add("/tmp/batch/\(name)") }

        let swap = RenamePlanner.plan([source("a.jpg"), source("b.jpg")],
                                      pattern: RenamePattern(text: "{name}", find: "x", replacement: "y"), probe: disk.probe)
        #expect(swap.changeCount == 0 && !swap.canRename, "nothing changes: nothing to rename")

        let swapped = RenamePlanner.plan([source("b.jpg"), source("a.jpg")],
                                         pattern: RenamePattern(text: "{#}", counterStart: 1), probe: disk.probe)
        #expect(swapped.items.map(\.newName) == ["1.jpg", "2.jpg"])
        #expect(swapped.canRename == false, "1.jpg and 2.jpg are held by files outside this batch")

        let chain = RenamePlanner.plan([source("1.jpg"), source("2.jpg")],
                                       pattern: RenamePattern(text: "{#}", counterStart: 2), probe: disk.probe)
        #expect(chain.items.map(\.newName) == ["2.jpg", "3.jpg"])
        #expect(chain.canRename, "2.jpg is freed by the batch itself")

        let lower = RenamePlanner.plan([source("IMG.JPG")], pattern: RenamePattern(nameCase: .lower, extensionCase: .lower),
                                       probe: disk.probe)
        #expect(lower.items[0].newName == "img.jpg" && !lower.items[0].isUnchanged)
        #expect(lower.canRename, "a case-only rename takes its own name")

        disk.caseSensitive = true
        disk.items = [:]
        for name in ["a.jpg", "b.jpg"] { disk.add("/tmp/batch/\(name)") }
        let sensitive = RenamePlanner.plan([source("a.jpg"), source("b.jpg")],
                                           pattern: RenamePattern(text: "{name}", find: "b", replacement: "A"),
                                           probe: disk.probe)
        #expect(sensitive.canRename, "A.jpg and a.jpg are two names on a case-sensitive volume")
    }
}

enum BatchFixtures {
    /// A JPEG with red top-left, green top-right, blue bottom-left and white
    /// bottom-right quadrants as stored, an EXIF orientation and optionally
    /// a date taken.
    static func writeJPEG(to url: URL, width: Int, height: Int, orientation: CGImagePropertyOrientation = .up,
                          dateTaken: String? = nil, type: UTType = .jpeg) throws {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h, width: w, height: h))
        fill(0, 1, 0, CGRect(x: w, y: h, width: w, height: h))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w, height: h))
        fill(1, 1, 1, CGRect(x: w, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue,
                                           kCGImageDestinationLossyCompressionQuality: 1.0]
        if let dateTaken {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTaken]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }
}
