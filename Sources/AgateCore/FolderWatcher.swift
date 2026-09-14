import Foundation
import CoreServices
import os

/// Calls `onChange` when files are added to, removed from or renamed in a
/// folder, so the browser can reload it.
///
/// Built on FSEvents rather than a kqueue file descriptor: FSEvents needs no
/// open descriptor per folder, keeps working when the folder is on a busy
/// volume, and coalesces bursts (a copy of 500 photos) into a handful of
/// callbacks, `latency` seconds apart, instead of 500.
///
/// Only changes to the folder itself are reported, not to files deep inside
/// its subfolders: the browser lists one level, so a busy subfolder (a
/// catalog, a build directory) must not make it reload over and over.
///
/// `onChange` runs on a private serial queue, never on the main thread.
/// Hop to the main actor there if you touch UI, asynchronously: `stop()`
/// waits for a running `onChange` to return, so an `onChange` that waited
/// for the main thread while the main thread calls `stop()` would deadlock.
/// The watcher stops when it is deallocated or `stop()` is called, and
/// never calls back afterwards.
public final class FolderWatcher: @unchecked Sendable {
    /// What the C callback can see. It is retained by the event stream
    /// itself (through the context's retain/release callbacks), so the
    /// callback never points at a watcher that is being deallocated.
    private final class Handler: @unchecked Sendable {
        let watchedPath: String
        let onChange: @Sendable () -> Void
        let stopped = OSAllocatedUnfairLock(initialState: false)

        init(watchedPath: String, onChange: @escaping @Sendable () -> Void) {
            self.watchedPath = watchedPath
            self.onChange = onChange
        }
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "agate.folder-watcher", qos: .utility)
    /// Marks `queue`, so `stop()` can tell whether it is running inside a
    /// callback. One key per watcher: a shared key would make watcher A's
    /// callback look like watcher B's.
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Returns nil if the folder doesn't exist or FSEvents refuses it.
    public init?(folder: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        // FSEvents reports real paths (/private/var/..., not /var/...), so
        // compare against the fully resolved path. `realpath` is used
        // because URL.resolvingSymlinksInPath strips /private again.
        guard let resolved = realpath(folder.path, nil) else { return nil }
        let path = String(cString: resolved)
        free(resolved)
        handler = Handler(watchedPath: path, onChange: onChange)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            guard !handler.stopped.withLock({ $0 }) else { return }
            // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a CFArray of CFString.
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let mustRescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                     | kFSEventStreamEventFlagRootChanged)
            for i in 0..<count {
                let trimmed = changed.indices.contains(i) ? String(changed[i].trimmingSuffix("/")) : ""
                if trimmed == handler.watchedPath || flags[i] & mustRescan != 0 {
                    handler.onChange()
                    return
                }
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else { return nil }
        queue.setSpecific(key: onQueueKey, value: true)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Stops watching. Safe to call more than once and from any thread,
    /// including from inside `onChange`.
    public func stop() {
        handler.stopped.withLock { $0 = true }
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // The `stopped` flag only stops callbacks that haven't begun. One
        // may already be inside `onChange` on the queue; waiting for the
        // queue to drain makes "never calls back after stop()" hold. From
        // inside a callback that wait would deadlock, and isn't needed: the
        // callback returns right after `onChange`.
        if DispatchQueue.getSpecific(key: onQueueKey) == nil {
            queue.sync {}
        }
    }

    deinit { stop() }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: Character) -> Substring {
        var s = Substring(self)
        while s.count > 1, s.last == suffix { s = s.dropLast() }
        return s
    }
}
