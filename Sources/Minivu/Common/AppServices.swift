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

    nonisolated static let thumbnailStore: ThumbnailStore? = try? ThumbnailStore(url: ThumbnailStore.defaultURL)

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
