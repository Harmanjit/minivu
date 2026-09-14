import Foundation

/// One item in a folder: an image file or a subfolder.
public struct FolderEntry: Sendable, Hashable, Identifiable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    /// nil for folders.
    public var kind: ImageKind?
    public var fileSize: Int64
    public var modified: Date
    public var created: Date

    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, kind: ImageKind?, fileSize: Int64,
                modified: Date, created: Date) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind
        self.fileSize = fileSize
        self.modified = modified
        self.created = created
    }

    /// Reads an entry for a single file from the file system.
    public init?(url: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                         .creationDateKey, .nameKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = v.isDirectory ?? false
        self.init(url: url, name: v.name ?? url.lastPathComponent, isDirectory: isDirectory,
                  kind: isDirectory ? nil : ImageFormats.kind(of: url),
                  fileSize: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast,
                  created: v.creationDate ?? .distantPast)
    }
}

public enum SortKey: String, CaseIterable, Sendable, Codable {
    case name, modified, created, size, type
    /// Star rating from the catalog, highest first when descending. Applied
    /// by the browser model (FolderListing has no catalog); FolderListing
    /// falls back to name order for it.
    case rating
    /// The user's own arrangement (drag to reorder), stored per folder in the
    /// catalog; files not yet placed follow in name order.
    case custom
}

public struct FileSortOrder: Sendable, Equatable, Codable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}
