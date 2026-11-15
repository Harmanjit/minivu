import Foundation
import Darwin

/// What the benchmark suites share (docs/feature-notes/perf.md). The same
/// helper is in MinivuRenderTests and MinivuTests (a test target can't share
/// files); keep the three alike.
///
/// Gating, as for the older benchmarks: MINIVU_BENCH=1 runs the synthetic
/// ones, which make their own files in a scratch folder under the temporary
/// directory; MINIVU_BENCH_DIR names a folder of real photos, which also
/// turns the synthetic ones on. That folder is only ever read: anything a
/// benchmark writes, it writes to a clone in its scratch folder.
///
/// MINIVU_BENCH_QUICK=1 runs every benchmark small and twice, to show it
/// works (a debug build, a busy machine); its numbers mean nothing.
///
/// Every metric is one line on stdout, which `scripts/bench.sh` collects:
///     BENCH <suite>.<metric> median_ms=<x> p90_ms=<y> runs=<n> [key=value ...]
enum Bench {
    static let environment = ProcessInfo.processInfo.environment

    /// Real photos, read only.
    static let folder: URL? = environment["MINIVU_BENCH_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    static let enabled = environment["MINIVU_BENCH"] != nil || folder != nil
    static let quick = environment["MINIVU_BENCH_QUICK"] != nil

    /// Timed runs after the warm-up: at least five, two when quick.
    static func runs(_ wanted: Int = 7) -> Int { quick ? 2 : max(wanted, 5) }

    /// A size for the real run, and a small one for a quick run.
    static func size(_ full: Int, quick small: Int) -> Int { quick ? small : full }

    // MARK: - Photos

    /// The first file in the photo folder with one of `names`, else the
    /// first (by name) with one of `extensions`, not looking in subfolders.
    static func photo(named names: [String] = [], extensions: [String]) -> URL? {
        guard let folder else { return nil }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for name in names {
            if let found = files.first(where: { $0.lastPathComponent == name }) { return found }
        }
        return files.first { extensions.contains($0.pathExtension.lowercased()) }
    }

    /// The 24 MP JPEG, HEIC and NEF of the test assets, or the nearest the
    /// folder has.
    static var jpeg: URL? { photo(named: ["HSB_6548.jpg"], extensions: ["jpg", "jpeg"]) }
    static var heic: URL? { photo(named: ["HSB_6548.heic"], extensions: ["heic"]) }
    static var nef: URL? { photo(named: ["HSB_6548.NEF"], extensions: ["nef"]) }

    /// `count` clones of `source` in `folder` (APFS clones: no data copied,
    /// the original untouched), named `prefix-0001.ext` and so on.
    static func clones(of source: URL, count: Int, in folder: URL, prefix: String = "photo") throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { i in
            let url = folder.appendingPathComponent(String(format: "%@-%04d.%@", prefix, i, source.pathExtension))
            try FileManager.default.copyItem(at: source, to: url)
            return url
        }
    }

    // MARK: - Timing

    static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Prints the metric's line: the median and 90th percentile of `samples`.
    static func report(_ suite: String, _ metric: String, _ samples: [Double], _ extra: String = "") {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return }
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        var line = String(format: "BENCH %@.%@ median_ms=%.2f p90_ms=%.2f runs=%d", suite, metric, median, p90, sorted.count)
        if !extra.isEmpty { line += " " + extra }
        print(line)
    }

    /// Runs `body` `warmups` times untimed, then `runs` times timed, and
    /// reports the timed runs. `setup` runs before every run, untimed.
    /// `timing` is told when each timed run starts (true) and ends (false),
    /// for a watcher that should count only those (`MainThreadMonitor`).
    @discardableResult
    static func measure(_ suite: String, _ metric: String, warmups: Int = 1, runs: Int = runs(),
                        extra: @autoclosure () -> String = "", setup: () throws -> Void = {},
                        timing: (Bool) -> Void = { _ in }, _ body: () throws -> Void) throws -> [Double] {
        for _ in 0..<warmups { try setup(); try body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            try setup()
            timing(true)
            let start = ContinuousClock.now
            try body()
            samples.append(milliseconds(ContinuousClock.now - start))
            timing(false)
        }
        report(suite, metric, samples, extra())
        return samples
    }

    @discardableResult
    static func measure(_ suite: String, _ metric: String, warmups: Int = 1, runs: Int = runs(),
                        extra: @autoclosure () -> String = "", isolation: isolated (any Actor)? = #isolation,
                        setup: () async throws -> Void = {}, timing: (Bool) -> Void = { _ in },
                        _ body: () async throws -> Void) async throws -> [Double] {
        for _ in 0..<warmups { try await setup(); try await body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            try await setup()
            timing(true)
            let start = ContinuousClock.now
            try await body()
            samples.append(milliseconds(ContinuousClock.now - start))
            timing(false)
        }
        report(suite, metric, samples, extra())
        return samples
    }

    /// Polls `condition` every millisecond until it holds or `seconds` pass.
    static func waitUntil(seconds: Double = 60, isolation: isolated (any Actor)? = #isolation,
                          _ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Memory

    /// The process's physical footprint in bytes, as Activity Monitor's
    /// Memory column and Xcode's memory gauge count it.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    /// Samples the footprint every few milliseconds on a thread of its own
    /// and keeps the highest, from creation until `stop`.
    final class FootprintPeak: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64
        private var running = true
        let start: UInt64

        init() {
            start = Bench.footprint()
            peak = start
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let now = Bench.footprint()
                    lock.withLock { peak = max(peak, now) }
                    usleep(5000)
                }
            }
        }

        /// Stops sampling: (start, end, peak) in MB.
        func stop() -> (start: Double, end: Double, peak: Double) {
            let end = Bench.footprint()
            let peak = lock.withLock { running = false; return max(self.peak, end) }
            return (Bench.megabytes(start), Bench.megabytes(end), Bench.megabytes(peak))
        }
    }
}
