import AppKit
import MinivuCore
import MinivuRender

/// The app's long-lived services, created once and shared by every window.
///
/// Kept in one place so the browser grid, the preview pane and the viewer's
/// filmstrip all hit the same thumbnail memory cache, and the preview and
/// viewer share decoded textures through `ImageLoader.shared`.
enum AppServices {
    /// Largest the on-disk thumbnail cache may grow before old entries go.
    nonisolated static let thumbnailCacheLimit = 1_000_000_000

    nonisolated static let thumbnailStore: ThumbnailStore? = {
        let url = thumbnailStoreURL()
        if url != ThumbnailStore.defaultURL {
            removeTemporaryStores(in: url.deletingLastPathComponent())
            atexit { AppServices.removeTemporaryStore(ofProcess: getpid()) }
        }
        return try? ThumbnailStore(url: url)
    }()

    /// The user's thumbnail cache, except where the catalog is a private one
    /// (test runs, snapshot runs, MINIVU_CATALOG=memory): those get a cache
    /// of their own in the temporary folder, so a test or a benchmark that
    /// thumbnails thousands of files leaves the user's cache alone and
    /// starts from an empty one every run.
    nonisolated static func thumbnailStoreURL(process: ProcessInfo = .processInfo) -> URL {
        guard Catalog.usesPrivateCatalog(process) else { return ThumbnailStore.defaultURL }
        return temporaryStoreURL(ofProcess: process.processIdentifier)
    }

    nonisolated static let temporaryStorePrefix = "minivu-thumbnails-"

    nonisolated static func temporaryStoreURL(ofProcess pid: Int32,
                                              in folder: URL = FileManager.default.temporaryDirectory) -> URL {
        folder.appendingPathComponent("\(temporaryStorePrefix)\(pid).sqlite")
    }

    /// A private cache goes when its process exits normally. One whose
    /// process crashed or was stopped is removed by the next process that
    /// makes one: a benchmark run starts dozens of processes, and the
    /// caches of a few thousand thumbnails are tens of megabytes each.
    nonisolated static func removeTemporaryStore(ofProcess pid: Int32,
                                                 in folder: URL = FileManager.default.temporaryDirectory) {
        let path = temporaryStoreURL(ofProcess: pid, in: folder).path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Removes the private caches in `folder` of processes no longer
    /// running (`isRunning`, which tests replace).
    nonisolated static func removeTemporaryStores(in folder: URL,
                                                  isRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let pids = Set(names.compactMap { name -> Int32? in
            guard name.hasPrefix(temporaryStorePrefix) else { return nil }
            let rest = name.dropFirst(temporaryStorePrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { return nil }
            return Int32(rest[..<dot])
        })
        for pid in pids where pid != getpid() && !isRunning(pid) { removeTemporaryStore(ofProcess: pid, in: folder) }
    }

    static let thumbnails = ThumbnailService(store: thumbnailStore)

    static var images: ImageLoader { .shared }

    private static var observers: [NSObjectProtocol] = []

    /// Call once at launch: trims the disk cache in the background, listens
    /// for "Clear Thumbnail Cache" from Settings, and keeps thumbnails drawn
    /// in the screen's colour space.
    static func start() {
        let store = thumbnailStore
        let limit = thumbnailCacheLimit
        // SQLite and file deletions block: on GCD (BlockingWork).
        Task { await BlockingWork.run(qos: .background) { store?.prune(maxBytes: limit) } }
        observers.append(NotificationCenter.default.addObserver(
            forName: .minivuClearThumbnailCache, object: nil, queue: .main) { _ in
            Task { await BlockingWork.run(qos: .utility) { store?.removeAll() } }
        })
        updateThumbnailColorSpace()
        // Marks carried by the files themselves show for files the catalog
        // has no row for, and are taken into a row before a change; marks
        // are written into the files while the setting is on (G2).
        Catalog.shared.fileMarksReader = { FileMarksCache.shared.marks(for: $0) }
        Catalog.shared.mirror = CatalogFileMirror(writer: .shared)
        // A display's settings changing, a window moving to another display,
        // or the browser appearing may put the browser on a display with
        // another colour space. The first is also posted for every step of
        // an EDR headroom change; setting the same colour space again costs
        // nothing.
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { updateThumbnailColorSpace() }
            })
        }
    }

    /// Thumbnails are drawn in the colour space of the browser's display, so
    /// Core Animation shows them without converting each one on the main
    /// thread. The browser's grid draws nearly all of them; the viewer's
    /// filmstrip on another display is still correct, just converted as
    /// before. Following the key window instead would empty the thumbnail
    /// memory cache each time the user switched between the displays.
    static func updateThumbnailColorSpace() {
        thumbnails.displayColorSpace = thumbnailColorSpace(browser: Displays.browserWindow(),
                                                           provider: Displays.provider)
    }

    /// The browser's display's colour space; the main display's without a
    /// browser, and sRGB when a display doesn't say.
    static func thumbnailColorSpace(browser: NSWindow?, provider: ScreenProviding) -> CGColorSpace {
        let display = browser.flatMap(provider.display(of:)) ?? provider.mainDisplay
        return display?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
