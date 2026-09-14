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
public final class ThumbnailService: @unchecked Sendable {
    public static let tiers = [256, 512]

    /// The smallest tier at least `forPixelSize`, else the largest.
    public static func tier(forPixelSize size: Int) -> Int {
        tiers.first { $0 >= size } ?? tiers[tiers.count - 1]
    }

    private let store: ThumbnailStore?
    private let memory = NSCache<NSString, CGImage>()
    private let workerLimit: Int
    private let workQueue = DispatchQueue(label: "agate.thumbnails", qos: .userInitiated, attributes: .concurrent)

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
    private var nextSequence: UInt64 = 0
    /// Bumped by `invalidate`, and part of the memory cache key, so old
    /// entries for a path stop matching without having to find them.
    private var generations: [String: Int] = [:]

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

    /// A thumbnail already in memory, for drawing a cell synchronously
    /// without a placeholder flash. A larger tier also satisfies the
    /// request (the cell scales it down).
    public func cachedImage(for entry: FolderEntry, pixelSize: Int) -> CGImage? {
        let wanted = Self.tier(forPixelSize: pixelSize)
        let generation = self.generation(for: entry.url.path)
        for tier in Self.tiers where tier >= wanted {
            if let image = memory.object(forKey: cacheKey(entry, tier: tier, generation: generation)) {
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
    /// was edited in place or deleted.
    public func invalidate(_ url: URL) {
        let path = url.path
        lock.lock()
        generations[path, default: 0] += 1
        lock.unlock()
        // The disk delete is a database write, so it never runs on the
        // caller's (probably the main) thread.
        if let store { workQueue.async { store.invalidate(url) } }
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
    /// both caches.
    private func produce(_ job: Job) -> CGImage? {
        lock.lock()
        let entry = job.entry
        let generation = generations[entry.url.path] ?? 0
        lock.unlock()

        let key = cacheKey(entry, tier: job.key.tier, generation: generation)
        if let image = memory.object(forKey: key) { return image }

        if let image = store?.image(for: entry.url, modified: entry.modified, fileSize: entry.fileSize,
                                    tier: job.key.tier) {
            memory.setObject(image, forKey: key, cost: Self.cost(of: image))
            return image
        }
        guard let image = ImageDecoder.thumbnail(for: entry.url, maxPixelSize: job.key.tier) else { return nil }
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        store?.store(image, for: entry.url, modified: entry.modified, fileSize: entry.fileSize, tier: job.key.tier)
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

    // MARK: - Helpers

    private func generation(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generations[path] ?? 0
    }

    /// The modification date and size are part of the key, so an edited
    /// file (new date) misses the cache without anyone invalidating it.
    private func cacheKey(_ entry: FolderEntry, tier: Int, generation: Int) -> NSString {
        "\(tier)|\(generation)|\(entry.modified.timeIntervalSinceReferenceDate)|\(entry.fileSize)|\(entry.url.path)"
            as NSString
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
