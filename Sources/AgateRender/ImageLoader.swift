import Foundation
import AgateCore

/// A request for a texture. Cancel it when the image is no longer wanted
/// (the user flipped past it) so its callback never runs and, if nobody
/// else wants the same decode, the decode stops early.
@MainActor public final class LoadHandle {
    fileprivate weak var loader: ImageLoader?
    fileprivate var jobID: Int?
    fileprivate var update: ((Result<ImageTexture, Error>) -> Void)?
    public private(set) var isCancelled = false

    fileprivate init(loader: ImageLoader?, update: ((Result<ImageTexture, Error>) -> Void)?) {
        self.loader = loader
        self.update = update
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        update = nil
        if let jobID { loader?.detach(self, from: jobID) }
    }

    /// Runs the callback once, unless cancelled; afterwards the handle is inert.
    fileprivate func deliver(_ result: Result<ImageTexture, Error>) {
        guard !isCancelled, let update else { return }
        self.update = nil
        jobID = nil
        update(result)
    }
}

/// Gets images onto the GPU: cache first, otherwise decode and upload in the
/// background (DESIGN.md 4.2).
///
/// The API is main-actor because its callers (the canvas, the viewer) are,
/// and because it lets the bookkeeping below be plain properties instead of
/// locks. Only the decode and upload themselves leave the main actor.
///
/// Three rules keep it fast and bounded:
///
/// - **One decode per image and size.** A request for something already
///   being decoded (usually because a prefetch got there first) joins that
///   job instead of starting another. Flipping to the next photo mid-prefetch
///   therefore waits for a decode that is already half done.
/// - **At most three decodes at once.** A 24 MP decode holds ~100 MB of CPU
///   memory until it is uploaded; unbounded concurrency would spike memory
///   when the user flips quickly. Waiting jobs start in priority order: what
///   the user is looking at before what might be looked at next.
/// - **Stale work stops.** When every requester of a job cancels, a waiting
///   job is dropped and a running one skips its upload.
@MainActor public final class ImageLoader {
    public static let shared = ImageLoader(cache: TextureCache(budgetBytes: TextureCache.defaultBudget()))

    public let cache: TextureCache

    /// Memory, not CPU, is the limit: see the type's documentation.
    static let maximumConcurrentDecodes = 3

    /// One decode + upload, shared by everyone who asked for it.
    private final class Job {
        let id: Int
        let entry: FolderEntry
        let page: Int
        /// Requested long edge in pixels; nil for full resolution.
        let pixelSize: Int?
        var priority: TaskPriority
        /// Request order, for choosing which waiting job starts next.
        var sequence: Int
        var handles: [LoadHandle] = []
        var wantedByPrefetch = false
        var task: Task<Void, Never>?
        /// Nobody wants the result any more; don't let new requests join.
        var abandoned = false
        /// The file changed while decoding; don't cache what was read.
        var discardResult = false
        var escalated = false

        init(id: Int, entry: FolderEntry, page: Int, pixelSize: Int?, priority: TaskPriority, sequence: Int) {
            self.id = id
            self.entry = entry
            self.page = page
            self.pixelSize = pixelSize
            self.priority = priority
            self.sequence = sequence
        }

        var isRunning: Bool { task != nil }
        var isWanted: Bool { wantedByPrefetch || !handles.isEmpty }
    }

    private var jobs: [Int: Job] = [:]
    private var waiting: [Int] = []
    private var runningCount = 0
    private var prefetchJobIDs: Set<Int> = []
    private var nextID = 0

    /// Decodes started, for tests that check work is shared.
    private(set) var decodeCount = 0

    public init(cache: TextureCache) {
        self.cache = cache
    }

    // MARK: - Requests

    /// Texture whose long edge covers pixelSize (the canvas drawable's long
    /// edge), for entry/page.
    ///
    /// Cache hit: `update` is called synchronously before returning. Otherwise
    /// decode (ImageDecoder.decode with maxPixelSize) + upload
    /// (TextureUploader.upload) off the main actor, then `update` on the main
    /// actor. Never called after cancel().
    @discardableResult
    public func load(_ entry: FolderEntry, page: Int = 0, pixelSize: Int,
                     update: @escaping (Result<ImageTexture, Error>) -> Void) -> LoadHandle {
        let size = snapped(pixelSize, for: entry, page: page)
        if let hit = cache.bestTexture(url: entry.url, modified: entry.modified, page: page, minimumLongEdge: size) {
            update(.success(hit))
            return LoadHandle(loader: nil, update: nil)
        }
        return enqueue(entry, page: page, pixelSize: size, update: update)
    }

