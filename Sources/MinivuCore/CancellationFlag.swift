import Foundation

/// A flag a long job checks between steps; set from any thread. Contact
/// sheets, montages and the multi-page tools check it between pages, so
/// Cancel stops a job at the next page rather than at its end.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}
