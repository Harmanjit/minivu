import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MinivuCore

/// Filters, the flat walk of a folder tree and Find (G3).
@Suite struct SearchTests {
    // MARK: - Reading what the filters need

    /// A JPEG with camera, exposure, date, keywords and a position.
    static func photo(in folder: URL, name: String = "photo.jpg", width: Int = 64, height: Int = 48,
                      keywords: [String] = ["Paris", "tower"], iso: Int = 400, fNumber: Double = 2.8,
                      focal: Double = 35, date: String = "2024:06:01 09:30:00", gps: Bool = true) -> URL {
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: fNumber, kCGImagePropertyExifFocalLength: focal,
                                             kCGImagePropertyExifISOSpeedRatings: [iso],
                                             kCGImagePropertyExifDateTimeOriginal: date,
                                             kCGImagePropertyExifLensModel: "XF23mmF2 R WR"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: keywords],
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 2.29, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        return TestImages.write(TestImages.gradient(width: width, height: height), to: folder.appendingPathComponent(name),
                                properties: properties)
    }

    @Test func readsEverythingTheFiltersUseFromTheHeader() throws {
        let t = try TemporaryFolder()
        let m = FilterMetadata.read(from: Self.photo(in: t.url))
        #expect(m.camera == "FUJIFILM X-T5" || m.camera == "X-T5" || m.camera?.contains("X-T5") == true)
        #expect(m.lens == "XF23mmF2 R WR")
        #expect(m.iso == 400 && m.aperture == 2.8 && m.focalLength == 35)
        #expect(m.dateTaken == 2024_06_01_093000)
        #expect(m.keywords == ["Paris", "tower"])
        #expect(m.hasLocation)
        #expect(m.pixelWidth == 64 && m.pixelHeight == 48)
    }

    @Test func aFileImageIOCannotOpenReadsAsEmpty() throws {
        let t = try TemporaryFolder()
        let m = FilterMetadata.read(from: try t.file("broken.jpg", bytes: 10))
        #expect(m == FilterMetadata())
    }

    // MARK: - Criteria

    let url = URL(fileURLWithPath: "/x/DSCF0001.RAF")
    let known = FilterMetadata(dateTaken: 2024_06_01_093000, camera: "FUJIFILM X-T5", lens: "XF23mmF2 R WR", iso: 400,
                               aperture: 2.8, focalLength: 23, keywords: ["Paris", "Tower"], hasLocation: true,
                               pixelWidth: 7728, pixelHeight: 5152)

    @Test func everyConditionFilters() {
        func passes(_ change: (inout MetadataCriteria) -> Void, label: ColorLabel = .none) -> Bool {
            var criteria = MetadataCriteria()
            change(&criteria)
            return criteria.passes(url, metadata: known, label: label)
        }
        #expect(passes { $0.fileTypes = [.raw] } && !passes { $0.fileTypes = [.jpeg, .heif] })
        #expect(passes { $0.takenFrom = 2024_06_01; $0.takenTo = 2024_06_01 })
        #expect(!passes { $0.takenFrom = 2024_06_02 } && !passes { $0.takenTo = 2024_05_31 })
        #expect(passes { $0.camera = "x-t5" } && !passes { $0.camera = "Canon" })
        #expect(passes { $0.lens = "23mm" } && !passes { $0.lens = "56mm" })
        #expect(passes { $0.iso = NumberRange(minimum: 100, maximum: 400) } && !passes { $0.iso = NumberRange(maximum: 200) })
        #expect(passes { $0.aperture = NumberRange(maximum: 2.8) } && !passes { $0.aperture = NumberRange(minimum: 4) })
        #expect(passes { $0.focalLength = NumberRange(minimum: 23) } && !passes { $0.focalLength = NumberRange(minimum: 24) })
        #expect(passes { $0.keywords = ["paris"] } && passes { $0.keywords = ["PARIS", "tower"] })
        #expect(!passes { $0.keywords = ["paris", "night"] })
        #expect(passes({ $0.colorLabel = .red }, label: .red) && !passes({ $0.colorLabel = .red }, label: .blue))
        #expect(passes { $0.hasLocation = true } && !passes { $0.hasLocation = false })
        #expect(passes { $0.shape = .landscape } && !passes { $0.shape = .portrait } && !passes { $0.shape = .square })
        #expect(passes { $0.minimumWidth = 7728; $0.minimumHeight = 5000 } && !passes { $0.minimumHeight = 6000 })
        #expect(passes { _ in })
    }

    @Test func unknownMetadataFailsOnlyConditionsThatNeedIt() {
        var criteria = MetadataCriteria()
        criteria.fileTypes = [.raw]
        criteria.colorLabel = .green
        #expect(!criteria.needsMetadata)
        #expect(criteria.passes(url, metadata: nil, label: .green))
        criteria.camera = "Fuji"
        #expect(criteria.needsMetadata && !criteria.passes(url, metadata: nil, label: .green))
        // A blank text condition is no condition.
        var blank = MetadataCriteria()
        blank.camera = "  "
        #expect(!blank.needsMetadata && blank.passes(url, metadata: nil, label: .none))
    }

    @Test func aMissingValueFailsARange() {
        var criteria = MetadataCriteria()
        criteria.iso = NumberRange(minimum: 100)
        #expect(!criteria.passes(url, metadata: FilterMetadata(), label: .none))
        criteria.iso = NumberRange()
        criteria.takenFrom = 2000_01_01
        #expect(!criteria.passes(url, metadata: FilterMetadata(), label: .none))
    }

    @Test func typeGroupsCoverTheBrowsersExtensions() {
        for ext in ImageFormats.allExtensions {
            let group = FileTypeGroup.of(URL(fileURLWithPath: "/a.\(ext.uppercased())"))
            if ImageFormats.rawExtensions.contains(ext) { #expect(group == .raw) }
        }
        #expect(FileTypeGroup.of(URL(fileURLWithPath: "/a.JPEG")) == .jpeg)
        #expect(FileTypeGroup.of(URL(fileURLWithPath: "/a.avif")) == .heif)
        #expect(FileTypeGroup.of(URL(fileURLWithPath: "/a.jxl")) == .other)
    }

    @Test func queriesRoundTripThroughJSON() throws {
        var criteria = MetadataCriteria()
        criteria.keywords = ["a", "b"]
        criteria.aperture = NumberRange(minimum: 1.4)
        criteria.hasLocation = false
        criteria.minimumWidth = 3000
        let query = SearchQuery(scope: URL(fileURLWithPath: "/Users/Shared/Photos"), name: "IMG", criteria: criteria)
        #expect(try SearchQuery.decoded(query.encoded()) == query)
        #expect(try SearchQuery.decoded(SearchQuery(scope: URL(fileURLWithPath: "/")).encoded()).criteria == MetadataCriteria())
    }

    /// Other held videos before the Video group: a search saved then with
    /// Other ticked still finds them. One saved since keeps what was ticked.
    @Test func otherSavedBeforeTheVideoGroupStillMatchesVideos() throws {
        let old = try SearchQuery.decoded(#"{"scope":"/","criteria":{"fileTypes":["other","png"]}}"#)
        #expect(old.criteria.fileTypes == [.other, .png, .video])
        #expect(old.criteria.passesType(URL(fileURLWithPath: "/clip.mov")))
        #expect(try SearchQuery.decoded(#"{"scope":"/","criteria":{"fileTypes":["raw"]}}"#).criteria.fileTypes == [.raw])
        var criteria = MetadataCriteria()
        criteria.fileTypes = [.other]
        let saved = SearchQuery(scope: URL(fileURLWithPath: "/"), criteria: criteria)
        #expect(try SearchQuery.decoded(saved.encoded()).criteria.fileTypes == [.other])
    }

    // MARK: - Walking a tree

    /// root/a.jpg, root/one/b.jpg, root/one/two/c.jpg, root/one/two/three/d.jpg,
    /// plus a hidden image, a package and a text file to leave out.
    func makeTree() throws -> TemporaryFolder {
        let t = try TemporaryFolder()
        var folder = t.url
        for (level, name) in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].enumerated() {
            if level > 0 {
                folder = folder.appendingPathComponent(["one", "two", "three"][level - 1], isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try t.file(".hidden.jpg")
        try t.file("notes.txt")
        let package = try t.folder("Library.photoslibrary")
        try Data().write(to: package.appendingPathComponent("inside.jpg"))
        return t
    }

    @Test func walksEveryLevelBreadthFirst() throws {
        let t = try makeTree()
        let result = try TreeEnumerator.images(under: t.url)
        #expect(result.images.map(\.name) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(result.foldersListed == 4 && !result.isTruncated && !result.isCancelled)
    }

    @Test func stopsAtTheDepthLimit() throws {
        let t = try makeTree()
        let result = try TreeEnumerator.images(under: t.url, limits: .init(maximumDepth: 1))
        #expect(result.images.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(result.isTruncated)
        let rootOnly = try TreeEnumerator.images(under: t.url, limits: .init(maximumDepth: 0))
        #expect(rootOnly.images.map(\.name) == ["a.jpg"] && rootOnly.foldersListed == 1)
    }

    @Test func stopsAtTheImageAndFolderLimits() throws {
        let t = try makeTree()
        for i in 0..<5 { try t.file("extra\(i).jpg") }
        let images = try TreeEnumerator.images(under: t.url, limits: .init(maximumImages: 3))
        #expect(images.images.count == 3 && images.isTruncated)
        #expect(images.images.map(\.name) == ["a.jpg", "extra0.jpg", "extra1.jpg"])
        let folders = try TreeEnumerator.images(under: t.url, limits: .init(maximumFolders: 2))
        #expect(folders.foldersListed == 2 && folders.isTruncated)
        #expect(Set(folders.images.map(\.name)) == Set(["a.jpg", "b.jpg"] + (0..<5).map { "extra\($0).jpg" }))
        // A limit the tree doesn't reach isn't reported as one.
        let exact = try TreeEnumerator.images(under: t.url, limits: .init(maximumImages: 9))
        #expect(exact.images.count == 9 && !exact.isTruncated)
    }

    @Test func cancellingStopsBetweenFolders() throws {
        let t = try makeTree()
        var batches = 0
        let result = try TreeEnumerator.images(under: t.url, isCancelled: { batches >= 2 }, batch: { _ in batches += 1 })
        #expect(result.isCancelled)
        #expect(result.images.map(\.name) == ["a.jpg", "b.jpg"])
    }

    @Test func aRootThatCannotBeReadThrows() throws {
        let t = try TemporaryFolder()
        #expect(throws: (any Error).self) {
            try TreeEnumerator.images(under: t.url.appendingPathComponent("missing", isDirectory: true))
        }
    }

    @Test func aLinkedFolderIsNotFollowed() throws {
        let t = try makeTree()
        try FileManager.default.createSymbolicLink(at: t.url.appendingPathComponent("one/loop"), withDestinationURL: t.url)
        let result = try TreeEnumerator.images(under: t.url)
        #expect(result.images.count == 4)
    }

    // MARK: - Find

    @Test func findsByNameMarksAndMetadataAcrossFolders() throws {
        let t = try TemporaryFolder()
        let sub = try t.folder("2024")
        let paris = Self.photo(in: sub, name: "IMG_1.jpg")
        let rome = Self.photo(in: t.url, name: "IMG_2.jpg", keywords: ["Rome"], iso: 3200, gps: false)
        _ = Self.photo(in: t.url, name: "DSC_3.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [paris])

        var query = SearchQuery(scope: t.url, name: "img")
        var found: [String] = []
        let outcome = try ImageSearch.run(query, catalog: catalog, found: { found += $0.map(\.name) })
        #expect(Set(outcome.matches.map(\.name)) == ["IMG_1.jpg", "IMG_2.jpg"] && Set(found) == ["IMG_1.jpg", "IMG_2.jpg"])
        #expect(outcome.scanned == 3 && outcome.foldersListed == 2)

        query.minimumRating = 3
        #expect(try ImageSearch.run(query, catalog: catalog).matches.map(\.name) == [paris.lastPathComponent])

        query = SearchQuery(scope: t.url)
        query.criteria.iso = NumberRange(minimum: 1600)
        #expect(try ImageSearch.run(query, catalog: catalog).matches.map(\.name) == [rome.lastPathComponent])
        query.criteria = MetadataCriteria()
        query.criteria.keywords = ["paris"]
        query.criteria.hasLocation = true
        #expect(Set(try ImageSearch.run(query, catalog: catalog).matches.map(\.name)) == ["IMG_1.jpg", "DSC_3.jpg"])

        query.includeSubfolders = false
        #expect(try ImageSearch.run(query, catalog: catalog).matches.map(\.name) == ["DSC_3.jpg"])
    }

    @Test func findAsksForLabelsAndMarksOnlyWhenTheQueryNeedsThem() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        let catalog = Catalog.inMemory()
        let labels = Counter()
        var query = SearchQuery(scope: t.url)
        _ = try ImageSearch.run(query, catalog: catalog, label: { _ in labels.add(); return .none })
        #expect(labels.value == 0)
        query.criteria.colorLabel = .purple
        let matches = try ImageSearch.run(query, catalog: catalog,
                                          label: { labels.add(); return $0.lastPathComponent == b.lastPathComponent ? .purple : .none }).matches
        #expect(matches.map(\.name) == [b.lastPathComponent] && labels.value == 2)

        // Marks a file carries itself count where the catalog has no row.
        query = SearchQuery(scope: t.url, taggedOnly: true)
        let tagged = try ImageSearch.run(query, catalog: catalog,
                                         fileMarks: { $0.lastPathComponent == a.lastPathComponent ? Catalog.Marks(isTagged: true) : nil }).matches
        #expect(tagged.map(\.name) == [a.lastPathComponent])
    }

    @Test func cancellingFindReturnsWhatItHad() throws {
        let t = try makeTree()
        var calls = 0
        let outcome = try ImageSearch.run(SearchQuery(scope: t.url), catalog: .inMemory(),
                                          isCancelled: { calls += 1; return calls > 3 })
        #expect(outcome.isCancelled && outcome.matches.count < 4)
    }
}
