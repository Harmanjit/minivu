import Testing
import Foundation
@testable import AgateCore

/// A fresh, empty folder in the temporary directory, deleted when the value
/// goes away. Also used by the other suites in this target.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agate-core-tests-\(getpid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, bytes: Int = 0) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(count: bytes).write(to: file)
        return file
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@Suite struct FolderListingTests {
    func makeMixedFolder() throws -> TemporaryFolder {
        let t = try TemporaryFolder()
        for name in ["img10.jpg", "img2.jpg", "IMG1.JPG", "photo.heic", "scan.NEF", "notes.txt", ".hidden.jpg"] {
            try t.file(name)
        }
        try t.folder("Sub 10")
        try t.folder("Sub 2")
        try t.folder("fake.jpg")          // a folder with an image extension is still a folder
        try t.folder("Tool.app")          // a package: neither folder nor image
        try t.folder(".git")              // hidden folder
        return t
    }

    @Test func listsImagesAndFoldersSkippingHiddenAndPackages() throws {
        let t = try makeMixedFolder()
        let contents = try FolderListing.contents(of: t.url)
        let images = FolderListing.sorted(contents.images, by: FileSortOrder()).map(\.name)
        let folders = FolderListing.sorted(contents.subfolders, by: FileSortOrder()).map(\.name)
        #expect(images == ["IMG1.JPG", "img2.jpg", "img10.jpg", "photo.heic", "scan.NEF"])
        #expect(folders == ["fake.jpg", "Sub 2", "Sub 10"])
        #expect(contents.images.first { $0.name == "scan.NEF" }?.kind == .raw)
        #expect(contents.subfolders.allSatisfy { $0.isDirectory && $0.kind == nil })
    }

    @Test func includeHiddenShowsDotFiles() throws {
        let t = try makeMixedFolder()
        let contents = try FolderListing.contents(of: t.url, includeHidden: true)
        #expect(contents.images.contains { $0.name == ".hidden.jpg" })
        #expect(contents.subfolders.contains { $0.name == ".git" })
        #expect(!contents.subfolders.contains { $0.name == "Tool.app" })
    }

    @Test func refusesFoldersVolumePolicyRejects() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect {
            try FolderListing.contents(of: missing)
        } throws: { error in
            if case FolderListingError.notAllowed = error { return true }
            return false
        }
    }

    @Test func subfoldersAreFinderSorted() throws {
        let t = try makeMixedFolder()
        #expect(FolderListing.subfolders(of: t.url).map(\.lastPathComponent) == ["fake.jpg", "Sub 2", "Sub 10"])
        #expect(FolderListing.subfolders(of: t.url, includeHidden: true).map(\.lastPathComponent)
                == [".git", "fake.jpg", "Sub 2", "Sub 10"])
        #expect(FolderListing.subfolders(of: t.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test func hasSubfoldersIgnoresFilesPackagesAndHidden() throws {
        let t = try makeMixedFolder()
        #expect(FolderListing.hasSubfolders(t.url))
        #expect(!FolderListing.hasSubfolders(t.url.appendingPathComponent("Sub 2")))

        let onlyOthers = try TemporaryFolder()
        try onlyOthers.file("a.jpg")
        try onlyOthers.folder("Thing.app")
        try onlyOthers.folder(".hidden")
        #expect(!FolderListing.hasSubfolders(onlyOthers.url))
        #expect(FolderListing.hasSubfolders(onlyOthers.url, includeHidden: true))
    }

    // MARK: - Sorting

    func entry(_ name: String, folder: String = "/a", size: Int64 = 0, modified: Double = 0,
               created: Double = 0) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "\(folder)/\(name)"), name: name, isDirectory: false,
                    kind: ImageFormats.kind(of: URL(fileURLWithPath: name)), fileSize: size,
                    modified: Date(timeIntervalSinceReferenceDate: modified),
                    created: Date(timeIntervalSinceReferenceDate: created))
    }

    @Test func sortsByNameNaturally() {
        let entries = ["b.jpg", "img10.jpg", "IMG2.jpg", "img1.jpg", "a.png"].map { entry($0) }
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .name)).map(\.name)
                == ["a.png", "b.jpg", "img1.jpg", "IMG2.jpg", "img10.jpg"])
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .name, ascending: false)).map(\.name)
                == ["img10.jpg", "IMG2.jpg", "img1.jpg", "b.jpg", "a.png"])
    }

    @Test func sortsBySizeWithNameTiebreak() {
        let entries = [entry("c.jpg", size: 10), entry("b.jpg", size: 5), entry("a.jpg", size: 10)]
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .size)).map(\.name) == ["b.jpg", "a.jpg", "c.jpg"])
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .size, ascending: false)).map(\.name)
                == ["c.jpg", "a.jpg", "b.jpg"])
    }

    @Test func sortsByDatesAndType() {
        let entries = [entry("x.png", modified: 3, created: 1), entry("y.jpg", modified: 1, created: 3),
                       entry("a.png", modified: 2, created: 2)]
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .modified)).map(\.name) == ["y.jpg", "a.png", "x.png"])
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .created)).map(\.name) == ["x.png", "a.png", "y.jpg"])
        #expect(FolderListing.sorted(entries, by: FileSortOrder(key: .type)).map(\.name) == ["y.jpg", "a.png", "x.png"])
    }

    @Test func sortIsStableForTies() {
        // Same name and size in different folders compare equal on every key.
        let entries = (0..<20).map { entry("same.jpg", folder: "/f\($0)", size: 1) }
        for key in SortKey.allCases {
            for ascending in [true, false] {
                let sorted = FolderListing.sorted(entries, by: FileSortOrder(key: key, ascending: ascending))
                #expect(sorted.map(\.url) == entries.map(\.url), "\(key) ascending \(ascending)")
            }
        }
    }

    /// 3,000 files must list and sort quickly even in a debug build.
    @Test func listsThreeThousandFilesQuickly() throws {
        let t = try TemporaryFolder()
        for i in 0..<3000 { try t.file("photo\(i).jpg") }
        try t.file("readme.txt")

        let clock = ContinuousClock()
        var sorted: [FolderEntry] = []
        let elapsed = try clock.measure {
            let contents = try FolderListing.contents(of: t.url)
            sorted = FolderListing.sorted(contents.images, by: FileSortOrder())
        }
        #expect(sorted.count == 3000)
        #expect(sorted.prefix(3).map(\.name) == ["photo0.jpg", "photo1.jpg", "photo2.jpg"])
        #expect(sorted[10].name == "photo10.jpg")
        #expect(sorted.last?.name == "photo2999.jpg")
        #expect(elapsed < .milliseconds(500), "listing took \(elapsed)")
    }
}
