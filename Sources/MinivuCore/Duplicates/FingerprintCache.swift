import Foundation

/// What the duplicate finder learnt about a file (G5): the SHA-256 of its
/// bytes and its feature print, either of which may not be known yet.
public struct Fingerprint: Sendable, Equatable {
    public var sha256: Data?
    public var print: FeaturePrint?

    public init(sha256: Data? = nil, print: FeaturePrint? = nil) {
        self.sha256 = sha256
        self.print = print
    }
}

/// A file as the fingerprint cache knows it: its identity (volume and file
/// identifier, which a rename or a move within the volume keeps), and the
/// size and modification date that say whether a cached row still
/// describes its contents. A save replaces the file atomically, so it
/// changes all of them.
public struct FileIdentity: Hashable, Sendable {
    public var volume: String
    public var fileID: Int64
    public var size: Int64
    public var modified: Double

    public init(volume: String, fileID: Int64, size: Int64, modified: Double) {
        self.volume = volume
        self.fileID = fileID
        self.size = size
        self.modified = modified
    }

    /// The identities of the files that can be read now: one `lstat` each, the
    /// volume's UUID looked up once per device. Blocking: off the main thread.
    public static func read(_ urls: [URL]) -> [URL: FileIdentity] {
        var volumes: [dev_t: String] = [:]
        var result: [URL: FileIdentity] = [:]
        for url in urls {
            let identity = Catalog.identity(ofPath: url.path, volumes: &volumes)
            guard let volume = identity.volume, let fileID = identity.fileID, let size = identity.size,
                  let modified = identity.modified else { continue }
            result[url] = FileIdentity(volume: volume, fileID: fileID, size: size, modified: modified)
        }
        return result
    }
}

/// The duplicate finder's cache, in the thumbnail database (it is a cache
/// like the thumbnails: rebuilt on demand, emptied with them), so a second
/// run over the same photos reads and analyses nothing. Rows are keyed by
/// file identity and kept only while the size and date match; the oldest
/// used go first once the cache passes its byte budget.
extension ThumbnailStore {
    static let fingerprintsTable = """
        CREATE TABLE IF NOT EXISTS fingerprints (
            volume TEXT NOT NULL,
            file_id INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            sha256 BLOB,
            print BLOB,
            print_revision INTEGER,
            accessed REAL NOT NULL,
            PRIMARY KEY (volume, file_id)
        );
        CREATE INDEX IF NOT EXISTS fingerprints_accessed ON fingerprints (accessed);
        """

    /// Largest the fingerprints may grow: about 20,000 photos' prints
    /// (a revision 2 print is 768 floats, 3 KB).
    public static let fingerprintCacheLimit = 64 << 20

    /// The cached fingerprints still current for `identities`; files whose row
    /// is missing or out of date are absent.
    public func fingerprints(for identities: [FileIdentity]) -> [FileIdentity: Fingerprint] {
        var result: [FileIdentity: Fingerprint] = [:]
        let now = Date().timeIntervalSinceReferenceDate
        var touched: [FileIdentity] = []
        for identity in identities {
            guard let row = try? db.query("""
                SELECT size, modified, sha256, print, print_revision, accessed FROM fingerprints
                WHERE volume = ?1 AND file_id = ?2
                """, [.text(identity.volume), .integer(identity.fileID)]).first,
                  row.int("size") == identity.size, abs((row.double("modified") ?? 0) - identity.modified) < 0.001
            else { continue }
            let print = row.data("print").flatMap { bytes in
                row.int("print_revision").flatMap { FeaturePrint(revision: Int($0), bytes: bytes) }
            }
            result[identity] = Fingerprint(sha256: row.data("sha256"), print: print)
            if now - (row.double("accessed") ?? 0) > Self.accessResolution { touched.append(identity) }
        }
        if !touched.isEmpty {
            try? db.transaction {
                for identity in touched {
                    try db.execute("UPDATE fingerprints SET accessed = ?1 WHERE volume = ?2 AND file_id = ?3",
                                   [.real(now), .text(identity.volume), .integer(identity.fileID)])
                }
            }
        }
        return result
    }

    /// Records content hashes, keeping a print already cached for the same
    /// contents and dropping one made of an older version of the file.
    public func storeHashes(_ items: [(identity: FileIdentity, sha256: Data)]) {
        store(items.map { ($0.identity, Fingerprint(sha256: $0.sha256)) })
    }

    /// Records feature prints, keeping a hash already cached for the same
    /// contents and dropping one of an older version.
    public func storePrints(_ items: [(identity: FileIdentity, print: FeaturePrint)]) {
        store(items.map { ($0.identity, Fingerprint(print: $0.print)) })
    }

    /// One transaction. What a row already holds for the same size and date
    /// stays where the new value leaves a gap; a row of other contents is
    /// replaced outright.
    private func store(_ items: [(identity: FileIdentity, fingerprint: Fingerprint)]) {
        guard !items.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        try? db.transaction {
            for (identity, fingerprint) in items {
                let print = fingerprint.print
                try db.execute("""
                    INSERT INTO fingerprints (volume, file_id, size, modified, sha256, print, print_revision, accessed)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    ON CONFLICT (volume, file_id) DO UPDATE SET
                        sha256 = CASE WHEN excluded.sha256 IS NOT NULL THEN excluded.sha256
                            WHEN size = excluded.size AND abs(modified - excluded.modified) < 0.001 THEN sha256 END,
                        print = CASE WHEN excluded.print IS NOT NULL THEN excluded.print
                            WHEN size = excluded.size AND abs(modified - excluded.modified) < 0.001 THEN print END,
                        print_revision = CASE WHEN excluded.print IS NOT NULL THEN excluded.print_revision
                            WHEN size = excluded.size AND abs(modified - excluded.modified) < 0.001 THEN print_revision END,
                        size = excluded.size, modified = excluded.modified, accessed = excluded.accessed
                    """,
                    [.text(identity.volume), .integer(identity.fileID), .integer(identity.size), .real(identity.modified),
                     fingerprint.sha256.map { .blob($0) } ?? .null, print.map { .blob($0.bytes) } ?? .null,
                     print.map { .integer(Int64($0.revision)) } ?? .null, .real(now)])
            }
        }
    }

    /// Bytes of hashes and prints cached (not counting SQLite's own overhead).
    public var fingerprintBytes: Int {
        Int((try? db.query("""
            SELECT COALESCE(SUM(COALESCE(length(sha256), 0) + COALESCE(length(print), 0)), 0) AS total FROM fingerprints
            """).first?.int("total")) ?? 0)
    }

    /// Deletes the least recently used fingerprints until the rest hold at
    /// most `maxBytes`, as `prune` does for thumbnails.
    public func pruneFingerprints(maxBytes: Int = fingerprintCacheLimit) {
        guard fingerprintBytes > maxBytes else { return }
        try? db.execute("""
            DELETE FROM fingerprints WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, SUM(COALESCE(length(sha256), 0) + COALESCE(length(print), 0))
                        OVER (ORDER BY accessed DESC, rowid DESC) AS running
                    FROM fingerprints
                ) WHERE running > ?
            )
            """, [.integer(Int64(maxBytes))])
        try? db.executeScript("PRAGMA incremental_vacuum")
    }
}
