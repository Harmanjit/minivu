import Foundation
import CoreGraphics

/// A handle to one thumbnail request. Cancel it when the cell showing the
/// thumbnail scrolls away or is reused.
public final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    /// Once this returns, the completion will not be called. (Guaranteed
    /// when called on the main actor, where completions run.)
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Thumbnails for the browser grid: memory cache, then disk cache, then
/// decode, with a bounded number of decodes at once.
///
/// **Order.** Requests run last-in, first-out. While the user scrolls, the
/// grid asks for every row that flies past; the row they stopped on was
/// asked for last and should be decoded first, not after everything they
/// skipped. Requests cancelled before they start are dropped without
/// decoding (DESIGN.md 6, rule 5).
///
/// **Workers.** Decoding is CPU-bound, so running more decodes than cores
/// only adds contention. Two cores are left for the main thread and the
/// window server, so scrolling stays smooth while thumbnails are made.
///
/// **Sizes.** Thumbnails are made at fixed tiers (256 and 512 px) instead of
/// the exact cell size, so dragging the thumbnail size slider reuses what
/// is cached rather than re-decoding the folder at every step.
///
/// **Display-ready pixels.** Core Animation converts a layer's image to the
/// display's format and colour space on the main thread, as the layer
/// commits, and an image read from the store also has its pixels decoded
/// then. Measured on M4 (`ThumbnailCommitBenchmark`), 48 new thumbnails
/// took 8 ms of the main thread to commit as decoded and 33 ms as read from
/// the store. So every thumbnail is redrawn on the worker (about 0.05 ms at
/// 512 px) before it is cached in memory, into exactly what the display
/// wants (`displayColorSpace`, 8-bit BGRA, premultiplied), and the same 48
/// commit in 0.3 ms. The disk cache keeps the compact JPEG or PNG made
/// from the decoded thumbnail.
public final class ThumbnailService: @unchecked Sendable {
    public static let tiers = [256, 512]

    /// The smallest tier at least `forPixelSize`, else the largest.
    public static func tier(forPixelSize size: Int) -> Int {
        tiers.first { $0 >= size } ?? tiers[tiers.count - 1]
    }

    private let store: ThumbnailStore?
    private let memory = NSCache<NSString, CGImage>()
    private let workerLimit: Int
    private let workQueue = DispatchQueue(label: "minivu.thumbnails", qos: .userInitiated, attributes: .concurrent)

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    /// Pending work, newest last. A job can appear more than once (it is
    /// pushed again when requested again); `sequence` tells which entry is
    /// current, and stale entries are skipped when popped.
    private var stack: [(job: Job, sequence: UInt64)] = []
    /// Every job not yet finished, by file and tier, so a second request
    /// for the same thumbnail joins the first instead of decoding twice.
    private var jobs: [JobKey: Job] = [:]
    private var runningWorkers = 0
    /// Tests set this to queue several requests before any work starts.
    private var suspended = false
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Bumped when `colorSpace` changes, and part of the memory cache key,
    /// so a thumbnail drawn for the old space is never handed out.
    private var colorGeneration = 0
    private var nextSequence: UInt64 = 0
    /// Bumped by `invalidate`, and part of the memory cache key, so old
    /// entries for a path stop matching without having to find them.
    private var generations: [String: Int] = [:]
    /// Paths whose disk rows `invalidate` is still deleting. Their disk
    /// copies must not be read in the meantime.
    private var pendingDiskDeletes: Set<String> = []
    /// Cache keys of thumbnails that failed to decode (a damaged file, a
    /// camera raw format macOS doesn't know). Without this, every time the
    /// cell scrolls back into view the doomed decode would run again. The
    /// key holds the file's date and size, so a file that changes is retried;
    /// `invalidate` also clears it.
    private var failures: Set<NSString> = []

    /// Held around disk writes and `invalidate`'s disk delete, so a decode
    /// that started before an invalidate can't write its now-stale result
    /// after the delete. SQLite serialises these writes anyway, so this
    /// costs no extra waiting; encoding happens before taking it.
    private let diskLock = NSLock()

