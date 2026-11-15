import Foundation

/// The images in a folder and every folder below it, for the browser's flat
/// view and for Find (G3).
///
/// Nothing is indexed ahead of time (DESIGN.md 1: no import step, idle means
/// idle): a tree is read when the user asks for it, off the main thread,
/// one folder at a time through `FolderListing.contents`, so each image
/// arrives with the attributes the grid needs from the same system call.
/// Breadth first, so the folders nearest the top are complete before a deep
/// one is begun and a limit cuts off the deepest material first.
///
/// Packages and hidden items are skipped as in the browser, and a symbolic
/// link to a folder is not followed (the listing reports it as a file), so
/// no tree can loop. Each folder goes through `VolumePolicy` as it is
/// listed, so an external disk mounted inside the tree is left out.
public enum TreeEnumerator {
    /// Where a walk stops. The defaults hold a big photo library's year of
    /// folders, and stop a search started at the top of a drive from
    /// reading the whole of it.
    public struct Limits: Sendable, Equatable {
        /// Levels below the root: 0 is the root alone.
        public var maximumDepth: Int
        public var maximumImages: Int
        public var maximumFolders: Int

        public init(maximumDepth: Int = 12, maximumImages: Int = 20_000, maximumFolders: Int = 5_000) {
            self.maximumDepth = maximumDepth
            self.maximumImages = maximumImages
            self.maximumFolders = maximumFolders
        }

        public static let standard = Limits()
    }

    public struct Result: Sendable {
        public var images: [FolderEntry]
        /// Folders listed, the root included.
        public var foldersListed: Int
        /// A limit stopped the walk: there may be more images than these.
        public var isTruncated: Bool
        public var isCancelled: Bool
    }

    /// Every image under `root`, within `limits`.
    ///
    /// - Parameters:
    ///   - isCancelled: asked before each folder; true stops the walk and
    ///     returns what was found, flagged cancelled.
    ///   - batch: called on the walking thread after each folder that held
    ///     images, with that folder's images, so a caller can show results
    ///     as they come.
    /// - Throws: `FolderListingError` when the root itself can't be read.
    ///   A subfolder that can't be read is skipped, as Finder's search does.
    public static func images(under root: URL, includeHidden: Bool = false, limits: Limits = .standard,
                              isCancelled: () -> Bool = { false },
                              batch: ([FolderEntry]) -> Void = { _ in }) throws -> Result {
        var result = Result(images: [], foldersListed: 0, isTruncated: false, isCancelled: false)
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var next = 0
        while next < queue.count {
            if isCancelled() {
                result.isCancelled = true
                break
            }
            if result.foldersListed >= limits.maximumFolders {
                result.isTruncated = true
                break
            }
            let (folder, depth) = queue[next]
            next += 1
            let contents: FolderContents
            do {
                contents = try FolderListing.contents(of: folder, includeHidden: includeHidden)
            } catch {
                if depth == 0 { throw error }
                continue
            }
            result.foldersListed += 1
            var images = contents.images
            let room = limits.maximumImages - result.images.count
            if images.count > room {
                images = Array(FolderListing.sorted(images, by: FileSortOrder()).prefix(max(room, 0)))
                result.isTruncated = true
            }
            if !images.isEmpty {
                result.images += images
                batch(images)
            }
            if result.images.count >= limits.maximumImages {
                // Exactly at the limit with nothing left anywhere is complete.
                if !result.isTruncated { result.isTruncated = next < queue.count || !contents.subfolders.isEmpty }
                break
            }
            if depth < limits.maximumDepth {
                let subfolders = FolderListing.sorted(contents.subfolders, by: FileSortOrder())
                queue += subfolders.map { ($0.url, depth + 1) }
            } else if !contents.subfolders.isEmpty {
                result.isTruncated = true
            }
        }
        return result
    }
}
