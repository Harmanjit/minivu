import Foundation
import os
import Synchronization

/// Signposts for measuring where the time goes (docs/feature-notes/perf.md).
///
/// Every interval is an `OSSignposter` interval in the subsystem
/// `com.minivu.app`, category `perf`, so Instruments (the os_signpost and
/// Points of Interest tracks) shows the phases of each user-facing operation
/// on the threads that ran them. A signposter that nobody is recording costs
/// a flag check per call, so the intervals stay in release builds.
///
/// Benchmarks need the same phases without Instruments: between
/// `startRecording()` and `stopRecording()` every interval's duration and
/// every `count` is also kept in memory. Outside a recording the only cost is
/// one atomic load.
///
/// Names are a dotted phase, the operation first: `folder.heal`,
/// `thumb.decode`, `viewer.upload`. One name per phase, never one per file,
/// so a trace groups them.
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "com.minivu.app", category: "perf")

    /// MINIVU_TRACE is set: launch milestones are also printed to stderr.
    static let traces = ProcessInfo.processInfo.environment["MINIVU_TRACE"] != nil

    // MARK: - Intervals

    /// One phase in progress. End it exactly once, on any thread.
    public struct Interval: @unchecked Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant?

        public func end() {
            Perf.signposter.endInterval(name, state)
            if let start { Perf.record(name, ContinuousClock.now - start) }
        }
    }

    public static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name),
                 start: isRecording.load(ordering: .relaxed) ? ContinuousClock.now : nil)
    }

    /// Runs `body` inside an interval named `name`.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try body()
    }

    /// Runs `body` inside an interval named `name`, suspensions included.
    @discardableResult
    public static func measure<T>(_ name: StaticString, isolation: isolated (any Actor)? = #isolation,
                                  _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try await body()
    }

    /// A moment worth marking on the timeline, and counted while recording:
    /// a file header opened, a catalog notification posted.
    public static func count(_ name: StaticString) {
        signposter.emitEvent(name)
        guard isRecording.load(ordering: .relaxed) else { return }
        recording.withLock { $0?.counts[String(describing: name), default: 0] += 1 }
    }

    // MARK: - Launch

    /// A launch milestone: an event on the timeline and, with MINIVU_TRACE
    /// set, a line on stderr with the time since the process started, so a
    /// launch can be timed without Instruments.
    public static func milestone(_ name: StaticString) {
        signposter.emitEvent(name)
        guard traces else { return }
        let elapsed = millisecondsSinceProcessStart().map { String(format: "%.1f ms", $0) } ?? "?"
        FileHandle.standardError.write(Data("launch: \(name) at \(elapsed)\n".utf8))
    }

    /// Since the kernel started this process, so dyld and everything before
    /// `main` is counted too.
    static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - started.tv_sec) * 1000 + Double(now.tv_usec - started.tv_usec) / 1000
    }

    // MARK: - Recording

    /// What happened between `startRecording` and `stopRecording`.
    public struct Recording: Sendable {
        /// Every interval's duration in milliseconds, by name, in the order
        /// they ended.
        public var durations: [String: [Double]] = [:]
        public var counts: [String: Int] = [:]

        /// Total milliseconds spent in intervals named `name`.
        public func total(_ name: String) -> Double { durations[name]?.reduce(0, +) ?? 0 }
    }

    private static let isRecording = Atomic<Bool>(false)
    private static let recording = Mutex<Recording?>(nil)

    /// Starts keeping intervals and counts in memory, forgetting any earlier
    /// recording. For benchmarks; the app never records.
    public static func startRecording() {
        recording.withLock { $0 = Recording() }
        isRecording.store(true, ordering: .relaxed)
    }

    @discardableResult
    public static func stopRecording() -> Recording {
        isRecording.store(false, ordering: .relaxed)
        return recording.withLock { taken in
            defer { taken = nil }
            return taken ?? Recording()
        }
    }

    private static func record(_ name: StaticString, _ elapsed: Duration) {
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        recording.withLock { $0?.durations[String(describing: name), default: []].append(ms) }
    }
}