    /// Same, full resolution (used when the user zooms beyond the screen
    /// texture).
    @discardableResult
    public func loadFullResolution(_ entry: FolderEntry, page: Int = 0,
                                   update: @escaping (Result<ImageTexture, Error>) -> Void) -> LoadHandle {
        if let hit = cachedFullResolution(entry, page: page) {
            update(.success(hit))
            return LoadHandle(loader: nil, update: nil)
        }
        return enqueue(entry, page: page, pixelSize: nil, update: update)
    }

    /// Background decode at utility priority of these entries at pixelSize;
    /// replaces the previous prefetch set, cancelling entries no longer
    /// wanted.
    ///
    /// Pass the nearest neighbours first: waiting prefetches start in the
    /// order given.
    public func prefetch(_ entries: [FolderEntry], pixelSize: Int) {
        var wanted: Set<Int> = []
        for entry in entries where !entry.isDirectory && entry.kind != nil {
            let size = snapped(pixelSize, for: entry, page: 0)
            // A cache hit also marks the texture used, so the neighbours of
            // the current photo are the last thing evicted.
            if cache.bestTexture(url: entry.url, modified: entry.modified, page: 0, minimumLongEdge: size) != nil {
                continue
            }
            let job = existingJob(entry, page: 0, pixelSize: size)
                ?? makeJob(entry, page: 0, pixelSize: size, priority: .utility)
            job.wantedByPrefetch = true
            wanted.insert(job.id)
        }
        for id in prefetchJobIDs.subtracting(wanted) {
            guard let job = jobs[id] else { continue }
            job.wantedByPrefetch = false
            dropIfUnwanted(job)
        }
        prefetchJobIDs = wanted
        startWaitingJobs()
    }

    /// Forgets every texture of a file that changed on disk. Decodes already
    /// running still deliver to whoever asked, but their result isn't cached
    /// and new requests start fresh.
    public func invalidate(_ url: URL) {
        cache.removeAll(for: url)
        for job in jobs.values where job.entry.url == url {
            job.discardResult = true
            job.abandoned = true
        }
    }

    // MARK: - Jobs

    private func enqueue(_ entry: FolderEntry, page: Int, pixelSize: Int?,
                         update: @escaping (Result<ImageTexture, Error>) -> Void) -> LoadHandle {
        let handle = LoadHandle(loader: self, update: update)
        let job: Job
        if let existing = existingJob(entry, page: page, pixelSize: pixelSize) {
            job = existing
            raisePriority(of: job)
        } else {
            job = makeJob(entry, page: page, pixelSize: pixelSize, priority: .userInitiated)
        }
        handle.jobID = job.id
        job.handles.append(handle)
        startWaitingJobs()
        return handle
    }

    /// A job that will produce what's asked for: the same image, and for
    /// screen requests a size at least as large (with the usual 3%).
    private func existingJob(_ entry: FolderEntry, page: Int, pixelSize: Int?) -> Job? {
        jobs.values
            .filter { job in
                guard !job.abandoned, job.entry.url == entry.url, job.entry.modified == entry.modified,
                      job.page == page else { return false }
                switch (job.pixelSize, pixelSize) {
                case (nil, nil): return true
                case let (have?, need?): return Double(have) >= Double(need) * 0.97
                default: return false   // a full decode is too slow to wait on for a screen request
                }
            }
            .min { ($0.pixelSize ?? .max) < ($1.pixelSize ?? .max) }
    }

    private func makeJob(_ entry: FolderEntry, page: Int, pixelSize: Int?, priority: TaskPriority) -> Job {
        nextID += 1
        let job = Job(id: nextID, entry: entry, page: page, pixelSize: pixelSize, priority: priority, sequence: nextID)
        jobs[job.id] = job
        waiting.append(job.id)
        return job
    }

    /// The user now wants what a prefetch was doing in the background.
    private func raisePriority(of job: Job) {
        nextID += 1
        job.sequence = nextID
        guard job.priority < .userInitiated else { return }
        job.priority = .userInitiated
        if let task = job.task, !job.escalated {
            // Swift raises a task's priority while a higher-priority task
            // awaits it, which also raises the decoding thread's QoS.
            job.escalated = true
            Task(priority: .userInitiated) { await task.value }
        }
    }

