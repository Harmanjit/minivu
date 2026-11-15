import Foundation

/// Runs blocking work (file system calls, decoding, database queries) on a
/// Grand Central Dispatch queue and awaits the result.
///
/// Why not `Task.detached { … }`: detached tasks run on Swift's cooperative
/// thread pool, which has only one thread per CPU core and expects work to
/// suspend rather than block. A few long synchronous jobs (decodes, a colour
/// count, a batch copy) can occupy every thread, and then even a 2 ms folder
/// listing waits behind them — the sidebar feels stuck. GCD's global queues
/// grow threads for blocking work instead, so quick jobs keep flowing.
///
/// Worse than slow, it can deadlock (measured on macOS 27, see
/// docs/feature-notes/coop-starvation.md): a cooperative thread blocked in a
/// wait still holds its place in GCD's per-QoS thread budget, so while every
/// cooperative thread of a QoS is blocked GCD starts no thread for work at
/// that QoS or below. Vision, ImageIO's HEIF and AVIF encoders and
/// AVFoundation's synchronous waits all hand work to a GCD queue at the
/// caller's QoS and wait for it; called from enough cooperative threads at
/// once, that work never starts and nothing returns. Call them only here.
///
/// `run` protects only because its queue's QoS is above the blocked
/// pool's: the default `.userInitiated` is above the default-QoS pool tests
/// and background tasks run on. A `qos:` at or below the QoS of the threads
/// that are blocked protects nothing (`.utility` and `.default` work is
/// starved by a blocked default-QoS pool, measured), and a blocked
/// user-initiated pool (main-actor tasks) starves `.userInitiated` work
/// too. So `run` is not a licence to block the pool elsewhere: the rule
/// is that no cooperative thread waits on these frameworks at all.
///
/// Cancellation of the awaiting task doesn't stop work already running (it
/// can't interrupt a blocking call); callers check for staleness when the
/// result arrives, as they would with a detached task.
public enum BlockingWork {
    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }

    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Checking

    /// True on a thread of Swift's cooperative pool, where a blocking call
    /// risks the deadlock above. GCD names the pool's root queues
    /// "com.apple.root.<qos>.cooperative"; any other thread (the main
    /// thread, a GCD queue, a plain `Thread`) answers false.
    ///
    /// Blind inside `DispatchQueue.concurrentPerform`: every iteration,
    /// including the one on the calling cooperative thread, sees the label
    /// "com.apple.root.<qos>" and answers false. Helpers that fan out that
    /// way call `expectOffCooperativePool` before they fan out.
    public static var isOnCooperativeThread: Bool {
        guard let label = String(validatingCString: __dispatch_queue_get_label(nil)) else { return false }
        return label.hasPrefix("com.apple.root.") && label.hasSuffix(".cooperative")
    }

    /// Called at the top of each synchronous helper that waits on a
    /// framework's own queue (`what` names it). In debug builds a call made
    /// on a cooperative thread is counted and reported once on standard
    /// error, so a caller that forgot `run` shows up in the tests long
    /// before enough of them line up to deadlock; release builds do nothing.
    @inline(__always)
    public static func expectOffCooperativePool(_ what: StaticString) {
        #if DEBUG
        guard isOnCooperativeThread else { return }
        CooperativeCalls.shared.record("\(what)")
        cooperativeCallLog?.append("\(what)")
        #endif
    }

    #if DEBUG
    /// How many times the helper named `what` has been called on a
    /// cooperative thread in this process.
    public static func cooperativeCalls(to what: String) -> Int {
        CooperativeCalls.shared.count(what)
    }

    /// Where a test collects the calls its own task (and that task's
    /// children) made on a cooperative thread, so it can check one code
    /// path without counting what other tests do at the same time.
    @TaskLocal public static var cooperativeCallLog: CallLog?

    public final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        public init() {}

        public var names: [String] { lock.withLock { calls } }

        func append(_ name: String) {
            lock.withLock { calls.append(name) }
        }
    }

    final class CooperativeCalls: @unchecked Sendable {
        static let shared = CooperativeCalls()
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ what: String) {
            let first = lock.withLock { () -> Bool in
                counts[what, default: 0] += 1
                return counts[what] == 1
            }
            if first {
                FileHandle.standardError.write(Data(("minivu: \(what) blocked a cooperative thread; "
                    + "call it through BlockingWork.run\n").utf8))
            }
        }

        func count(_ what: String) -> Int {
            lock.withLock { counts[what, default: 0] }
        }
    }
    #endif
}
