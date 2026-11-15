import Testing
import Foundation
@testable import MinivuCore

/// Schema version 3 (G3): the upgrade from catalogs earlier minivus wrote,
/// the metadata cache, collections and smart folders.
@Suite struct CatalogLibraryTests {
    typealias Marks = Catalog.Marks

    // MARK: - Upgrading

    /// A catalog written by the minivu with schema version 2 (ratings, a
    /// tag, a row standing over a file's own marks, a custom order and a
    /// non-ASCII name), opened by this one.
    @Test func upgradesARealVersion2Catalog() throws {
        let t = try TemporaryFolder()
        let fixture = try #require(Bundle.module.url(forResource: "catalog-v2", withExtension: "sqlite",
                                                     subdirectory: "Fixtures"))
        let url = t.url.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: fixture, to: url)
        let before = try SQLiteDatabase(url: url)
        #expect(try before.userVersion() == 2)

        let catalog = try Catalog(url: url)
        #expect(catalog.storage == .persistent)
        #expect(try catalog.db.userVersion() == Catalog.schemaVersion)
        let folder = URL(fileURLWithPath: "/Users/Shared/minivu-fixture", isDirectory: true)
        let a = folder.appendingPathComponent("a.jpg"), b = folder.appendingPathComponent("b.jpg")
        let c = folder.appendingPathComponent("Ünïcode.heic")
        #expect(catalog.marks(for: [a, b, c]) == [a: Marks(rating: 4), b: Marks(isTagged: true),
                                                   c: Marks(rating: 2, isTagged: true)])
        let overrides = try catalog.db.query("SELECT overrides_file, file_id FROM files WHERE path LIKE '%b.jpg'").first
        #expect(overrides?.int("overrides_file") == 1 && overrides?.int("file_id") == 4242)
        #expect(catalog.customOrder(in: folder) == ["b.jpg", "a.jpg", "Ünïcode.heic"])

        // Every new table is there and works.
        let id = try #require(catalog.createCollection(named: "Best"))
        #expect(catalog.collections().map(\.name) == ["Best"] && catalog.collections().first?.id == id)
        #expect(catalog.saveSmartFolder(named: "Recent", query: SearchQuery(scope: folder)) != nil)
        #expect(try catalog.db.query("SELECT COUNT(*) AS n FROM metadata").first?.int("n") == 0)
    }

    /// A version 1 catalog (before the row standing over a file's marks)
    /// goes through both steps.
    @Test func upgradesAVersion1Catalog() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("catalog.sqlite")
        do {
            let db = try SQLiteDatabase(url: url)
            try db.executeScript("""
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    folder TEXT NOT NULL COLLATE NOCASE,
                    volume TEXT,
                    file_id INTEGER,
                    size INTEGER,
                    modified REAL,
                    rating INTEGER NOT NULL DEFAULT 0,
                    tagged INTEGER NOT NULL DEFAULT 0,
                    missing_since REAL
                );
                CREATE INDEX files_identity ON files (volume, file_id);
                CREATE INDEX files_folder ON files (folder);
                CREATE TABLE folder_order (
                    folder TEXT NOT NULL COLLATE NOCASE,
                    name TEXT NOT NULL COLLATE NOCASE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (folder, name)
                ) WITHOUT ROWID;
                INSERT INTO files (path, folder, rating, tagged) VALUES ('/old/one.jpg', '/old', 3, 1);
                INSERT INTO folder_order (folder, name, position) VALUES ('/old', 'one.jpg', 0);
                PRAGMA user_version = 1;
                """)
        }
        let catalog = try Catalog(url: url)
        #expect(try catalog.db.userVersion() == 3)
        #expect(catalog.marks(for: URL(fileURLWithPath: "/old/one.jpg")) == Marks(rating: 3, isTagged: true))
        #expect(try catalog.db.query("SELECT overrides_file FROM files").first?.int("overrides_file") == 0)
        #expect(catalog.customOrder(in: URL(fileURLWithPath: "/old")) == ["one.jpg"])
        #expect(catalog.createCollection(named: "From v1") != nil)
    }

    @Test func aCurrentCatalogOpensWithoutMigratingAgain() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("catalog.sqlite")
        let file = try t.file("a.jpg")
        do {
            let catalog = try Catalog(url: url)
            let id = try #require(catalog.createCollection(named: "Kept"))
            catalog.addToCollection(id, urls: [file])
        }
        let reopened = try Catalog(url: url)
        #expect(reopened.collections().map(\.count) == [1])
    }

    // MARK: - Metadata cache

    /// Read afresh: a URL keeps the resource values it was first asked for.
    func entry(_ url: URL) throws -> FolderEntry { try #require(FolderEntry(url: URL(fileURLWithPath: url.path))) }

    @Test func cachedMetadataIsReadBackWhileTheFileIsUnchanged() throws {
        let t = try TemporaryFolder()
        let url = try t.file("a.jpg", bytes: 10)
        let catalog = Catalog.inMemory()
        let metadata = FilterMetadata(dateTaken: 2024_06_01_093000, camera: "Canon EOS R5", lens: "RF 24-70mm",
                                      iso: 400, aperture: 2.8, focalLength: 35, keywords: ["paris", "night; rain"],
                                      hasLocation: true, pixelWidth: 6000, pixelHeight: 4000)
        catalog.storeFilterMetadata([(try entry(url), metadata)])
        #expect(catalog.filterMetadata(for: [try entry(url)]) == [url: metadata])

        // Changed on disk: the row no longer counts.
        try Data(count: 20).write(to: url)
        #expect(catalog.filterMetadata(for: [try entry(url)]).isEmpty)
    }

    @Test func metadataIsReadOnceThenComesFromTheCache() throws {
        let t = try TemporaryFolder()
        let urls = try (0..<5).map { try t.file("\($0).jpg", bytes: 3) }
        let entries = try urls.map(entry)
        let catalog = Catalog.inMemory()
        let reads = Counter()
        let first = catalog.loadFilterMetadata(for: entries, reader: { _ in reads.add(); return FilterMetadata(iso: 100) })
        #expect(first.count == 5 && reads.value == 5)
        let second = catalog.loadFilterMetadata(for: entries, reader: { _ in reads.add(); return FilterMetadata() })
        #expect(second.values.allSatisfy { $0.iso == 100 } && reads.value == 5)
    }

    @Test func aCancelledMetadataReadKeepsWhatItRead() throws {
        let t = try TemporaryFolder()
        let entries = try (0..<250).map { try entry(try t.file("\($0).jpg")) }
        let catalog = Catalog.inMemory()
        let reads = Counter()
        let result = catalog.loadFilterMetadata(for: entries, isCancelled: { reads.value >= 120 }, reader: { _ in
            reads.add()
            return FilterMetadata()
        })
        #expect(result.count == 120)
        #expect(catalog.filterMetadata(for: entries).count == 120)
    }

    @Test func cachedMetadataFollowsMovesAndGoesWithRemovals() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg", bytes: 4)
        let catalog = Catalog.inMemory()
        catalog.storeFilterMetadata([(try entry(a), FilterMetadata(camera: "X100"))])
        let renamed = t.url.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: a, to: renamed)
        catalog.fileMoved(from: a, to: renamed)
        #expect(catalog.filterMetadata(for: [try entry(renamed)])[renamed]?.camera == "X100")
        catalog.fileRemoved(renamed)
        #expect(catalog.filterMetadata(for: [try entry(renamed)]).isEmpty)
    }

    // MARK: - Collections

    @Test func collectionsKeepTheirMembersInOrder() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg"), c = try t.file("c.jpg")
        let catalog = Catalog.inMemory()
        let trip = try #require(catalog.createCollection(named: "Trip"))
        let best = try #require(catalog.createCollection(named: "best"))
        catalog.addToCollection(trip, urls: [c, a])
        catalog.addToCollection(trip, urls: [a, b])              // a already in: stays first
        catalog.addToCollection(best, urls: [b])
        #expect(catalog.collectionMembers(trip).map(\.lastPathComponent) == ["c.jpg", "a.jpg", "b.jpg"])
        #expect(catalog.collections().map(\.name) == ["best", "Trip"])
        #expect(catalog.collections().map(\.count) == [1, 3])
        #expect(catalog.collections(containing: b) == [trip, best])

        catalog.removeFromCollection(trip, urls: [a])
        #expect(catalog.collectionMembers(trip).map(\.lastPathComponent) == ["c.jpg", "b.jpg"])
        catalog.renameCollection(trip, to: "Summer")
        #expect(catalog.collections().map(\.name) == ["best", "Summer"])
        catalog.deleteCollection(trip)
        #expect(catalog.collections().map(\.name) == ["best"])
        #expect(try catalog.db.query("SELECT COUNT(*) AS n FROM collection_items").first?.int("n") == 1)
        #expect(FileManager.default.fileExists(atPath: c.path))   // never the files
    }

    @Test func membershipSurvivesARenameAndAMoveByMinivu() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let other = try t.folder("Other")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])

        let renamed = try FileOperations.rename(a, to: "renamed.jpg")
        catalog.fileMoved(from: a, to: renamed)
        #expect(catalog.collectionMembers(id) == [renamed])

        let moved = try #require(FileOperations.move([renamed], to: other, conflict: .skip).completed.first?.to)
        catalog.fileMoved(from: renamed, to: moved)
        #expect(catalog.collectionMembers(id).map(\.path) == [moved.path])
        #expect(catalog.collections(containing: moved) == [id])
    }

    @Test func membersInsideAMovedFolderFollowIt() throws {
        let t = try TemporaryFolder()
        let folder = try t.folder("Shoot")
        let inside = folder.appendingPathComponent("x.jpg")
        try Data().write(to: inside)
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [inside])
        let destination = t.url.appendingPathComponent("Shoot 2024")
        try FileManager.default.moveItem(at: folder, to: destination)
        catalog.filesMoved([(folder, destination)])
        #expect(catalog.collectionMembers(id).map(\.lastPathComponent) == ["x.jpg"])
        #expect(catalog.collectionMembers(id).first?.deletingLastPathComponent().lastPathComponent == "Shoot 2024")
    }

    @Test func aFileMinivuTrashesLeavesItsCollections() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        try FileManager.default.removeItem(at: a)
        catalog.fileRemoved(a)
        #expect(catalog.collections().first?.count == 0)
    }

    /// A move into the Trash that minivu records (every Move to Trash does,
    /// through `FileWriteQueue.trash`): the member leaves the list and the
    /// count at once, but stays a member until it is put back.
    @Test func aMemberMinivuMovesToTheTrashIsLeftOutUntilPutBack() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let trash = try t.folder(".Trash")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let trashed = trash.appendingPathComponent("a.jpg")
        try FileManager.default.moveItem(at: a, to: trashed)
        catalog.fileMoved(from: a, to: trashed)
        #expect(catalog.collections().first?.count == 0)
        #expect(catalog.collectionMembers(id).isEmpty)
        try FileManager.default.moveItem(at: trashed, to: a)
        catalog.fileMoved(from: trashed, to: a)
        #expect(catalog.collectionMembers(id).map(\.lastPathComponent) == ["a.jpg"])
    }

    /// Moved to the Trash by minivu, then put back in Finder, which minivu
    /// isn't told about: opening the collection finds it by identity
    /// without its folder being listed first, and counts it again.
    @Test func aMemberMinivuTrashedAndPutBackInFinderComesBack() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let trash = try t.folder(".Trash")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let trashed = trash.appendingPathComponent("a.jpg")
        try FileManager.default.moveItem(at: a, to: trashed)
        catalog.fileMoved(from: a, to: trashed)
        #expect(catalog.collectionMembers(id).isEmpty)

        try FileManager.default.moveItem(at: trashed, to: a)
        #expect(catalog.collectionMembers(id).map { $0.resolvingSymlinksInPath().path }
                == [a.resolvingSymlinksInPath().path])
        #expect(catalog.collections().first?.count == 1)
        let stored = try catalog.db.query("SELECT path, missing_since FROM collection_items").first
        #expect(stored?.string("path") == Catalog.key(a))
        #expect(stored?["missing_since"] == .null)
    }

    /// Moved to the Trash by minivu, then the Trash was emptied: the row is
    /// stamped missing (when the collection is opened, or by the first heal
    /// of a launch even if it never is), so the yearly prune drops it.
    @Test func aMemberLeftInAnEmptiedTrashIsStampedMissing() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        let trash = try t.folder(".Trash")
        let catalog = Catalog.inMemory()
        let opened = try #require(catalog.createCollection(named: "Opened"))
        let unopened = try #require(catalog.createCollection(named: "Unopened"))
        catalog.addToCollection(opened, urls: [a])
        catalog.addToCollection(unopened, urls: [b])
        for file in [a, b] {
            let trashed = trash.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: trashed)
            catalog.fileMoved(from: file, to: trashed)
        }
        // Still in the Trash: left out but not stamped.
        #expect(catalog.collectionMembers(opened).isEmpty)
        #expect(try catalog.db.query("SELECT 1 AS x FROM collection_items WHERE missing_since IS NOT NULL").isEmpty)

        try FileManager.default.removeItem(at: trash)
        #expect(catalog.collectionMembers(opened).isEmpty)
        func stamped(_ id: Int64) throws -> Bool {
            try catalog.db.query("SELECT missing_since FROM collection_items WHERE collection = ?1",
                                 [.integer(id)]).first?["missing_since"] != .null
        }
        #expect(try stamped(opened))
        #expect(try !stamped(unopened))
        catalog.heal(folder: t.url)
        #expect(try stamped(unopened))
    }

    /// Trashed where the catalog wasn't told (in Finder, or a Move to Trash
    /// that failed part way): its identity is found in the Trash, which
    /// counts as not found. The row keeps its path, so Put Back brings the
    /// member back, counted again.
    @Test func aMemberFoundInTheTrashByIdentityIsLeftOut() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let trash = try t.folder(".Trash")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let trashed = trash.appendingPathComponent("a.jpg")
        try FileManager.default.moveItem(at: a, to: trashed)

        #expect(catalog.collectionMembers(id).isEmpty)
        #expect(catalog.collections().first?.count == 0)
        let stored = try catalog.db.query("SELECT path FROM collection_items").first?.string("path")
        #expect(stored == Catalog.key(a))

        try FileManager.default.moveItem(at: trashed, to: a)
        #expect(catalog.collectionMembers(id).map(\.lastPathComponent) == ["a.jpg"])
        #expect(catalog.collections().first?.count == 1)
    }

    /// An identity found where minivu can't read (outside the folders the
    /// sandbox lets it see; here a file it may not open) counts as not
    /// found, and the row stays where it was until the file can be read.
    @Test func aMemberFoundWhereItCantBeReadIsLeftOut() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let elsewhere = try t.folder("Elsewhere")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let moved = elsewhere.appendingPathComponent("a.jpg")
        try FileManager.default.moveItem(at: a, to: moved)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: moved.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path) }

        #expect(catalog.collectionMembers(id).isEmpty)
        let stored = try catalog.db.query("SELECT path FROM collection_items").first?.string("path")
        #expect(stored == Catalog.key(a))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        #expect(catalog.collectionMembers(id).map { $0.resolvingSymlinksInPath().path }
                == [moved.resolvingSymlinksInPath().path])
    }

    /// Moved in Finder, not by minivu: found by its identity when the
    /// collection is opened, and its row takes the new path.
    @Test func aFileMovedOutsideMinivuIsFoundByIdentity() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let elsewhere = try t.folder("Elsewhere")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let moved = elsewhere.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: a, to: moved)

        let members = catalog.collectionMembers(id)
        #expect(members.map { $0.resolvingSymlinksInPath().path } == [moved.resolvingSymlinksInPath().path])
        let stored = try catalog.db.query("SELECT path FROM collection_items").first?.string("path")
        #expect(stored == Catalog.key(moved))
    }

    /// The other way back: listing the folder a member was moved into heals
    /// it, as marks are healed.
    @Test func healingAFolderFindsMembersMovedIntoIt() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg")
        let elsewhere = try t.folder("Elsewhere")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a])
        let moved = elsewhere.appendingPathComponent("a.jpg")
        try FileManager.default.moveItem(at: a, to: moved)
        catalog.heal(folder: elsewhere)
        let stored = try catalog.db.query("SELECT path, missing_since FROM collection_items").first
        #expect(stored?.string("path") == Catalog.key(moved))
        #expect(stored?["missing_since"] == .null)
    }

    @Test func aMemberThatIsGoneIsLeftOutAndStampedMissing() throws {
        let t = try TemporaryFolder()
        let a = try t.file("a.jpg"), b = try t.file("b.jpg")
        let catalog = Catalog.inMemory()
        let id = try #require(catalog.createCollection(named: "Keep"))
        catalog.addToCollection(id, urls: [a, b])
        try FileManager.default.removeItem(at: a)
        #expect(catalog.collectionMembers(id).map(\.lastPathComponent) == ["b.jpg"])
        #expect(catalog.collections().first?.count == 1)
        // Kept, not forgotten: it comes back if the file does.
        #expect(try catalog.db.query("SELECT COUNT(*) AS n FROM collection_items").first?.int("n") == 2)
        try Data().write(to: a)
        #expect(catalog.collectionMembers(id).count == 2)
    }

    // MARK: - Smart folders

    @Test func smartFoldersPersistAcrossLaunches() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("catalog.sqlite")
        var criteria = MetadataCriteria()
        criteria.camera = "Fujifilm"
        criteria.iso = NumberRange(minimum: 100, maximum: 800)
        criteria.fileTypes = [.raw, .jpeg]
        criteria.takenFrom = 2024_01_01
        criteria.colorLabel = .green
        criteria.shape = .portrait
        let query = SearchQuery(scope: t.url, includeSubfolders: false, name: "DSCF", minimumRating: 3,
                                taggedOnly: true, criteria: criteria)
        let id: Int64
        do {
            let catalog = try Catalog(url: url)
            id = try #require(catalog.saveSmartFolder(named: "Fuji portraits", query: query))
            catalog.saveSmartFolder(named: "another", query: SearchQuery(scope: t.url))
        }
        let catalog = try Catalog(url: url)
        #expect(catalog.smartFolders().map(\.name) == ["another", "Fuji portraits"])
        #expect(catalog.smartFolder(id)?.query == query)

        var changed = query
        changed.minimumRating = 5
        catalog.updateSmartFolder(id, query: changed)
        catalog.renameSmartFolder(id, to: "Best Fuji")
        #expect(catalog.smartFolder(id)?.query.minimumRating == 5 && catalog.smartFolder(id)?.name == "Best Fuji")
        catalog.deleteSmartFolder(id)
        #expect(catalog.smartFolders().map(\.name) == ["another"])
    }

    @Test func aSmartFolderSavedWithFewerFieldsStillOpens() throws {
        let catalog = Catalog.inMemory()
        try catalog.db.execute("INSERT INTO smart_folders (name, query, created) VALUES ('Old', ?1, 0)",
                               [.text(#"{"scope":"/Users/Shared","criteria":{"camera":"Leica","fileTypes":["raw","floppy"]}}"#)])
        try catalog.db.execute("INSERT INTO smart_folders (name, query, created) VALUES ('Broken', 'not json', 0)")
        let folders = catalog.smartFolders()
        #expect(folders.map(\.name) == ["Old"])
        let query = try #require(folders.first?.query)
        #expect(query.includeSubfolders && query.name.isEmpty && query.minimumRating == 0)
        #expect(query.criteria.camera == "Leica" && query.criteria.fileTypes == [.raw])
    }
}
