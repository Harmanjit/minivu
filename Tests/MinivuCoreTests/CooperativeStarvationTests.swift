import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

/// The deadlock that hung the whole MinivuCoreTests run on macOS 27 (see
/// docs/feature-notes/coop-starvation.md): a cooperative thread blocked in a
/// wait keeps its place in GCD's thread budget for its QoS, so once every
/// cooperative thread of a QoS is blocked, GCD starts no thread for work at
/// that QoS or below — and Vision and ImageIO's HEIF and AVIF encoders wait
/// for exactly such work. `BlockingWork` keeps those calls off the pool.
@Suite(.serialized) struct CooperativeStarvationTests {
    static var width: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// The state the hung run was in: every cooperative thread at the tests'
    /// QoS blocked, and more AVIF encodes and feature prints waiting than the
    /// pool has threads. Through `BlockingWork` they all finish. Should they
    /// ever depend on the held pool again, the watchdog lets the pool go at
    /// the deadline: the test fails and the run carries on.
    @Test func blockingWorkFinishesWhileEveryCooperativeThreadIsBlocked() async {
        let image = TestImages.gradient(width: 256, height: 192)
        let encoded: ExportFormat = ExportFormat.avif.isWritable ? .avif : .heic
        let outcome = await PoolHold.run(holders: Self.width, jobs: 2 * Self.width) { index in
            if index.isMultiple(of: 2) {
                _ = try? ImageEncoder.encode(image, options: .defaults(for: encoded), metadataSource: nil)
            } else {
                _ = FeaturePrint.make(from: image)
            }
        }
        #expect(outcome.held > 0, "no cooperative thread could be held")
        if !outcome.finishedInTime {
            Issue.record("""
                \(outcome.finished) of \(outcome.jobs) encodes and feature prints finished while \(outcome.held) \
                cooperative threads were blocked: the work waits on the cooperative pool again
                """)
        }
    }

    #if DEBUG
    /// The check the regression test relies on: Vision called straight from
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
    #endif
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

    /// A plain wait, kept out of the async closure that calls it.
    static func block(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }
}
