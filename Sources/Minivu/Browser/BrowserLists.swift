import Foundation
import MinivuCore

/// A list the browser shows instead of a folder (G3): Find's results, a
/// smart folder or a collection. It is a list of files from anywhere in the
/// folders the user has granted, and the browser's usual commands work on
/// it (open, rate, label, move, copy, trash, the batch tools, Edit
/// Metadata); those that need one folder (New Folder, Paste, Custom Order,
/// dropping files in) step aside.
nonisolated struct VirtualList: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Results of a search from the Find sheet, not saved.
        case search(SearchQuery)
        /// Read from the catalog when opened, so a smart folder edited in
        /// another window runs as it is now.
        case smartFolder(id: Int64)
        case collection(id: Int64)
    }

    var kind: Kind
    /// The window's title while it is shown.
    var title: String

    /// What reading a list needs from the window, gathered on the main actor.
    struct Context: Sendable {
        var catalog: Catalog
        var includeHidden: Bool
        /// Finder's names for its colour tags (`ColorLabelCommand.standardNames`),
        /// which only the main actor may ask the workspace for.
        var standardNames: [Int: String]
    }

    /// What reading a list found.
    struct Outcome: Sendable {
        var images: [FolderEntry]
        /// A search stopped at a walk limit: more may match.
        var isTruncated: Bool
    }

    enum LoadError: LocalizedError {
        case smartFolderGone
        case collectionGone

        var errorDescription: String? {
            switch self {
            case .smartFolderGone: "This smart folder has been deleted."
            case .collectionGone: "This collection has been deleted."
            }
        }
    }

    /// Reads a list: runs the search, or lists the collection's members
    /// that exist. Blocking disk work, called off the main thread by the
    /// model; `batch` gets matches as they are found, `cancel` stops it.
    static func load(_ list: VirtualList, context: Context, cancel: CancellationFlag,
                     batch: ([FolderEntry]) -> Void) throws -> Outcome {
        let catalog = context.catalog
        let query: SearchQuery
        switch list.kind {
        case .search(let q):
            query = q
        case .smartFolder(let id):
            guard let folder = catalog.smartFolder(id) else { throw LoadError.smartFolderGone }
            query = folder.query
        case .collection(let id):
            guard catalog.collections().contains(where: { $0.id == id }) else { throw LoadError.collectionGone }
            // Only what the sandbox lets minivu read shows; a member in a
            // folder whose access has gone is left out like a missing one.
            let images = catalog.collectionMembers(id).compactMap { url -> FolderEntry? in
                guard let entry = FolderEntry(url: url), !entry.isDirectory, entry.kind != nil else { return nil }
                return entry
            }
            batch(images)
            return Outcome(images: images, isTruncated: false)
        }
        let names = context.standardNames
        let outcome = try ImageSearch.run(query, catalog: catalog, includeHidden: context.includeHidden,
                                          fileMarks: { FileMarksCache.shared.marks(for: $0) },
                                          label: { ColorLabelCommand.label(of: FinderTag.read(from: $0), standardNames: names) },
                                          isCancelled: { cancel.isCancelled }, found: batch)
        return Outcome(images: outcome.matches, isTruncated: outcome.isTruncated)
    }
}
