import Foundation

/// Writes files so that a crash, a full disk or an encoder error never
/// leaves a half-written photo behind.
///
/// The new file is written next to the old one under a hidden temporary
/// name, flushed to disk, and only then swapped into place. Until the swap
/// the original is untouched; after it the new file is complete. The
/// temporary file lives in the same folder (not in the temporary
/// directory) because a rename is only atomic within one volume, and
/// because the sandbox grants access to the folder the user chose, not to
/// other places on that volume. So writing next to a file needs read-write
/// access to its folder, which user-selected folders have.
///
/// Replacing goes through `FileManager.replaceItemAt`, which carries the
/// original's creation date, permissions and extended attributes (Finder
/// tags, "where from") over to the new file. What it can't keep is the file
/// identifier: the new file is a new inode, so anything tracking the file by
/// identifier should look it up by path after a save.
public enum SafeFileWriter {
    /// Calls `fill` with a temporary URL in the destination's folder, which
    /// it must create and write the complete file to, then puts that file
    /// in place of `url` (creating it if it doesn't exist). If `fill` or
    /// anything after it throws, the temporary file is deleted and `url` is
    /// left as it was.
    public static func replace(_ url: URL, fill: (URL) throws -> Void) throws {
        let temp = temporaryURL(for: url)
        do {
            try fill(temp)
            try synchronize(temp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Writes `data` to `url` atomically.
    public static func write(_ data: Data, to url: URL) throws {
        try replace(url) { temp in try data.write(to: temp, options: .withoutOverwriting) }
    }

    /// A hidden sibling (a leading dot keeps it out of Finder and our own
    /// folder listing) with a random part, so two saves never collide.
    static func temporaryURL(for url: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).minivu-\(token).tmp", isDirectory: false)
    }

    /// Asks the kernel to write the file's data to disk before we rename
    /// it, so a power cut can't leave the rename done but the data missing.
    /// `fsync`, not `F_FULLFSYNC`: the latter also flushes the drive's own
    /// cache but costs tens of milliseconds per file, which adds up in a
    /// batch convert, and APFS's copy-on-write metadata already keeps the
    /// old or the new file whole.
    static func synchronize(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
