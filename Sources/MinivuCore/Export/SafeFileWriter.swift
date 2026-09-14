import Foundation

/// Writes files so that a crash, a full disk or an encoder error never
/// leaves a half-written photo behind.
///
/// The new file is written next to the old one under a hidden temporary
/// name, flushed to disk, and only then swapped into place. Until the swap
/// the original is untouched; after it the new file is complete. The
/// temporary file lives in the same folder (not in the temporary
/// directory) because a rename is only atomic within one volume.
///
/// Under the sandbox that needs write access to the folder, which folders
/// the user opened in minivu have. A Save panel is different: it grants
/// the one file the user named, not its folder, so a temporary sibling
/// can't be created there (Save As onto the Desktop, say). In that case the
/// temporary file goes in the system's item-replacement folder for that
/// volume, which the sandbox allows and which is on the same volume, so the
/// final swap is still atomic.
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
    ///
    /// A symbolic link is followed: the file it points at is replaced and
    /// the link stays a link. (`replaceItemAt` refuses a link outright.) A
    /// folder at `url` is refused, because `replaceItemAt` would otherwise
    /// swap the new file in and delete the folder with everything in it; a
    /// batch convert writing "photo.jpg" next to a folder of that name must
    /// fail, not destroy it.
    public static func replace(_ url: URL, fill: (URL) throws -> Void) throws {
        try replace(url, canCreateSibling: probeCreate, fill: fill)
    }

    static func replace(_ url: URL, canCreateSibling: (URL) -> Bool, fill: (URL) throws -> Void) throws {
        let url = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        let (temp, scratchFolder) = temporaryLocation(for: url, canCreateSibling: canCreateSibling)
        defer { if let scratchFolder { try? FileManager.default.removeItem(at: scratchFolder) } }
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

    /// Where to write the temporary file: a hidden sibling when the folder
    /// accepts new files, otherwise a fresh item-replacement folder on the
    /// same volume (returned so it can be removed afterwards).
    /// `canCreateSibling` is injectable for tests; by default it tries to
    /// create the sibling, which is the only reliable test under the sandbox
    /// (`access(2)` reports POSIX permissions, not sandbox rules).
    static func temporaryLocation(for url: URL,
                                  canCreateSibling: (URL) -> Bool = probeCreate) -> (URL, URL?) {
        let sibling = temporaryURL(for: url)
        if canCreateSibling(sibling) { return (sibling, nil) }
        if let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: url, create: true) {
            return (folder.appendingPathComponent(sibling.lastPathComponent, isDirectory: false), folder)
        }
        return (sibling, nil)
    }

    static func probeCreate(_ url: URL) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        unlink(url.path)
        return true
    }

    /// Writes `data` to `url` atomically.
    public static func write(_ data: Data, to url: URL) throws {
        try replace(url) { temp in try data.write(to: temp, options: .withoutOverwriting) }
    }

    /// A hidden sibling (a leading dot keeps it out of Finder and our own
    /// folder listing) with a random part, so two saves never collide.
    /// File names are limited to 255 bytes, and the dot and suffix add 21,
    /// so a very long name is shortened first (by whole characters, so the
    /// name stays valid UTF-8).
    static func temporaryURL(for url: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        var name = url.lastPathComponent
        while name.utf8.count > 200 { name.removeLast() }
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).minivu-\(token).tmp", isDirectory: false)
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
