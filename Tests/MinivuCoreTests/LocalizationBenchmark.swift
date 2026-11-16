import Testing
import Foundation
@testable import MinivuCore

extension Benchmarks {
    /// `Bundle.localizedText`, which the viewer's chrome calls several times
    /// on every zoom step of a pinch. Each metric is 1,000 lookups, so its
    /// median in ms is the cost of one lookup in µs.
    @Suite(.serialized) struct LocalizationBenchmark {
        static let calls = 1_000

        func measure(_ metric: String, _ lookup: () -> String) throws {
            var sink = 0
            try Bench.measure("l10n", metric, extra: "calls=\(Self.calls) unit=us_per_call") {
                for _ in 0..<Self.calls { sink &+= lookup().utf8.count }
            }
            #expect(sink > 0)
        }

        @Test(.enabled(if: Bench.enabled)) func lookups() throws {
            var n = 0
            try measure("literal") { localized("Red") }
            try measure("interpolated") { n += 1; return localized("\(n % 16) bits per channel") }
            try measure("keyed") { localized(.init("metadata.hemisphere.north", defaultValue: "N", comment: "Compass point")) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-bench-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let lproj = folder.appendingPathComponent("en.lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try #""status.count" = "%lld pictures";"#.write(to: lproj.appendingPathComponent("Localizable.strings"),
                                                           atomically: true, encoding: .utf8)
            let bundle = try #require(Bundle(url: folder))
            try measure("keyedInterpolated") {
                n += 1
                return bundle.localizedText(.init("status.count", defaultValue: "\(n) images"))
            }
        }
    }
}
