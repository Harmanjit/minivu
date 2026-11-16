import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.minivu.app", category: "catalog")

/// Star ratings, the "tagged" flag and custom sort order (DESIGN.md 4.6),
/// kept in one SQLite file: Application Support/minivu/catalog.sqlite.
///
/// **Keys.** A file is identified by its path: standardised, with its
/// folder's symlinks resolved (`/private/var` and `/var` are one folder),
/// in Unicode NFC (APFS preserves whichever normalisation a name was
/// created with, so the same name can arrive either way). Paths compare
/// case-insensitively (`COLLATE NOCASE`) because minivu works only on
/// internal volumes, and those are case-insensitive APFS unless the user
/// chose otherwise: a case-only rename in Finder must not lose a rating.
/// The price, on a case-sensitive volume, is that "A.jpg" and "a.jpg" in one
/// folder share their marks. NOCASE folds ASCII letters only.
///
/// **Identity.** Each row also records the file's volume UUID and file
/// identifier (the inode number, which APFS never reuses) so a file moved
/// in Finder is found again: see `heal(folder:)`.
///
/// **Size.** A file has a row only while it has a rating or the tag;
/// clearing both deletes the row, so the database grows with what the user
/// marked, not with what they browsed. The exception is a file that carries
/// marks of its own (an `xmp:Rating` from Lightroom, say): its row stays
/// when emptied, standing for "no marks" over what the file says.
///
/// **Marks in the files (G2).** A file without a row shows the marks it
/// carries itself (`FileMarksCache`), and a file with a row shows the row's:
/// the catalog wins, because a rating made in minivu is the user's explicit
/// choice and a file's timestamps can't say who changed what last (any
/// edit, copy or sync touches them, and a sidecar has its own). The first
/// change to such a file takes its marks into a new row before applying
/// the change (`fileMarksReader`), so rating a file keeps the tag it
/// carries, and the row is kept when emptied, so clearing a rating in
/// minivu doesn't bring the file's back.
///
/// Thread-safe (SQLiteDatabase serialises every call). Reading a folder's
/// marks is one indexed query, fine on the main thread; writes stat the
/// files they mark, so large ones belong off it.
public final class Catalog: @unchecked Sendable {
    /// Rating 0 (none) to 5, and FastStone's "tagged" flag for culling.
    public struct Marks: Sendable, Equatable, Hashable {
        public var rating: Int
        public var isTagged: Bool
        public init(rating: Int = 0, isTagged: Bool = false) {
            self.rating = rating
            self.isTagged = isTagged
        }
        public static let none = Marks()
    }

    /// One of the two marks: what a change set.
    public enum MarkField: Sendable, Equatable {
        case rating, tagged
    }

    /// Where a catalog's marks are being kept, and whether that is what the
    /// user asked for. Everything the interface shows carries on working
    /// when it is not the user's own file, so the app reads this once at
    /// launch and says so (`AppDelegate.catalogNotice(for:)`).
    ///
    /// The reason travels as text already rendered rather than as the error
    /// itself, so the value stays `Sendable` and `Equatable` and can be read
    /// from any thread.
    public enum Storage: Sendable, Equatable {
        /// The user's own file, opened as it was left. Marks are kept.
        case persistent
        /// A catalog in memory asked for deliberately, by a test run, the
        /// snapshot harness or `MINIVU_CATALOG=memory`. Nothing is wrong.
        case `private`
        /// The user's file could not be opened at all, so this catalog is in
        /// memory and everything marked in this session goes at quit.
        case temporary(reason: String)
        /// The user's file was damaged and a fresh one took its place.
        /// `setAside` is the name the damaged file was given, or nil when it
        /// could not be moved: nothing may name a file that is not there.
        case recovered(setAside: String?)
    }

    /// Posted on the main queue after marks or custom order change. `object`
    /// is the `[URL]` of files (or the folder, for custom order) affected.
    public static let didChange = Notification.Name("MinivuCatalogDidChange")

    /// The user's catalog, except in test runs and snapshot runs (or with
    /// `MINIVU_CATALOG=memory`), which get a private one in memory: tests and
    /// the snapshot harness rate and move files through app code, and must
    /// never change or read the ratings a user has made.
    ///
    /// However it turns out, `storage` records it, so that a catalog the
    /// user did not ask for is not passed off as their own.
    public static let shared: Catalog = Perf.measure("catalog.open") { () -> Catalog in
        if usesPrivateCatalog(ProcessInfo.processInfo) { return Catalog.inMemory() }
        do { return try Catalog(url: Catalog.defaultURL) } catch {
            log.error("Catalog unavailable, using a temporary one: \(String(describing: error), privacy: .public)")
            // The SQLite message alone ("database or disk is full"), because
            // the full description carries the SQL that failed with it. For
            // anything else the localised text, because `describing` renders
            // a Cocoa error as its domain, code and whole userInfo dictionary,
            // and this reason is read back to the user in an alert.
            return Catalog.temporary(reason: (error as? SQLiteError)?.message ?? error.localizedDescription)
        }
    }

