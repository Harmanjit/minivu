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
/// marked, not with what they browsed.
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

    /// Posted on the main queue after marks or custom order change. `object`
    /// is the `[URL]` of files (or the folder, for custom order) affected.
    public static let didChange = Notification.Name("MinivuCatalogDidChange")

    /// The user's catalog, except in test runs and snapshot runs (or with
    /// `MINIVU_CATALOG=memory`), which get a private one in memory: tests and
    /// the snapshot harness rate and move files through app code, and must
    /// never change or read the ratings a user has made.
    public static let shared: Catalog = {
        if usesPrivateCatalog(ProcessInfo.processInfo) { return Catalog.inMemory() }
        do { return try Catalog(url: Catalog.defaultURL) } catch {
            log.error("Catalog unavailable, using a temporary one: \(String(describing: error), privacy: .public)")
            return Catalog.inMemory()
        }
    }()

    /// XCTest runs in `xctest`, Swift Testing under SwiftPM in
    /// `swiftpm-testing-helper`; Xcode sets XCTestConfigurationFilePath.
    static func usesPrivateCatalog(_ process: ProcessInfo) -> Bool {
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

    static let schemaVersion = 1

    let db: SQLiteDatabase
    private let lock = NSLock()
    private var hasPrunedMissing = false
    private var _mirror: (any CatalogMirror)?

    /// Opens (creating if needed) the catalog at `url`, or a private one in
    /// memory when `url` is nil.
    ///
    /// A damaged file is not deleted, unlike the thumbnail cache: it holds
    /// the user's ratings. It is renamed aside (catalog.sqlite.damaged-…)
    /// so it can be recovered by hand, and a fresh catalog starts.
    public init(url: URL?) throws {
        guard let url else {
            db = try Self.migrated(.inMemory())
            return
        }
        do {
            db = try Self.migrated(SQLiteDatabase(url: url))
        } catch let error as SQLiteError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.moveItem(atPath: url.path + suffix,
                                                  toPath: url.path + ".damaged-\(stamp)" + suffix)
            }
            log.error("Catalog was damaged and has been set aside: \(String(describing: error), privacy: .public)")
            db = try Self.migrated(SQLiteDatabase(url: url))
        }
    }

    public static func inMemory() -> Catalog { try! Catalog(url: nil) }

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
            try db.setUserVersion(version)
        }
        return db
    }

    /// Receives every rating and tag change once committed, for keeping marks
    /// somewhere besides the catalog (XMP sidecars or embedded XMP, so other
    /// apps see them). None is installed: minivu doesn't write marks into
    /// image files yet, and when it does the writes must go through the
    /// app's FileWriteQueue, which lives above this module.
    public var mirror: (any CatalogMirror)? {
        get { lock.withLock { _mirror } }
        set { lock.withLock { _mirror = newValue } }
    }

    // MARK: - Marks

    public func marks(for url: URL) -> Marks {
        let rows = (try? db.query("SELECT rating, tagged FROM files WHERE path = ?1", [.text(Self.key(url))])) ?? []
        return rows.first.map(Self.marks(from:)) ?? .none
    }

    /// Marks for the files that have any; files without are left out.
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
        write(urls, column: "rating", value: r)
    }

    public func setTagged(_ tagged: Bool, for urls: [URL]) {
        write(urls, column: "tagged", value: tagged ? 1 : 0)
    }

    /// Sets one mark column for `urls` in one transaction. A non-zero value
    /// inserts the row (recording the file's identity for healing) or
    /// updates it; zero deletes rows left with no marks at all.
    private func write(_ urls: [URL], column: String, value: Int) {
        guard !urls.isEmpty else { return }
        let keys = Self.keys(for: urls)
        // Stat before taking the database lock: readers shouldn't wait on
        // the file system.
        let identities = value == 0 ? [] : Self.identities(of: keys)
        do {
            try db.transaction {
                for (i, key) in keys.enumerated() {
                    if value == 0 {
                        try db.execute("UPDATE files SET \(column) = 0 WHERE path = ?1", [.text(key)])
                        try db.execute("DELETE FROM files WHERE path = ?1 AND rating = 0 AND tagged = 0", [.text(key)])
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
        } catch {
            log.error("Writing marks failed: \(String(describing: error), privacy: .public)")
        }
        if let mirror { mirror.catalog(self, didChangeMarks: marks(for: urls), of: urls) }
        post(urls)
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
    }

    private func applyMove(from: URL, to: URL) throws {
        let f = Self.key(from), t = Self.key(to)
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
        let place: [SQLiteValue] = [.text(fParent), .text(Self.name(ofKey: f)), .text(Self.name(ofKey: t))]
        if fParent.lowercased() == tParent.lowercased() {
            try db.execute("UPDATE OR REPLACE folder_order SET name = ?3 WHERE folder = ?1 AND name = ?2", place)
        } else {
            try db.execute("DELETE FROM folder_order WHERE folder = ?1 AND name = ?2", Array(place.prefix(2)))
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
                    INSERT INTO files (path, folder, rating, tagged)
                    SELECT ?4, ?7, rating, tagged FROM files WHERE path = ?1
                    """, args + [.text(Self.parent(ofKey: t))])
                try db.execute("""
                    INSERT INTO files (path, folder, rating, tagged)
                    SELECT ?4 || substr(path, length(?1) + 1), ?4 || substr(folder, length(?1) + 1), rating, tagged
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
            }
        } catch {
            log.error("Removing marks failed: \(String(describing: error), privacy: .public)")
        }
        post([url])
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
        let folderKey = Self.folderKey(folder)
        struct Listed { var name: String; var fileID: Int64? }
        var listed: [String: Listed] = [:]
        do {
            guard let directory = opendir(folder.path) else { return [] }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let length = Int(entry.pointee.d_namlen)
                let raw = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
                guard raw != ".", raw != ".." else { continue }
                let name = Self.normalized(raw)
                listed[name.lowercased()] = Listed(name: name, fileID: Int64(bitPattern: UInt64(entry.pointee.d_ino)))
            }
        }
        let volume = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString

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

    /// True only the first time it's called, so pruning runs once a launch.
    private func claimFirstPrune() -> Bool {
        lock.withLock {
            defer { hasPrunedMissing = true }
            return !hasPrunedMissing
        }
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
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: urls) }
    }
}

/// The extension point for keeping marks outside the catalog as well, such
/// as XMP (`xmp:Rating`) for Lightroom and Bridge. Off unless installed as
/// `Catalog.mirror`; nothing implements it yet.
public protocol CatalogMirror: AnyObject, Sendable {
    /// Called after a rating or tag change is committed, on the thread that
    /// made it, with the new marks of the files in `urls` (files left with
    /// none are absent from `marks`).
    func catalog(_ catalog: Catalog, didChangeMarks marks: [URL: Catalog.Marks], of urls: [URL])
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
}
