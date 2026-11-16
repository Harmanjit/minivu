import Foundation
import Darwin
import MinivuCore
import AppKit

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

    /// The median of `samples`: the middle one, or the mean of the two
    /// middle ones; 0 when there are none (a recording another suite
    /// emptied, a phase that never ran), rather than a crash.
    static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Prints the metric's line: the median and 90th percentile of `samples`.
    /// No samples is a line of its own saying so, so a metric never goes
    /// missing without a trace.
    static func report(_ suite: String, _ metric: String, _ samples: [Double], _ extra: String = "") {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else {
            print("BENCH-EMPTY \(suite).\(metric) no samples")
            return
        }
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        var line = String(format: "BENCH %@.%@ median_ms=%.2f p90_ms=%.2f runs=%d", suite, metric, median(sorted), p90,
                          sorted.count)
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

    /// Polls `condition` every millisecond until it holds or `seconds` pass,
    /// and says whether it held. Callers `#expect` it: a condition that
    /// never comes true is a failure, not a slow sample.
    static func waitUntil(seconds: Double = 60, isolation: isolated (any Actor)? = #isolation,
                          _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    // MARK: - Windows

    /// One turn of the main queue: whatever was queued before it has run.
    static func mainQueueTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// Lays out and draws `window` now, as the next display cycle would, so
    /// the work a change leaves for the screen falls inside the timed run.
    @MainActor static func display(_ window: NSWindow?) {
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
    }

    // MARK: - Phases

    /// The signposts' recording (`Perf`) over the timed runs only, not the
    /// warm-ups or the setup between them: pass `timing` as a
    /// measurement's `timing` (with a `MainThreadMonitor`'s, if any) and
    /// read `recording` in its `extra`; totals are then over exactly the
    /// timed runs. An interval still running when a run ends is lost, and
    /// one begun in the setup counts if it ends inside a run.
    final class Phases: @unchecked Sendable {
        private(set) var recording = Perf.Recording()

        func timing(_ on: Bool) {
            if on {
                Perf.startRecording()
            } else {
                let run = Perf.stopRecording()
                for (name, durations) in run.durations { recording.durations[name, default: []] += durations }
                for (name, count) in run.counts { recording.counts[name, default: 0] += count }
            }
        }

        /// Milliseconds in intervals named `name`, per run of `runs`.
        func perRun(_ name: String, _ runs: Int) -> Double { recording.total(name) / Double(max(runs, 1)) }

        /// How many intervals named `name` (or events, for a count) per run.
        func countPerRun(_ name: String, _ runs: Int) -> Double {
            Double(recording.durations[name]?.count ?? recording.counts[name] ?? 0) / Double(max(runs, 1))
        }

        /// The median interval named `name`.
        func median(_ name: String) -> Double { Bench.median(recording.durations[name] ?? []) }
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

    // MARK: - The main thread

    /// How long the main thread was kept busy while it ran: a thread of its
    /// own asks the main queue to run an empty block, waits for it, and
    /// sleeps a millisecond, over and over. A block that waited `L` ms means
    /// the main thread was busy for about that long, so the waits of 2 ms
    /// or more are added up. Resolution about a millisecond; a busy spell
    /// shorter than 2 ms is not counted.
    ///
    /// Counts only the timed runs: pass `counting` as a measurement's
    /// `timing`. Each wait is clipped to the timed windows by when the
    /// block was sent and when it ran, so a busy spell that began in the
    /// setup counts only from the run's start, and one still going when the
    /// run ended counts up to its end. The busy time can never exceed the
    /// wall time of the runs.
    final class MainThreadMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        /// The timed windows so far; the last one's end is nil while a run
        /// is being timed.
        private var windows: [(start: ContinuousClock.Instant, end: ContinuousClock.Instant?)] = []
        private var blocked = 0.0, longest = 0.0, stalls = 0

        func counting(_ on: Bool) {
            let now = ContinuousClock.now
            lock.withLock {
                if on {
                    windows.append((now, nil))
                } else if let last = windows.indices.last, windows[last].end == nil {
                    windows[last].end = now
                }
            }
        }

        init() {
            Thread.detachNewThread { [self] in
                let answered = DispatchSemaphore(value: 0)
                while lock.withLock({ running }) {
                    let sent = ContinuousClock.now
                    DispatchQueue.main.async { answered.signal() }
                    answered.wait()
                    let ran = ContinuousClock.now
                    if Bench.milliseconds(ran - sent) >= 2 { add(sent: sent, ran: ran) }
                    usleep(1000)
                }
            }
        }

        /// Adds the part of one busy spell inside the timed windows.
        private func add(sent: ContinuousClock.Instant, ran: ContinuousClock.Instant) {
            lock.withLock {
                var inside = 0.0
                for window in windows.reversed() {
                    let end = min(window.end ?? ran, ran)
                    if end <= sent { break }
                    let start = max(window.start, sent)
                    if end > start { inside += Bench.milliseconds(end - start) }
                }
                guard inside > 0 else { return }
                blocked += inside
                longest = max(longest, inside)
                stalls += 1
            }
        }

        /// Stops watching: the busy time in all, the longest spell, and
        /// how many spells there were.
        func stop() -> (blocked: Double, longest: Double, stalls: Int) {
            lock.withLock {
                running = false
                return (blocked, longest, stalls)
            }
        }

        /// The same as `key=value` pairs for a BENCH line: the busy time and
        /// spells per run, and the longest spell of all.
        func stopText(runs: Int) -> String {
            let main = stop()
            let n = Double(max(runs, 1))
            return String(format: "main_blocked_ms=%.1f main_longest_ms=%.1f main_stalls=%.1f", main.blocked / n,
                          main.longest, Double(main.stalls) / n)
        }
    }
}
