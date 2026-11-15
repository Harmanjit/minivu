import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Ratings, the tag and colour labels in the files themselves (G2), and the
/// Finder colour tags minivu's Label commands set (G4).
@Suite struct FileMarksTests {
    typealias F = ExportFixtures
    typealias Marks = Catalog.Marks
    typealias W = MetadataWriterTests

    static func xmpValue(_ url: URL, _ path: String) -> String? {
        MetadataFields.xmpText(W.xmp(url), path)
    }

    // MARK: - Writing marks

    @Test(arguments: MetadataWriterTests.inPlaceTypes.map(\.1))
    func marksAreWrittenIntoTheFileWithIdenticalPixels(_ ext: String) throws {
        let type = W.inPlaceTypes.first { $0.1 == ext }!.0
        let t = try TemporaryFolder()
        let url = W.tagged(type, ext: ext, in: t.url)
        let pixels = F.pixels(of: try #require(F.decode(url)))
        #expect(MarksXMP.readMarks(from: url) == Marks(rating: 4), "the fixture's own rating")

        let outcome = try MetadataWriter.apply(MetadataEdit(rating: 2, tagged: true, colorLabel: .red), to: url)
        #expect(!outcome.usedSidecar)
        #expect(MarksXMP.readMarks(from: url) == Marks(rating: 2, isTagged: true), "\(ext)")
        #expect(Self.xmpValue(url, "xmp:Rating") == "2", "\(ext)")
        #expect(Self.xmpValue(url, "xmp:Label") == "Red", "\(ext)")
        let fields = MetadataFields.read(from: url)
        #expect(fields.pickLabel == 3 && fields.label == "Red" && fields.rating == 2, "\(ext)")
        // Everything else stays.
        #expect(fields.title == W.oldTitle && fields.hasLocation && Set(fields.keywords) == ["paris", "tower"], "\(ext)")
        #expect(F.pixels(of: try #require(F.decode(url))) == pixels, "\(ext)")

        // Clearing takes all three out again.
        try MetadataWriter.apply(MetadataEdit(rating: 0, tagged: false, colorLabel: ColorLabel.none), to: url)
        #expect(MarksXMP.readMarks(from: url) == nil, "\(ext)")
        let cleared = MetadataFields.read(from: url)
        #expect(cleared.rating == nil && cleared.pickLabel == nil && cleared.label == nil, "\(ext)")
        #expect(F.pixels(of: try #require(F.decode(url))) == pixels, "\(ext)")
    }

    @Test func otherApplicationsMarksAreKept() throws {
        let t = try TemporaryFolder()
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "-1" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Approved" as CFString)
        CGImageMetadataRegisterNamespaceForPrefix(metadata, MarksXMP.digiKamNamespace as CFString, "digiKam" as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, "digiKam:PickLabel" as CFString, "1" as CFString)
        let url = t.url.appendingPathComponent("rejected.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, TestImages.gradient(), metadata, nil)
        #expect(CGImageDestinationFinalize(destination))

        // A reject shows as no stars, and minivu's tag isn't digiKam's "Rejected".
        #expect(MarksXMP.readMarks(from: url) == nil)
        // Clearing in minivu keeps Bridge's reject, digiKam's pick and Bridge's label text.
        try MetadataWriter.apply(MetadataEdit(rating: 0, tagged: false, colorLabel: ColorLabel.none), to: url)
        #expect(Self.xmpValue(url, "xmp:Rating") == "-1")
        #expect(Self.xmpValue(url, "xmp:Label") == "Approved")
        #expect(MetadataFields.read(from: url).pickLabel == 1)
        // Choosing marks replaces them.
        try MetadataWriter.apply(MetadataEdit(rating: 3, tagged: true, colorLabel: .blue), to: url)
        #expect(Self.xmpValue(url, "xmp:Rating") == "3")
        #expect(Self.xmpValue(url, "xmp:Label") == "Blue")
        #expect(MarksXMP.readMarks(from: url) == Marks(rating: 3, isTagged: true))
    }

    @Test func rawFilesGetTheirMarksInTheSidecar() throws {
        let t = try TemporaryFolder()
        let dng = W.tagged(.tiff, ext: "dng", in: t.url, name: "camera")
        let original = try Data(contentsOf: dng)
        let sidecar = t.url.appendingPathComponent("camera.xmp")
        // Lightroom's sidecar, with its rating as an attribute and a title.
        let lightroom = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="5" xmp:Label="Yellow">
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">From Lightroom</rdf:li></rdf:Alt></dc:title>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        try Data(lightroom.utf8).write(to: sidecar)
        // The sidecar's rating wins over the one inside the raw file (4).
        #expect(MarksXMP.readMarks(from: dng) == Marks(rating: 5))

        let outcome = try MetadataWriter.apply(MetadataEdit(rating: 2, tagged: true, colorLabel: .green), to: dng)
        #expect(outcome.usedSidecar && outcome.written == sidecar)
        #expect(try Data(contentsOf: dng) == original, "a raw file is never modified")
        #expect(MarksXMP.readMarks(from: dng) == Marks(rating: 2, isTagged: true))
        let xmp = try #require(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData))
        #expect(MetadataFields.xmpText(xmp, "xmp:Label") == "Green")
        #expect(MetadataFields.xmpText(xmp, "dc:title") == "From Lightroom")
    }

    @Test func aJPEGNeverReadsItsRawTwinsSidecar() throws {
        let t = try TemporaryFolder()
        let jpeg = TestImages.write(TestImages.gradient(), to: t.url.appendingPathComponent("twin.jpg"))
        let side = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(side, nil, "xmp:Rating" as CFString, "5" as CFString)
        try (CGImageMetadataCreateXMPData(side, nil)! as Data).write(to: t.url.appendingPathComponent("twin.xmp"))
        #expect(MarksXMP.readMarks(from: jpeg) == nil)
        #expect(MarksXMP.readMarks(from: t.url.appendingPathComponent("missing.jpg")) == nil)
    }

    @Test func colourLabelNames() {
        #expect(ColorLabel.allCases.map(\.name) == ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        #expect(ColorLabel(xmpLabel: "red") == .red)
        #expect(ColorLabel(xmpLabel: " Grey ") == .gray)
        #expect(ColorLabel(xmpLabel: "Approved") == nil)
        #expect(ColorLabel(xmpLabel: "None") == nil)
        for label in ColorLabel.allCases {
            #expect(ColorLabel(finderColorIndex: label.finderColorIndex) == label)
        }
        #expect(ColorLabel.red.finderColorIndex == 6 && ColorLabel.gray.finderColorIndex == 1)
    }

    // MARK: - The cache

    @Test func theCacheReadsAFileOnceUntilItChanges() throws {
        let t = try TemporaryFolder()
        let url = try t.file("a.jpg")
        let raw = try t.file("b.NEF")
        let reads = Counter()
        let cache = FileMarksCache { url in
            reads.add()
            return url.lastPathComponent == "a.jpg" ? Marks(rating: 3) : nil
        }
        #expect(cache.cachedMarks(for: url) == nil, "unknown before a read")
        #expect(cache.marks(for: url) == Marks(rating: 3))
        #expect(cache.marks(for: url) == Marks(rating: 3))
        #expect(reads.value == 1)
        #expect(cache.cachedMarks(for: url) == .some(Marks(rating: 3)))

        // A new date means another read.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        #expect(cache.cachedMarks(for: url) == nil)
        _ = cache.marks(for: url)
        #expect(reads.value == 2)

        // A raw file's entry follows its sidecar too.
        #expect(cache.marks(for: raw) == nil)
        #expect(cache.cachedMarks(for: raw) == .some(nil), "known to have none")
        try Data("<x/>".utf8).write(to: t.url.appendingPathComponent("b.xmp"))
        #expect(cache.cachedMarks(for: raw) == nil, "a new sidecar")
        _ = cache.marks(for: raw)
        #expect(reads.value == 4)

        cache.forget(url)
        #expect(cache.cachedMarks(for: url) == nil)
        // A missing file has none, without a read.
        #expect(cache.marks(for: t.url.appendingPathComponent("gone.jpg")) == nil)
        #expect(reads.value == 4)
    }

    // MARK: - The catalog and the files' marks

    @Test func aFilesMarksBecomeTheRowsBeforeAChange() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg"), c = try t.file("c.jpg")
        let catalog = Catalog.inMemory()
        let fileMarks: [String: Marks] = ["a.jpg": Marks(isTagged: true), "b.jpg": Marks(rating: 4)]
        catalog.fileMarksReader = { fileMarks[$0.lastPathComponent] }

        // Rating a file keeps the tag it carries.
        catalog.setRating(3, for: [a])
        #expect(catalog.marks(for: a) == Marks(rating: 3, isTagged: true))
        // Clearing a file's rating keeps an empty row over the file's 4 stars.
        catalog.setRating(0, for: [b])
        #expect(catalog.storedMarks(for: b) == Marks.none)
        #expect(catalog.marks(for: [a, b, c]) == [a: Marks(rating: 3, isTagged: true), b: .none])
        // And it stays when set and cleared again.
        catalog.setTagged(true, for: [b])
        catalog.setTagged(false, for: [b])
        #expect(catalog.storedMarks(for: b) == Marks.none)
        // A file with no marks of its own gets no row when cleared.
        catalog.setRating(2, for: [c])
        catalog.setRating(0, for: [c])
        #expect(catalog.storedMarks(for: c) == nil)
        // A row the user made before the file had marks is kept once it would empty.
        let d = try t.file("d.jpg")
        catalog.setRating(2, for: [d])
        let withD = fileMarks.merging(["d.jpg": Marks(rating: 5)]) { $1 }
        catalog.fileMarksReader = { withD[$0.lastPathComponent] }
        catalog.setRating(0, for: [d])
        #expect(catalog.storedMarks(for: d) == Marks.none)
        // A copy keeps standing over the file's marks.
        let copy = t.url.appendingPathComponent("b copy.jpg")
        try FileManager.default.copyItem(at: b, to: copy)
        catalog.fileCopied(from: b, to: copy)
        catalog.fileMarksReader = nil
        catalog.setTagged(true, for: [copy])
        catalog.setTagged(false, for: [copy])
        #expect(catalog.storedMarks(for: copy) == Marks.none)
    }

    @Test func withoutAReaderNothingChanges() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [a])
        catalog.setRating(0, for: [a])
        #expect(catalog.storedMarks(for: a) == nil)
    }

    @Test func aVersionOneCatalogKeepsItsRatings() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let dbURL = t.url.appendingPathComponent("catalog.sqlite")
        do {
            let db = try SQLiteDatabase(url: dbURL)
            try db.executeScript("""
                CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    folder TEXT NOT NULL COLLATE NOCASE, volume TEXT, file_id INTEGER, size INTEGER, modified REAL,
                    rating INTEGER NOT NULL DEFAULT 0, tagged INTEGER NOT NULL DEFAULT 0, missing_since REAL);
                CREATE INDEX files_identity ON files (volume, file_id);
                CREATE INDEX files_folder ON files (folder);
                CREATE TABLE folder_order (folder TEXT NOT NULL COLLATE NOCASE, name TEXT NOT NULL COLLATE NOCASE,
                    position INTEGER NOT NULL, PRIMARY KEY (folder, name)) WITHOUT ROWID;
                """)
            try db.execute("INSERT INTO files (path, folder, rating) VALUES (?1, ?2, 4)",
                           [.text(Catalog.key(a)), .text(Catalog.folderKey(t.url))])
            try db.setUserVersion(1)
        }
        let catalog = try Catalog(url: dbURL)
        #expect(try catalog.db.userVersion() == 2)
        #expect(catalog.marks(for: a) == Marks(rating: 4))
        catalog.fileMarksReader = { _ in Marks(rating: 1) }
        catalog.setRating(0, for: [a])
        #expect(catalog.storedMarks(for: a) == Marks.none)
    }

    // MARK: - Finder colour tags

    @Test func settingALabelKeepsTheOtherTags() {
        let tags = ["Work\n0", "Red\n6", "Project\n4", "orange\n0"]
        #expect(FinderTags.entries(tags, settingColorLabel: .green) == ["Work\n0", "Project\n4", "Green\n2"])
        #expect(FinderTags.entries(tags, settingColorLabel: ColorLabel.none) == ["Work\n0", "Project\n4"])
        // Finder's own names, in the system's language, are standard tags too.
        let german = [6: "Rot", 2: "Grün"]
        #expect(FinderTags.entries(["Rot\n6", "Urlaub\n0"], settingColorLabel: .green, standardNames: german)
                == ["Urlaub\n0", "Grün\n2"])
        #expect(FinderTags.entries([], settingColorLabel: .purple) == ["Purple\n3"])
    }

    @Test func labelsAreWrittenAsFinderStoresThem() throws {
        let t = try TemporaryFolder()
        let url = try t.file("a.jpg")
        try FinderTags.setColorLabel(.blue, for: url)
        #expect(FinderTags.entries(of: url) == ["Blue\n4"])
        #expect(FinderTags.tags(for: url) == ["Blue"])
        try FinderTags.setTags(["Blue", "Holiday"], for: url)
        try FinderTags.setColorLabel(.red, for: url)
        #expect(FinderTags.tags(for: url) == ["Holiday", "Red"])
        try FinderTags.setColorLabel(ColorLabel.none, for: url)
        #expect(FinderTags.tags(for: url) == ["Holiday"])
        let alone = try t.file("b.jpg")
        try FinderTags.setColorLabel(.yellow, for: alone)
        try FinderTags.setColorLabel(ColorLabel.none, for: alone)
        #expect(getxattr(alone.path, FinderTags.attributeName, nil, 0, 0, 0) < 0, "no empty attribute left")
        // Nothing to do leaves the file alone; a missing file throws.
        #expect(throws: (any Error).self) { try FinderTags.setColorLabel(.red, for: t.url.appendingPathComponent("gone.jpg")) }
    }
}

/// A count from a `@Sendable` closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
