import Foundation

/// Find across folders (G3): the images under a folder that match a
/// `SearchQuery`, read when asked for and never indexed ahead.
///
/// **Why not Spotlight.** `NSMetadataQuery` scoped to the folder would skip
/// the walk, but it answers only for what Spotlight has indexed: nothing in
/// a folder excluded in Privacy settings or on a volume with indexing off,
/// nothing yet in a folder just copied in, RAW keywords only from embedded
/// XMP (never minivu's sidecars), and no ratings or tags, which live in the
/// catalog. A search that silently misses files is worse than a slower one,
/// and the walk is quick: listing is the browser's own call (65 ms for
/// 10,000 files, FolderListing), and the header reads it adds for metadata
/// conditions are cached in the catalog, so a second search of the same
/// tree reads nothing. Measured figures are in docs/feature-notes/org.md.
///
/// The cheap tests run first, on every file as it is listed: name, type,
/// marks (one catalog query per folder), colour label (one extended
/// attribute each); only files still in the running have their headers read.
public enum ImageSearch {
    public struct Outcome: Sendable {
        public var matches: [FolderEntry]
        /// Images looked at.
        public var scanned: Int
        public var foldersListed: Int
        /// A walk limit stopped the search: more may match beyond it.
        public var isTruncated: Bool
        public var isCancelled: Bool
    }

    /// Runs `query`. Blocking disk work: call it off the main thread.
    ///
    /// - Parameters:
    ///   - fileMarks: the marks a file without a catalog row carries itself
    ///     (`FileMarksCache.marks(for:)`, G2); nil treats files as carrying none.
    ///   - label: the file's colour label (its Finder tags), asked only
    ///     while the query has a label condition.
    ///   - found: called on the searching thread with each folder's
    ///     matches as they are found.
    public static func run(_ query: SearchQuery, catalog: Catalog, limits: TreeEnumerator.Limits = .standard,
                           includeHidden: Bool = false, fileMarks: ((URL) -> Catalog.Marks?)? = nil,
                           label: (URL) -> ColorLabel = { _ in .none }, isCancelled: () -> Bool = { false },
                           found: ([FolderEntry]) -> Void = { _ in }) throws -> Outcome {
        var matches: [FolderEntry] = []
        var scanned = 0
        let effective = query.includeSubfolders ? limits : TreeEnumerator.Limits(
            maximumDepth: 0, maximumImages: limits.maximumImages, maximumFolders: 1)
        let walk = try TreeEnumerator.images(under: query.scopeURL, includeHidden: includeHidden, limits: effective,
                                             isCancelled: isCancelled) { images in
            scanned += images.count
            let hits = filter(images, query: query, catalog: catalog, fileMarks: fileMarks, label: label,
                              isCancelled: isCancelled)
            if !hits.isEmpty {
                matches += hits
                found(hits)
            }
        }
        return Outcome(matches: matches, scanned: scanned, foldersListed: walk.foldersListed,
                       isTruncated: walk.isTruncated, isCancelled: walk.isCancelled || isCancelled())
    }

    /// The images that match, cheapest tests first. Exposed for the
    /// browser's filter and for tests.
    public static func filter(_ images: [FolderEntry], query: SearchQuery, catalog: Catalog,
                              fileMarks: ((URL) -> Catalog.Marks?)? = nil, label: (URL) -> ColorLabel = { _ in .none },
                              isCancelled: () -> Bool = { false }) -> [FolderEntry] {
        let filtering = Perf.begin("search.filter")
        defer { filtering.end() }
        let name = MetadataCriteria.folded(query.name)
        let criteria = query.criteria
        var candidates = images.filter { entry in
            !entry.isDirectory && (name.isEmpty || MetadataCriteria.folded(entry.name).contains(name))
                && criteria.passesType(entry.url)
        }
        if query.minimumRating > 0 || query.taggedOnly {
            let rows = catalog.marks(for: candidates.map(\.url))
            candidates = candidates.filter { entry in
                let marks = rows[entry.url] ?? fileMarks?(entry.url) ?? .none
                return marks.rating >= query.minimumRating && (!query.taggedOnly || marks.isTagged)
            }
        }
        guard criteria.isActive, !candidates.isEmpty else { return candidates }
        var labels: [URL: ColorLabel] = [:]
        if criteria.colorLabel != nil {
            for entry in candidates { labels[entry.url] = label(entry.url) }
            candidates = candidates.filter { labels[$0.url] == criteria.colorLabel }
        }
        guard criteria.needsMetadata, !candidates.isEmpty else { return candidates }
        let metadata = catalog.loadFilterMetadata(for: candidates, isCancelled: isCancelled)
        return candidates.filter { criteria.passes($0.url, metadata: metadata[$0.url], label: labels[$0.url] ?? .none) }
    }
}
