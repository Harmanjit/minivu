import Foundation
import ImageIO
import MinivuCore

/// A request for an image's dimensions. Cancel it when the cell scrolls away.
nonisolated final class PixelSizeRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Pixel dimensions for the grid's detail line ("6016 × 4016").
///
/// Reading them means opening each file and parsing its header, which is
/// cheap (no pixels are decoded) but still disk work, so it happens here:
/// one file at a time on a utility queue, newest request first, cancelled
/// requests skipped, results remembered by file, date and size. One file
/// at a time keeps it from competing with thumbnail decoding.
nonisolated final class PixelSizeCache: @unchecked Sendable {
    static let shared = PixelSizeCache()

    private let memory = NSCache<NSString, NSValue>()
    private let queue = DispatchQueue(label: "minivu.pixel-sizes", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stack: [Job] = []
    private var isRunning = false

    private struct Job {
        let entry: FolderEntry
        let request: PixelSizeRequest
        let completion: @MainActor @Sendable (CGSize?) -> Void
    }

    init(countLimit: Int = 50_000) {
        memory.countLimit = countLimit
    }

    /// Known dimensions, or nil if not read yet or not available.
    func cachedSize(for entry: FolderEntry) -> CGSize? {
        guard let size = memory.object(forKey: key(entry))?.sizeValue, size != .zero else { return nil }
        return size
    }

    /// Reads the dimensions in the background; `completion` runs on the
    /// main actor (with nil for files without them) unless cancelled first.
    @discardableResult
    func request(_ entry: FolderEntry, completion: @escaping @MainActor @Sendable (CGSize?) -> Void) -> PixelSizeRequest {
        let request = PixelSizeRequest()
        if let value = memory.object(forKey: key(entry))?.sizeValue {
            deliver(value == .zero ? nil : value, to: Job(entry: entry, request: request, completion: completion))
            return request
        }
        let start = lock.withLock {
            stack.append(Job(entry: entry, request: request, completion: completion))
            defer { isRunning = true }
            return !isRunning
        }
        if start { queue.async { self.drain() } }
        return request
    }

    private func drain() {
        while let job = nextJob() {
            let cacheKey = key(job.entry)
            let size: CGSize
            if let known = memory.object(forKey: cacheKey)?.sizeValue {
                size = known
            } else {
                // .zero records "no dimensions", so a file isn't read twice.
                size = Self.readPixelSize(of: job.entry.url) ?? .zero
                memory.setObject(NSValue(size: size), forKey: cacheKey)
            }
            deliver(size == .zero ? nil : size, to: job)
        }
    }

    private func nextJob() -> Job? {
        lock.withLock {
            while let job = stack.popLast() {
                if !job.request.isCancelled { return job }
            }
            isRunning = false
            return nil
        }
    }

    private func deliver(_ size: CGSize?, to job: Job) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !job.request.isCancelled else { return }
                job.completion(size)
            }
        }
    }

    private func key(_ entry: FolderEntry) -> NSString {
        "\(entry.modified.timeIntervalSinceReferenceDate)|\(entry.fileSize)|\(entry.url.path)" as NSString
    }

    /// Oriented width and height from the file's properties, without
    /// decoding. PDF and SVG have no pixel size of their own, so none.
    static func readPixelSize(of url: URL) -> CGSize? {
        guard let kind = ImageFormats.kind(of: url), kind == .raster || kind == .raw,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let swapsAxes = (5...8).contains(raw)
        return swapsAxes ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
