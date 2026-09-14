import Foundation
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

    /// Call once at launch: trims the disk cache in the background and
    /// listens for "Clear Thumbnail Cache" from Settings.
    static func start() {
        let store = thumbnailStore
        let limit = thumbnailCacheLimit
        Task.detached(priority: .background) {
            store?.prune(maxBytes: limit)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .minivuClearThumbnailCache, object: nil, queue: .main) { _ in
            Task.detached(priority: .utility) { store?.removeAll() }
        })
    }
}
