import Testing
import Foundation
@testable import MinivuCore

@Suite struct CatalogTests {
    typealias Marks = Catalog.Marks

    func rowCount(_ catalog: Catalog) throws -> Int {
        Int(try catalog.db.query("SELECT COUNT(*) AS n FROM files").first?.int("n") ?? 0)
    }

    // MARK: - Marks

    @Test func setsAndReadsRatingsAndTags() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg"), c = try t.file("c.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [a, b])
        catalog.setTagged(true, for: [b, c])
        #expect(catalog.marks(for: a) == Marks(rating: 4))
        #expect(catalog.marks(for: b) == Marks(rating: 4, isTagged: true))
        #expect(catalog.marks(for: c) == Marks(isTagged: true))
        let all = catalog.marks(for: [a, b, c, t.url.appendingPathComponent("none.jpg")])
        #expect(all == [a: Marks(rating: 4), b: Marks(rating: 4, isTagged: true), c: Marks(isTagged: true)])
        #expect(catalog.marks(for: []) == [:])

        catalog.setRating(9, for: [c])
        #expect(catalog.marks(for: c).rating == 5)
        catalog.setRating(-3, for: [a])
        #expect(catalog.marks(for: a) == .none)
    }

    @Test func rowsExistOnlyForMarkedFiles() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(0, for: [a])
        catalog.setTagged(false, for: [a])
        #expect(try rowCount(catalog) == 0)
        catalog.setRating(3, for: [a])
        catalog.setTagged(true, for: [a])
        catalog.setRating(0, for: [a])
        #expect(try rowCount(catalog) == 1)                     // still tagged
        catalog.setTagged(false, for: [a])
        #expect(try rowCount(catalog) == 0)
    }

    @Test func recordsFileIdentity() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg", bytes: 123)
        let catalog = Catalog.inMemory()
        catalog.setRating(2, for: [a])
        let row = try #require(try catalog.db.query("SELECT volume, file_id, size, folder FROM files").first)
        let values = try a.resourceValues(forKeys: [.fileIdentifierKey, .volumeUUIDStringKey])
        #expect(row.int("file_id") == values.fileIdentifier.map { Int64(bitPattern: $0) })
        #expect(row.string("volume") == values.volumeUUIDString)
        #expect(row.int("size") == 123)
        #expect(row.string("folder") == Catalog.folderKey(t.url))
    }

    @Test func keysIgnoreSymlinkedFoldersCaseAndNormalisation() throws {
        let t = try TemporaryFolder()
        let file = try t.file("Café.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(5, for: [file])

        // The temporary folder lives under /var, a symlink to /private/var.
        let resolvedPath = t.url.resolvingSymlinksInPath().path
        let privatePath = resolvedPath.hasPrefix("/private") ? resolvedPath : "/private" + resolvedPath
        #expect(catalog.marks(for: URL(fileURLWithPath: privatePath).appendingPathComponent("Café.jpg")).rating == 5)
        #expect(catalog.marks(for: t.url.appendingPathComponent("CAFé.JPG")).rating == 5)
        let decomposed = "Café.jpg".decomposedStringWithCanonicalMapping
        #expect(decomposed.utf8.count != "Café.jpg".utf8.count)
        #expect(catalog.marks(for: t.url.appendingPathComponent(decomposed)).rating == 5)
        #expect(catalog.marks(for: t.url.appendingPathComponent("sub/../Café.jpg")).rating == 5)
        // A symlinked folder reaches the same file.
        let link = t.url.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.url)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(catalog.marks(for: [link.appendingPathComponent("Café.jpg")]).values.first?.rating == 5)
    }

    @Test func pathsNeedingJSONEscapesWork() throws {
        let t = try TemporaryFolder()
        let names = ["quote\".jpg", "back\\slash.jpg", "tab\there.jpg", "emoji 📷.jpg", "plain.jpg"]
        let urls = try names.map { try t.file($0) }
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: urls)
        #expect(catalog.marks(for: urls).count == names.count)
        let json = Catalog.jsonArray(["a\"b", "c\\d", "e\u{1}f"])
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]
        #expect(decoded == ["a\"b", "c\\d", "e\u{1}f"])
    }

    @Test func persistsAcrossLaunches() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let dbURL = t.url.appendingPathComponent("db/catalog.sqlite")
        do {
            let catalog = try Catalog(url: dbURL)
            catalog.setRating(4, for: [a])
            catalog.setCustomOrder(["b.jpg", "a.jpg"], in: t.url)
        }
        let reopened = try Catalog(url: dbURL)
        #expect(reopened.marks(for: a).rating == 4)
        #expect(reopened.customOrder(in: t.url) == ["b.jpg", "a.jpg"])
        #expect(try reopened.db.userVersion() == Catalog.schemaVersion)
    }

    @Test func damagedCatalogIsSetAsideNotDeleted() throws {
        let t = try TemporaryFolder()
        let dbURL = t.url.appendingPathComponent("catalog.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: dbURL)
        let catalog = try Catalog(url: dbURL)
        let a = try t.file("a.jpg")
        catalog.setRating(1, for: [a])
        #expect(catalog.marks(for: a).rating == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(names.contains { $0.hasPrefix("catalog.sqlite.damaged-") })
    }

    @Test func postsDidChangeOnTheMainQueue() async throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = ObserverBox()
            box.token = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil, queue: nil) { note in
                guard (note.object as? [URL])?.contains(a) == true else { return }
                box.finish(Thread.isMainThread, continuation)
            }
            catalog.setRating(2, for: [a])
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { box.finish(false, continuation) }
        }
        #expect(received)
    }

    final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
        private let lock = NSLock()
        private var done = false
        func finish(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
            let first = lock.withLock { defer { done = true }; return !done }
            guard first else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            continuation.resume(returning: value)
        }
    }

    // MARK: - Custom order

    @Test func customOrderReplacesAndDeduplicates() throws {
        let t = try TemporaryFolder()
        let catalog = Catalog.inMemory()
        #expect(catalog.customOrder(in: t.url) == [])
        catalog.setCustomOrder(["c.jpg", "a.jpg", "b.jpg", "a.jpg"], in: t.url)
        #expect(catalog.customOrder(in: t.url) == ["c.jpg", "a.jpg", "b.jpg"])
        catalog.setCustomOrder(["b.jpg"], in: t.url)
        #expect(catalog.customOrder(in: t.url) == ["b.jpg"])
        catalog.setCustomOrder([], in: t.url)
        #expect(catalog.customOrder(in: t.url) == [])
    }

    // MARK: - Moves, copies and removals made by minivu

    @Test func renameKeepsMarksAndPlaceInOrder() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [a])
        catalog.setCustomOrder(["b.jpg", "a.jpg", "c.jpg"], in: t.url)
        let renamed = t.url.appendingPathComponent("z.jpg")
        try FileManager.default.moveItem(at: a, to: renamed)
        catalog.fileMoved(from: a, to: renamed)
        #expect(catalog.marks(for: a) == .none)
        #expect(catalog.marks(for: renamed).rating == 3)
        #expect(catalog.customOrder(in: t.url) == ["b.jpg", "z.jpg", "c.jpg"])
    }

    @Test func moveBetweenFoldersDropsOldPlaceAndReplacedRow() throws {
        let t = try TemporaryFolder()
        let src = try t.folder("src"), dst = try t.folder("dst")
        let a = try t.file("src/a.jpg"), existing = try t.file("dst/a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(2, for: [a])
        catalog.setTagged(true, for: [existing])
        catalog.setCustomOrder(["a.jpg", "x.jpg"], in: src)
        try FileManager.default.removeItem(at: existing)
        try FileManager.default.moveItem(at: a, to: existing)
        catalog.fileMoved(from: a, to: existing)
        #expect(catalog.marks(for: existing) == Marks(rating: 2))
        #expect(catalog.customOrder(in: src) == ["x.jpg"])
        #expect(try rowCount(catalog) == 1)
        _ = dst
    }

    @Test func folderMoveCarriesEverythingInside() throws {
        let t = try TemporaryFolder()
        try t.folder("Trip/Day 1")
        let top = try t.file("Trip/top.jpg"), deep = try t.file("Trip/Day 1/deep.jpg")
        let sibling = try t.folder("Trip 2")
        let outside = try t.file("Trip 2/out.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(1, for: [top])
        catalog.setRating(5, for: [deep, outside])
        catalog.setCustomOrder(["deep.jpg"], in: t.url.appendingPathComponent("Trip/Day 1"))
        catalog.setCustomOrder(["Trip", "Trip 2"], in: t.url)

        let archive = try t.folder("Archive")
        let moved = archive.appendingPathComponent("Trip")
        try FileManager.default.moveItem(at: t.url.appendingPathComponent("Trip"), to: moved)
        catalog.fileMoved(from: t.url.appendingPathComponent("Trip"), to: moved)

        #expect(catalog.marks(for: moved.appendingPathComponent("top.jpg")).rating == 1)
        #expect(catalog.marks(for: moved.appendingPathComponent("Day 1/deep.jpg")).rating == 5)
        #expect(catalog.marks(for: deep) == .none)
        #expect(catalog.marks(for: outside).rating == 5)            // "Trip 2" is not inside "Trip"
        #expect(catalog.customOrder(in: moved.appendingPathComponent("Day 1")) == ["deep.jpg"])
        #expect(catalog.customOrder(in: t.url) == ["Trip 2"])
        _ = sibling
        // The moved rows are still healable: their folder column moved too.
        let row = try #require(try catalog.db.query("SELECT folder FROM files WHERE path = ?1",
                                                    [.text(Catalog.key(moved.appendingPathComponent("Day 1/deep.jpg")))]).first)
        #expect(row.string("folder") == Catalog.folderKey(moved.appendingPathComponent("Day 1")))
    }

    @Test func caseOnlyRenameKeepsMarks() throws {
        let t = try TemporaryFolder()
        try t.folder("trip")
        let a = try t.file("trip/a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [a])
        catalog.setCustomOrder(["a.jpg"], in: t.url.appendingPathComponent("trip"))
        let upper = t.url.appendingPathComponent("Trip")
        #expect(rename(t.url.appendingPathComponent("trip").path, upper.path) == 0)
        catalog.fileMoved(from: t.url.appendingPathComponent("trip"), to: upper)
        #expect(catalog.marks(for: upper.appendingPathComponent("a.jpg")).rating == 4)
        #expect(catalog.customOrder(in: upper) == ["a.jpg"])
        #expect(rename(upper.appendingPathComponent("a.jpg").path, upper.appendingPathComponent("A.jpg").path) == 0)
        catalog.fileMoved(from: upper.appendingPathComponent("a.jpg"), to: upper.appendingPathComponent("A.jpg"))
        #expect(catalog.marks(for: upper.appendingPathComponent("A.jpg")).rating == 4)
        #expect(try catalog.db.query("SELECT path FROM files").first?.string("path")?.hasSuffix("/Trip/A.jpg") == true)
    }

    @Test func copyDuplicatesMarksWithTheCopysIdentity() throws {
        let t = try TemporaryFolder()
        try t.folder("Set/inner")
        let a = try t.file("Set/a.jpg"), b = try t.file("Set/inner/b.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [a])
        catalog.setTagged(true, for: [b])
        catalog.setCustomOrder(["b.jpg"], in: t.url.appendingPathComponent("Set/inner"))
        let copy = t.url.appendingPathComponent("Set copy")
        try FileManager.default.copyItem(at: t.url.appendingPathComponent("Set"), to: copy)
        catalog.fileCopied(from: t.url.appendingPathComponent("Set"), to: copy)

        #expect(catalog.marks(for: a).rating == 3)
        #expect(catalog.marks(for: copy.appendingPathComponent("a.jpg")).rating == 3)
        #expect(catalog.marks(for: copy.appendingPathComponent("inner/b.jpg")).isTagged)
        #expect(catalog.customOrder(in: copy.appendingPathComponent("inner")) == ["b.jpg"])
        let copiedID = try copy.appendingPathComponent("inner/b.jpg").resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
        let row = try #require(try catalog.db.query("SELECT file_id FROM files WHERE path = ?1",
                                                    [.text(Catalog.key(copy.appendingPathComponent("inner/b.jpg")))]).first)
        #expect(row.int("file_id") == copiedID.map { Int64(bitPattern: $0) })
    }

    @Test func removingAFolderForgetsEverythingInside() throws {
        let t = try TemporaryFolder()
        try t.folder("Gone/deeper")
        let a = try t.file("Gone/a.jpg"), b = try t.file("Gone/deeper/b.jpg"), keep = try t.file("Gone2.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(2, for: [a, b, keep])
        catalog.setCustomOrder(["Gone", "Gone2.jpg"], in: t.url)
        catalog.setCustomOrder(["a.jpg"], in: t.url.appendingPathComponent("Gone"))
        catalog.fileRemoved(t.url.appendingPathComponent("Gone"))
        #expect(catalog.marks(for: [a, b, keep]) == [keep: Marks(rating: 2)])
        #expect(catalog.customOrder(in: t.url) == ["Gone2.jpg"])
        #expect(catalog.customOrder(in: t.url.appendingPathComponent("Gone")) == [])
    }

    // MARK: - Healing moves made outside minivu

    @Test func healFindsAFileMovedInFinder() throws {
        let t = try TemporaryFolder()
        let from = try t.folder("from"), to = try t.folder("to")
        let a = try t.file("from/a.jpg", bytes: 10)
        try t.file("to/other.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(5, for: [a])
        catalog.setTagged(true, for: [a])

        let moved = to.appendingPathComponent("renamed too.jpg")
        try FileManager.default.moveItem(at: a, to: moved)       // not through the catalog
        #expect(catalog.marks(for: moved) == .none)

        let healed = catalog.heal(folder: to)
        #expect(healed.map(\.lastPathComponent) == ["renamed too.jpg"])
        #expect(catalog.marks(for: moved) == Marks(rating: 5, isTagged: true))
        #expect(catalog.marks(for: a) == .none)
        #expect(catalog.heal(folder: to).isEmpty)                  // nothing left to do
        #expect(catalog.heal(folder: from).isEmpty)

        // Renamed in Finder within its folder: healed in the same pass that
        // finds its old name gone.
        let finderName = to.appendingPathComponent("Finder name.jpg")
        try FileManager.default.moveItem(at: moved, to: finderName)
        #expect(catalog.heal(folder: to) == [to.appendingPathComponent("Finder name.jpg")])
        #expect(catalog.marks(for: finderName) == Marks(rating: 5, isTagged: true))
        #expect(try catalog.db.query("SELECT missing_since FROM files").first?["missing_since"] == .null)
    }

    @Test func healMarksMissingRowsAndRefreshesSavedFiles() throws {
        let t = try TemporaryFolder()
        let folder = try t.folder("f")
        let a = try t.file("f/a.jpg"), b = try t.file("f/b.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [a, b])

        // A save replaces the file: same name, new inode.
        let replacement = t.url.appendingPathComponent("tmp.jpg")
        try Data(count: 5).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(a, withItemAt: replacement)
        try FileManager.default.removeItem(at: b)
        #expect(catalog.heal(folder: folder).isEmpty)

        let rows = try catalog.db.query("SELECT path, file_id, missing_since FROM files ORDER BY path")
        let newID = try a.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier.map { Int64(bitPattern: $0) }
        #expect(rows[0].int("file_id") == newID)
        #expect(rows[0]["missing_since"] == .null)
        #expect(rows[1]["missing_since"] != .null)
        #expect(catalog.marks(for: a).rating == 3)

        // The saved file, now moved in Finder, is still found.
        let other = try t.folder("other")
        try FileManager.default.moveItem(at: a, to: other.appendingPathComponent("a.jpg"))
        #expect(catalog.heal(folder: other).count == 1)
        #expect(catalog.marks(for: other.appendingPathComponent("a.jpg")).rating == 3)
    }

    @Test func healIgnoresHardLinksAndNewFilesUnderAnOldName() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let other = try t.folder("other")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [a])
        let link = other.appendingPathComponent("link.jpg")
        try FileManager.default.linkItem(at: a, to: link)
        #expect(catalog.heal(folder: other).isEmpty)
        #expect(catalog.marks(for: a).rating == 4)
        #expect(catalog.marks(for: link) == .none)
    }

    @Test func healKeepsCustomOrderThroughFinderRenames() throws {
        let t = try TemporaryFolder()
        let trip = try t.folder("Trip")
        try t.folder("Trip/Day")
        let a = try t.file("Trip/a.jpg"), deep = try t.file("Trip/Day/deep.jpg")
        try t.file("Trip/b.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [a, deep])
        catalog.setCustomOrder(["b.jpg", "a.jpg"], in: trip)
        catalog.setCustomOrder(["deep.jpg", "x.jpg"], in: trip.appendingPathComponent("Day"))

        // Renamed in place: keeps its place under the new name.
        try FileManager.default.moveItem(at: a, to: trip.appendingPathComponent("z.jpg"))
        #expect(catalog.heal(folder: trip).count == 1)
        #expect(catalog.customOrder(in: trip) == ["b.jpg", "z.jpg"])

        // The whole folder renamed: its orders, and its subfolders', follow.
        let renamed = t.url.appendingPathComponent("Trip to Japan")
        try FileManager.default.moveItem(at: trip, to: renamed)
        #expect(catalog.heal(folder: renamed).count == 1)
        #expect(catalog.marks(for: renamed.appendingPathComponent("z.jpg")).rating == 3)
        #expect(catalog.customOrder(in: renamed) == ["b.jpg", "z.jpg"])
        #expect(catalog.customOrder(in: renamed.appendingPathComponent("Day")) == ["deep.jpg", "x.jpg"])
        #expect(catalog.customOrder(in: trip) == [])
        #expect(catalog.heal(folder: renamed.appendingPathComponent("Day")).count == 1)
        #expect(catalog.customOrder(in: renamed.appendingPathComponent("Day")) == ["deep.jpg", "x.jpg"])
    }

    @Test func healMovesOrdersOfARenamedFolderOpenedFromTheInside() throws {
        let t = try TemporaryFolder()
        let trip = try t.folder("Trip"), day = try t.folder("Trip/Day")
        let top = try t.file("Trip/top.jpg"), deep = try t.file("Trip/Day/deep.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(1, for: [top, deep])
        catalog.setCustomOrder(["Day", "top.jpg"], in: trip)
        catalog.setCustomOrder(["deep.jpg"], in: day)
        let renamed = t.url.appendingPathComponent("Trip 2024")
        try FileManager.default.moveItem(at: trip, to: renamed)
        // The subfolder is opened first, then the renamed folder itself.
        #expect(catalog.heal(folder: renamed.appendingPathComponent("Day")).count == 1)
        #expect(catalog.customOrder(in: renamed.appendingPathComponent("Day")) == ["deep.jpg"])
        #expect(catalog.heal(folder: renamed).count == 1)
        #expect(catalog.customOrder(in: renamed) == ["Day", "top.jpg"])
        #expect(catalog.customOrder(in: renamed.appendingPathComponent("Day")) == ["deep.jpg"])
    }

    @Test func healDropsThePlaceOfAFileThatLeftAFolderStillThere() throws {
        let t = try TemporaryFolder()
        let from = try t.folder("from"), to = try t.folder("to")
        let a = try t.file("from/a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(2, for: [a])
        catalog.setCustomOrder(["a.jpg", "b.jpg"], in: from)
        catalog.setCustomOrder(["c.jpg"], in: to)
        try FileManager.default.moveItem(at: a, to: to.appendingPathComponent("a.jpg"))
        #expect(catalog.heal(folder: to).count == 1)
        #expect(catalog.customOrder(in: from) == ["b.jpg"])
        #expect(catalog.customOrder(in: to) == ["c.jpg"])
    }

    @Test func healStampsRowsWhoseFileLeftTheTrash() throws {
        let t = try TemporaryFolder()
        try t.folder(".Trash")
        let emptied = try t.file(".Trash/emptied.jpg"), kept = try t.file(".Trash/kept.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [emptied, kept])
        try FileManager.default.removeItem(at: emptied)
        catalog.heal(folder: try t.folder("elsewhere"))
        let rows = try catalog.db.query("SELECT path, missing_since FROM files ORDER BY path")
        #expect(rows.count == 2)
        #expect(rows[0].string("path")?.hasSuffix("emptied.jpg") == true && rows[0]["missing_since"] != .null)
        #expect(rows[1].string("path")?.hasSuffix("kept.jpg") == true && rows[1]["missing_since"] == .null)
    }

    /// Test runs must never read or write the user's real catalog.
    @Test func sharedCatalogIsPrivateInTestRuns() throws {
        #expect(Catalog.usesPrivateCatalog(ProcessInfo.processInfo))
        let file = try Catalog.shared.db.query("PRAGMA database_list").first?.string("file")
        #expect(file == "")
    }

    @Test func healPrunesRowsMissingForAYear() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(1, for: [a])
        try catalog.db.execute("UPDATE files SET missing_since = ?1", [.real(Date().timeIntervalSince1970 - 400 * 86400)])
        catalog.heal(folder: try t.folder("elsewhere"))
        #expect(try rowCount(catalog) == 0)
    }

    /// Both array lookups must loop over the array and search an index.
    @Test func arrayLookupsSearchTheIndex() throws {
        let catalog = Catalog.inMemory()
        for sql in ["SELECT j.key AS i, f.rating AS rating FROM json_each(?1) AS j CROSS JOIN files AS f ON f.path = j.value",
                    "SELECT j.key AS i, f.id AS id FROM json_each(?1) AS j CROSS JOIN files AS f ON f.volume = ?2 AND f.file_id = j.value"] {
            let arguments: [SQLiteValue] = sql.contains("?2") ? [.text("[1]"), .text("v")] : [.text("[\"a\"]")]
            let plan = try catalog.db.query("EXPLAIN QUERY PLAN " + sql, arguments).compactMap { $0.string("detail") }
            #expect(plan.first?.hasPrefix("SCAN j") == true, "\(plan)")
            #expect(plan.last?.hasPrefix("SEARCH f USING") == true && plan.last?.contains("INDEX") == true, "\(plan)")
        }
    }

    // MARK: - Performance

    /// Limits are for release builds; debug builds get four times as long.
    static let slack: Double = {
        #if DEBUG
        4
        #else
        1
        #endif
    }()

    @Test func readingMarksForAFolderIsFast() throws {
        let catalog = Catalog.inMemory()
        let folder = URL(fileURLWithPath: "/Users/someone/Pictures/Big Trip", isDirectory: true)
        let rated = (0..<10_000).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)) }
        for rating in 1...5 {
            catalog.setRating(rating, for: rated.enumerated().filter { $0.offset % 5 == rating - 1 }.map(\.element))
        }
        #expect(try rowCount(catalog) == 10_000)
        let asked = (0..<5_000).map { folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0 * 3)) }
        _ = catalog.marks(for: asked)                              // warm the statement cache
        var result: [URL: Marks] = [:]
        let elapsed = ContinuousClock().measure { result = catalog.marks(for: asked) }
        print("marks(for: 5,000 URLs) among 10,000 rows: \(elapsed)")
        #expect(result.count == (0..<5_000).filter { $0 * 3 < 10_000 }.count)
        #expect(result[asked[1]] == Marks(rating: 3 % 5 + 1))
        #expect(elapsed < .milliseconds(30 * Self.slack))
    }

    @Test func ratingAThousandFilesIsOneQuickTransaction() throws {
        let t = try TemporaryFolder()
        let files = try (0..<1_000).map { try t.file("f\($0).jpg") }
        let catalog = Catalog.inMemory()
        catalog.setRating(1, for: [try t.file("warm.jpg")])
        let elapsed = ContinuousClock().measure { catalog.setRating(4, for: files) }
        print("setRating for 1,000 files: \(elapsed)")
        #expect(catalog.marks(for: files).count == 1_000)
        #expect(elapsed < .milliseconds(50 * Self.slack))
    }
}
