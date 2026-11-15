import Testing
import Foundation
import CoreGraphics
import MinivuTestWatchdog
@testable import MinivuCore

/// The deadlock that hung the whole MinivuCoreTests run on macOS 27 (see
/// docs/feature-notes/coop-starvation.md): a cooperative thread blocked in a
/// wait keeps its place in GCD's thread budget for its QoS, so once every
/// cooperative thread of a QoS is blocked, GCD starts no thread for work at
/// that QoS or below — and Vision and ImageIO's HEIF and AVIF encoders wait
/// for exactly such work. `BlockingWork` keeps those calls off the pool.
///
/// No test in a run can catch that run hanging: once the pool is starved
/// no test gets a thread, its own watchdog included. What catches it is the
/// MinivuTestWatchdog target's watchdog, started when the test bundle loads
/// on a plain thread of its own; these tests check that it is running and
/// that its check sees a starved pool, and guard the pieces the app's
/// protection is built from.
@Suite(.serialized) struct CooperativeStarvationTests {
    static var width: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// The watchdog started when the bundle loaded, before any test ran,
    /// with the limit its header documents.
    @Test func theRunWatchdogStartedWhenTheTestsLoaded() throws {
        if ProcessInfo.processInfo.environment["MINIVU_TEST_WATCHDOG"] != nil {
            try Test.cancel("MINIVU_TEST_WATCHDOG is set for this run, so the watchdog's limit is the caller's")
        }
        #expect(minivu_test_watchdog_is_running())
        #expect(minivu_test_watchdog_stall_limit() == 30 * TestTiming.slack)
    }

    /// The watchdog's check fails in the hung run's state, every
    /// default-QoS cooperative thread blocked, and passes once the pool is
    /// free: so a starved run ends at the watchdog's limit.
    @Test func theWatchdogsCheckSeesAStarvedPool() async throws {
        let (held, starved) = await PoolHold.whileHeld(holders: Self.width) { _ in
            minivu_test_default_queue_runs_within(1)
        }
        let recovered = await PoolHold.onPlainThread {
            minivu_test_default_queue_runs_within(TestTiming.patience(seconds: 5).timeIntervalSinceNow)
        }
        #expect(recovered)
        guard held == Self.width else {
            try Test.cancel("only \(held) of \(Self.width) cooperative threads could be held beside other tests")
        }
        #expect(!starved, "a default-QoS item ran while every default-QoS cooperative thread was blocked")
    }

    /// The protection the app relies on: with every default-QoS cooperative
    /// thread blocked, more AVIF encodes and feature prints than the pool
    /// has threads still finish through `BlockingWork`, because its queue's
    /// QoS is above the blocked pool's. Lowered to the pool's QoS they
    /// never start: the watchdog lets the pool go at the deadline, the test
    /// fails and the run carries on. (It can't catch a test that blocks the
    /// pool itself; that is the run watchdog's job.)
    @Test func blockingWorkFinishesWhileEveryCooperativeThreadIsBlocked() async throws {
        let image = TestImages.gradient(width: 256, height: 192)
        let encoded: ExportFormat = ExportFormat.avif.isWritable ? .avif : .heic
        // Other suites' tests may hold some of the pool's threads for a
        // while; with fewer than all of them blocked, GCD still starts
        // default-QoS work and the test would prove nothing, so it tries
        // again, and is skipped if it never manages.
        var outcome: PoolHold.Outcome
        var attempt = 0
        repeat {
            attempt += 1
            outcome = await PoolHold.run(holders: Self.width, jobs: 2 * Self.width) { index in
                if index.isMultiple(of: 2) {
                    _ = try? ImageEncoder.encode(image, options: .defaults(for: encoded), metadataSource: nil)
                } else {
                    _ = FeaturePrint.make(from: image)
                }
            }
        } while outcome.held < Self.width && outcome.finishedInTime && attempt < 3
        if !outcome.finishedInTime {
            Issue.record("""
                \(outcome.finished) of \(outcome.jobs) encodes and feature prints finished while \(outcome.held) \
                cooperative threads were blocked: the work waits on the cooperative pool again
                """)
        } else if outcome.held < Self.width {
            try Test.cancel("only \(outcome.held) of \(Self.width) cooperative threads could be held beside other tests")
        }
    }

    /// The check the app's audit relies on: Vision called straight from
    /// a task is on a cooperative thread and is logged; the same call
    /// through `BlockingWork` is not.
    @Test func directCallsFromATaskAreLoggedAndBlockingWorkCallsAreNot() async {
        let image = TestImages.gradient(width: 64, height: 48)
        #expect(BlockingWork.isOnCooperativeThread)
        #expect(await BlockingWork.run { BlockingWork.isOnCooperativeThread } == false)

        let direct = BlockingWork.CallLog()
        await BlockingWork.$cooperativeCallLog.withValue(direct) {
            _ = await Task { FeaturePrint.make(from: image) }.value
        }
        #expect(direct.names == ["FeaturePrint.make(from:)"])

        let routed = BlockingWork.CallLog()
        await BlockingWork.$cooperativeCallLog.withValue(routed) {
            _ = await BlockingWork.run { FeaturePrint.make(from: image) }
            _ = try? await BlockingWork.run { try ImageEncoder.encode(image, options: .defaults(for: .heic), metadataSource: nil) }
        }
        #expect(routed.names.isEmpty, "\(routed.names)")
    }

