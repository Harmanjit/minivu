import Testing
import Foundation
@testable import MinivuCore

@Suite struct FileOperationsTests {
    typealias Ops = FileOperations

    /// A temporary folder with a stand-in Trash inside it, so tests never
    /// touch the user's real Trash.
    struct Sandbox {
        let t: TemporaryFolder
        let trash: URL
        let catalog = Catalog.inMemory()
        var environment: Ops.Environment

        init() throws {
            t = try TemporaryFolder()
            let trash = try t.folder(".FakeTrash")
            self.trash = trash
            environment = Ops.Environment(
                trash: { url in
                    let destination = trash.appendingPathComponent(UUID().uuidString + " " + url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: destination)
                    return destination
                },
                isAllowedVolume: { _ in true })
        }

        func copy(_ urls: [URL], to folder: URL, _ conflict: Ops.ConflictPolicy,
                  progress: ((Int, Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> Ops.Result {
            Ops.transfer(urls, to: folder, conflict: conflict, move: false, catalog: catalog, environment: environment,
                         progress: progress, isCancelled: isCancelled)
        }

        func move(_ urls: [URL], to folder: URL, _ conflict: Ops.ConflictPolicy,
                  progress: ((Int, Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> Ops.Result {
            Ops.transfer(urls, to: folder, conflict: conflict, move: true, catalog: catalog, environment: environment,
                         progress: progress, isCancelled: isCancelled)
        }

        @discardableResult
        func write(_ name: String, _ text: String) throws -> URL {
            let url = t.url.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
    }

    func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    func exists(_ url: URL) -> Bool { Ops.itemExists(url) }
    func inode(_ url: URL) throws -> UInt64? { try url.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier }

    // MARK: - Copy

    @Test func copyKeepsTagsDatesAndMarks() throws {
        let s = try Sandbox()
        let src = try s.t.folder("src"), dst = try s.t.folder("dst")
        let a = try s.write("src/a.jpg", "A")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        try FinderTags.setTags(["Red", "Keep"], for: a)
        s.catalog.setRating(4, for: [a])

        let result = s.copy([a], to: dst, .skip)
        let copy = dst.appendingPathComponent("a.jpg")
        #expect(result.completed == [Ops.Transfer(from: a, to: copy)])
        #expect(text(copy) == "A" && text(a) == "A")
        #expect(FinderTags.tags(for: copy) == ["Red", "Keep"])
        let modified = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(modified == date)
        #expect(s.catalog.marks(for: copy).rating == 4)
        #expect(s.catalog.marks(for: a).rating == 4)
        _ = src
    }

    @Test func copyIntoItsOwnFolderDuplicates() throws {
        let s = try Sandbox()
        let a = try s.write("photo.jpg", "A")
        for policy in [Ops.ConflictPolicy.skip, .replace, .keepBoth] {
            let result = s.copy([a], to: s.t.url, policy)
            #expect(result.completed.count == 1)
        }
        #expect(exists(s.t.url.appendingPathComponent("photo 2.jpg")))
        #expect(exists(s.t.url.appendingPathComponent("photo 3.jpg")))
        #expect(exists(s.t.url.appendingPathComponent("photo 4.jpg")))
        #expect(text(a) == "A")
    }

    @Test func copyingAFolderCopiesTheMarksInside() throws {
        let s = try Sandbox()
        try s.t.folder("Trip/Day")
        let deep = try s.write("Trip/Day/deep.jpg", "D")
        let dst = try s.t.folder("Backup")
        s.catalog.setTagged(true, for: [deep])
        let result = s.copy([s.t.url.appendingPathComponent("Trip")], to: dst, .skip)
        #expect(result.completed.count == 1)
        #expect(s.catalog.marks(for: dst.appendingPathComponent("Trip/Day/deep.jpg")).isTagged)
    }

    // MARK: - Move

    @Test func moveIsARenameAndCarriesMarks() throws {
        let s = try Sandbox()
        try s.t.folder("Trip/Day")
        let top = try s.write("Trip/top.jpg", "T")
        let deep = try s.write("Trip/Day/deep.jpg", "D")
        let dst = try s.t.folder("Archive")
        s.catalog.setRating(2, for: [top])
        s.catalog.setRating(5, for: [deep])
        let before = try inode(deep)

        let trip = s.t.url.appendingPathComponent("Trip")
        let result = s.move([trip], to: dst, .skip)
        let moved = dst.appendingPathComponent("Trip")
        #expect(result.completed.map(\.to.lastPathComponent) == ["Trip"])
        #expect(!exists(trip))
        #expect(try inode(moved.appendingPathComponent("Day/deep.jpg")) == before)
        #expect(s.catalog.marks(for: moved.appendingPathComponent("top.jpg")).rating == 2)
        #expect(s.catalog.marks(for: moved.appendingPathComponent("Day/deep.jpg")).rating == 5)
        #expect(s.catalog.marks(for: deep) == .none)
    }

    @Test func moveIntoTheSameFolderIsSkipped() throws {
        let s = try Sandbox()
        let a = try s.write("a.jpg", "A")
        let result = s.move([a], to: s.t.url, .keepBoth)
        #expect(result.skipped == [a] && result.completed.isEmpty)
        #expect(text(a) == "A")
    }

    // MARK: - Conflicts

    @Test func skipLeavesTheDestinationAlone() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "new")
        let existing = try s.write("dst/a.jpg", "old")
        for move in [false, true] {
            let result = move ? s.move([a], to: dst, .skip) : s.copy([a], to: dst, .skip)
            #expect(result.skipped == [a] && result.completed.isEmpty && result.failed.isEmpty)
        }
        #expect(text(existing) == "old" && text(a) == "new")
    }

    @Test func keepBothPicksTheNextFreeName() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "new")
        try s.write("dst/a.jpg", "old")
        try s.write("dst/a 2.jpg", "old 2")
        let result = s.move([a], to: dst, .keepBoth)
        #expect(result.completed.map(\.to.lastPathComponent) == ["a 3.jpg"])
        #expect(text(dst.appendingPathComponent("a 3.jpg")) == "new")
        #expect(text(dst.appendingPathComponent("a.jpg")) == "old")
    }

    @Test func replaceTrashesTheOldFileAndUndoBringsItBack() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "new")
        let existing = try s.write("dst/a.jpg", "old")
        s.catalog.setRating(1, for: [a])
        s.catalog.setRating(5, for: [existing])

        let result = s.move([a], to: dst, .replace)
        let transfer = try #require(result.completed.first)
        let trashed = try #require(transfer.replaced)
        #expect(transfer.from == a && transfer.to.path == existing.path)
        #expect(text(existing) == "new")
        #expect(trashed.path.hasPrefix(s.trash.path) && text(trashed) == "old")   // trashed, not deleted
        #expect(s.catalog.marks(for: existing).rating == 1)
        #expect(s.catalog.marks(for: trashed).rating == 5)

        let undo = Ops.undoMove(result, catalog: s.catalog)
        #expect(undo.failed.isEmpty && undo.completed.count == 2)
        #expect(text(a) == "new" && text(existing) == "old")
        #expect(s.catalog.marks(for: a).rating == 1)
        #expect(s.catalog.marks(for: existing).rating == 5)
    }

