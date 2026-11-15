import Foundation
import CryptoKit

/// The SHA-256 of a file's bytes, for finding exact duplicates (G5).
///
/// Streamed: the file is read a chunk at a time into CryptoKit's hasher, so
/// a 2 GB TIFF costs one chunk of memory, never the whole file. Reads go
/// through `FileHandle` with the system cache left on, since the finder
/// reads each candidate once and the user may well open one of them next.
public enum ContentHash {
    /// Bytes read at a time: large enough that the system call per chunk is
    /// lost in the hashing (SHA-256 runs at about 2 GB/s on Apple silicon),
    /// small enough not to matter beside a thumbnail.
    public static let chunkSize = 1 << 20

    /// The digest of the file at `url`.
    ///
    /// - Parameters:
    ///   - chunkSize: bytes read at a time; tests make it small.
    ///   - isCancelled: asked before each chunk; true throws `CancellationError`.
    ///   - didRead: called with the length of each chunk as it is hashed.
    /// - Throws: the file system's error when the file can't be opened or read.
    public static func sha256(of url: URL, chunkSize: Int = chunkSize, isCancelled: () -> Bool = { false },
                              didRead: (Int) -> Void = { _ in }) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            // Each chunk's Data is released before the next is read.
            let done = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: max(chunkSize, 1)), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                didRead(chunk.count)
                return false
            }
            if done { break }
        }
        return Data(hasher.finalize())
    }
}
