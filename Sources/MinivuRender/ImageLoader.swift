import Foundation
import Synchronization
import MinivuCore

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

/// How RAW files are shown.
public enum RawDecoding: String, Sendable, CaseIterable {
    /// The JPEG the camera embedded, wherever it is large enough for what is
    /// shown: fast, and the camera's own colour rendering. Where it is too
    /// small (zoomed in, or a camera's 1616 px preview on a large screen)
    /// the RAW data is rendered instead.
    case embeddedPreview
    /// Always render the sensor data with Apple's RAW engine, at the size
    /// shown: slower, but the same rendering at every zoom.
    case fullRaw
}

/// The user's choices that change what a file's texture looks like.
///
/// Textures made under other settings are wrong, so changing these empties
/// the texture cache (see `ImageLoader.settings`).
public struct DisplaySettings: Sendable, Equatable {
    public var rawDecoding: RawDecoding
    /// Decode HDR photos (gain maps, PQ, HLG) with their highlights. Off:
    /// ImageIO tone maps them to SDR.
    public var showHDR: Bool
    /// Render RAW files with extended dynamic range. Needs `showHDR`, and
    /// always renders the sensor data, since embedded previews are SDR.
    public var hdrRaw: Bool
    /// How much of the RAW engine's extended range to use, 0...1.
    public var hdrRawAmount: Float

    public init(rawDecoding: RawDecoding = .embeddedPreview, showHDR: Bool = true, hdrRaw: Bool = false,
                hdrRawAmount: Float = 1) {
        self.rawDecoding = rawDecoding
        self.showHDR = showHDR
        self.hdrRaw = hdrRaw
        self.hdrRawAmount = hdrRawAmount
    }

    /// RAW files render with highlights above SDR white.
    var rendersHDRRaw: Bool { showHDR && hdrRaw && hdrRawAmount > 0 }

    /// Every RAW load goes through `RawRenderer`, at any size.
    var alwaysRendersRaw: Bool { rawDecoding == .fullRaw || rendersHDRRaw }

    /// The headroom to ask `RawRenderer` for: the amount scales the
    /// engine's range exponentially, as exposure does.
    var rawHeadroom: Float { pow(RawRenderer.maximumHeadroom, min(max(hdrRawAmount, 0), 1)) }
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
///   the user is looking at before what might be looked at next. Prefetches
///   never take the last slot, so a jump to a far-away photo starts decoding
///   at once instead of queueing behind three neighbours.
/// - **One RAW render at a time**, in a slot of its own. Apple's RAW engine
///   adds about 1.6 GB to the footprint for a full-size 24 MP render and
///   0.8 GB for a screen-sized one, and holds it for about five seconds, so
///   three at once page an 8 GB Mac. Other decodes carry on beside it. Only
///   the nearest RAW neighbour is prefetched as a render, and on Macs with
///   8 GB or less none is: embedded previews still are. A RAW file whose
///   embedded preview may cover the request decodes that first, in a decode
///   slot, and moves to the render slot only if the preview falls short.
/// - **Stale work stops.** When every requester of a job cancels, a waiting
///   job is dropped and a running one skips its upload. A running job that
///   is wanted again before its decode finishes (the user flipped away and
///   straight back, or `prefetch` replaced the set just before `load` asked
///   for the same photo) is picked up again rather than decoded twice.
@MainActor public final class ImageLoader {
    public static let shared = ImageLoader(cache: TextureCache(budgetBytes: TextureCache.defaultBudget()))

    public let cache: TextureCache

    /// How files become textures. The app sets this from its preferences.
    ///
    /// A change empties the texture cache and stops the decodes under way
    /// from caching or being joined, as `invalidate` does for one file:
    /// what they produce is right for the old settings only. Requests
    /// already waiting on such a decode still get its result; whoever shows
    /// images reloads them after a change.
    public var settings = DisplaySettings() {
        didSet {
            guard settings != oldValue else { return }
            cache.removeAll()
            for job in jobs.values {
                job.discardResult = true
                job.wantedByPrefetch = false
                dropIfUnwanted(job)
            }
        }
    }

    /// Memory, not CPU, is the limit: see the type's documentation.
    static let maximumConcurrentDecodes = 3
    /// One slot stays free for what the user asks for.
    static let maximumConcurrentPrefetches = maximumConcurrentDecodes - 1
    /// RAW renders, which don't take decode slots. A prefetched render may
    /// hold the slot when the user jumps to another RAW file that needs one;
    /// that photo waits a few hundred milliseconds, which is cheaper than
    /// another gigabyte.
    static let maximumConcurrentRawRenders = 1

