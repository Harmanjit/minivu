import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// The on-disk thumbnail cache: small encoded images in one SQLite file
/// (DESIGN.md 4.5).
///
/// One database file instead of one image file per thumbnail: a folder of
/// 10,000 photos would otherwise mean 20,000 tiny files, each costing an
/// inode, a directory entry and an open/close to read. SQLite reads a
/// 30 KB blob in well under a millisecond.
///
/// A row is valid only while the source file's modification date and size
/// match what was recorded, so an edited photo simply misses and is
/// re-thumbnailed. Everything here does disk I/O: call it off the main
/// thread. Failures are swallowed on purpose, because a broken cache must
/// never stop the browser; the worst case is a slower re-decode.
public final class ThumbnailStore: @unchecked Sendable {
    private let db: SQLiteDatabase

    /// Bump when the table layout or the encoding changes. Old caches are
    /// dropped, not migrated: they're rebuilt on demand.
    static let schemaVersion = 1

    /// Reads refresh `accessed` only when it is older than this, so browsing
    /// a cached folder doesn't turn every read into a write.
    static let accessResolution: TimeInterval = 3600

    /// Caches/Agate/thumbnails.sqlite. Under the App Sandbox the caches
    /// directory is inside the app's container, so this needs no permission.
    public static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Agate", isDirectory: true)
            .appendingPathComponent("thumbnails.sqlite")
    }

    public init(url: URL) throws {
        db = try SQLiteDatabase(url: url)
        try migrate()
    }

    private init(database: SQLiteDatabase) throws {
        db = database
        try migrate()
    }

    public static func inMemory() throws -> ThumbnailStore {
        try ThumbnailStore(database: .inMemory())
    }

    private func migrate() throws {
        guard try db.userVersion() != Self.schemaVersion else { return }
        // auto_vacuum only takes effect on a database with no tables yet (or
        // after a VACUUM). INCREMENTAL lets prune() hand freed pages back to
        // the file system cheaply instead of leaving the file at its peak size.
        try db.executeScript("""
            DROP TABLE IF EXISTS thumbnails;
            PRAGMA auto_vacuum = INCREMENTAL;
            VACUUM;
            """)
        try db.transaction {
            try db.executeScript("""
                CREATE TABLE thumbnails (
                    path TEXT NOT NULL,
                    tier INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    size INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    accessed REAL NOT NULL,
                    PRIMARY KEY (path, tier)
                );
                CREATE INDEX thumbnails_accessed ON thumbnails (accessed);
                """)
            try db.setUserVersion(Self.schemaVersion)
        }
    }

    // MARK: - Reading and writing

    /// The cached thumbnail, decoded, or nil if there is none or the file
    /// has changed since it was made.
    ///
    /// Pixels are decoded here, on the calling thread
    /// (`kCGImageSourceShouldCacheImmediately`). Without it ImageIO decodes
    /// lazily the first time the image is drawn, which would be on the main
    /// thread in the middle of a scroll.
    public func image(for file: URL, modified: Date, fileSize: Int64, tier: Int) -> CGImage? {
        let path = file.path
        guard let row = try? db.query("SELECT modified, size, data, accessed FROM thumbnails WHERE path = ? AND tier = ?",
                                      [.text(path), .integer(Int64(tier))]).first,
              let storedModified = row.double("modified"), let storedSize = row.int("size"),
              let data = row.data("data")
        else { return nil }
        // Dates round-trip through REAL exactly, but allow a millisecond so
        // a file system that stores coarser times can't cause endless misses.
        guard abs(storedModified - modified.timeIntervalSinceReferenceDate) < 0.001, storedSize == fileSize else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                                                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else {
            try? db.execute("DELETE FROM thumbnails WHERE path = ? AND tier = ?", [.text(path), .integer(Int64(tier))])
            return nil
        }
        let now = Date().timeIntervalSinceReferenceDate
        if let accessed = row.double("accessed"), now - accessed > Self.accessResolution {
            try? db.execute("UPDATE thumbnails SET accessed = ? WHERE path = ? AND tier = ?",
                            [.real(now), .text(path), .integer(Int64(tier))])
        }
        return image
    }

    /// Encodes and saves a thumbnail, replacing any older one for the same
    /// file and tier.
    public func store(_ image: CGImage, for file: URL, modified: Date, fileSize: Int64, tier: Int) {
        guard let data = Self.encode(image) else { return }
        try? db.execute("""
            INSERT OR REPLACE INTO thumbnails (path, tier, modified, size, data, accessed)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(file.path), .integer(Int64(tier)), .real(modified.timeIntervalSinceReferenceDate),
             .integer(fileSize), .blob(data), .real(Date().timeIntervalSinceReferenceDate)])
    }

    /// Forgets every tier of one file (it was deleted, or edited in place).
    public func invalidate(_ file: URL) {
        try? db.execute("DELETE FROM thumbnails WHERE path = ?", [.text(file.path)])
    }

    public func removeAll() {
        try? db.execute("DELETE FROM thumbnails")
        try? db.executeScript("PRAGMA incremental_vacuum")
    }

    /// Deletes the least recently used thumbnails until the cache holds at
    /// most `maxBytes` of image data.
    ///
    /// One statement does it: a running total over the rows from newest to
    /// oldest access, and every row whose running total passes the budget
    /// goes. SQLite has had window functions since 3.25; macOS 15 ships 3.43.
    public func prune(maxBytes: Int) {
        guard totalBytes > maxBytes else { return }
        try? db.execute("""
            DELETE FROM thumbnails WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, SUM(length(data)) OVER (ORDER BY accessed DESC, rowid DESC) AS running
                    FROM thumbnails
                ) WHERE running > ?
            )
            """, [.integer(Int64(maxBytes))])
        try? db.executeScript("PRAGMA incremental_vacuum")
    }

    /// Bytes of encoded image data in the cache (not counting SQLite's own
    /// overhead). `length()` of a blob reads the row header, not the blob.
    public var totalBytes: Int {
        Int((try? db.query("SELECT COALESCE(SUM(length(data)), 0) AS total FROM thumbnails").first?.int("total")) ?? 0)
    }

    // MARK: - Encoding

    /// JPEG at quality 0.8 for opaque images: a 512 px photo thumbnail is
    /// about 40 KB, roughly a tenth of the PNG. Images with an alpha channel
    /// use PNG so transparency survives. The colour profile is embedded
    /// either way, so thumbnails of wide-gamut photos stay wide-gamut.
    static func encode(_ image: CGImage) -> Data? {
        let opaque: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
        let type = opaque ? UTType.jpeg : UTType.png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString,
                                                                 1, nil) else { return nil }
        let options: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