    /// Inside `concurrentPerform` every thread, the calling cooperative one
    /// included, carries a plain GCD label, so the check can't see the
    /// caller there. The helpers that fan out that way check before they
    /// fan out; called from a task they are reported.
    @Test func fanOutHelpersAreReportedBeforeTheyFanOut() async {
        let insideFanOut = await Task {
            let seen = Locked(false)
            DispatchQueue.concurrentPerform(iterations: 1) { _ in seen.value = BlockingWork.isOnCooperativeThread }
            return seen.value
        }.value
        #expect(!insideFanOut, "the label check sees through concurrentPerform now; the note in BlockingWork is stale")

        let log = BlockingWork.CallLog()
        await BlockingWork.$cooperativeCallLog.withValue(log) {
            _ = await Task {
                _ = DuplicateFinder.featurePrints(for: [], store: nil)
                _ = RenameSource.withImageMetadata([])
            }.value
        }
        #expect(log.names == ["DuplicateFinder.featurePrints(for:)", "RenameSource.withImageMetadata(_:)"])

        let routed = BlockingWork.CallLog()
        await BlockingWork.$cooperativeCallLog.withValue(routed) {
            _ = await BlockingWork.run {
                _ = DuplicateFinder.featurePrints(for: [], store: nil)
                _ = RenameSource.withImageMetadata([])
            }
        }
        #expect(routed.names.isEmpty, "\(routed.names)")
    }
}

/// A value shared with the threads of a fan-out.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds Swift's cooperative threads blocked while jobs run through
/// `BlockingWork`, with a watchdog on a plain thread (not in the pool) that
/// lets them go by a deadline whatever happens.
///
/// Late jobs are a failure the test reports once the pool is free again.
/// If the pool never comes back (the jobs themselves blocked on it, which
/// nothing outside can undo), the watchdog stops the process with the
/// reason rather than leave the run hanging at 0% CPU.
enum PoolHold {
    struct Outcome {
        var jobs: Int
        var held: Int
        var finished: Int
        var finishedInTime: Bool { finished == jobs }
    }

    /// - Parameters:
    ///   - holders: cooperative threads to block, at the priority Swift
    ///     Testing runs tests at (the default QoS).
    ///   - jobs: `work` calls, each through `BlockingWork.run`, all started
    ///     together once the pool is held.
    static func run(holders: Int, jobs: Int, seconds: Double = 10,
                    work: @escaping @Sendable (Int) -> Void) async -> Outcome {
        let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        // The jobs first, so each is queued on GCD before the pool is taken;
        // they wait there (on GCD threads) for the signal to start.
        let tasks = (0..<jobs).map { index in
            Task {
                await BlockingWork.run {
                    entered.signal()
                    go.wait()
                    work(index)
                    finished.signal()
                }
            }
        }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            Thread {
                let soon = DispatchTime.now() + 10
                for _ in 0..<jobs { _ = entered.wait(timeout: soon) }
                for _ in 0..<holders {
                    Task.detached(priority: .medium) {
                        holding.signal()
                        block(release)
                    }
                }
                // Other suites' tests may have threads of their own for a
                // while; what can be held in a few seconds is held.
                var held = 0
                let holdBy = DispatchTime.now() + 5
                while held < holders, holding.wait(timeout: holdBy) == .success { held += 1 }
                for _ in 0..<jobs { go.signal() }
                var done = 0
                let deadline = TestTiming.patience(seconds: seconds)
                while done < jobs, finished.wait(wallTimeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success {
                    done += 1
                }
                for _ in 0..<holders { release.signal() }
                continuation.resume(returning: Outcome(jobs: jobs, held: held, finished: done))
                if done < jobs, resumed.wait(timeout: .now() + 30) == .timedOut {
                    fatalError("""
                        The cooperative pool is deadlocked: \(done) of \(jobs) jobs finished and the test \
                        can't resume. Blocking work is running on the pool again (see \
                        docs/feature-notes/coop-starvation.md).
                        """)
                }
            }.start()
        }
        resumed.signal()
        // Starved work finishes once the pool is let go; wait for it only
        // when it already has, so a real hang can't hold the run.
        if outcome.finishedInTime {
            for task in tasks { await task.value }
        }
        return outcome
    }

    /// Runs `body` on a plain thread while up to `holders` default-QoS
    /// cooperative threads are blocked, and returns how many were held (what
    /// could be held in a few seconds beside other tests) with its result.
    static func whileHeld<T: Sendable>(holders: Int,
                                       _ body: @escaping @Sendable (_ held: Int) -> T) async -> (held: Int, result: T) {
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        return await withCheckedContinuation { continuation in
            Thread {
                for _ in 0..<holders {
                    Task.detached(priority: .medium) {
                        holding.signal()
                        block(release)
                    }
                }
                var held = 0
                let holdBy = DispatchTime.now() + 5
                while held < holders, holding.wait(timeout: holdBy) == .success { held += 1 }
                let result = body(held)
                for _ in 0..<holders { release.signal() }
                continuation.resume(returning: (held, result))
            }.start()
        }
    }

    /// Runs `body` on a plain thread, outside the pool and GCD.
    static func onPlainThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    /// A plain wait, kept out of the async closure that calls it.
    static func block(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }
}