    /// XCTest runs in `xctest`, Swift Testing under SwiftPM in
    /// `swiftpm-testing-helper`; Xcode sets XCTestConfigurationFilePath.
    public static func usesPrivateCatalog(_ process: ProcessInfo) -> Bool {
        let environment = process.environment
        return environment["MINIVU_CATALOG"] == "memory"
            || environment["MINIVU_SNAPSHOT"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || ["xctest", "swiftpm-testing-helper"].contains(process.processName)
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("minivu", isDirectory: true)
            .appendingPathComponent("catalog.sqlite", isDirectory: false)
    }

    /// Rows whose file has been missing from its folder this long are
    /// forgotten. Long, because a file moved in Finder is healed only when
    /// the folder it went to is opened in minivu.
    static let missingRetention: TimeInterval = 365 * 24 * 3600

    static let schemaVersion = 4

    let db: SQLiteDatabase
    /// Fixed at construction, never afterwards: this class is `@unchecked
    /// Sendable` with its own locking, and a `var` here would be read on the
    /// main thread while the write queue worked with the compiler silenced.
    public let storage: Storage
    private let lock = NSLock()
    private var hasPrunedMissing = false
    private var hasPrunedMetadata = false
    private var hasPrunedMembers = false
    private var movesInFlight = 0
    /// Held from a heal's last pause check until its commit is done (the
    /// folder's, its collection members', `collectionMembers`' write-back),
    /// and taken by `pauseHealing`: a move can't begin between the two, so
    /// what a heal commits was listed with no move under way.
    let healCommit = NSLock()
    private var _mirror: (any CatalogMirror)?
    private var _fileMarksReader: (@Sendable (URL) -> Marks?)?

    /// Opens (creating if needed) the catalog at `url`, or a private one in
    /// memory when `url` is nil.
    ///
    /// A damaged file is not deleted, unlike the thumbnail cache: it holds
    /// the user's ratings. It is renamed aside (catalog.sqlite.damaged-…)
    /// so it can be recovered by hand, and a fresh catalog starts.
    public init(url: URL?) throws {
        guard let url else {
            db = try Self.migrated(.inMemory())
            storage = .private
            return
        }
        do {
            db = try Self.migrated(SQLiteDatabase(url: url))
            storage = .persistent
        } catch let error as SQLiteError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            let setAside = Self.setDamagedFileAside(url)
            let fate = setAside.map { "has been set aside as \($0)" } ?? "could not be set aside"
            log.error("Catalog was damaged and \(fate, privacy: .public): \(String(describing: error), privacy: .public)")
            db = try Self.migrated(SQLiteDatabase(url: url))
            storage = .recovered(setAside: setAside)
        }
    }

    /// Renames a damaged catalog, and the write-ahead log files beside it,
    /// out of the way, and reports the name the catalog itself was given.
    /// Nil when that move failed, so that nothing tells the user a file was
    /// kept for them when it was not.
    static func setDamagedFileAside(_ url: URL) -> String? {
        let name = url.lastPathComponent + ".damaged-\(Int(Date().timeIntervalSince1970))"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        var setAside: String?
        for suffix in ["", "-wal", "-shm"] {
            // Only the catalog's own move decides the answer: the -wal and
            // -shm files are often absent, and neither is named to the user.
            let moved = (try? FileManager.default.moveItem(atPath: url.path + suffix,
                                                           toPath: destination.path + suffix)) != nil
            if suffix.isEmpty, moved { setAside = name }
        }
        return setAside
    }

    public static func inMemory() -> Catalog { try! Catalog(url: nil) }

    /// A catalog in memory standing in for the user's, which could not be
    /// opened at all: see `shared`.
    static func temporary(reason: String) -> Catalog { try! Catalog(temporaryBecause: reason) }

    private init(temporaryBecause reason: String) throws {
        db = try Self.migrated(.inMemory())
        storage = .temporary(reason: reason)
    }

