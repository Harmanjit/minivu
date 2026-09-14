import Foundation
import AgateCore

/// Folders the user has granted access to, remembered across launches.
///
/// Under the App Sandbox a saved path is useless: the app may name the
/// folder but not open it. A security-scoped bookmark carries the
/// permission the user gave in the open panel forward; resolving it and
/// calling `startAccessingSecurityScopedResource` grants access again.
/// Adapted from Latent's BookmarkStore.
final class BookmarkStore {
    static let shared = BookmarkStore()
    private let key = "favoriteFolderBookmarks"
    private(set) var folders: [URL] = []

    private init() {
        let datas = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var refreshed: [Data] = []
        for data in datas {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
            refreshed.append(stale ? (Self.bookmark(for: url) ?? data) : data)
        }
        UserDefaults.standard.set(refreshed, forKey: key)
    }

    /// Adds a folder the user just picked. Refuses external volumes.
    @discardableResult
    func add(_ url: URL) -> Bool {
        guard VolumePolicy.isAllowed(url) else { return false }
        guard !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return true }
        guard let data = Self.bookmark(for: url) else { return false }
        folders.append(url)
        var datas = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        datas.append(data)
        UserDefaults.standard.set(datas, forKey: key)
        return true
    }

    func remove(_ url: URL) {
        guard let index = folders.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        folders[index].stopAccessingSecurityScopedResource()
        folders.remove(at: index)
        var datas = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        if datas.indices.contains(index) { datas.remove(at: index) }
        UserDefaults.standard.set(datas, forKey: key)
    }

    /// The user's Pictures folder: always reachable (entitlement), no bookmark needed.
    /// Inside the sandbox the home directory is the container, so the real
    /// path is built from the account's home.
    static var picturesFolder: URL {
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        return home.appendingPathComponent("Pictures", isDirectory: true)
    }

    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }
}