    /// Whether neighbours may be prefetched as RAW renders at all. Not with
    /// 8 GB or less: a render the user may never look at would hold 0.8 GB
    /// for seconds, which such a Mac pays for in paging.
    nonisolated static func allowsRawRenderPrefetch(physicalMemory: UInt64) -> Bool {
        physicalMemory > 8 << 30
    }

    /// `allowsRawRenderPrefetch` for this Mac; tests set it.
    var prefetchesRawRenders = ImageLoader.allowsRawRenderPrefetch(physicalMemory: ProcessInfo.processInfo.physicalMemory)

    /// "Nobody wants this any more", shared with the decoding task.
    ///
    /// Task cancellation can't be undone, but a job that loses its last
    /// requester may be wanted again a moment later, so the task checks this
    /// flag instead. Atomic because the main actor writes it while the
    /// decoding thread reads it.
    private final class StopFlag: Sendable {
        private let value = Atomic<Bool>(false)
        var isSet: Bool { value.load(ordering: .relaxed) }
        func set(_ stop: Bool) { value.store(stop, ordering: .relaxed) }
    }

    /// The embedded preview wasn't enough, so the job needs the RAW slot.
    private struct NeedsRawRender: Error {}

    /// One decode + upload, shared by everyone who asked for it.
    private final class Job {
        /// What the job's task does when it next starts, which decides the
        /// slot it waits for.
        enum Stage {
            /// ImageIO, or a RAW file's embedded preview.
            case decode
            /// `RawRenderer`.
            case rawRender
        }

        let id: Int
        let entry: FolderEntry
        let page: Int
        /// Requested long edge in pixels; nil for full resolution.
        let pixelSize: Int?
        /// The settings when the job was made, which its decode follows.
        let settings: DisplaySettings
        var priority: TaskPriority
        /// Request order, for choosing which waiting job starts next.
        var sequence: Int
        var handles: [LoadHandle] = []
        var wantedByPrefetch = false
        var task: Task<Void, Never>?
        let stop = StopFlag()
        /// The file changed on disk, or the settings did; don't cache what
        /// was read, and don't let new requests join.
        var discardResult = false
        var escalated = false
        var stage: Stage
        /// Came to `.rawRender` after its preview fell short; the render is
        /// the same job going on, not another decode.
        var continuedToRender = false
        /// Wanted by a prefetch that allows it to go on to a RAW render.
        var prefetchMayRender = false

        init(id: Int, entry: FolderEntry, page: Int, pixelSize: Int?, settings: DisplaySettings,
             priority: TaskPriority, sequence: Int, stage: Stage) {
            self.id = id
            self.entry = entry
            self.page = page
            self.pixelSize = pixelSize
            self.settings = settings
            self.priority = priority
            self.sequence = sequence
            self.stage = stage
        }

        var isRunning: Bool { task != nil }
        var isWanted: Bool { wantedByPrefetch || !handles.isEmpty }
    }

    /// A RAW file at a size its embedded preview didn't cover.
    private struct PreviewKey: Hashable {
        let url: URL
        let modified: Date
        let pixelSize: Int?
    }

    private var jobs: [Int: Job] = [:]
    private var waiting: [Int] = []
    private var runningCount = 0
    private var runningRawRenders = 0
    private var prefetchJobIDs: Set<Int> = []
    private var nextID = 0
    /// Previews already found too small, so the next request for the same
    /// size goes straight to the render instead of decoding the preview
    /// again, and a prefetch that may not render doesn't try.
    private var previewShortfalls: Set<PreviewKey> = []

    /// Decodes started (a RAW render that follows its preview isn't another),
    /// for tests that check work is shared.
    private(set) var decodeCount = 0
    /// RAW renders started, and the most that ran at once, for tests.
    private(set) var rawRenderCount = 0
    private(set) var peakConcurrentRawRenders = 0

    public init(cache: TextureCache) {
        self.cache = cache
    }

    // MARK: - Requests