    /// Brings `db` to the current schema one version step at a time, so a
    /// catalog from any earlier minivu keeps its ratings.
    private static func migrated(_ db: SQLiteDatabase) throws -> SQLiteDatabase {
        var version = try db.userVersion()
        guard version < schemaVersion else { return db }
        try db.transaction {
            if version < 1 {
                // `folder` (the parent's key) makes "rows in this folder" an
                // index lookup for healing. folder_order has no rowid: its
                // primary key is the only way it's ever read.
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
                    """)
                version = 1
            }
            if version < 2 {
                // A row standing for marks over a file's own (see
                // `fileMarksReader`), kept when emptied.
                try db.executeScript("ALTER TABLE files ADD COLUMN overrides_file INTEGER NOT NULL DEFAULT 0;")
                version = 2
            }
            if version < 3 {
                // G3. `metadata` caches what the filters and Find read from
                // a file's header, valid while its size and date are those
                // recorded (CatalogLibrary.swift). Collections keep each
                // member's identity, as `files` does, so healing finds a
                // member moved in Finder; smart folders keep their search as
                // JSON. No foreign keys: SQLite enforces them only with a
                // pragma on every connection, and the one place that deletes
                // a collection deletes its members in the same transaction.
                try db.executeScript("""
                    CREATE TABLE metadata (
                        path TEXT PRIMARY KEY COLLATE NOCASE,
                        size INTEGER NOT NULL,
                        modified REAL NOT NULL,
                        read_at REAL NOT NULL,
                        date_taken INTEGER,
                        camera TEXT,
                        lens TEXT,
                        iso REAL,
                        aperture REAL,
                        focal_length REAL,
                        keywords TEXT,
                        has_location INTEGER NOT NULL DEFAULT 0,
                        width INTEGER,
                        height INTEGER
                    ) WITHOUT ROWID;
                    CREATE TABLE collections (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        created REAL NOT NULL
                    );
                    CREATE TABLE collection_items (
                        collection INTEGER NOT NULL,
                        path TEXT NOT NULL COLLATE NOCASE,
                        folder TEXT NOT NULL COLLATE NOCASE,
                        volume TEXT,
                        file_id INTEGER,
                        added REAL NOT NULL,
                        missing_since REAL,
                        PRIMARY KEY (collection, path)
                    );
                    CREATE INDEX collection_items_path ON collection_items (path);
                    CREATE INDEX collection_items_folder ON collection_items (folder);
                    CREATE INDEX collection_items_identity ON collection_items (volume, file_id);
                    CREATE TABLE smart_folders (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        query TEXT NOT NULL,
                        created REAL NOT NULL
                    );
                    """)
                version = 3
            }
            if version < 4 {
                // A video's metadata rows were read before the filters read
                // its date, camera and location: empty, and current by size
                // and date for ever. The table is a cache; every row is read
                // again when next needed.
                try db.executeScript("DELETE FROM metadata;")
                version = 4
            }
            try db.setUserVersion(version)
        }
        return db
    }

    /// Receives every rating and tag change once committed, for keeping marks
    /// somewhere besides the catalog (XMP sidecars or embedded XMP, so other
    /// apps see them). The app installs one that writes them into the files
    /// while "Write ratings into files (XMP)" is on; its writes go through
    /// the app's FileWriteQueue, which lives above this module.
    public var mirror: (any CatalogMirror)? {
        get { lock.withLock { _mirror } }
        set { lock.withLock { _mirror = newValue } }
    }

    /// The marks a file carries itself (`FileMarksCache.marks(for:)`), asked
    /// when a change reaches a file without a row, or would empty a row:
    /// the file's marks become the row's before the change, and the row is
    /// kept when emptied, standing for "no marks" over the file's. Nil (the
    /// default, and in tests that don't set it) treats files as carrying
    /// none. Called on the writing thread, outside the database lock.
    public var fileMarksReader: (@Sendable (URL) -> Marks?)? {
        get { lock.withLock { _fileMarksReader } }
        set { lock.withLock { _fileMarksReader = newValue } }
    }

    // MARK: - Marks

    public func marks(for url: URL) -> Marks {
        storedMarks(for: url) ?? .none
    }

    /// The row's marks, or nil when the file has no row, which is when a
    /// file's own marks show instead. An emptied row kept over a file's
    /// marks gives `.none`.
    public func storedMarks(for url: URL) -> Marks? {
        let rows = (try? db.query("SELECT rating, tagged FROM files WHERE path = ?1", [.text(Self.key(url))])) ?? []
        return rows.first.map(Self.marks(from:))
    }

    /// Marks for the files that have a row; files without are left out. A
    /// row kept over a file's own marks is in, as `.none`.
    ///
    /// One statement however many files: the keys travel as a single JSON
    /// array that `json_each` turns into rows joined against the path index.
    /// Chunked `IN (?, ?, …)` lists would need a cached statement per chunk
    /// size. `CROSS JOIN` makes SQLite loop over the array and search the
    /// index, never the other way round: the planner can't estimate a
    /// virtual table's size and, for the identity lookup in `heal`, chose to
    /// scan the table instead (78 ms against 3 ms on 5,000 files).
    public func marks(for urls: [URL]) -> [URL: Marks] {
        guard !urls.isEmpty else { return [:] }
        let reading = Perf.begin("catalog.marks")
        defer { reading.end() }
        let keys = Self.keys(for: urls)
        let rows: [SQLiteRow]
        do {
            rows = try db.query("""
                SELECT j.key AS i, f.rating AS rating, f.tagged AS tagged
                FROM json_each(?1) AS j CROSS JOIN files AS f ON f.path = j.value
                """, [.text(Self.jsonArray(keys))])
        } catch {
            log.error("Reading marks failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
        var result: [URL: Marks] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let i = row.int("i"), i >= 0, Int(i) < urls.count else { continue }
            result[urls[Int(i)]] = Self.marks(from: row)
        }
        return result
    }

    /// Clamped to 0...5.
    public func setRating(_ rating: Int, for urls: [URL]) {
        let r = min(max(rating, 0), 5)
        write(urls, field: .rating, value: r)
    }

    public func setTagged(_ tagged: Bool, for urls: [URL]) {
        write(urls, field: .tagged, value: tagged ? 1 : 0)
    }

    /// Sets one mark column for `urls` in one transaction. A non-zero value
    /// inserts the row (recording the file's identity for healing) or
    /// updates it; zero deletes rows left with no marks at all, unless they
    /// stand over marks the file carries.
    private func write(_ urls: [URL], field: MarkField, value: Int) {
        guard !urls.isEmpty else { return }
        let column = field == .rating ? "rating" : "tagged"
        let keys = Self.keys(for: urls)
        // Read the files and stat them before taking the database lock:
        // readers shouldn't wait on the file system.
        let fromFiles = marksFromFiles(urls, keys: keys, clearing: value == 0)
        let identities = value == 0 && fromFiles.isEmpty ? [] : Self.identities(of: keys)
        let committed: Bool
        do {
            try db.transaction {
                for (i, key) in keys.enumerated() {
                    if let file = fromFiles[i] {
                        // The file's marks become the row's (a row already
                        // there keeps its own), and the row is kept when emptied.
                        try db.execute("""
                            INSERT INTO files (path, folder, volume, file_id, size, modified, rating, tagged, overrides_file)
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)
                            ON CONFLICT (path) DO UPDATE SET overrides_file = 1
                            """, [.text(key), .text(Self.parent(ofKey: key))] + identities[i].values
                                + [.integer(Int64(file.rating)), .integer(file.isTagged ? 1 : 0)])
                    }
                    if value == 0 {
                        try db.execute("UPDATE files SET \(column) = 0 WHERE path = ?1", [.text(key)])
                        try db.execute("DELETE FROM files WHERE path = ?1 AND rating = 0 AND tagged = 0 AND overrides_file = 0",
                                       [.text(key)])
                    } else {
                        try db.execute("""
                            INSERT INTO files (path, folder, volume, file_id, size, modified, \(column))
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                            ON CONFLICT (path) DO UPDATE SET
                                \(column) = excluded.\(column), path = excluded.path, folder = excluded.folder,
                                volume = coalesce(excluded.volume, volume), file_id = coalesce(excluded.file_id, file_id),
                                size = coalesce(excluded.size, size), modified = coalesce(excluded.modified, modified),
                                missing_since = NULL
                            """, [.text(key), .text(Self.parent(ofKey: key))] + identities[i].values + [.integer(Int64(value))])
                    }
                }
            }
            committed = true
        } catch {
            log.error("Writing marks failed: \(String(describing: error), privacy: .public)")
            committed = false
        }
        // Only a change that was made is mirrored: after a failed one the
        // rows still hold their old marks, which would overwrite a value
        // another application has put in the file since.
        if committed, let mirror { mirror.catalog(self, didChange: field, marks: marks(for: urls), of: urls) }
        post(urls)
    }

    /// The marks files carry, by index into `urls`, for those a change
    /// should take them from: files without a row, and (when `clearing`)
    /// files whose row could be emptied and doesn't yet stand over the
    /// file's marks. Empty without a `fileMarksReader`.
    private func marksFromFiles(_ urls: [URL], keys: [String], clearing: Bool) -> [Int: Marks] {
        guard let reader = fileMarksReader else { return [:] }
        var overrides: [Int: Bool] = [:]
        do {
            for row in try db.query("""
                SELECT j.key AS i, f.overrides_file AS overrides
                FROM json_each(?1) AS j CROSS JOIN files AS f ON f.path = j.value
                """, [.text(Self.jsonArray(keys))]) {
                if let i = row.int("i") { overrides[Int(i)] = (row.int("overrides") ?? 0) != 0 }
            }
        } catch {
            log.error("Reading rows failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
        var result: [Int: Marks] = [:]
        for (i, url) in urls.enumerated() {
            switch overrides[i] {
            case nil: break
            case false?: guard clearing else { continue }
            case true?: continue
            }
            if let marks = reader(url), marks != .none { result[i] = marks }
        }
        return result
    }

    // MARK: - Custom order

    /// File names in the user's order for `folder` (possibly naming files
    /// that no longer exist; callers ignore those).
    public func customOrder(in folder: URL) -> [String] {
        let rows = (try? db.query("SELECT name FROM folder_order WHERE folder = ?1 ORDER BY position",
                                  [.text(Self.folderKey(folder))])) ?? []
        return rows.compactMap { $0.string("name") }
    }

    /// Replaces the folder's order. A repeated name keeps its first place.
    public func setCustomOrder(_ names: [String], in folder: URL) {
        let key = Self.folderKey(folder)
        do {
            try db.transaction {
                try db.execute("DELETE FROM folder_order WHERE folder = ?1", [.text(key)])
                for (position, name) in names.enumerated() {
                    try db.execute("INSERT OR IGNORE INTO folder_order (folder, name, position) VALUES (?1, ?2, ?3)",
                                   [.text(key), .text(Self.normalized(name)), .integer(Int64(position))])
                }
            }
        } catch {
            log.error("Writing custom order failed: \(String(describing: error), privacy: .public)")
        }
        post([folder])
    }

    // MARK: - Files minivu moves, copies and removes

    // The statements below address an item and everything inside it with
    // `path = k OR (path >= k/ AND path < k0)`: "0" follows "/" in ASCII,
    // so the range holds exactly the paths below k, and it is an index
    // range scan (NOCASE folds only letters, never "/" or "0").

    /// Keeps marks with a file or folder that minivu itself moved or renamed:
    /// the item's row, the rows of everything inside a folder, the folder's
    /// own custom orders, and the item's place in its folder's order (kept on
    /// a rename, dropped when it leaves the folder). Rows already at the
    /// destination (a replaced file) are dropped. Call after the move.
    public func fileMoved(from: URL, to: URL) {
        filesMoved([(from, to)])
    }

    /// `fileMoved` for many moves, applied in order in one transaction with
    /// one `didChange` naming every item. A batch rename of thousands of
    /// files moves their marks this way once the renames are done: one
    /// transaction and one notification per file cost more than a second
    /// of catalog work and thousands of main-queue updates.
    public func filesMoved(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        do {
            try db.transaction {
                for move in moves { try applyMove(from: move.from, to: move.to) }
            }
        } catch {
            log.error("Moving marks failed: \(String(describing: error), privacy: .public)")
        }
        post(moves.flatMap { [$0.from, $0.to] })
        postLibraryChange()
    }

    private func applyMove(from: URL, to: URL) throws {
        let f = Self.key(from), t = Self.key(to)
        try rehomeStrayRows(at: t, movingFrom: f)
        let fParent = Self.parent(ofKey: f), tParent = Self.parent(ofKey: t)
        // ?1 source, ?2 ?3 its descendants' range; ?4 destination, ?5 ?6 its range.
        let args: [SQLiteValue] = [.text(f), .text(f + "/"), .text(f + "0"), .text(t), .text(t + "/"), .text(t + "0")]
        let four = Array(args.prefix(4))
        try db.execute("""
            DELETE FROM files WHERE (path = ?4 OR (path >= ?5 AND path < ?6))
                AND NOT (path = ?1 OR (path >= ?2 AND path < ?3))
            """, args)
        try db.execute("UPDATE files SET path = ?4, folder = ?7, missing_since = NULL WHERE path = ?1",
                       args + [.text(tParent)])
        try db.execute("""
            UPDATE files SET path = ?4 || substr(path, length(?1) + 1), folder = ?4 || substr(folder, length(?1) + 1)
            WHERE path >= ?2 AND path < ?3
            """, four)
        try db.execute("""
            DELETE FROM folder_order WHERE (folder = ?4 OR (folder >= ?5 AND folder < ?6))
                AND NOT (folder = ?1 OR (folder >= ?2 AND folder < ?3))
            """, args)
        try db.execute("""
            UPDATE folder_order SET folder = ?4 || substr(folder, length(?1) + 1)
            WHERE folder = ?1 OR (folder >= ?2 AND folder < ?3)
            """, four)
        // Collection members and cached metadata follow the item too (G3),
        // and those of a replaced item at the destination go, as its marks do.
        try db.execute("""
            DELETE FROM collection_items WHERE (path = ?4 OR (path >= ?5 AND path < ?6))
                AND NOT (path = ?1 OR (path >= ?2 AND path < ?3))
            """, args)
        try db.execute("UPDATE collection_items SET path = ?4, folder = ?7, missing_since = NULL WHERE path = ?1",
                       args + [.text(tParent)])
        try db.execute("""
            UPDATE collection_items SET path = ?4 || substr(path, length(?1) + 1),
                folder = ?4 || substr(folder, length(?1) + 1)
            WHERE path >= ?2 AND path < ?3
            """, four)
        try db.execute("""
            DELETE FROM metadata WHERE (path = ?4 OR (path >= ?5 AND path < ?6))
                AND NOT (path = ?1 OR (path >= ?2 AND path < ?3))
            """, args)
        try db.execute("UPDATE metadata SET path = ?4 WHERE path = ?1", four)
        try db.execute("UPDATE metadata SET path = ?4 || substr(path, length(?1) + 1) WHERE path >= ?2 AND path < ?3",
                       four)
        let place: [SQLiteValue] = [.text(fParent), .text(Self.name(ofKey: f)), .text(Self.name(ofKey: t))]
        if fParent.lowercased() == tParent.lowercased() {
            try db.execute("UPDATE OR REPLACE folder_order SET name = ?3 WHERE folder = ?1 AND name = ?2", place)
        } else {
            try db.execute("DELETE FROM folder_order WHERE folder = ?1 AND name = ?2", Array(place.prefix(2)))
        }
    }

    /// Rows at a move's destination are dropped as a replaced file's, unless
    /// their file is still there under another path: one Finder put back
    /// from the Trash keeps its rows at the Trash path until its folder is
    /// healed, and trashing another file of the same name then takes that
    /// slot. Such rows go to where their file is now (found by identity),
    /// unless rows are already there.
    private func rehomeStrayRows(at t: String, movingFrom f: String) throws {
        let rows = try db.query("""
            SELECT volume, file_id FROM files WHERE path = ?1 AND file_id IS NOT NULL AND volume IS NOT NULL
            UNION SELECT volume, file_id FROM collection_items
            WHERE path = ?1 AND file_id IS NOT NULL AND volume IS NOT NULL
            """, [.text(t)])
        for row in rows {
            guard let fileID = row.int("file_id"), let volume = row.string("volume"),
                  let now = Self.path(ofFile: fileID, onVolume: volume, near: t) else { continue }
            let p = Self.key(URL(fileURLWithPath: now))
            guard p.lowercased() != t.lowercased(), p.lowercased() != f.lowercased(),
                  try db.query("""
                    SELECT 1 AS x FROM files WHERE path = ?1 UNION SELECT 1 AS x FROM collection_items WHERE path = ?1
                    """, [.text(p)]).isEmpty
            else { continue }
            try applyMove(from: URL(fileURLWithPath: t), to: URL(fileURLWithPath: p))
            return
        }
    }

    /// Gives a copy the marks of its original, including everything inside a
    /// copied folder, and copies the folder's custom orders. The copies'
    /// identities are read from the new files after the transaction.
    public func fileCopied(from: URL, to: URL) {
        let f = Self.key(from), t = Self.key(to)
        let args: [SQLiteValue] = [.text(f), .text(f + "/"), .text(f + "0"), .text(t), .text(t + "/"), .text(t + "0")]
        let four = Array(args.prefix(4))
        do {
            let copied = try db.transaction { () throws -> [SQLiteRow] in
                try db.execute("DELETE FROM files WHERE path = ?4 OR (path >= ?5 AND path < ?6)", args)
                try db.execute("""
                    INSERT INTO files (path, folder, rating, tagged, overrides_file)
                    SELECT ?4, ?7, rating, tagged, overrides_file FROM files WHERE path = ?1
                    """, args + [.text(Self.parent(ofKey: t))])
                try db.execute("""
                    INSERT INTO files (path, folder, rating, tagged, overrides_file)
                    SELECT ?4 || substr(path, length(?1) + 1), ?4 || substr(folder, length(?1) + 1), rating, tagged,
                        overrides_file
                    FROM files WHERE path >= ?2 AND path < ?3
                    """, four)
                try db.execute("DELETE FROM folder_order WHERE folder = ?4 OR (folder >= ?5 AND folder < ?6)", args)
                try db.execute("""
                    INSERT OR REPLACE INTO folder_order (folder, name, position)
                    SELECT ?4 || substr(folder, length(?1) + 1), name, position FROM folder_order
                    WHERE folder = ?1 OR (folder >= ?2 AND folder < ?3)
                    """, four)
                return try db.query("SELECT id, path FROM files WHERE path = ?4 OR (path >= ?5 AND path < ?6)", args)
            }
            if !copied.isEmpty {
                let identities = Self.identities(of: copied.map { $0.string("path") ?? "" })
                try db.transaction {
                    for (row, identity) in zip(copied, identities) {
                        guard let id = row.int("id"), identity.fileID != nil else { continue }
                        try db.execute("UPDATE files SET volume = ?1, file_id = ?2, size = ?3, modified = ?4 WHERE id = ?5",
                                       identity.values + [.integer(id)])
                    }
                }
            }
        } catch {
            log.error("Copying marks failed: \(String(describing: error), privacy: .public)")
        }
        post([to])
    }

    /// Forgets a file (or a folder and everything in it) that minivu deleted
    /// or moved to the Trash.
    public func fileRemoved(_ url: URL) {
        let k = Self.key(url)
        let args: [SQLiteValue] = [.text(k), .text(k + "/"), .text(k + "0")]
        do {
            try db.transaction {
                try db.execute("DELETE FROM files WHERE path = ?1 OR (path >= ?2 AND path < ?3)", args)
                try db.execute("DELETE FROM folder_order WHERE folder = ?1 OR (folder >= ?2 AND folder < ?3)", args)
                try db.execute("DELETE FROM folder_order WHERE folder = ?1 AND name = ?2",
                               [.text(Self.parent(ofKey: k)), .text(Self.name(ofKey: k))])
                // A file minivu removes leaves its collections, as it loses
                // its marks (G3).
                try db.execute("DELETE FROM collection_items WHERE path = ?1 OR (path >= ?2 AND path < ?3)", args)
                try db.execute("DELETE FROM metadata WHERE path = ?1 OR (path >= ?2 AND path < ?3)", args)
            }
        } catch {
            log.error("Removing marks failed: \(String(describing: error), privacy: .public)")
        }
        post([url])
        postLibraryChange()
    }

    // MARK: - Healing files moved outside minivu

    /// Reattaches marks to files that were moved or renamed into `folder`
    /// outside minivu (in Finder). Returns the URLs whose marks were found
    /// again and posts `didChange` for them. Reads the folder: call it off
    /// the main thread, when the browser opens a folder.
    ///
    /// **Strategy.** One `readdir` pass gives every item's name and file
    /// identifier (`d_ino`) without fetching any attributes: 5,000 files
    /// took 90 ms through `contentsOfDirectory` with the identifier key, a
    /// few ms this way. Then:
    /// 1. Rows of this folder whose name is listed are current. Their
    ///    identity is refreshed, because saving writes a new file (a new
    ///    inode) under the old name, and the path is what the user sees.
    ///    Rows whose name is gone are stamped `missing_since`.
    /// 2. Listed items without a row are looked up by (volume, file
    ///    identifier) in one query. A hit whose old path no longer holds that
    ///    file is the same file, moved here: its row takes the new path.
    ///    Its custom-order place is renamed when it was renamed in this
    ///    folder. When marked files arrive from one folder that no longer
    ///    exists (a folder renamed or moved in Finder), that folder's custom
    ///    orders move here too, unless this folder has its own.
    ///
    /// Skipped while minivu's own moves are under way (`pauseHealing`).
    ///
    /// **Limits.** A moved file is found when the folder it went *to* is
    /// healed, so marks follow files into folders the user opens, not
    /// before. A file moved away and replaced by a different file of the
    /// same name, before its old folder is opened again, lends the newcomer
    /// its marks (the path wins, as it must for saves). Copies made in Finder
    /// have new identifiers and start unmarked. A file moved to another
    /// volume gets a new identifier and loses its marks. Rows missing for a
    /// year are pruned.
    @discardableResult
    public func heal(folder: URL) -> [URL] {
        guard !isHealingPaused else { return [] }
        let healing = Perf.begin("catalog.heal")
        defer { healing.end() }
        let folderKey = Self.folderKey(folder)
        var listed: [String: ListedItem] = [:]
        do {
            guard let directory = opendir(folder.path) else { return [] }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let length = Int(entry.pointee.d_namlen)
                let raw = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
                guard raw != ".", raw != ".." else { continue }
                let name = Self.normalized(raw)
                listed[name.lowercased()] = ListedItem(name: name, fileID: Int64(bitPattern: UInt64(entry.pointee.d_ino)))
            }
        }
        let volume = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        // Collection members first (G3): the marks' pass below returns early
        // in several places.
        _ = healCollectionMembers(folder: folder, folderKey: folderKey, listed: listed, volume: volume)

        var healed: [URL] = []
        do {
            let rows = try db.query("SELECT id, path, file_id, volume, missing_since FROM files WHERE folder = ?1",
                                    [.text(folderKey)])
            // An empty catalog can have nothing to reattach.
            if rows.isEmpty, try db.query("SELECT 1 AS x FROM files LIMIT 1").isEmpty { return [] }

            var rowed = Set<String>()
            var refresh: [(id: Int64, fileID: Int64?)] = []
            var missing: [Int64] = []
            for row in rows {
                guard let id = row.int("id"), let path = row.string("path") else { continue }
                let lower = Self.name(ofKey: path).lowercased()
                if let item = listed[lower] {
                    rowed.insert(lower)
                    if row.int("file_id") != item.fileID || row.string("volume") != volume || row["missing_since"] != .null {
                        refresh.append((id, item.fileID))
                    }
                } else if row["missing_since"] == .null {
                    missing.append(id)
                }
            }

            let orphans = listed.filter { !rowed.contains($0.key) && $0.value.fileID != nil }.map(\.value)
            var moves: [(id: Int64, oldPath: String, name: String)] = []
            // Old folders of moved files, and whether each is gone (renamed or
            // moved as a whole in Finder), looked up before taking the lock.
            var oldFolderIsGone: [String: Bool] = [:]
            if let volume, !orphans.isEmpty {
                let json = "[" + orphans.map { String($0.fileID!) }.joined(separator: ",") + "]"
                let hits = try db.query("""
                    SELECT j.key AS i, f.id AS id, f.path AS path FROM json_each(?1) AS j
                    CROSS JOIN files AS f ON f.volume = ?2 AND f.file_id = j.value
                    """, [.text(json), .text(volume)])
                var volumes: [dev_t: String] = [:]
                var claimed = Set<Int64>()
                for hit in hits {
                    guard let i = hit.int("i"), let id = hit.int("id"), let oldPath = hit.string("path"),
                          !claimed.contains(id) else { continue }
                    let item = orphans[Int(i)]
                    // Still there under its old path too: a hard link, not a move.
                    if Self.identity(ofPath: oldPath, volumes: &volumes).fileID == item.fileID { continue }
                    claimed.insert(id)
                    moves.append((id, oldPath, item.name))
                    let oldFolder = Self.parent(ofKey: oldPath)
                    if oldFolderIsGone[oldFolder] == nil {
                        var st = stat()
                        // Only "no such file": an unreadable folder isn't gone.
                        oldFolderIsGone[oldFolder] = lstat(oldFolder, &st) != 0 && errno == ENOENT
                    }
                }
            }

            // Asked again after listing: moves may have begun meanwhile, and
            // this listing may already show some of them. None can begin
            // now until the commit is done.
            healCommit.lock()
            defer { healCommit.unlock() }
            guard !isHealingPaused else { return [] }
            let prunes = claimFirstPrune()
            // Marks of files that `.replace` sent to the Trash stay with them
            // so undo can restore them. Nobody opens the Trash in minivu, so
            // those rows would never be stamped missing and never pruned:
            // stamp them once they've left it (emptied, or put back, where
            // healing by identity still finds them within the year).
            var goneFromTrash: [Int64] = []
            if prunes {
                for row in try db.query("SELECT id, path FROM files WHERE instr(path, '/.Trash') > 0 AND missing_since IS NULL") {
                    var st = stat()
                    if let id = row.int("id"), let path = row.string("path"), lstat(path, &st) != 0, errno == ENOENT {
                        goneFromTrash.append(id)
                    }
                }
            }
            guard prunes || !refresh.isEmpty || !missing.isEmpty || !moves.isEmpty else { return [] }
            let now = Date().timeIntervalSince1970
            try db.transaction {
                for r in refresh {
                    try db.execute("UPDATE files SET file_id = ?1, volume = ?2, missing_since = NULL WHERE id = ?3",
                                   [r.fileID.map { .integer($0) } ?? .null, volume.map { .text($0) } ?? .null, .integer(r.id)])
                }
                for id in missing {
                    try db.execute("UPDATE files SET missing_since = ?1 WHERE id = ?2", [.real(now), .integer(id)])
                }
                var goneFoldersMovedFrom = Set<String>()
                for move in moves {
                    let newPath = folderKey == "/" ? "/" + move.name : folderKey + "/" + move.name
                    try db.execute("UPDATE OR IGNORE files SET path = ?1, folder = ?2, missing_since = NULL WHERE id = ?3",
                                   [.text(newPath), .text(folderKey), .integer(move.id)])
                    guard db.changes > 0 else { continue }
                    healed.append(folder.appendingPathComponent(move.name))
                    // The file's place in its old folder's custom order: kept
                    // under the new name when renamed in place; left for the
                    // order move below when the whole folder went; dropped
                    // when the file left a folder that is still there.
                    let oldFolder = Self.parent(ofKey: move.oldPath)
                    let place: [SQLiteValue] = [.text(oldFolder), .text(Self.name(ofKey: move.oldPath)), .text(move.name)]
                    if oldFolder.lowercased() == folderKey.lowercased() {
                        try db.execute("UPDATE OR REPLACE folder_order SET name = ?3 WHERE folder = ?1 AND name = ?2", place)
                    } else if oldFolderIsGone[oldFolder] == true {
                        goneFoldersMovedFrom.insert(oldFolder)
                    } else {
                        try db.execute("DELETE FROM folder_order WHERE folder = ?1 AND name = ?2", Array(place.prefix(2)))
                    }
                }
                // Marked files arriving from exactly one folder that no longer
                // exists: the folder was renamed or moved in Finder, so its
                // custom orders (its own and its subfolders') follow, unless
                // this folder already has one. A subfolder healed earlier
                // keeps the order it already took.
                if goneFoldersMovedFrom.count == 1, let old = goneFoldersMovedFrom.first,
                   try db.query("SELECT 1 AS x FROM folder_order WHERE folder = ?1 LIMIT 1", [.text(folderKey)]).isEmpty {
                    try db.execute("""
                        UPDATE OR IGNORE folder_order SET folder = ?4 || substr(folder, length(?1) + 1)
                        WHERE folder = ?1 OR (folder >= ?2 AND folder < ?3)
                        """, [.text(old), .text(old + "/"), .text(old + "0"), .text(folderKey)])
                }
                if prunes {
                    try db.execute("DELETE FROM files WHERE missing_since < ?1", [.real(now - Self.missingRetention)])
                    for id in goneFromTrash {
                        try db.execute("UPDATE files SET missing_since = ?1 WHERE id = ?2", [.real(now), .integer(id)])
                    }
                }
            }
        } catch {
            log.error("Healing a folder failed: \(String(describing: error), privacy: .public)")
        }
        if !healed.isEmpty { post(healed) }
        return healed
    }

    /// Holds `heal` off while minivu moves files and then reports the moves
    /// (`fileMoved`, or a batch rename's `filesMoved` once every rename is
    /// done). A folder listed in between (its watcher fires as files move)
    /// would otherwise reattach the rows by identity first, and the report
    /// would then find a row already at each new name and drop it as a
    /// replaced file's: the marks would be lost. A skipped heal costs
    /// nothing; the next listing heals. Calls nest; pair each with
    /// `resumeHealing`.
    public func pauseHealing() {
        healCommit.withLock { lock.withLock { movesInFlight += 1 } }
    }

    public func resumeHealing() {
        lock.withLock { movesInFlight = max(movesInFlight - 1, 0) }
    }

    var isHealingPaused: Bool { lock.withLock { movesInFlight > 0 } }

    /// True only the first time it's called, so pruning runs once a launch.
    private func claimFirstPrune() -> Bool {
        lock.withLock {
            defer { hasPrunedMissing = true }
            return !hasPrunedMissing
        }
    }

    /// The same for the metadata cache and for collection members.
    func claimFirstMetadataPrune() -> Bool {
        lock.withLock {
            defer { hasPrunedMetadata = true }
            return !hasPrunedMetadata
        }
    }

    func claimFirstMemberPrune() -> Bool {
        lock.withLock {
            defer { hasPrunedMembers = true }
            return !hasPrunedMembers
        }
    }

    /// An item of a folder as `heal` lists it: its name and file identifier.
    struct ListedItem {
        var name: String
        var fileID: Int64?
    }

    // MARK: - Keys

    static func key(_ url: URL) -> String {
        var resolver = ParentResolver()
        return resolver.key(url)
    }

    /// Keys for many URLs, resolving each distinct folder's symlinks once
    /// (a folder's files share it) instead of once per file.
    static func keys(for urls: [URL]) -> [String] {
        var resolver = ParentResolver()
        return urls.map { resolver.key($0) }
    }

    /// Builds keys, remembering resolved folders. Works on UTF-8 bytes:
    /// Character-level `String` searching made keys 90% of the time of
    /// reading a 5,000-file folder's marks.
    struct ParentResolver {
        private var last: (parent: Substring, resolved: String)?
        private var cache: [Substring: String] = [:]

        mutating func key(_ url: URL) -> String {
            var path = url.path
            var bytes = Self.scan(path)
            if bytes.needsStandardizing {
                path = url.standardizedFileURL.path
                bytes = Self.scan(path)
            }
            guard let slash = bytes.lastSlash else { return normalized(path) }
            let utf8 = path.utf8
            let slashIndex = utf8.index(utf8.startIndex, offsetBy: slash)
            let parent = slash == 0 ? Substring("/") : Substring(utf8[..<slashIndex])
            let name = Substring(utf8[utf8.index(after: slashIndex)...])
            let resolved: String
            if let last, last.parent == parent {
                resolved = last.resolved
            } else if let cached = cache[parent] {
                resolved = cached
            } else {
                resolved = URL(fileURLWithPath: String(parent), isDirectory: true).resolvingSymlinksInPath().path
                cache[parent] = resolved
            }
            last = (parent, resolved)
            var key = resolved
            key.reserveCapacity(resolved.utf8.count + name.utf8.count + 1)
            if resolved != "/" { key.append("/") }
            key.append(contentsOf: name)
            return bytes.isASCII && resolved.utf8.allSatisfy({ $0 < 0x80 }) ? key : key.precomposedStringWithCanonicalMapping
        }

        /// One pass over the path: the last "/", whether it's all ASCII, and
        /// whether it holds "//", "/." or "/.." that standardising removes
        /// (a hidden file's "/." costs only an unneeded standardise).
        private static func scan(_ path: String) -> (lastSlash: Int?, isASCII: Bool, needsStandardizing: Bool) {
            var lastSlash: Int?
            var isASCII = true, needsStandardizing = false
            var previous: UInt8 = 0
            var offset = 0
            for byte in path.utf8 {
                if byte >= 0x80 { isASCII = false }
                if previous == 0x2F && (byte == 0x2F || byte == 0x2E) { needsStandardizing = true }
                if byte == 0x2F { lastSlash = offset }
                previous = byte
                offset += 1
            }
            return (lastSlash, isASCII, needsStandardizing)
        }
    }

    /// A folder's own key resolves the folder itself: the `folder` column
    /// of the files inside it, and the key of its custom order.
    static func folderKey(_ folder: URL) -> String {
        normalized(folder.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func parent(ofKey key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return slash == key.startIndex ? "/" : String(key[..<slash])
    }

    static func name(ofKey key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    /// NFC, skipped for ASCII (nearly every path), which is NFC already.
    static func normalized(_ s: String) -> String {
        s.utf8.allSatisfy({ $0 < 0x80 }) ? s : s.precomposedStringWithCanonicalMapping
    }

    /// A JSON array of strings, built by hand: paths almost never need
    /// escaping, and this avoids bridging every path through JSONSerialization.
    static func jsonArray(_ strings: [String]) -> String {
        var out = "["
        out.reserveCapacity(strings.reduce(2) { $0 + $1.utf8.count + 3 })
        for (i, s) in strings.enumerated() {
            if i > 0 { out.append(",") }
            out.append("\"")
            if s.utf8.contains(where: { $0 == 0x22 || $0 == 0x5C || $0 < 0x20 }) {
                for scalar in s.unicodeScalars {
                    switch scalar {
                    case "\"": out.append("\\\"")
                    case "\\": out.append("\\\\")
                    case _ where scalar.value < 0x20: out.append(String(format: "\\u%04x", scalar.value))
                    default: out.unicodeScalars.append(scalar)
                    }
                }
            } else {
                out.append(s)
            }
            out.append("\"")
        }
        out.append("]")
        return out
    }

    // MARK: - File identity

    struct Identity {
        var volume: String?
        var fileID: Int64?
        var size: Int64?
        var modified: Double?

        /// volume, file_id, size, modified, as statement arguments.
        var values: [SQLiteValue] {
            [volume.map { .text($0) } ?? .null, fileID.map { .integer($0) } ?? .null,
             size.map { .integer($0) } ?? .null, modified.map { .real($0) } ?? .null]
        }
    }

    /// One `lstat` per path (a missing file gets an empty identity), and the
    /// volume UUID looked up once per device number.
    static func identities(of paths: [String]) -> [Identity] {
        var volumes: [dev_t: String] = [:]
        return paths.map { identity(ofPath: $0, volumes: &volumes) }
    }

    /// `lstat`, not `stat`: a symlink's marks belong to the link, as its
    /// path does. `st_ino` is the same number as `fileIdentifierKey`.
    static func identity(ofPath path: String, volumes: inout [dev_t: String]) -> Identity {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Identity() }
        let volume: String?
        if let cached = volumes[st.st_dev] {
            volume = cached
        } else {
            volume = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            if let volume { volumes[st.st_dev] = volume }
        }
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Identity(volume: volume, fileID: Int64(bitPattern: UInt64(st.st_ino)), size: Int64(st.st_size),
                        modified: modified)
    }

    private static func marks(from row: SQLiteRow) -> Marks {
        Marks(rating: Int(row.int("rating") ?? 0), isTagged: (row.int("tagged") ?? 0) != 0)
    }

    private func post(_ urls: [URL]) {
        Perf.count("catalog.didChange")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: urls) }
    }
}

/// The extension point for keeping marks outside the catalog as well: the
/// app installs one that writes them into the files as XMP (`xmp:Rating`)
/// for Lightroom, Bridge and digiKam, while the user has that on (G2).
public protocol CatalogMirror: AnyObject, Sendable {
    /// Called after a rating or tag change is committed, on the thread that
    /// made it, with the mark the change set (`field`) and the new marks of
    /// the files in `urls` (files left with none are absent from `marks`, or
    /// present as `.none`). A mirror should copy out only `field`: the
    /// other mark in `marks` may be a stale one that the file has since
    /// replaced in another application.
    func catalog(_ catalog: Catalog, didChange field: Catalog.MarkField, marks: [URL: Catalog.Marks], of urls: [URL])
}

/// Finder tags (the coloured labels) on files, read and written through the
/// file system, so they show in Finder and Spotlight too.
public enum FinderTags {
    public static func tags(for url: URL) -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// `URLResourceValues.tagNames` is read-only before macOS 26; NSURL's
    /// setter works on every supported system.
    public static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    // MARK: - Colour labels (G4)

    /// The extended attribute Finder keeps tags in: a property list of
    /// "Name\nN" strings, N the colour's label number (0 for none).
    public static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// The standard colour tags' names by label number, as an English
    /// system names them. The app passes Finder's own names
    /// (`NSWorkspace.fileLabels`), which follow the system's language and
    /// any renaming in Finder's settings.
    public static let englishColorNames: [Int: String] = Dictionary(
        uniqueKeysWithValues: ColorLabel.allCases.filter { $0 != .none }.map { ($0.finderColorIndex, $0.name) })

    /// The file's tags exactly as stored, colours included; empty when it
    /// has none. Throws when it has tags that can't be read (the attribute
    /// changed while it was read, or isn't a list of names), so a write
    /// built on them can't drop the tags it couldn't see.
    public static func entries(of url: URL) throws -> [String] {
        let path = url.path
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        if size < 0 {
            guard errno == ENOATTR else { throw posixError(path) }
            return []
        }
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, 0) }
        guard read >= 0 else { throw posixError(path) }
        guard read == size,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
        return values
    }

    /// `entries` with the standard colour tags taken out and `label`'s put
    /// in (none for `.none`). A standard colour tag is one named as any of
    /// them (`standardNames`, or the English names), in any letter case;
    /// every other tag stays as it was, colour and all, in its place.
    public static func entries(_ entries: [String], settingColorLabel label: ColorLabel,
                               standardNames: [Int: String] = englishColorNames) -> [String] {
        let names = Set((Array(standardNames.values) + Array(englishColorNames.values) + ["Grey"]).map { $0.lowercased() })
        var result = entries.filter { entry in
            let name = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return !names.contains(String(name).lowercased())
        }
        if label != .none {
            let index = label.finderColorIndex
            result.append("\(standardNames[index] ?? label.name)\n\(index)")
        }
        return result
    }

    /// Gives `url` the colour label `label` (none for `.none`), keeping its
    /// other tags. Written as Finder writes tags, with the colour beside the
    /// name, so the label shows in its colour whatever the name. The
    /// attribute is removed when no tag is left. A file that already says
    /// this is left alone, and one whose tags can't be read is refused
    /// (`entries(of:)` throws) rather than left with only the new label.
    public static func setColorLabel(_ label: ColorLabel, for url: URL,
                                     standardNames: [Int: String] = englishColorNames) throws {
        let old = try entries(of: url)
        let new = entries(old, settingColorLabel: label, standardNames: standardNames)
        guard new != old else { return }
        let path = url.path
        if new.isEmpty {
            guard removexattr(path, attributeName, 0) == 0 || errno == ENOATTR else { throw posixError(path) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: new, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(path, attributeName, $0.baseAddress, data.count, 0, 0) }
        guard result == 0 else { throw posixError(path) }
    }

    private static func posixError(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
