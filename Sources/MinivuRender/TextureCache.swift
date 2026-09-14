import Foundation
import Dispatch
import MinivuCore

/// Identifies one decoded texture of one image.
///
/// The same photo can be cached at several sizes at once (a screen-sized
/// preview and the full-resolution refinement), so the size is part of the
/// key. `modified` makes an edited file miss the cache without anyone
/// having to remember to invalidate it.
public struct TextureKey: Hashable, Sendable {
    public var url: URL
    public var modified: Date
    /// Page of a PDF or multi-page TIFF; 0 for everything else.
    public var page: Int
    /// Long edge of the texture in pixels (not of the image).
    public var longEdge: Int
    public var fullResolution: Bool

    public init(url: URL, modified: Date, page: Int, longEdge: Int, fullResolution: Bool) {
        self.url = url
        self.modified = modified
        self.page = page
        self.longEdge = longEdge
        self.fullResolution = fullResolution
    }

    /// True when both keys name the same image, whatever the size.
    func sameImage(url: URL, modified: Date, page: Int) -> Bool {
        self.url == url && self.modified == modified && self.page == page
    }
}

/// Decoded textures kept in memory under a byte budget (DESIGN.md 4.5).
///
/// Flipping back to the previous photo should cost nothing, so textures
/// stay on the GPU after they leave the screen until the budget is spent;
/// then the least recently used go first.
///
/// Recency is a counter bumped on every insert and lookup. Eviction scans for
/// the smallest one, which is O(n), but n is a few dozen textures at most:
/// simpler than a linked list and just as fast in practice.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`, so the
/// cache can be read from the main actor while loads insert from background
/// tasks and memory pressure trims from a dispatch queue.
public final class TextureCache: @unchecked Sendable {
    private struct Entry {
        var texture: ImageTexture
        var lastUsed: UInt64
    }

    /// 1/8 of RAM, capped at 1.5 GB and never below 256 MB.
    ///
    /// Textures live in unified memory shared with every other app, so the
    /// cache must stay a modest slice of it; the floor keeps a few full
    /// screen textures cached even on a small machine.
    public static func defaultBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let mib: UInt64 = 1 << 20
        let budget = min(1536 * mib, physicalMemory / 8)
        return Int(max(256 * mib, budget))
    }

    public let budgetBytes: Int

    private let lock = NSLock()
    private var entries: [TextureKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    public init(budgetBytes: Int) {
        self.budgetBytes = budgetBytes
        // The system tells us when memory runs short; no need to watch it.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleMemoryPressure(source.data)
        }
        source.resume()
        pressureSource = source
    }

    deinit {
        pressureSource?.cancel()
    }

    public var usedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Insert and look up

    /// Stores `texture`, evicting least recently used textures beyond the
    /// budget. The new texture itself is never evicted, even if it alone is
    /// over budget: it is about to be shown.
    public func insert(_ texture: ImageTexture, for key: TextureKey) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries[key] { bytes -= old.texture.byteCost }
        entries[key] = Entry(texture: texture, lastUsed: tick())
        bytes += texture.byteCost
        evict(downTo: budgetBytes, keeping: key)
    }

    /// The texture for exactly `key`, marking it recently used.
    public func texture(for key: TextureKey) -> ImageTexture? {
        lock.lock(); defer { lock.unlock() }
        guard entries[key] != nil else { return nil }
        entries[key]!.lastUsed = tick()
        return entries[key]!.texture
    }

    /// Full resolution if cached, else the smallest screen texture whose long
    /// edge >= 0.97 * min(minimumLongEdge, image long edge).
    ///
    /// The 3% tolerance is the same one `ImageDecoder.scaledDecodeSize` uses
    /// when it snaps a request to a cheap codec scale, so a texture decoded
    /// for a request is found again by the same request. Capping at the
    /// image's own long edge lets a small image's only texture satisfy a
    /// large window.
    public func bestTexture(url: URL, modified: Date, page: Int, minimumLongEdge: Int) -> ImageTexture? {
        bestTexture(url: url, modified: modified, page: page,
                    fitting: CGSize(width: minimumLongEdge, height: minimumLongEdge))
    }

    /// The same for the image fitted into `viewSize` (drawable pixels): the
    /// long edge needed is the one the image has there, worked out from each
    /// texture's own image size, so a texture decoded for a larger view (or
    /// for the view's long edge) still serves a smaller fit.
    public func bestTexture(url: URL, modified: Date, page: Int, fitting viewSize: CGSize) -> ImageTexture? {
        lock.lock(); defer { lock.unlock() }
        var best: (key: TextureKey, entry: Entry)?
        for (key, entry) in entries where key.sameImage(url: url, modified: modified, page: page) {
            if key.fullResolution { best = (key, entry); break }
            let imageSize = entry.texture.imageSize
            let imageLongEdge = Int(max(imageSize.width, imageSize.height))
            let fitted = ImageDecoder.fittedLongEdge(imageSize: imageSize, in: viewSize)
            let needed = Double(min(fitted, imageLongEdge)) * 0.97
            guard Double(key.longEdge) >= needed else { continue }
            if best == nil || key.longEdge < best!.key.longEdge { best = (key, entry) }
        }
        guard let best else { return nil }
        entries[best.key]!.lastUsed = tick()
        return best.entry.texture
    }

    /// Largest texture of any size for the image (instant low-res placeholder
    /// while navigating).
    public func anyTexture(url: URL, modified: Date, page: Int) -> ImageTexture? {
        lock.lock(); defer { lock.unlock() }
        let best = entries.filter { $0.key.sameImage(url: url, modified: modified, page: page) }
            .max { $0.key.longEdge < $1.key.longEdge }
        guard let best else { return nil }
        entries[best.key]!.lastUsed = tick()
        return best.value.texture
    }

    /// The oriented pixel size of an image if any texture of it is cached.
    /// Does not count as a use, so asking doesn't keep the texture alive.
    func knownImageSize(url: URL, modified: Date, page: Int) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key.sameImage(url: url, modified: modified, page: page) }?.value.texture.imageSize
    }

    // MARK: - Removal

    /// Drops every texture of a file, at any size and modification date.
    public func removeAll(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        for (key, entry) in entries where key.url == url {
            bytes -= entry.texture.byteCost
            entries[key] = nil
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        bytes = 0
    }

    /// Warning: trim to half the budget. Critical: keep only the texture used
    /// last, which is almost certainly the one on screen.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        lock.lock(); defer { lock.unlock() }
        if event.contains(.critical) {
            guard let newest = entries.max(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
            evict(downTo: 0, keeping: newest.key)
        } else if event.contains(.warning) {
            evict(downTo: budgetBytes / 2, keeping: nil)
        }
    }

    // MARK: - Private (call with the lock held)

    private func tick() -> UInt64 {
        clock += 1
        return clock
    }

    private func evict(downTo limit: Int, keeping kept: TextureKey?) {
        while bytes > limit {
            guard let oldest = entries.filter({ $0.key != kept }).min(by: { $0.value.lastUsed < $1.value.lastUsed })
            else { return }
            bytes -= oldest.value.texture.byteCost
            entries[oldest.key] = nil
        }
    }
}
