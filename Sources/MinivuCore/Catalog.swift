import Foundation

/// Star ratings, the "tagged" flag and custom sort order (DESIGN.md 4.6).
///
/// PLACEHOLDER STORAGE: this in-memory version defines the API the browser,
/// viewer and compare window use. The catalog work package replaces the
/// storage with SQLite (Application Support/minivu/catalog.sqlite, file
/// identifier healing) and keeps every signature below.
///
/// Thread-safe. Reads of a folder's worth of files are one query, fast
/// enough for the main thread; large writes should run off it.
public final class Catalog: @unchecked Sendable {
    /// Rating 0 (none) to 5, and FastStone's "tagged" flag for culling.
    public struct Marks: Sendable, Equatable, Hashable {
        public var rating: Int
        public var isTagged: Bool
        public init(rating: Int = 0, isTagged: Bool = false) {
            self.rating = rating
            self.isTagged = isTagged
        }
        public static let none = Marks()
    }

    /// Posted on the main queue after marks or custom order change. `object`
    /// is the `[URL]` of files (or the folder, for custom order) affected.
    public static let didChange = Notification.Name("MinivuCatalogDidChange")

    public static let shared: Catalog = (try? Catalog(url: Catalog.defaultURL)) ?? Catalog.inMemory()

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("minivu", isDirectory: true)
            .appendingPathComponent("catalog.sqlite", isDirectory: false)
    }

    private let lock = NSLock()
    private var marks: [String: Marks] = [:]
    private var orders: [String: [String]] = [:]

    public init(url: URL?) throws {}

    public static func inMemory() -> Catalog { try! Catalog(url: nil) }

    public func marks(for url: URL) -> Marks {
        lock.withLock { marks[Self.key(url)] ?? .none }
    }

    public func marks(for urls: [URL]) -> [URL: Marks] {
        lock.withLock {
            var result: [URL: Marks] = [:]
            for url in urls { if let m = marks[Self.key(url)] { result[url] = m } }
            return result
        }
    }

    /// Clamped to 0...5.
    public func setRating(_ rating: Int, for urls: [URL]) {
        let r = min(max(rating, 0), 5)
        lock.withLock { for url in urls { marks[Self.key(url), default: .none].rating = r } }
        post(urls)
    }

    public func setTagged(_ tagged: Bool, for urls: [URL]) {
        lock.withLock { for url in urls { marks[Self.key(url), default: .none].isTagged = tagged } }
        post(urls)
    }

    /// File names in the user's order for `folder` (possibly naming files
    /// that no longer exist; callers ignore those).
    public func customOrder(in folder: URL) -> [String] {
        lock.withLock { orders[Self.key(folder)] ?? [] }
    }

    public func setCustomOrder(_ names: [String], in folder: URL) {
        lock.withLock { orders[Self.key(folder)] = names }
        post([folder])
    }

    /// Keeps marks with files that minivu itself moves, renames, copies or
    /// deletes. (Files moved in Finder are found again by file identifier in
    /// the SQLite version.)
    public func fileMoved(from: URL, to: URL) {
        lock.withLock {
            if let m = marks.removeValue(forKey: Self.key(from)) { marks[Self.key(to)] = m }
        }
        post([from, to])
    }

    public func fileCopied(from: URL, to: URL) {
        lock.withLock { if let m = marks[Self.key(from)] { marks[Self.key(to)] = m } }
        post([to])
    }

    public func fileRemoved(_ url: URL) {
        lock.withLock { _ = marks.removeValue(forKey: Self.key(url)) }
        post([url])
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    private func post(_ urls: [URL]) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: urls) }
    }
}

/// Finder tags (the coloured labels) on files, read and written through the
/// file system, so they show in Finder and Spotlight too.
public enum FinderTags {
    public static func tags(for url: URL) -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// `URLResourceValues.tagNames` is read-only before macOS 26; NSURL's
    /// setter works on every supported system.
    public static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