    /// Texture whose long edge covers pixelSize (the canvas drawable's long
    /// edge), for entry/page.
    ///
    /// Cache hit: `update` is called synchronously before returning. Otherwise
    /// decode (ImageDecoder.decode with maxPixelSize, or RawRenderer for RAW
    /// files as `settings` say) + upload (TextureUploader.upload) off the
    /// main actor, then `update` on the main actor. Never called after
    /// cancel().
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
        prefetch(pages: entries.map { ($0, 0) }, pixelSize: pixelSize)
    }

    /// The same for particular pages, so a document's next page can be
    /// prefetched ahead of the neighbouring files.
    ///
    /// RAW renders are prefetched for the nearest RAW file only (the first
    /// in `pages`), and not at all where `prefetchesRawRenders` is false;
    /// other RAW files are prefetched only as far as their embedded preview
    /// covers the size.
    public func prefetch(pages: [(entry: FolderEntry, page: Int)], pixelSize: Int) {
        var wanted: Set<Int> = []
        var renderAllowance = prefetchesRawRenders
        for (entry, page) in pages where !entry.isDirectory && entry.kind != nil {
            var mayRender = false
            if Self.isRaw(entry) {
                mayRender = renderAllowance
                renderAllowance = false
            }
            let size = snapped(pixelSize, for: entry, page: page)
            // A cache hit also marks the texture used, so the neighbours of
            // the current photo are the last thing evicted.
            if cache.bestTexture(url: entry.url, modified: entry.modified, page: page, minimumLongEdge: size) != nil {
                continue
            }
            let existing = existingJob(entry, page: page, pixelSize: size)
            if !mayRender, (existing?.stage ?? initialStage(entry, pixelSize: size)) == .rawRender {
                continue   // left out of `wanted`, so dropped below unless the user wants it
            }
            let job = existing ?? makeJob(entry, page: page, pixelSize: size, priority: .utility)
            job.wantedByPrefetch = true
            job.prefetchMayRender = mayRender
            job.stop.set(false)
            if job.priority < .userInitiated {
                // Waiting prefetches start in the order of this call, not
                // the order of whichever call first asked for them.
                job.sequence = nextSequence()
            }
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
    /// and new requests start fresh. Prefetches of the file stop: their
    /// result could only be thrown away.
    public func invalidate(_ url: URL) {
        cache.removeAll(for: url)
        previewShortfalls = previewShortfalls.filter { $0.url != url }
        for job in jobs.values where job.entry.url == url {
            job.discardResult = true
            job.wantedByPrefetch = false
            dropIfUnwanted(job)
        }
    }

    // MARK: - Jobs

    private func enqueue(_ entry: FolderEntry, page: Int, pixelSize: Int?,
                         update: @escaping (Result<ImageTexture, Error>) -> Void) -> LoadHandle {
        let handle = LoadHandle(loader: self, update: update)
        let job: Job
        if let existing = existingJob(entry, page: page, pixelSize: pixelSize) {
            job = existing
            job.stop.set(false)
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
                guard !job.discardResult, job.entry.url == entry.url, job.entry.modified == entry.modified,
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
        let id = nextSequence()
        let job = Job(id: id, entry: entry, page: page, pixelSize: pixelSize, settings: settings,
                      priority: priority, sequence: id, stage: initialStage(entry, pixelSize: pixelSize))
        jobs[job.id] = job
        waiting.append(job.id)
        return job
    }

    nonisolated private static func isRaw(_ entry: FolderEntry) -> Bool {
        ImageFormats.kind(of: entry.url) == .raw
    }

    /// Where a new job for `entry` starts: a RAW file goes straight to the
    /// render when the settings always render, or when its preview is
    /// already known to fall short at this size.
    private func initialStage(_ entry: FolderEntry, pixelSize: Int?) -> Job.Stage {
        guard Self.isRaw(entry) else { return .decode }
        if Self.rawPlan(settings: settings) != .previewOrRender { return .rawRender }
        let key = PreviewKey(url: entry.url, modified: entry.modified, pixelSize: pixelSize)
        return previewShortfalls.contains(key) ? .rawRender : .decode
    }

    /// One counter for job ids and request order: both only need to grow.
    private func nextSequence() -> Int {
        nextID += 1
        return nextID
    }

    /// The user now wants what a prefetch was doing in the background.
    private func raisePriority(of job: Job) {
        job.sequence = nextSequence()
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
    /// then prefetches in the order they were asked for, leaving one decode
    /// slot free. Decodes and RAW renders wait for slots of their own, so a
    /// full one never holds up the other.
    private func startWaitingJobs() {
        waiting.removeAll { jobs[$0] == nil }
        guard !waiting.isEmpty else { return }
        let ordered = waiting.compactMap { jobs[$0] }.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.priority >= .userInitiated ? a.sequence > b.sequence : a.sequence < b.sequence
        }
        var full: Set<Job.Stage> = []
        for job in ordered where !full.contains(job.stage) {
            // Everything after a job that can't start ranks below it, and
            // would find its slots just as full.
            guard hasSlot(for: job) else {
                full.insert(job.stage)
                continue
            }
            waiting.removeAll { $0 == job.id }
            start(job)
        }
    }

    private func hasSlot(for job: Job) -> Bool {
        switch job.stage {
        case .decode:
            runningCount < (job.priority >= .userInitiated ? Self.maximumConcurrentDecodes
                                                          : Self.maximumConcurrentPrefetches)
        case .rawRender:
            runningRawRenders < Self.maximumConcurrentRawRenders
        }
    }

    private func start(_ job: Job) {
        switch job.stage {
        case .decode:
            runningCount += 1
            decodeCount += 1
        case .rawRender:
            runningRawRenders += 1
            rawRenderCount += 1
            peakConcurrentRawRenders = max(peakConcurrentRawRenders, runningRawRenders)
            if !job.continuedToRender { decodeCount += 1 }
        }
        let id = job.id, url = job.entry.url, page = job.page, size = job.pixelSize, stop = job.stop
        let settings = job.settings, stage = job.stage
        job.task = Task.detached(priority: job.priority) { [weak self] in
            let result = Result {
                try Self.decodeAndUpload(url: url, pixelSize: size, page: page, settings: settings, stage: stage,
                                         stop: stop)
            }
            await self?.finish(jobID: id, stage: stage, result: result)
        }
    }

    /// The only part that leaves the main actor. The stop flag is checked
    /// before and between the steps: an ImageIO decode or a RAW render can't
    /// be interrupted, but it needn't start, and the upload (a colour
    /// conversion and a GPU copy) can be skipped.
    nonisolated private static func decodeAndUpload(url: URL, pixelSize: Int?, page: Int, settings: DisplaySettings,
                                                    stage: Job.Stage, stop: StopFlag) throws -> ImageTexture {
        func checkStop() throws {
            if stop.isSet || Task.isCancelled { throw CancellationError() }
        }
        try checkStop()
        if ImageFormats.kind(of: url) == .raw {
            switch stage {
            case .decode:
                return try loadRawPreview(url: url, pixelSize: pixelSize, checkStop: checkStop)
            case .rawRender:
                if let texture = try renderRaw(url: url, pixelSize: pixelSize, settings: settings,
                                               checkStop: checkStop) {
                    return texture
                }
            }
        }
        let decoded = try ImageDecoder.decode(url, maxPixelSize: pixelSize, page: page, allowHDR: settings.showHDR)
        try checkStop()
        return try TextureUploader.upload(decoded)
    }

    /// A RAW file's embedded preview when it covers the request; otherwise
    /// throws `NeedsRawRender`, and the job waits for the render slot.
    ///
    /// ImageIO's decode isn't used for RAW files because of what it does
    /// when the embedded preview is smaller than asked (many cameras store
    /// 1616 px): a screen request gets that small preview, so the canvas
    /// keeps asking for pixels that never come, and a full-resolution
    /// request renders the RAW on the CPU (0.5-1.2 s for 24 MP).
    nonisolated private static func loadRawPreview(url: URL, pixelSize: Int?,
                                                   checkStop: () throws -> Void) throws -> ImageTexture {
        guard let preview = try? ImageDecoder.decodeRawPreview(url, maxPixelSize: pixelSize),
              previewCovers(preview, pixelSize: pixelSize) else { throw NeedsRawRender() }
        try checkStop()
        return try TextureUploader.upload(preview)
    }

    /// A RAW file rendered as `settings` say; nil leaves it to ImageIO's
    /// decode (a file with no embedded preview whose render failed).
    nonisolated private static func renderRaw(url: URL, pixelSize: Int?, settings: DisplaySettings,
                                              checkStop: () throws -> Void) throws -> ImageTexture? {
        do {
            return try RawRenderer.render(url: url, maxPixelSize: pixelSize,
                                          hdr: rawPlan(settings: settings) == .render(hdr: true),
                                          headroom: settings.rawHeadroom)
        } catch DecodeError.noImage {
            // Core Image's RAW engine doesn't know this camera, and ImageIO
            // renders RAW files with the same engine: the embedded preview is
            // the most this file will show.
            try checkStop()
            guard var preview = try? ImageDecoder.decodeRawPreview(url, maxPixelSize: pixelSize) else { return nil }
            // Smaller than asked for, so it is all there is. Saying so stops
            // the canvas asking again and again.
            if !previewCovers(preview, pixelSize: pixelSize) { preview.isFullResolution = true }
            return try TextureUploader.upload(preview)
        } catch {
            return nil   // a GPU failure: ImageIO's decode may still manage
        }
    }

    /// How a RAW file is loaded.
    enum RawPlan: Equatable {
        /// `RawRenderer` at the requested size.
        case render(hdr: Bool)
        /// The embedded preview when it covers the request (at full
        /// resolution: the camera stored one at sensor size, 140-260 ms with
        /// the upload for 24 MP), otherwise a render at the requested size.
        case previewOrRender
    }

    nonisolated static func rawPlan(settings: DisplaySettings) -> RawPlan {
        settings.alwaysRendersRaw ? .render(hdr: settings.rendersHDRRaw) : .previewOrRender
    }

    /// Whether an embedded preview decoded for `pixelSize` (nil: full
    /// resolution) is as good as a render: the whole image, or at least the
    /// requested size, with the usual 3% slack.
    nonisolated static func previewCovers(_ preview: DecodedImage, pixelSize: Int?) -> Bool {
        if preview.isFullResolution { return true }
        guard let pixelSize else { return false }
        return Double(max(preview.image.width, preview.image.height)) >= Double(pixelSize) * 0.97
    }

    private func finish(jobID: Int, stage: Job.Stage, result: Result<ImageTexture, Error>) {
        switch stage {
        case .decode: runningCount -= 1
        case .rawRender: runningRawRenders -= 1
        }
        guard let job = jobs[jobID] else { startWaitingJobs(); return }
        job.task = nil
        if case .failure(let error) = result, error is NeedsRawRender {
            rememberShortfall(of: job)
            job.stage = .rawRender
            job.continuedToRender = true
            // Only a prefetch allowed to render keeps it for the prefetch's sake.
            if !job.prefetchMayRender { job.wantedByPrefetch = false }
            if job.isWanted {
                waiting.append(jobID)
            } else {
                jobs[jobID] = nil
                prefetchJobIDs.remove(jobID)
            }
            startWaitingJobs()
            return
        }
        if case .failure(let error) = result, error is CancellationError, job.isWanted {
            // Stopped, but wanted again after the task had already given up:
            // run it again rather than hand the requester a cancellation.
            waiting.append(jobID)
            startWaitingJobs()
            return
        }
        jobs[jobID] = nil
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

    private func rememberShortfall(of job: Job) {
        // A few bytes per RAW file and size looked at; a folder session
        // stays far below this, and forgetting only costs a preview decode.
        if previewShortfalls.count >= 1000 { previewShortfalls.removeAll() }
        previewShortfalls.insert(PreviewKey(url: job.entry.url, modified: job.entry.modified, pixelSize: job.pixelSize))
    }

    fileprivate func detach(_ handle: LoadHandle, from jobID: Int) {
        guard let job = jobs[jobID] else { return }
        job.handles.removeAll { $0 === handle }
        dropIfUnwanted(job)
    }

    private func dropIfUnwanted(_ job: Job) {
        guard !job.isWanted else { return }
        if job.isRunning {
            // Running: it still holds its slot until ImageIO returns, which
            // is what keeps memory bounded. Stay findable in `jobs` so a new
            // request can pick it up again.
            job.stop.set(true)
        } else {
            waiting.removeAll { $0 == job.id }
            jobs[job.id] = nil
        }
    }

    // MARK: - Sizes

    /// Snaps a screen request the way the decoder will, once the image's size
    /// is known from any cached texture of it. Requests of 3000 and 3024 px
    /// then both ask for the 3016 px the JPEG codec makes cheaply, and share
    /// one decode. A PDF or SVG renders at exactly the size asked, so there is
    /// nothing to snap to.
    private func snapped(_ pixelSize: Int, for entry: FolderEntry, page: Int) -> Int {
        guard entry.kind != .pdf, entry.kind != .svg,
              let size = cache.knownImageSize(url: entry.url, modified: entry.modified, page: page) else {
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
