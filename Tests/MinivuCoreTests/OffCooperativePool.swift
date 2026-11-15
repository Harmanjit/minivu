import Testing
import Foundation
import MinivuCore

/// Runs a suite's tests on GCD threads instead of Swift's cooperative pool,
/// for suites whose tests (or the fixtures they write) call Vision, HEIF or
/// AVIF encoding or AVFoundation's synchronous waits directly.
///
/// Swift Testing runs every test body on the cooperative pool, ten threads
/// on a ten-core Mac. Those frameworks hand their work to a GCD queue at the
/// caller's QoS and wait for it, and GCD starts no thread for that work
/// while every cooperative thread of the QoS is blocked: ten such tests at
/// once and the whole run hangs at 0% CPU (measured on macOS 27, see
/// docs/feature-notes/coop-starvation.md). The app routes these calls
/// through `BlockingWork`; tests that call the synchronous helpers on
/// purpose, or write HEIC fixtures, run here instead, which is
/// `BlockingWork` for a whole test: GCD grows threads for blocked work.
///
/// Structured child tasks (`async let`, task groups) inherit the executor;
/// main-actor code still runs on the main thread.
struct OffCooperativePool: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // Only around each test case: the suite-level scope would just nest.
        guard testCase != nil else { return try await function() }
        try await withTaskExecutorPreference(GCDTaskExecutor.shared) {
            try await function()
        }
    }
}

extension Trait where Self == OffCooperativePool {
    static var offCooperativePool: Self { Self() }
}

/// A task executor that runs jobs on GCD threads at the default QoS (the
/// QoS Swift Testing runs tests at), as many at once as the Mac has cores:
/// the parallelism the cooperative pool gave these suites, without letting
/// a hundred parameterised cases render at once. Its threads are ordinary
/// GCD workers, so one blocked in a framework's wait doesn't stop GCD
/// starting the thread that framework is waiting for.
final class GCDTaskExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = GCDTaskExecutor()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "minivu.tests.off-cooperative-pool"
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        queue.qualityOfService = .default
        return queue
    }()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.addOperation { job.runSynchronously(on: executor) }
    }
}
