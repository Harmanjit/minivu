import Testing
import Foundation
import os
@testable import MinivuCore

@Suite struct FolderWatcherTests {
    /// Counts callbacks. (An AsyncStream won't do here: cancelling a task
    /// that iterates one finishes the stream for good, so a timed-out wait
    /// would break every later wait.)
    final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }

        /// True once the count exceeds `previous`, false after `timeout`.
        func waitForMore(than previous: Int, timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if count > previous { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return count > previous
        }
    }

    @Test func reportsNewFile() async throws {
        let t = try TemporaryFolder()
        let counter = Counter()
        let watcher = try #require(FolderWatcher(folder: t.url, latency: 0.05) { counter.increment() })
        try t.file("new.jpg")
        #expect(await counter.waitForMore(than: 0, timeout: TestTiming.limit(milliseconds: 5000)))
        watcher.stop()
    }

    /// The browser lists one level, so a change inside a subfolder must not
    /// trigger a reload; a change to the folder itself still must.
    @Test func ignoresChangesInsideSubfolders() async throws {
        let t = try TemporaryFolder()
        let sub = try t.folder("sub")
        let counter = Counter()
        let watcher = try #require(FolderWatcher(folder: t.url, latency: 0.05) { counter.increment() })
        // FSEvents may still deliver the creation of "sub" a moment ago,
        // even to a stream started after it. Waiting for the stream to fall
        // quiet, rather than for a fixed time, is what makes the baseline
        // mean anything: a straggler arriving after it would otherwise be
        // read as the subfolder change below.
        var baseline = counter.count
        while await counter.waitForMore(than: baseline, timeout: TestTiming.limit(milliseconds: 300)) {
            baseline = counter.count
        }
        try Data().write(to: sub.appendingPathComponent("deep.jpg"))
        #expect(await !counter.waitForMore(than: baseline, timeout: TestTiming.limit(milliseconds: 1000)))
        try t.file("top.jpg")
        #expect(await counter.waitForMore(than: baseline, timeout: TestTiming.limit(milliseconds: 5000)))
        watcher.stop()
    }

    @Test func noCallbacksAfterStop() async throws {
        let t = try TemporaryFolder()
        let counter = Counter()
        let watcher = try #require(FolderWatcher(folder: t.url, latency: 0.05) { counter.increment() })
        watcher.stop()
        watcher.stop()   // idempotent
        try t.file("after-stop.jpg")
        #expect(await !counter.waitForMore(than: 0, timeout: TestTiming.limit(milliseconds: 700)))
    }

    /// A callback already running when `stop()` is called must finish
    /// before `stop()` returns, or the caller could see it afterwards.
    @Test func stopWaitsForRunningCallback() async throws {
        let t = try TemporaryFolder()
        let started = Counter()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let watcher = try #require(FolderWatcher(folder: t.url, latency: 0.05) {
            started.increment()
            // Long enough that `stop()` below is reached while this is still
            // running, which is the whole point of the test, on a machine
            // that may be slow to get back to it.
            Thread.sleep(forTimeInterval: 0.3 * TestTiming.slack)
            finished.withLock { $0 = true }
        })
        try t.file("slow.jpg")
        #expect(await started.waitForMore(than: 0, timeout: TestTiming.limit(milliseconds: 5000)))
        watcher.stop()
        #expect(finished.withLock { $0 })
    }

    /// Stopping from inside the callback must not deadlock.
    @Test func stopFromInsideCallback() async throws {
        let t = try TemporaryFolder()
        let counter = Counter()
        let box = OSAllocatedUnfairLock<FolderWatcher?>(uncheckedState: nil)
        let watcher = try #require(FolderWatcher(folder: t.url, latency: 0.05) {
            box.withLockUnchecked { $0 }?.stop()
            counter.increment()
        })
        box.withLockUnchecked { $0 = watcher }
        try t.file("stop-inside.jpg")
        #expect(await counter.waitForMore(than: 0, timeout: TestTiming.limit(milliseconds: 5000)))
        box.withLockUnchecked { $0 = nil }
    }

    @Test func stopsWhenReleased() async throws {
        let t = try TemporaryFolder()
        let counter = Counter()
        var watcher = FolderWatcher(folder: t.url, latency: 0.05) { counter.increment() }
        #expect(watcher != nil)
        watcher = nil
        try t.file("after-release.jpg")
        #expect(await !counter.waitForMore(than: 0, timeout: TestTiming.limit(milliseconds: 700)))
    }

    @Test func missingFolderGivesNil() {
        #expect(FolderWatcher(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) {} == nil)
    }
}
