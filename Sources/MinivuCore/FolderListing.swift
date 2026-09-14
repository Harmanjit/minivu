import Foundation

/// One level of a folder, split the way the browser shows it.
public struct FolderContents: Sendable {
    public var folder: URL
    public var subfolders: [FolderEntry]
    public var images: [FolderEntry]

    public init(folder: URL, subfolders: [FolderEntry], images: [FolderEntry]) {
        self.folder = folder
        self.subfolders = subfolders
        self.images = images
    }
}

public enum FolderListingError: Error, CustomStringConvertible {
    /// The folder is on a volume minivu doesn't browse (VolumePolicy).
    case notAllowed(URL)
    case unreadable(URL, String)

    public var description: String {
        switch self {
        case .notAllowed(let url): "\(url.lastPathComponent) is not on this Mac's internal storage."
        case .unreadable(let url, let reason): "\(url.lastPathComponent) could not be read: \(reason)"
        }
    }
}

/// Reads folders for the browser and the sidebar tree.
///
/// Everything here touches the disk, so call it off the main thread. The
/// functions are stateless and thread-safe.
public enum FolderListing {
    /// Every attribute the browser needs, fetched in the same system call
    /// that reads the directory. Asking for a key later, one file at a time,
    /// would cost a separate `stat` per file: the difference between a few
    /// milliseconds and a visible pause on a folder of 10,000 photos.
    static let entryKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .nameKey,
    ]
    static let entryKeySet = Set(entryKeys)

    /// The sidebar only needs to know what is a visible, non-package folder.
    static let folderKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .nameKey]
    static let folderKeySet = Set(folderKeys)

    /// One level: image files (`ImageFormats.isImage`) and subfolders.
    ///
    /// Hidden files are skipped unless `includeHidden`. Packages (.app,
    /// .photoslibrary, any bundle) look like folders to the file system but
    /// like single documents to the user, so they are neither folders nor
    /// images here, exactly as Finder treats them.
    ///
    /// Measured on 10,000 files (M4, release): 65 ms to list, 43 ms more to
    /// sort by name.
    public static func contents(of folder: URL, includeHidden: Bool = false) throws -> FolderContents {
        guard VolumePolicy.isAllowed(folder) else { throw FolderListingError.notAllowed(folder) }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: entryKeys,
                                                               options: [])
        } catch {
            throw FolderListingError.unreadable(folder, error.localizedDescription)
        }

        var subfolders: [FolderEntry] = []
        var images: [FolderEntry] = []
        images.reserveCapacity(urls.count)
        for url in urls {
            // The values were prefetched with the listing, so this is a
            // lookup in memory, not another trip to the disk.
            guard let values = try? url.resourceValues(forKeys: entryKeySet) else { continue }
            let kind = ImageFormats.kind(of: url)
            if !includeHidden && values.isHidden == true { continue }
            if values.isPackage == true { continue }
            let isDirectory = values.isDirectory ?? false
            if !isDirectory && kind == nil { continue }

            let entry = FolderEntry(url: url, name: values.name ?? url.lastPathComponent, isDirectory: isDirectory,
                                    kind: isDirectory ? nil : kind, fileSize: Int64(values.fileSize ?? 0),
                                    modified: values.contentModificationDate ?? .distantPast,
                                    created: values.creationDate ?? .distantPast)
            if isDirectory { subfolders.append(entry) } else { images.append(entry) }
        }
        return FolderContents(folder: folder, subfolders: subfolders, images: images)
    }

    /// Subfolders only, for the sidebar tree, in Finder's order. Returns an
    /// empty array if the folder can't be read: the tree shows nothing to
    /// expand rather than an error for every unreadable system folder.
    ///
    /// Reads with `readdir`, as `hasSubfolders` does: the sidebar lists the
    /// photo folder the browser is in again whenever it changes on disk, and
    /// fetching attributes for every photo to find the few folders among
    /// them took 20 ms on 5,000 files, against about 1 ms this way.
    public static func subfolders(of folder: URL, includeHidden: Bool = false) -> [URL] {
        var named: [(url: URL, name: String)] = []
        forEachVisibleSubfolder(of: folder, includeHidden: includeHidden) { url, name in
            named.append((url, name))
            return true
        }
        return named.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.url)
    }

    /// True as soon as one visible subfolder is found, for disclosure
    /// triangles in the sidebar.
    ///
    /// The sidebar asks this for every folder it shows, and most photo
    /// folders hold thousands of files and no subfolders, so the common
    /// answer is "no" after looking at everything. `readdir` makes that
    /// cheap: each entry carries its type (`d_type`), so plain files are
    /// skipped without fetching any attributes, and only real directories
    /// are checked for being hidden or a package. It also stops reading at
    /// the first subfolder. Measured on 10,000 files (M4, release): 43 ms
    /// with a FileManager enumerator, 2.5 ms this way.
    public static func hasSubfolders(_ folder: URL, includeHidden: Bool = false) -> Bool {
        var found = false
        forEachVisibleSubfolder(of: folder, includeHidden: includeHidden) { _, _ in
            found = true
            return false
        }
        return found
    }

    /// Calls `body` with each visible, non-package subfolder and its name,
    /// in directory order, until it returns false. Nothing if unreadable.
    private static func forEachVisibleSubfolder(of folder: URL, includeHidden: Bool,
                                                _ body: (URL, String) -> Bool) {
        guard let directory = opendir(folder.path) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            // DT_UNKNOWN: some file systems don't fill in the type; check those.
            let type = Int32(entry.pointee.d_type)
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." || (!includeHidden && name.hasPrefix(".")) { continue }
            let url = folder.appendingPathComponent(name, isDirectory: true)
            if let values = try? url.resourceValues(forKeys: folderKeySet),
               isVisibleFolder(values, includeHidden: includeHidden),
               !body(url, values.name ?? name) {
                return
            }
        }
    }

    static func isVisibleFolder(_ values: URLResourceValues, includeHidden: Bool) -> Bool {
        values.isDirectory == true && values.isPackage != true && (includeHidden || values.isHidden != true)
    }

    // MARK: - Sorting

    /// Sorts entries for display. The sort is stable: entries that compare
    /// equal keep their incoming order, so re-sorting never shuffles ties.
    ///
    /// - name: the name without its extension in Finder order
    ///   (`localizedStandardCompare`: img2 before img10, case ignored), then
    ///   the extension, so a photo's variants stay together.
    /// - type: extension, then name.
    /// - size, modified, created: that value, then name.
    ///
    /// `ascending == false` reverses the comparison, name tiebreak included.
    public static func sorted(_ entries: [FolderEntry], by order: FileSortOrder) -> [FolderEntry] {
        // Decorate once: the extension would otherwise be recomputed (and
        // lowercased) on each of the ~n log n comparisons.
        let decorated = entries.enumerated().map { index, entry in
            let ext = entry.isDirectory ? "" : entry.url.pathExtension.lowercased()
            let base = ext.isEmpty ? entry.name : String(entry.name.dropLast(ext.count + 1))
            return (index: index, entry: entry, ext: ext, base: base)
        }
        let result = decorated.sorted { a, b in
            var c = compare(a.entry, a.ext, a.base, b.entry, b.ext, b.base, key: order.key)
            if !order.ascending { c = c.reversed }
            if c == .orderedSame { return a.index < b.index }
            return c == .orderedAscending
        }
        return result.map(\.entry)
    }

    private static func compare(_ a: FolderEntry, _ aExt: String, _ aBase: String,
                                _ b: FolderEntry, _ bExt: String, _ bBase: String,
                                key: SortKey) -> ComparisonResult {
        let primary: ComparisonResult
        switch key {
        case .name: primary = .orderedSame
        case .type: primary = aExt.compare(bExt)
        case .size: primary = ordering(a.fileSize, b.fileSize)
        case .modified: primary = ordering(a.modified, b.modified)
        case .created: primary = ordering(a.created, b.created)
        // Need the catalog, which the browser model applies on top.
        case .rating, .custom: primary = .orderedSame
        }
        if primary != .orderedSame { return primary }
        // Name without the extension first, so "IMG_1.heic" sits with
        // "IMG_1.jpg" ahead of "IMG_1_edit.jpg", as in Finder's list and
        // Windows Explorer; then the extension; then the full name.
        let byBase = aBase.localizedStandardCompare(bBase)
        if byBase != .orderedSame { return byBase }
        let byExt = aExt.compare(bExt)
        return byExt != .orderedSame ? byExt : a.name.localizedStandardCompare(b.name)
    }

    private static func ordering<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

extension ComparisonResult {
    fileprivate var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
