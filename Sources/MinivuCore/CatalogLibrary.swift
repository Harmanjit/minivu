import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.minivu.app", category: "catalog")

/// What G3 keeps in the catalog beside the marks: the metadata the filters
/// and Find have read, collections and smart folders.
extension Catalog {
    /// Posted on the main queue after collections or smart folders change:
    /// one made, renamed or deleted, members added or removed, or members
    /// found again by healing. The sidebar lists them again and a browser
    /// showing one lists it again. No object.
    public static let libraryDidChange = Notification.Name("MinivuCatalogLibraryDidChange")

    // MARK: - Metadata for filtering

    /// Cached rows older than this are dropped, the next time the cache is
    /// written to: it costs a header read to make one again, and a file
    /// nobody has searched for in a year shouldn't keep a row.
    static let metadataRetention: TimeInterval = 365 * 24 * 3600

    /// The cached metadata of the entries whose row is still current: the
    /// file has the size and modification date the row was read at. A file
    /// changed since (a save, an edit in another app, keywords written by
    /// Edit Metadata) misses, and is read again. One query for any number.
    public func filterMetadata(for entries: [FolderEntry]) -> [URL: FilterMetadata] {
        guard !entries.isEmpty else { return [:] }
        let keys = Self.keys(for: entries.map(\.url))
        let rows: [SQLiteRow]
        do {
            rows = try db.query("""
                SELECT j.key AS i, m.size AS size, m.modified AS modified, m.date_taken AS date_taken,
                    m.camera AS camera, m.lens AS lens, m.iso AS iso, m.aperture AS aperture,
                    m.focal_length AS focal_length, m.keywords AS keywords, m.has_location AS has_location,
                    m.width AS width, m.height AS height
                FROM json_each(?1) AS j CROSS JOIN metadata AS m ON m.path = j.value
                """, [.text(Self.jsonArray(keys))])
        } catch {
            log.error("Reading cached metadata failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
        var result: [URL: FilterMetadata] = [:]
        for row in rows {
            guard let i = row.int("i").map(Int.init), entries.indices.contains(i) else { continue }
            let entry = entries[i]
            guard row.int("size") == entry.fileSize,
                  abs((row.double("modified") ?? 0) - entry.modified.timeIntervalSince1970) < 0.001 else { continue }
            result[entry.url] = FilterMetadata(
                dateTaken: row.int("date_taken"), camera: row.string("camera"), lens: row.string("lens"),
                iso: row.double("iso"), aperture: row.double("aperture"), focalLength: row.double("focal_length"),
                keywords: Self.keywordList(row.string("keywords")), hasLocation: (row.int("has_location") ?? 0) != 0,
                pixelWidth: row.int("width").map(Int.init), pixelHeight: row.int("height").map(Int.init))
        }
        return result
    }

    /// Caches metadata just read from the files, with the size and date
    /// each entry had when it was read, in one transaction.
    public func storeFilterMetadata(_ items: [(entry: FolderEntry, metadata: FilterMetadata)]) {
        guard !items.isEmpty else { return }
        let keys = Self.keys(for: items.map(\.entry.url))
        let now = Date().timeIntervalSince1970
        let prunes = claimFirstMetadataPrune()
        do {
            try db.transaction {
                for (key, item) in zip(keys, items) {
                    let m = item.metadata
                    try db.execute("""
                        INSERT OR REPLACE INTO metadata (path, size, modified, read_at, date_taken, camera, lens, iso,
                            aperture, focal_length, keywords, has_location, width, height)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                        """, [.text(key), .integer(item.entry.fileSize), .real(item.entry.modified.timeIntervalSince1970),
                              .real(now), m.dateTaken.map { .integer($0) } ?? .null,
                              m.camera.map { .text($0) } ?? .null, m.lens.map { .text($0) } ?? .null,
                              m.iso.map { .real($0) } ?? .null, m.aperture.map { .real($0) } ?? .null,
                              m.focalLength.map { .real($0) } ?? .null,
                              m.keywords.isEmpty ? .null : .text(Self.keywordText(m.keywords)),
                              .integer(m.hasLocation ? 1 : 0), m.pixelWidth.map { .integer(Int64($0)) } ?? .null,
                              m.pixelHeight.map { .integer(Int64($0)) } ?? .null])
                }
                if prunes {
                    try db.execute("DELETE FROM metadata WHERE read_at < ?1", [.real(now - Self.metadataRetention)])
                }
            }
        } catch {
            log.error("Caching metadata failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The metadata of every entry: cached rows where they are current, the
    /// rest read from the files (header only) and cached, a chunk at a time
    /// so a cancelled read keeps what it read. Blocking disk work; call it
    /// off the main thread. Entries left out of the result were cancelled.
    public func loadFilterMetadata(for entries: [FolderEntry], isCancelled: () -> Bool = { false },
                                   reader: (URL) -> FilterMetadata = FilterMetadata.read(from:)) -> [URL: FilterMetadata] {
        var result = filterMetadata(for: entries)
        let missing = entries.filter { result[$0.url] == nil }
        var start = 0
        while start < missing.count, !isCancelled() {
            let chunk = missing[start..<min(start + Self.metadataChunk, missing.count)]
            var read: [(entry: FolderEntry, metadata: FilterMetadata)] = []
            for entry in chunk {
                if isCancelled() { break }
                read.append((entry, reader(entry.url)))
            }
            storeFilterMetadata(read)
            for item in read { result[item.entry.url] = item.metadata }
            start += Self.metadataChunk
        }
        return result
    }

    /// Files read between two writes of the cache.
    static let metadataChunk = 100

    /// Keywords as one text column: a record separator between them, which
    /// no keyword contains (IPTC and XMP keywords are lines of text).
    static func keywordText(_ keywords: [String]) -> String { keywords.joined(separator: "\u{1E}") }

    static func keywordList(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Collections

    /// A named collection: membership chosen by the user, kept by file
    /// identity (see `addToCollection`).
    public struct Collection: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var name: String
        /// Members whose file is where the catalog last saw it, outside the Trash.
        public var count: Int
    }

    /// Every collection, by name in Finder's order.
    public func collections() -> [Collection] {
        let rows = (try? db.query("""
            SELECT c.id AS id, c.name AS name,
                (SELECT COUNT(*) FROM collection_items AS i
                 WHERE i.collection = c.id AND i.missing_since IS NULL
                     AND instr(i.path, '/.Trash/') = 0 AND instr(i.path, '/.Trashes/') = 0) AS n
            FROM collections AS c
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row.int("id"), let name = row.string("name") else { return nil }
            return Collection(id: id, name: name, count: Int(row.int("n") ?? 0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes an empty collection and returns its id; nil if it couldn't be
    /// written. Names need not be unique, as Finder's smart folders' needn't.
    @discardableResult
    public func createCollection(named name: String) -> Int64? {
        let id: Int64?
        do {
            id = try db.transaction { () throws -> Int64? in
                try db.execute("INSERT INTO collections (name, created) VALUES (?1, ?2)",
                               [.text(name), .real(Date().timeIntervalSince1970)])
                return try db.query("SELECT last_insert_rowid() AS id").first?.int("id")
            }
        } catch {
            log.error("Making a collection failed: \(String(describing: error), privacy: .public)")
            id = nil
        }
        postLibraryChange()
        return id
    }

    public func renameCollection(_ id: Int64, to name: String) {
        run("Renaming a collection") {
            try db.execute("UPDATE collections SET name = ?1 WHERE id = ?2", [.text(name), .integer(id)])
        }
    }

    /// Deletes the collection, never its files.
    public func deleteCollection(_ id: Int64) {
        run("Deleting a collection") {
            try db.transaction {
                try db.execute("DELETE FROM collection_items WHERE collection = ?1", [.integer(id)])
                try db.execute("DELETE FROM collections WHERE id = ?1", [.integer(id)])
            }
        }
    }

    /// Adds files to a collection, recording each one's volume and file
    /// identifier so it is found again after a move: minivu's own moves and
    /// renames carry members with them (`fileMoved`), and one made in Finder
    /// is found when its new folder is listed (`heal`) or when the
    /// collection is opened (`collectionMembers`). Files already in it stay
    /// as they are. Stats the files: call off the main thread.
    public func addToCollection(_ id: Int64, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let keys = Self.keys(for: urls)
        let identities = Self.identities(of: keys)
        let now = Date().timeIntervalSince1970
        run("Adding to a collection") {
            try db.transaction {
                for (key, identity) in zip(keys, identities) {
                    try db.execute("""
                        INSERT INTO collection_items (collection, path, folder, volume, file_id, added)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                        ON CONFLICT (collection, path) DO UPDATE SET volume = excluded.volume,
                            file_id = excluded.file_id, missing_since = NULL
                        """, [.integer(id), .text(key), .text(Self.parent(ofKey: key)),
                              identity.volume.map { .text($0) } ?? .null,
                              identity.fileID.map { .integer($0) } ?? .null, .real(now)])
                }
            }
        }
    }

    public func removeFromCollection(_ id: Int64, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let keys = Self.keys(for: urls)
        run("Removing from a collection") {
            try db.transaction {
                for key in keys {
                    try db.execute("DELETE FROM collection_items WHERE collection = ?1 AND path = ?2",
                                   [.integer(id), .text(key)])
                }
            }
        }
    }

    /// The collections `url` belongs to, by id.
    public func collections(containing url: URL) -> Set<Int64> {
        let rows = (try? db.query("SELECT collection FROM collection_items WHERE path = ?1",
                                  [.text(Self.key(url))])) ?? []
        return Set(rows.compactMap { $0.int("collection") })
    }

    /// The files of a collection that exist, in the order they were added.
    ///
    /// A member not at its recorded path is looked for by its identity on
    /// its volume (`fsgetpath`), which finds a file moved or renamed in
    /// Finder anywhere on the same volume; its row takes the new path. One
    /// that can't be found (deleted, moved to another volume, or somewhere
    /// the sandbox can't see) is stamped missing and left out, and comes
    /// back if healing finds it later; after a year missing it is dropped,
    /// as marks are. An identity found in a Trash folder, or at a path minivu
    /// can't open (outside every folder the user granted), counts as not
    /// found: the row keeps its path, so Put Back in Finder or a new grant
    /// brings the member back. A member minivu moved to the Trash (every
    /// Move to Trash records the move) is left out but stays a member, as
    /// its marks stay with it: minivu's moves out of the Trash (undoing a
    /// Replace) bring it back, and once it has left the Trash it is looked
    /// for by identity, so Finder's Put Back brings it back too (an emptied
    /// Trash stamps it missing). Stats every member: call off the main
    /// thread.
    public func collectionMembers(_ id: Int64) -> [URL] {
        guard let rows = try? db.query("""
            SELECT rowid AS id, path, volume, file_id, missing_since FROM collection_items
            WHERE collection = ?1 ORDER BY added, rowid
            """, [.integer(id)]) else { return [] }
        var members: [URL] = []
        var found: [(id: Int64, path: String)] = []
        var missing: [Int64] = []
        var volumes: [dev_t: String] = [:]
        for row in rows {
            guard let rowID = row.int("id"), let path = row.string("path") else { continue }
            // Moved to the Trash by minivu and still there: left out, still a
            // member. Gone from the Trash, it was put back in Finder (found
            // by identity below) or the Trash was emptied (stamped missing
            // below, then pruned with the rest).
            if Self.isInTrash(path), !Self.isGone(path) { continue }
            let fileID = row.int("file_id"), volume = row.string("volume")
            let here = Self.identity(ofPath: path, volumes: &volumes)
            // The recorded path still holds a file: the same one, or one saved
            // over it under the same name (a save writes a new file), which
            // is the member as far as the user can tell.
            if here.fileID != nil {
                members.append(URL(fileURLWithPath: path))
                // Back where it was (put back from the Trash): counted again.
                if row["missing_since"] != .null { found.append((rowID, path)) }
                continue
            }
            if let fileID, let volume, let moved = Self.path(ofFile: fileID, onVolume: volume, near: path),
               !Self.isInTrash(moved), Self.canOpen(moved) {
                members.append(URL(fileURLWithPath: moved))
                found.append((rowID, moved))
            } else if row["missing_since"] == .null {
                missing.append(rowID)
            }
        }
        if !found.isEmpty || !missing.isEmpty {
            let now = Date().timeIntervalSince1970
            run("Updating a collection", notify: false) {
                try db.transaction {
                    for item in found {
                        // The file system's spelling (/private/var) made into
                        // the catalog's (/var), as every other key is.
                        let key = Self.key(URL(fileURLWithPath: item.path))
                        try db.execute("""
                            UPDATE OR IGNORE collection_items SET path = ?1, folder = ?2, missing_since = NULL
                            WHERE rowid = ?3
                            """, [.text(key), .text(Self.parent(ofKey: key)), .integer(item.id)])
                    }
                    for rowID in missing {
                        try db.execute("UPDATE collection_items SET missing_since = ?1 WHERE rowid = ?2",
                                       [.real(now), .integer(rowID)])
                    }
                }
            }
        }
        return members
    }

    /// A path inside a Trash folder: the user's (~/.Trash) or a volume's
    /// (/.Trashes/501). Members there are left out of their collections.
    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// Whether nothing is at `path` any more (not merely unreadable).
    static func isGone(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) != 0 && errno == ENOENT
    }

    /// Whether minivu may read the file at `path`. `fsgetpath` names a file
    /// anywhere on its volume, but under the App Sandbox only granted
    /// folders can be read, and a member listed where it can't be opened
    /// would vanish from the list anyway, its row moved out of reach.
    /// `access` is asked rather than opening the file, which could make a
    /// cloud placeholder download; the sandbox answers it as it would an
    /// open.
    static func canOpen(_ path: String) -> Bool {
        access(path, R_OK) == 0
    }

    /// Where a file now is, from its identifier and its volume's UUID, or
    /// nil. `near` is a path it had: the volume's file system id is read
    /// from the nearest folder above it that still exists, and checked to
    /// be the volume recorded, so an identifier is never looked up on
    /// another volume (where it names a different file).
    static func path(ofFile fileID: Int64, onVolume volume: String, near oldPath: String) -> String? {
        var folder = parent(ofKey: oldPath)
        var st = stat()
        while !folder.isEmpty, folder != "/", lstat(folder, &st) != 0 { folder = parent(ofKey: folder) }
        guard !folder.isEmpty,
              (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volume
        else { return nil }
        var fs = statfs()
        guard statfs(folder, &fs) == 0 else { return nil }
        var fsid = fs.f_fsid
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = fsgetpath(&buffer, buffer.count, &fsid, UInt64(bitPattern: fileID))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
        // The identifier must still name this file there, as `heal` checks.
        guard lstat(path, &st) == 0, Int64(bitPattern: UInt64(st.st_ino)) == fileID else { return nil }
        return path
    }

    /// `heal`'s pass over collection members in `folder`: members whose name
    /// is listed take the listed identity; those gone are stamped missing;
    /// listed files that are members elsewhere by identity (moved here in
    /// Finder) take this path. True when any member moved.
    func healCollectionMembers(folder: URL, folderKey: String, listed: [String: ListedItem], volume: String?) -> Bool {
        do {
            guard try !db.query("SELECT 1 AS x FROM collection_items LIMIT 1").isEmpty else { return false }
            let rows = try db.query("SELECT rowid AS id, path, file_id, volume, missing_since FROM collection_items WHERE folder = ?1",
                                    [.text(folderKey)])
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
            var moves: [(id: Int64, name: String)] = []
            let orphans = listed.filter { !rowed.contains($0.key) && $0.value.fileID != nil }.map(\.value)
            if let volume, !orphans.isEmpty {
                let json = "[" + orphans.map { String($0.fileID!) }.joined(separator: ",") + "]"
                var volumes: [dev_t: String] = [:]
                for hit in try db.query("""
                    SELECT j.key AS i, c.rowid AS id, c.path AS path FROM json_each(?1) AS j
                    CROSS JOIN collection_items AS c ON c.volume = ?2 AND c.file_id = j.value
                    """, [.text(json), .text(volume)]) {
                    guard let i = hit.int("i"), let id = hit.int("id"), let oldPath = hit.string("path") else { continue }
                    let item = orphans[Int(i)]
                    if Self.identity(ofPath: oldPath, volumes: &volumes).fileID == item.fileID { continue }
                    moves.append((id, item.name))
                }
            }
            let prunes = claimFirstMemberPrune()
            // Members minivu moved to the Trash are left out of their
            // collections, so opening one never stamps them; stamp those
            // that have left it (emptied, or put back, where opening the
            // collection still finds them by identity) so the prune below
            // drops them after the year, as `heal` does for marks.
            if prunes {
                for row in try db.query("""
                    SELECT rowid AS id, path FROM collection_items
                    WHERE (instr(path, '/.Trash/') > 0 OR instr(path, '/.Trashes/') > 0) AND missing_since IS NULL
                    """) {
                    if let id = row.int("id"), let path = row.string("path"), Self.isGone(path) { missing.append(id) }
                }
            }
            guard prunes || !refresh.isEmpty || !missing.isEmpty || !moves.isEmpty else { return false }
            let now = Date().timeIntervalSince1970
            try db.transaction {
                for r in refresh {
                    try db.execute("UPDATE collection_items SET file_id = ?1, volume = ?2, missing_since = NULL WHERE rowid = ?3",
                                   [r.fileID.map { .integer($0) } ?? .null, volume.map { .text($0) } ?? .null, .integer(r.id)])
                }
                for id in missing {
                    try db.execute("UPDATE collection_items SET missing_since = ?1 WHERE rowid = ?2", [.real(now), .integer(id)])
                }
                for move in moves {
                    let newPath = folderKey == "/" ? "/" + move.name : folderKey + "/" + move.name
                    try db.execute("""
                        UPDATE OR IGNORE collection_items SET path = ?1, folder = ?2, missing_since = NULL WHERE rowid = ?3
                        """, [.text(newPath), .text(folderKey), .integer(move.id)])
                    // Already a member under its new path: the old row goes.
                    if db.changes == 0 {
                        try db.execute("DELETE FROM collection_items WHERE rowid = ?1", [.integer(move.id)])
                    }
                }
                if prunes {
                    try db.execute("DELETE FROM collection_items WHERE missing_since < ?1", [.real(now - Self.missingRetention)])
                }
            }
            if !moves.isEmpty || !missing.isEmpty || !refresh.isEmpty { postLibraryChange() }
            return !moves.isEmpty
        } catch {
            log.error("Healing collection members failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Smart folders

    /// A saved search, re-run whenever it is opened.
    public struct SmartFolder: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var name: String
        public var query: SearchQuery
    }

    /// Every smart folder whose search can be read, by name in Finder's order.
    public func smartFolders() -> [SmartFolder] {
        let rows = (try? db.query("SELECT id, name, query FROM smart_folders")) ?? []
        return rows.compactMap { row in
            guard let id = row.int("id"), let name = row.string("name"), let json = row.string("query") else { return nil }
            do {
                return SmartFolder(id: id, name: name, query: try SearchQuery.decoded(json))
            } catch {
                log.error("A smart folder's search can't be read: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func smartFolder(_ id: Int64) -> SmartFolder? {
        smartFolders().first { $0.id == id }
    }

    @discardableResult
    public func saveSmartFolder(named name: String, query: SearchQuery) -> Int64? {
        let id: Int64?
        do {
            let json = try query.encoded()
            id = try db.transaction { () throws -> Int64? in
                try db.execute("INSERT INTO smart_folders (name, query, created) VALUES (?1, ?2, ?3)",
                               [.text(name), .text(json), .real(Date().timeIntervalSince1970)])
                return try db.query("SELECT last_insert_rowid() AS id").first?.int("id")
            }
        } catch {
            log.error("Saving a smart folder failed: \(String(describing: error), privacy: .public)")
            id = nil
        }
        postLibraryChange()
        return id
    }

    public func updateSmartFolder(_ id: Int64, query: SearchQuery) {
        guard let json = try? query.encoded() else { return }
        run("Updating a smart folder") {
            try db.execute("UPDATE smart_folders SET query = ?1 WHERE id = ?2", [.text(json), .integer(id)])
        }
    }

    public func renameSmartFolder(_ id: Int64, to name: String) {
        run("Renaming a smart folder") {
            try db.execute("UPDATE smart_folders SET name = ?1 WHERE id = ?2", [.text(name), .integer(id)])
        }
    }

    public func deleteSmartFolder(_ id: Int64) {
        run("Deleting a smart folder") {
            try db.execute("DELETE FROM smart_folders WHERE id = ?1", [.integer(id)])
        }
    }

    // MARK: - Helpers

    private func run(_ what: String, notify: Bool = true, _ body: () throws -> Void) {
        do { try body() } catch {
            log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        if notify { postLibraryChange() }
    }

    func postLibraryChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.libraryDidChange, object: nil) }
    }
}
