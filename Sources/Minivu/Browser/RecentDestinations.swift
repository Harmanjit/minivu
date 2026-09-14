import AppKit
import MinivuCore

/// The last five folders files were copied or moved to, for the Copy To and
/// Move To submenus.
///
/// Kept as security-scoped bookmarks, like the sidebar's favourites
/// (`BookmarkStore`): under the sandbox a remembered path alone could name a
/// folder chosen in an open panel last week but not write into it.
final class RecentDestinations {
    static let shared = RecentDestinations(defaults: .standard)
    static let limit = 5

    private let defaults: UserDefaults
    private let key: String
    private(set) var folders: [URL] = []
    private var bookmarks: [Data] = []

    init(defaults: UserDefaults, key: String = "recentTransferDestinations") {
        self.defaults = defaults
        self.key = key
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                      bookmarkDataIsStale: &stale))
                    ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            else { continue }
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
            bookmarks.append(stale ? (Self.bookmark(for: url) ?? data) : data)
        }
    }

    /// Puts `folder` first, dropping the oldest past the limit.
    func add(_ folder: URL) {
        if let index = folders.firstIndex(where: { BrowserModel.samePath($0, folder) }) {
            folders.remove(at: index)
            let data = bookmarks.remove(at: index)
            folders.insert(folder, at: 0)
            bookmarks.insert(data, at: 0)
        } else {
            guard let data = Self.bookmark(for: folder) else { return }
            _ = folder.startAccessingSecurityScopedResource()
            folders.insert(folder, at: 0)
            bookmarks.insert(data, at: 0)
        }
        while folders.count > Self.limit {
            folders.removeLast().stopAccessingSecurityScopedResource()
            bookmarks.removeLast()
        }
        defaults.set(bookmarks, forKey: key)
    }

    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }
}

/// Fills a Copy To or Move To submenu each time it opens: the recent
/// folders, then "Choose Folder…". Items carry the folder as their
/// `representedObject` (nil asks with an open panel) and have no target, so
/// the browser handles and validates them like any menu command.
final class RecentDestinationsMenu: NSObject, NSMenuDelegate {
    let action: Selector
    let store: RecentDestinations

    init(action: Selector, store: RecentDestinations = .shared) {
        self.action = action
        self.store = store
    }

    /// A submenu that keeps its delegate alive: a menu holds its delegate
    /// weakly, so the menu itself retains it as an associated object.
    static func make(title: String, action: Selector, store: RecentDestinations = .shared) -> NSMenu {
        let menu = NSMenu(title: title)
        let delegate = RecentDestinationsMenu(action: action, store: store)
        objc_setAssociatedObject(menu, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.delegate = delegate
        delegate.fill(menu)
        return menu
    }

    nonisolated(unsafe) private static var delegateKey: UInt8 = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        for folder in store.folders {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: folder.path), action: action,
                                  keyEquivalent: "")
            item.representedObject = folder
            item.toolTip = folder.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !store.folders.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: "Choose Folder…", action: action, keyEquivalent: ""))
    }
}