    /// Starts waiting jobs while slots are free: user requests first, newest
    /// first (the photo the user flipped to last is the one on screen);
    /// then prefetches in the order they were asked for.
    private func startWaitingJobs() {
        while runningCount < Self.maximumConcurrentDecodes, !waiting.isEmpty {
            let candidates = waiting.compactMap { jobs[$0] }
            guard let next = candidates.max(by: { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                return a.priority >= .userInitiated ? a.sequence < b.sequence : a.sequence > b.sequence
            }) else { waiting.removeAll(); return }
            waiting.removeAll { $0 == next.id }
            start(next)
        }
    }

    private func start(_ job: Job) {
        runningCount += 1
        decodeCount += 1
        let id = job.id, url = job.entry.url, page = job.page, size = job.pixelSize
        job.task = Task.detached(priority: job.priority) { [weak self] in
            let result = Result { try Self.decodeAndUpload(url: url, pixelSize: size, page: page) }
            await self?.finish(jobID: id, result: result)
        }
    }

    /// The only part that leaves the main actor. Cancellation is checked
    /// between the two steps: an ImageIO decode can't be interrupted, but the
    /// upload (a colour conversion and a GPU copy) can be skipped.
    nonisolated private static func decodeAndUpload(url: URL, pixelSize: Int?, page: Int) throws -> ImageTexture {
        try Task.checkCancellation()
        let decoded = try ImageDecoder.decode(url, maxPixelSize: pixelSize, page: page)
        try Task.checkCancellation()
        return try TextureUploader.upload(decoded)
    }

    private func finish(jobID: Int, result: Result<ImageTexture, Error>) {
        runningCount -= 1
        guard let job = jobs.removeValue(forKey: jobID) else { startWaitingJobs(); return }
        prefetchJobIDs.remove(jobID)
        if case .success(let texture) = result, !job.discardResult {
            let key = TextureKey(url: job.entry.url, modified: job.entry.modified, page: job.page,
                                 longEdge: max(texture.texture.width, texture.texture.height),
                                 fullResolution: texture.isFullResolution)
            cache.insert(texture, for: key)
        }
        for handle in job.handles { handle.deliver(result) }
        startWaitingJobs()
    }

    fileprivate func detach(_ handle: LoadHandle, from jobID: Int) {
        guard let job = jobs[jobID] else { return }
        job.handles.removeAll { $0 === handle }
        dropIfUnwanted(job)
    }

    private func dropIfUnwanted(_ job: Job) {
        guard !job.isWanted else { return }
        job.abandoned = true
        if let task = job.task {
            // Running: it still holds its slot until ImageIO returns, which
            // is what keeps memory bounded.
            task.cancel()
        } else {
            waiting.removeAll { $0 == job.id }
            jobs[job.id] = nil
        }
    }

    // MARK: - Sizes

    /// Snaps a screen request the way the decoder will, once the image's size
    /// is known from any cached texture of it. Requests of 3000 and 3024 px
    /// then both ask for the 3016 px the JPEG codec makes cheaply, and share
    /// one decode.
    private func snapped(_ pixelSize: Int, for entry: FolderEntry, page: Int) -> Int {
        guard let size = cache.knownImageSize(url: entry.url, modified: entry.modified, page: page) else {
            return pixelSize
        }
        let longest = Int(max(size.width, size.height))
        return min(ImageDecoder.scaledDecodeSize(longestEdge: longest, needed: pixelSize), longest)
    }

    /// A full-resolution texture, or for images beyond Metal's size limit the
    /// largest texture Metal allows (which is as good as it gets).
    private func cachedFullResolution(_ entry: FolderEntry, page: Int) -> ImageTexture? {
        guard let size = cache.knownImageSize(url: entry.url, modified: entry.modified, page: page) else { return nil }
        let longest = Int(max(size.width, size.height))
        let texture = cache.bestTexture(url: entry.url, modified: entry.modified, page: page,
                                        minimumLongEdge: min(longest, TextureUploader.maximumDimension))
        guard let texture else { return nil }
        if texture.isFullResolution { return texture }
        let edge = max(texture.texture.width, texture.texture.height)
        return edge >= TextureUploader.maximumDimension ? texture : nil
    }

    // MARK: - Testing

    /// Waits until every job has finished, for tests.
    func waitUntilIdle() async {
        while !jobs.isEmpty {
            if let task = jobs.values.first(where: { $0.isRunning })?.task {
                await task.value
            } else {
                await Task.yield()
            }
        }
    }
}