    /// - Parameters:
    ///   - store: the disk cache, or nil to keep thumbnails in memory only.
    ///   - memoryCacheBytes: decoded pixels kept in memory. 200 MB holds
    ///     about 800 thumbnails at 512 px or 3,000 at 256 px.
    public convenience init(store: ThumbnailStore?, memoryCacheBytes: Int = 200_000_000) {
        self.init(store: store, memoryCacheBytes: memoryCacheBytes,
                  workerLimit: max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// `workerLimit` is adjustable for tests, which use one worker to check
    /// the order work runs in.
    init(store: ThumbnailStore?, memoryCacheBytes: Int, workerLimit: Int) {
        self.store = store
        self.workerLimit = max(1, workerLimit)
        memory.totalCostLimit = memoryCacheBytes
    }

    // MARK: - Public API

    /// The colour space thumbnails are drawn in: the screen's, which the app
    /// sets at launch and whenever the screens change. Setting a different
    /// one empties the memory cache (the disk cache is independent of it);
    /// setting the same one again does nothing, which matters because the
    /// screens "change" every time EDR headroom moves.
    public var displayColorSpace: CGColorSpace {
        get { lock.withLock { colorSpace } }
        set {
            lock.withLock {
                guard newValue != colorSpace else { return }
                colorSpace = newValue
                colorGeneration += 1
                memory.removeAllObjects()
            }
        }
    }

    /// A thumbnail already in memory, for drawing a cell synchronously
    /// without a placeholder flash. A larger tier also satisfies the
    /// request (the cell scales it down).
    public func cachedImage(for entry: FolderEntry, pixelSize: Int) -> CGImage? {
        let wanted = Self.tier(forPixelSize: pixelSize)
        let (generation, colorGeneration) = lock.withLock { (generations[entry.url.path] ?? 0, self.colorGeneration) }
        for tier in Self.tiers where tier >= wanted {
            let key = memoryKey(cacheKey(entry, tier: tier, generation: generation), colorGeneration: colorGeneration)
            if let image = memory.object(forKey: key) {
                return image
            }
        }
        return nil
    }

    /// Asks for a thumbnail at least `pixelSize` on its long edge.
    ///
    /// `completion` runs on the main actor, with nil if the file can't be
    /// thumbnailed (or is a folder), and never after the request is
    /// cancelled.
    @discardableResult
    public func request(_ entry: FolderEntry, pixelSize: Int,
                        completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> ThumbnailRequest {
        let request = ThumbnailRequest()
        let waiter = Waiter(request: request, completion: completion)
        if entry.isDirectory {
            Self.deliver(nil, to: [waiter])
            return request
        }
        if let image = cachedImage(for: entry, pixelSize: pixelSize) {
            Self.deliver(image, to: [waiter])
            return request
        }

        let tier = Self.tier(forPixelSize: pixelSize)
        let key = JobKey(path: entry.url.path, tier: tier)
        lock.lock()
        if failures.contains(cacheKey(entry, tier: tier, generation: generations[key.path] ?? 0)) {
            lock.unlock()
            Self.deliver(nil, to: [waiter])
            return request
        }
        let job: Job
        let sameFile = { (other: FolderEntry) in other.modified == entry.modified && other.fileSize == entry.fileSize }
        if let existing = jobs[key], !existing.started || sameFile(existing.entry) {
            // Join the job already queued or running. If it's still queued,
            // the push below moves it to the top of the stack.
            job = existing
            // Changed on disk since that job was queued: the newest wins.
            if !sameFile(job.entry) { job.entry = entry }
        } else {
            // New, or running for an older version of the file: that job
            // finishes for its own waiters, this one replaces it in `jobs`.
            job = Job(key: key, entry: entry)
            jobs[key] = job
        }
        job.waiters.append(waiter)
        var startWorker = false
        if !job.started {
            nextSequence += 1
            job.sequence = nextSequence
            stack.append((job, nextSequence))
            startWorker = !suspended && runningWorkers < workerLimit
            if startWorker { runningWorkers += 1 }
        }
        lock.unlock()

        if startWorker { workQueue.async { self.workerLoop() } }
        return request
    }

    /// Forgets a file's thumbnails in memory and on disk, for a file that
    /// was edited in place or deleted. A request made right after this
    /// always decodes the file again.
    public func invalidate(_ url: URL) {
        let path = url.path
        lock.lock()
        generations[path, default: 0] += 1
        failures = failures.filter { !$0.hasSuffix("|" + path) }
        // A decode already running read the file before this call. New
        // requests must start a fresh job rather than join it; the old job
        // still finishes for the waiters it has.
        for tier in Self.tiers {
            let key = JobKey(path: path, tier: tier)
            if jobs[key]?.started == true { jobs[key] = nil }
        }
        if store != nil { pendingDiskDeletes.insert(path) }
        lock.unlock()

        // The disk delete is a database write, so it never runs on the
        // caller's (probably the main) thread.
        guard let store else { return }
        workQueue.async {
            self.diskLock.withLock { store.invalidate(url) }
            self.lock.withLock { _ = self.pendingDiskDeletes.remove(path) }
        }
    }

    /// While suspended, requests queue up but no decode starts. Only for
    /// tests, which need several requests queued at once to check ordering.
    func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        let pending = stack.count
        let toStart = value ? 0 : max(0, min(workerLimit - runningWorkers, pending))
        runningWorkers += toStart
        lock.unlock()
        for _ in 0..<toStart { workQueue.async { self.workerLoop() } }
    }

    // MARK: - Work

    /// Runs jobs until the stack is empty. Each worker is one block on the
    /// concurrent queue; there are never more than `workerLimit` of them,
    /// and none exist while there is nothing to do.
    private func workerLoop() {
        while let job = nextJob() {
            let image = produce(job)
            lock.lock()
            if jobs[job.key] === job { jobs[job.key] = nil }
            let waiters = job.waiters
            lock.unlock()
            Self.deliver(image, to: waiters)
        }
    }

    /// Pops the newest job that still has someone waiting for it. Stops the
    /// worker (inside the lock, so no request can slip in unseen) when the
    /// stack is empty.
    private func nextJob() -> Job? {
        lock.lock(); defer { lock.unlock() }
        while let top = stack.popLast() {
            let job = top.job
            guard !job.started, job.sequence == top.sequence else { continue }   // a stale duplicate
            job.waiters.removeAll { $0.request.isCancelled }
            if job.waiters.isEmpty {
                if jobs[job.key] === job { jobs[job.key] = nil }
                continue
            }
            job.started = true
            return job
        }
        runningWorkers -= 1
        return nil
    }

    /// Memory, then disk, then decode. A decoded thumbnail is written to
    /// both caches: display-ready in memory, compactly encoded on disk.
    private func produce(_ job: Job) -> CGImage? {
        lock.lock()
        let entry = job.entry
        let path = entry.url.path
        let generation = generations[path] ?? 0
        let diskIsStale = pendingDiskDeletes.contains(path)
        let space = colorSpace, colorGeneration = self.colorGeneration
        lock.unlock()

        let key = cacheKey(entry, tier: job.key.tier, generation: generation)
        let imageKey = memoryKey(key, colorGeneration: colorGeneration)
        if let image = memory.object(forKey: imageKey) { return image }

        if !diskIsStale, let stored = store?.image(for: entry.url, modified: entry.modified,
                                                   fileSize: entry.fileSize, tier: job.key.tier) {
            let image = Self.displayReady(stored, in: space)
            cacheInMemory(image, forKey: imageKey, colorGeneration: colorGeneration)
            return image
        }
        guard let decoded = ImageDecoder.thumbnail(for: entry.url, maxPixelSize: job.key.tier) else {
            lock.withLock { _ = failures.insert(key) }
            return nil
        }
        let image = Self.displayReady(decoded, in: space)
        cacheInMemory(image, forKey: imageKey, colorGeneration: colorGeneration)

        // Encoded from the decode, not the display copy: an opaque photo
        // stays a JPEG rather than becoming a PNG for its alpha channel.
        if let store, let data = ThumbnailStore.encode(decoded) {
            diskLock.withLock {
                // Invalidated while decoding: this picture may be of the old file.
                guard lock.withLock({ generations[path] ?? 0 }) == generation else { return }
                store.store(encoded: data, for: entry.url, modified: entry.modified, fileSize: entry.fileSize,
                            tier: job.key.tier)
            }
        }
        return image
    }

    /// Calls completions on the main actor, skipping cancelled requests.
    /// The cancel check happens on the main actor, right before the call,
    /// which is what makes "never after cancel()" hold for main-actor callers.
    private static func deliver(_ image: CGImage?, to waiters: [Waiter]) {
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for waiter in waiters where !waiter.request.isCancelled {
                    waiter.completion(image)
                }
            }
        }
    }

