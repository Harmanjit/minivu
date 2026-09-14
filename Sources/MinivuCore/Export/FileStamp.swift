import Foundation
import Synchronization

/// What a file looked like at one moment: its modification date and size.
/// Enough to tell that it has been rewritten since, because a save changes
/// both (APFS timestamps have nanosecond resolution).
public struct FileStamp: Sendable, Equatable {
    public let modified: Date?
    public let size: Int64?

    public init(modified: Date?, size: Int64?) {
        self.modified = modified
        self.size = size
    }

    /// The file as it is on disk now; nil when it can't be read. Disk work.
    public static func read(_ url: URL) -> FileStamp? {
        // URLs cache resource values; every reading must go to the disk.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return FileStamp(modified: values.contentModificationDate, size: values.fileSize.map(Int64.init))
    }
}

/// The files minivu itself wrote most recently, each with the stamp the
/// write left, so an in-place Save can tell a file minivu rewrote (an
/// earlier Save, a JPEG comment) from one another application changed.
///
/// Recorded by `ImageEncoder.write` and `JPEGComment.write`. A lossless
/// rotate is deliberately not: the edits being saved were made on the
/// unrotated pixels, so to a Save it is a change like any other.
public enum OwnWrites {
    private static let stamps = Mutex<[String: FileStamp]>([:])
    /// Only recent writes matter; a long batch of captures mustn't grow this.
    static let limit = 256

    /// Notes that minivu has just written `url`. Disk work (one stat).
    public static func record(_ url: URL) {
        guard let stamp = FileStamp.read(url) else { return }
        let key = key(url)
        stamps.withLock { stamps in
            if stamps.count >= limit, stamps[key] == nil { stamps.removeAll() }
            stamps[key] = stamp
        }
    }

    /// Whether `stamp` is what minivu's own last write of `url` left.
    public static func isOwn(_ url: URL, stamp: FileStamp?) -> Bool {
        guard let stamp else { return false }
        let key = key(url)
        return stamps.withLock { $0[key] == stamp }
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
