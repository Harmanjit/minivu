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
}