    /// A copy that fails cleans up only after itself: here another app puts
    /// a file at the destination between the Trash step and the copy.
    @Test func failedCopyNeverRemovesWhatAnotherAppPutThere() throws {
        var s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "new")
        try s.write("dst/a.jpg", "old")
        let trash = s.trash
        s.environment.trash = { url in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: destination)
            try Data("newcomer".utf8).write(to: url)
            return destination
        }
        let result = s.copy([a], to: dst, .replace)
        #expect(result.failed.map(\.url) == [a] && result.completed.isEmpty)
        #expect(text(dst.appendingPathComponent("a.jpg")) == "newcomer")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(trashed.count == 1 && text(trash.appendingPathComponent(trashed[0])) == "old")   // still recoverable
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["a.jpg"])     // no temporary copy left
    }

    @Test func copyThatFailsPartwayLeavesNothingBehind() throws {
        let s = try Sandbox()
        try s.t.folder("Set")
        try s.write("Set/readable.jpg", "R")
        let locked = try s.write("Set/locked.jpg", "L")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let dst = try s.t.folder("dst")
        let result = s.copy([s.t.url.appendingPathComponent("Set")], to: dst, .skip)
        #expect(result.failed.count == 1 && result.completed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == [])

        let ok = s.copy([s.t.url.appendingPathComponent("Set/readable.jpg")], to: dst, .skip)
        #expect(ok.completed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["readable.jpg"])
    }

    /// A move to another volume copies first. A copy that fails partway
    /// leaves the original whole and nothing under the destination's name;
    /// one that succeeds removes the original. (Exercised on one volume:
    /// EXDEV itself needs a second volume.)
    @Test func moveAcrossVolumesNeverLeavesAPartialItem() throws {
        let s = try Sandbox()
        try s.t.folder("Set")
        try s.write("Set/readable.jpg", "R")
        let locked = try s.write("Set/locked.jpg", "L")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let dst = try s.t.folder("dst")
        let set = s.t.url.appendingPathComponent("Set")
        #expect(throws: (any Error).self) { try FileOperations.moveByCopying(set, to: dst.appendingPathComponent("Set")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: set.path).sorted() == ["locked.jpg", "readable.jpg"])

        let readable = set.appendingPathComponent("readable.jpg")
        try FileOperations.moveByCopying(readable, to: dst.appendingPathComponent("readable.jpg"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["readable.jpg"])
        #expect(!FileManager.default.fileExists(atPath: readable.path))
        try s.write("Set/other.jpg", "O")
        #expect(throws: (any Error).self) {
            try FileOperations.moveByCopying(set.appendingPathComponent("other.jpg"), to: dst.appendingPathComponent("readable.jpg"))
        }
        #expect(try String(contentsOf: dst.appendingPathComponent("readable.jpg"), encoding: .utf8) == "R")
    }

    @Test func neverReplacesAcrossFilesAndFolders() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let file = try s.write("item", "file")
        try s.t.folder("dst/item")
        try s.t.folder("sub")
        let folder = s.t.url.appendingPathComponent("sub/thing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try s.write("dst/thing", "a file")

        let fileOverFolder = s.move([file], to: dst, .replace)
        #expect(fileOverFolder.failed.count == 1 && fileOverFolder.completed.isEmpty)
        #expect(fileOverFolder.failed.first?.message.contains("folder") == true)
        let folderOverFile = s.copy([folder], to: dst, .replace)
        #expect(folderOverFile.failed.count == 1 && folderOverFile.completed.isEmpty)
        #expect(exists(file) && text(dst.appendingPathComponent("thing")) == "a file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.trash.path).isEmpty)
    }

    @Test func refusesFoldersIntoThemselves() throws {
        let s = try Sandbox()
        let trip = try s.t.folder("Trip")
        let day = try s.t.folder("Trip/Day")
        for move in [false, true] {
            for target in [trip, day] {
                let result = move ? s.move([trip], to: target, .keepBoth) : s.copy([trip], to: target, .keepBoth)
                #expect(result.failed.count == 1 && result.completed.isEmpty)
            }
        }
        // Through a symlink and a different case, too.
        let link = s.t.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: day)
        #expect(s.move([trip], to: link, .keepBoth).failed.count == 1)
        #expect(s.move([trip], to: s.t.url.appendingPathComponent("TRIP/DAY"), .keepBoth).failed.count == 1)
        #expect(exists(day))
    }

    @Test func refusesToReplaceTheFolderHoldingTheSource() throws {
        let s = try Sandbox()
        try s.t.folder("Photos/Photos")
        let inner = s.t.url.appendingPathComponent("Photos/Photos")
        try s.write("Photos/Photos/a.jpg", "A")
        let result = s.move([inner], to: s.t.url, .replace)
        #expect(result.failed.count == 1)
        #expect(exists(inner.appendingPathComponent("a.jpg")))
    }

    @Test func refusesVolumesThePolicyRejects() throws {
        var s = try Sandbox()
        s.environment.isAllowedVolume = { _ in false }
        let a = try s.write("a.jpg", "A")
        let dst = try s.t.folder("dst")
        let result = s.copy([a], to: dst, .keepBoth)
        #expect(result.failed.map(\.url) == [a] && result.completed.isEmpty)
        #expect(!exists(dst.appendingPathComponent("a.jpg")))
        #expect(!VolumePolicy.isAllowed(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
        #expect(s.move([a], to: s.t.url.appendingPathComponent("missing"), .skip).failed.count == 1)
    }

    @Test func reportsMissingSources() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let gone = s.t.url.appendingPathComponent("gone.jpg")
        let a = try s.write("a.jpg", "A")
        let result = s.copy([gone, a], to: dst, .skip)
        #expect(result.failed.map(\.url) == [gone])
        #expect(result.completed.count == 1)
    }

    // MARK: - Progress and cancellation

    @Test func reportsProgressAndStopsWhenCancelled() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let files = try (0..<5).map { try s.write("f\($0).jpg", "\($0)") }
        var reports: [String] = []
        let all = s.copy(files, to: dst, .skip, progress: { reports.append("\($0)/\($1)") })
        #expect(reports == ["1/5", "2/5", "3/5", "4/5", "5/5"])
        #expect(all.completed.count == 5 && !all.wasCancelled)

        let other = try s.t.folder("other")
        var asked = 0
        reports = []
        let cancelled = s.move(files, to: other, .skip, progress: { reports.append("\($0)/\($1)") },
                               isCancelled: { asked += 1; return asked > 2 })
        #expect(cancelled.wasCancelled)
        #expect(cancelled.completed.count == 2 && reports == ["1/5", "2/5"])
        #expect(exists(files[2]) && !exists(files[1]))
    }

    // MARK: - Undo

    @Test func undoCopyTrashesTheCopies() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "A")
        try s.write("dst/a.jpg", "old")
        s.catalog.setRating(3, for: [a])
        let result = s.copy([a], to: dst, .replace)
        #expect(s.catalog.marks(for: dst.appendingPathComponent("a.jpg")).rating == 3)

        let undo = Ops.undoCopy(result, catalog: s.catalog, environment: s.environment)
        #expect(undo.failed.isEmpty)
        #expect(text(dst.appendingPathComponent("a.jpg")) == "old")     // the replaced file is back
        #expect(text(a) == "A")
        #expect(s.catalog.marks(for: dst.appendingPathComponent("a.jpg")) == .none)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: s.trash.path)
        #expect(trashed.count == 1)                                     // the copy, trashed not deleted
    }

    @Test func undoMoveNeverOverwrites() throws {
        let s = try Sandbox()
        let dst = try s.t.folder("dst")
        let a = try s.write("a.jpg", "A")
        let result = s.move([a], to: dst, .skip)
        try s.write("a.jpg", "newcomer")
        let undo = Ops.undoMove(result, catalog: s.catalog)
        #expect(undo.failed.count == 1 && undo.completed.isEmpty)
        #expect(text(a) == "newcomer" && text(dst.appendingPathComponent("a.jpg")) == "A")
    }

    // MARK: - Rename

    @Test func validatesNames() throws {
        let s = try Sandbox()
        let a = try s.write("a.jpg", "A")
        try s.write("b.jpg", "B")
        let folder = s.t.url
        #expect(Ops.validateName("", in: folder, excluding: a) != nil)
        #expect(Ops.validateName("   ", in: folder, excluding: a) != nil)
        #expect(Ops.validateName("x/y.jpg", in: folder, excluding: a) != nil)
        #expect(Ops.validateName("x:y.jpg", in: folder, excluding: a) != nil)
        #expect(Ops.validateName(".hidden.jpg", in: folder, excluding: a) != nil)
        #expect(Ops.validateName("tab\there.jpg", in: folder, excluding: a) != nil)
        #expect(Ops.validateName(String(repeating: "é", count: 128), in: folder, excluding: a) != nil)   // 256 bytes
        #expect(Ops.validateName(String(repeating: "e", count: 255), in: folder, excluding: a) == nil)
        #expect(Ops.validateName("b.jpg", in: folder, excluding: a)?.contains("already taken") == true)
        #expect(Ops.validateName("B.JPG", in: folder, excluding: a)?.contains("already taken") == true)
        #expect(Ops.validateName("A.JPG", in: folder, excluding: a) == nil)     // itself, another case
        #expect(Ops.validateName("a.jpg", in: folder, excluding: a) == nil)
        #expect(Ops.validateName("c.jpg", in: folder, excluding: nil) == nil)
    }

    @Test func renameMovesMarksAndUndoes() throws {
        let s = try Sandbox()
        let a = try s.write("a.jpg", "A")
        s.catalog.setRating(4, for: [a])
        s.catalog.setCustomOrder(["z.jpg", "a.jpg"], in: s.t.url)
        let renamed = try Ops.rename(a, to: "sunset.jpg", catalog: s.catalog)
        #expect(renamed.lastPathComponent == "sunset.jpg" && text(renamed) == "A" && !exists(a))
        #expect(s.catalog.marks(for: renamed).rating == 4)
        #expect(s.catalog.customOrder(in: s.t.url) == ["z.jpg", "sunset.jpg"])

        #expect(throws: CocoaError.self) { try Ops.rename(renamed, to: "bad/name.jpg", catalog: s.catalog) }
        try s.write("taken.jpg", "T")
        #expect(throws: CocoaError.self) { try Ops.rename(renamed, to: "taken.jpg", catalog: s.catalog) }

        let back = try Ops.undoRename(renamed, to: a, catalog: s.catalog)
        #expect(back.path == a.path && text(a) == "A")
        #expect(s.catalog.marks(for: a).rating == 4)
        #expect(try Ops.rename(a, to: "a.jpg", catalog: s.catalog) == a)
    }

    @Test func caseOnlyRenameWorks() throws {
        let s = try Sandbox()
        let a = try s.write("photo.jpg", "A")
        s.catalog.setTagged(true, for: [a])
        let renamed = try Ops.rename(a, to: "Photo.JPG", catalog: s.catalog)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.t.url.path).contains("Photo.JPG"))
        #expect(text(renamed) == "A")
        #expect(s.catalog.marks(for: renamed).isTagged)
        let folder = try s.t.folder("trip")
        let upper = try Ops.rename(folder, to: "Trip", catalog: s.catalog)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.t.url.path).contains("Trip"))
        #expect(upper.lastPathComponent == "Trip")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: s.t.url.path).contains { $0.hasPrefix(".minivu-rename") }))
    }

    // MARK: - New folders and unique names

    @Test func createsUniqueFolders() throws {
        let s = try Sandbox()
        let first = try Ops.createFolder(in: s.t.url)
        let second = try Ops.createFolder(in: s.t.url)
        let named = try Ops.createFolder(in: s.t.url, name: "2024.06 Trip")
        let again = try Ops.createFolder(in: s.t.url, name: "2024.06 Trip")
        #expect([first, second, named, again].map(\.lastPathComponent)
                == ["untitled folder", "untitled folder 2", "2024.06 Trip", "2024.06 Trip 2"])
        #expect(throws: CocoaError.self) { try Ops.createFolder(in: s.t.url, name: "a/b") }
    }

    @Test func uniqueNamesContinueCounters() throws {
        let s = try Sandbox()
        let folder = s.t.url
        #expect(Ops.uniqueName(for: "free.jpg", in: folder) == "free.jpg")
        for name in ["photo.jpg", "photo 2.jpg", "README", "IMG 0042.jpg", "Trip 2024", "photo 1.jpg", "v1.5", "archive.tar.gz"] {
            try s.write(name, "x")
        }
        #expect(Ops.uniqueName(for: "photo.jpg", in: folder) == "photo 3.jpg")
        #expect(Ops.uniqueName(for: "photo 2.jpg", in: folder) == "photo 3.jpg")
        #expect(Ops.uniqueName(for: "README", in: folder) == "README 2")
        #expect(Ops.uniqueName(for: "IMG 0042.jpg", in: folder) == "IMG 0042 2.jpg")
        #expect(Ops.uniqueName(for: "Trip 2024", in: folder, isDirectory: true) == "Trip 2024 2")
        #expect(Ops.uniqueName(for: "photo 1.jpg", in: folder) == "photo 1 2.jpg")
        #expect(Ops.uniqueName(for: "archive.tar.gz", in: folder) == "archive.tar 2.gz")
        #expect(Ops.uniqueName(for: "PHOTO.JPG", in: folder) == "PHOTO 3.JPG")         // case-insensitive volume
        try s.write("photo 3.jpg", "x")
        #expect(Ops.uniqueName(for: "photo 2.jpg", in: folder) == "photo 4.jpg")
        // A broken symlink still takes its name.
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link.jpg").path,
                                                   withDestinationPath: "/nonexistent-\(UUID().uuidString)")
        #expect(Ops.uniqueName(for: "link.jpg", in: folder) == "link 2.jpg")
    }
}
