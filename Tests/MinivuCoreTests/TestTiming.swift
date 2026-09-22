import Foundation

/// How much longer than a quiet Mac this run is allowed to take.
///
/// The suite drives real windows, decodes and GPU work, and Swift Testing
/// runs its suites side by side, so on a loaded machine a viewer can take
/// many seconds to open that takes a tenth of one when nothing else runs.
/// Limits written for a quiet Mac then fail for no reason anybody can act
/// on. Every wall-clock limit and every wait in the suite is multiplied by
/// this one number instead of each being guessed at separately, and
/// `MINIVU_TEST_SLACK` raises it where the machine is shared, as it is on a
/// continuous integration runner.
///
/// A debug build is several times slower than a release one, which is what
/// the default covers; the limits themselves are written for release.
enum TestTiming {
    static let slack: Double = {
        if let text = ProcessInfo.processInfo.environment["MINIVU_TEST_SLACK"],
           let given = Double(text), given > 0 { return given }
        #if DEBUG
        return 4
        #else
        return 1
        #endif
    }()

    /// A limit in milliseconds, stretched to what this machine may take.
    static func limit(milliseconds: Double) -> Duration {
        .milliseconds(milliseconds * slack)
    }

    /// How long to wait for something the app does in the background. The
    /// wait is generous on purpose: it costs nothing when the condition
    /// comes true at once, and a timeout here is a test failure that says
    /// nothing useful, so it should only be reached when the work really is
    /// never going to happen.
    static func patience(seconds: Double = 10) -> Date {
        Date().addingTimeInterval(seconds * slack)
    }
}

extension TestTiming {
    /// Polls `condition` until it holds or the patience runs out. Nothing
    /// in these targets is main-actor isolated, so this one is not either.
    static func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async {
        let end = patience(seconds: seconds)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