    // MARK: - Display-ready images

    /// Bitmap layout Core Animation composites without converting.
    static let displayBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// `image` redrawn at its own size as 8-bit BGRA, premultiplied, in
    /// `space`; ColorSync converts from the image's own profile. Returns
    /// `image` itself when it already is, or when `space` can't back such a
    /// bitmap (Core Animation then converts it as before).
    static func displayReady(_ image: CGImage, in space: CGColorSpace) -> CGImage {
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bitmapInfo.rawValue == displayBitmapInfo,
           image.colorSpace == space {
            return image
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: displayBitmapInfo)
        else { return image }
        // The same size, so there is nothing to filter.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Caches unless the display colour space changed while the image was
    /// being drawn: under the lock, so a change can't slip in between the
    /// check and the insert and leave the old space's pixels cached.
    private func cacheInMemory(_ image: CGImage, forKey key: NSString, colorGeneration: Int) {
        lock.withLock {
            guard colorGeneration == self.colorGeneration else { return }
            memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
    }

    // MARK: - Helpers

    /// The modification date and size are part of the key, so an edited
    /// file (new date) misses the cache without anyone invalidating it.
    private func cacheKey(_ entry: FolderEntry, tier: Int, generation: Int) -> NSString {
        "\(tier)|\(generation)|\(entry.modified.timeIntervalSinceReferenceDate)|\(entry.fileSize)|\(entry.url.path)"
            as NSString
    }

    /// Memory cache key: the file's key plus the display colour space it
    /// was drawn for. (Failures don't depend on the colour space, so they
    /// use the file's key alone.)
    private func memoryKey(_ key: NSString, colorGeneration: Int) -> NSString {
        "\(colorGeneration)|\(key)" as NSString
    }

    /// Bytes of decoded pixels, which is what memory pressure is about.
    private static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    private struct JobKey: Hashable {
        let path: String
        let tier: Int
    }

    private struct Waiter: Sendable {
        let request: ThumbnailRequest
        let completion: @MainActor @Sendable (CGImage?) -> Void
    }

    /// Mutable, but only touched while holding the service's lock.
    private final class Job: @unchecked Sendable {
        let key: JobKey
        var entry: FolderEntry
        var waiters: [Waiter] = []
        var started = false
        var sequence: UInt64 = 0

        init(key: JobKey, entry: FolderEntry) {
            self.key = key
            self.entry = entry
        }
    }
}
