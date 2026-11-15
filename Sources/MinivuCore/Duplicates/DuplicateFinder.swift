import Foundation
import CoreGraphics

/// Finds duplicate and similar images (G5, Tools > Find Duplicates…).
///
/// **Exact duplicates** are files with the same bytes. Only files of the same
/// size can match, so sizes come first (free: the listing has them) and only
/// files that share a size are read, through a streamed SHA-256
/// (`ContentHash`). A folder of 5,000 different photos usually reads nothing.
///
/// **Similar images** are pictures that look alike: a resized or re-encoded
/// copy, an edit, a burst. Each image gets a Vision feature print from a
/// thumbnail-sized decode (`FeaturePrint`), and `SimilarityIndex` keeps the
/// pairs of prints that are close; the user's threshold then picks which of
/// those count, so moving it regroups without analysing anything again.
///
/// Both kinds of fingerprint are cached in the thumbnail database by file
/// identity, size and date (`FingerprintCache.swift`), so a second run over
/// the same photos is quick. Everything here blocks: call it off the main
/// thread. Nothing here deletes anything; the results window does, and only
/// when the user asks.
public enum DuplicateFinder {
    public enum Mode: String, Sendable, CaseIterable, Codable {
        case exact
        case similar
    }

    /// How far a run has got, for the progress bar.
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Reading the contents of files that share a size.
            case comparing
            /// Making feature prints.
            case analysing
            /// Comparing the prints with each other.
            case grouping
        }

        public var phase: Phase
        public var done: Int
        public var total: Int

        public init(phase: Phase, done: Int, total: Int) {
            self.phase = phase
            self.done = done
            self.total = total
        }
    }

    // MARK: - Memory

    /// Images analysed at once. Each Vision request holds its network and
    /// buffers (tens of megabytes) besides the decode, so an 8 GB Mac makes
    /// one print at a time, as it renders one RAW and converts one file at a
    /// time; larger Macs make a few.
    public static func analysisWorkers(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        switch physicalMemory {
        case ...(8 << 30): 1
        case ...(16 << 30): 2
        default: 3
        }
    }

    /// The most images one similarity search compares. Comparing holds every
    /// print twice (as rows and as columns of one matrix product, 3 KB each)
    /// plus a block of distances: about 130 MB for 20,000 images, the walk's
    /// own limit. An 8 GB Mac stops at half that.
    public static func maximumSimilarImages(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory <= 8 << 30 ? 10_000 : 20_000
    }

    // MARK: - Exact duplicates

    /// Groups of files with identical bytes, each group in path order, the
    /// groups with the most space to win back first. Empty files are left
    /// out: they are not pictures, and all of them are "identical".
    ///
    /// - Parameters:
    ///   - cache: where hashes are kept between runs; nil reads every file.
    ///   - isCancelled: asked before each file (and each chunk of one);
    ///     a cancelled run returns the groups found among files read so far.
    public static func exactGroups(in entries: [FolderEntry], cache: ThumbnailStore?,
                                   chunkSize: Int = ContentHash.chunkSize, isCancelled: () -> Bool = { false },
                                   progress: (Progress) -> Void = { _ in }) -> [[FolderEntry]] {
        let files = unique(entries).filter { !$0.isDirectory && $0.fileSize > 0 }
        let candidates = Dictionary(grouping: files, by: \.fileSize).values.filter { $0.count > 1 }.flatMap { $0 }
        guard !candidates.isEmpty else { return [] }
        let identities = FileIdentity.read(candidates.map(\.url))
        let cached = cache?.fingerprints(for: Array(identities.values)) ?? [:]
        var hashes: [URL: Data] = [:]
        var pending: [(identity: FileIdentity, sha256: Data)] = []
        progress(Progress(phase: .comparing, done: 0, total: candidates.count))
        for (index, entry) in candidates.enumerated() {
            if isCancelled() { break }
            let identity = identities[entry.url]
            if let identity, let hash = cached[identity]?.sha256 {
                hashes[entry.url] = hash
            } else if let hash = try? ContentHash.sha256(of: entry.url, chunkSize: chunkSize, isCancelled: isCancelled) {
                hashes[entry.url] = hash
                if let identity { pending.append((identity, hash)) }
                if pending.count >= 100 {
                    cache?.storeHashes(pending)
                    pending.removeAll()
                }
            }
            progress(Progress(phase: .comparing, done: index + 1, total: candidates.count))
        }
        cache?.storeHashes(pending)
        // The size is part of the key: a hash collision across sizes is
        // impossible to see, but it costs nothing to rule out.
        let groups = Dictionary(grouping: candidates.filter { hashes[$0.url] != nil }) {
            "\($0.fileSize):\(hashes[$0.url]!.base64EncodedString())"
        }
        return groups.values.filter { $0.count > 1 }
            .map { $0.sorted(by: pathOrder) }
            .sorted { ($0[0].fileSize * Int64($0.count - 1), $1[0].url.path) > ($1[0].fileSize * Int64($1.count - 1), $0[0].url.path) }
    }

    // MARK: - Similar images

    /// The feature print of each image that has one: cached prints where
    /// they are current, the rest made by `workers` threads at a time and
    /// cached as they are made, so a cancelled run keeps its work.
    ///
    /// - Parameter make: makes one print; tests count the calls.
    public static func featurePrints(for entries: [FolderEntry], store: ThumbnailStore?,
                                     workers: Int = analysisWorkers(), isCancelled: @Sendable () -> Bool = { false },
                                     progress: @Sendable (Progress) -> Void = { _ in },
                                     make: @Sendable (FolderEntry, ThumbnailStore?) -> FeaturePrint? = FeaturePrint.make(for:thumbnails:))
        -> [URL: FeaturePrint] {
        let images = unique(entries).filter { !$0.isDirectory }
        guard !images.isEmpty else { return [:] }
        let revision = FeaturePrint.currentRevision
        let identities = FileIdentity.read(images.map(\.url))
        let cached = store?.fingerprints(for: Array(identities.values)) ?? [:]
        let collector = PrintCollector(store: store)
        var missing: [FolderEntry] = []
        for entry in images {
            if let identity = identities[entry.url], let print = cached[identity]?.print, print.revision == revision {
                collector.prints[entry.url] = print
            } else {
                missing.append(entry)
            }
        }
        let alreadyDone = images.count - missing.count
        progress(Progress(phase: .analysing, done: alreadyDone, total: images.count))
        let next = Counter()
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, missing.count))) { _ in
            while !isCancelled(), let index = next.take(below: missing.count) {
                let entry = missing[index]
                let print = make(entry, store)
                let done = collector.add(print, for: entry.url, identity: identities[entry.url])
                progress(Progress(phase: .analysing, done: alreadyDone + done, total: images.count))
            }
        }
        collector.flush()
        return collector.prints
    }

    /// Prints made by the workers, stored in the cache a batch at a time.
    private final class PrintCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let store: ThumbnailStore?
        var prints: [URL: FeaturePrint] = [:]
        private var pending: [(identity: FileIdentity, print: FeaturePrint)] = []
        private var made = 0

        init(store: ThumbnailStore?) {
            self.store = store
        }

        /// Returns how many the workers have finished, failures included.
        func add(_ print: FeaturePrint?, for url: URL, identity: FileIdentity?) -> Int {
            let (count, batch) = lock.withLock { () -> (Int, [(identity: FileIdentity, print: FeaturePrint)]) in
                made += 1
                if let print {
                    prints[url] = print
                    if let identity { pending.append((identity, print)) }
                }
                guard pending.count >= 50 else { return (made, []) }
                defer { pending.removeAll() }
                return (made, pending)
            }
            store?.storePrints(batch)
            return count
        }

        func flush() {
            let batch = lock.withLock { () -> [(identity: FileIdentity, print: FeaturePrint)] in
                defer { pending.removeAll() }
                return pending
            }
            store?.storePrints(batch)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func take(below limit: Int) -> Int? {
            lock.withLock {
                guard value < limit else { return nil }
                defer { value += 1 }
                return value
            }
        }
    }

    // MARK: - Helpers

    /// Each file once, however many spellings reached it (a symbolic link,
    /// a selection that also holds the folder's flat view).
    static func unique(_ entries: [FolderEntry]) -> [FolderEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.url.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    static func pathOrder(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    /// The oriented pixel size of each image whose header names one, for
    /// the results' dimensions and the Highest Resolution rule.
    public static func pixelSizes(of entries: [FolderEntry], isCancelled: () -> Bool = { false }) -> [URL: CGSize] {
        var sizes: [URL: CGSize] = [:]
        for entry in entries {
            if isCancelled() { break }
            if let size = ImageDecoder.headerPixelSize(of: entry.url) { sizes[entry.url] = size }
        }
        return sizes
    }
}

/// Which file of a group the results window suggests keeping; the others
/// are the ones Mark Suggested marks for the Trash.
public enum KeepRule: String, CaseIterable, Sendable, Codable {
    /// The most bytes: usually the least compressed copy.
    case largestFile
    /// The most pixels: the original rather than a downsized copy.
    case highestResolution
    /// The earliest date (created or modified, whichever is earlier): the
    /// original rather than a later copy or export.
    case oldest

    /// The file to keep. Ties go to the next rule's choice (resolution, then
    /// size, then age), and then to path order, so the answer never depends
    /// on the order the files were found in.
    public func keeper(of files: [FolderEntry], pixelSizes: [URL: CGSize]) -> FolderEntry? {
        files.min { better($0, than: $1, pixelSizes: pixelSizes) }
    }

    /// Whether `a` should be kept before `b`.
    func better(_ a: FolderEntry, than b: FolderEntry, pixelSizes: [URL: CGSize]) -> Bool {
        let pixels = { (e: FolderEntry) -> Double in pixelSizes[e.url].map { Double($0.width * $0.height) } ?? 0 }
        let age = { (e: FolderEntry) -> Date in min(e.created, e.modified) }
        let keys: [(FolderEntry, FolderEntry) -> Bool?] = {
            let bySize = { (a: FolderEntry, b: FolderEntry) -> Bool? in a.fileSize == b.fileSize ? nil : a.fileSize > b.fileSize }
            let byPixels = { (a: FolderEntry, b: FolderEntry) -> Bool? in pixels(a) == pixels(b) ? nil : pixels(a) > pixels(b) }
            let byAge = { (a: FolderEntry, b: FolderEntry) -> Bool? in age(a) == age(b) ? nil : age(a) < age(b) }
            switch self {
            case .largestFile: return [bySize, byPixels, byAge]
            case .highestResolution: return [byPixels, bySize, byAge]
            case .oldest: return [byAge, byPixels, bySize]
            }
        }()
        for key in keys {
            if let answer = key(a, b) { return answer }
        }
        return DuplicateFinder.pathOrder(a, b)
    }
}
