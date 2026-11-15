import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

/// The signposts' in-memory recording, which the benchmarks read
/// (docs/feature-notes/perf.md). Serialized: a recording is process-wide.
@Suite(.serialized) struct PerfTests {
    @Test func recordsIntervalsAndCountsOnlyWhileRecording() async {
        Perf.measure("perfTest.outside") {}
        Perf.startRecording()
        Perf.measure("perfTest.interval") { usleep(2000) }
        let interval = Perf.begin("perfTest.interval")
        interval.end()
        await Perf.measure("perfTest.async") { try? await Task.sleep(for: .milliseconds(1)) }
        Perf.count("perfTest.count")
        Perf.count("perfTest.count")
        let recording = Perf.stopRecording()
        Perf.count("perfTest.count")

        #expect(recording.durations["perfTest.outside"] == nil)
        #expect(recording.durations["perfTest.interval"]?.count == 2)
        #expect((recording.durations["perfTest.interval"]?.first ?? 0) >= 2)
        #expect(recording.total("perfTest.async") >= 1)
        #expect(recording.counts["perfTest.count"] == 2)
        // Stopped means stopped: nothing is kept until the next start.
        #expect(Perf.stopRecording().counts.isEmpty)
    }

    @Test func launchTimeIsSinceTheProcessStarted() throws {
        let elapsed = try #require(Perf.millisecondsSinceProcessStart())
        // The test runner has been running for a while, and not for a day.
        #expect(elapsed > 0 && elapsed < 24 * 3600 * 1000)
    }

    /// A thumbnail made from the file shows its decode, encode and store
    /// write; the same thumbnail again, from the store, the read. At least
    /// once rather than once: other suites run beside this one and may make
    /// thumbnails of their own while it records.
    @Test func thumbnailPhasesAreSignposted() async throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(TestImages.gradient(width: 800, height: 600),
                                   to: folder.url.appendingPathComponent("photo.jpg"))
        let entry = try #require(FolderEntry(url: url))
        let store = try ThumbnailStore.inMemory()
        func thumbnail(_ service: ThumbnailService) async -> CGImage? {
            await withCheckedContinuation { done in service.request(entry, pixelSize: 256) { done.resume(returning: $0) } }
        }

        Perf.startRecording()
        _ = await thumbnail(ThumbnailService(store: store))
        let cold = Perf.stopRecording()
        #expect((cold.durations["thumb.decode"]?.count ?? 0) >= 1)
        #expect((cold.durations["thumb.encode"]?.count ?? 0) >= 1)
        #expect((cold.durations["thumb.storeWrite"]?.count ?? 0) >= 1)
        #expect((cold.counts["file.open"] ?? 0) >= 1)

        Perf.startRecording()
        _ = await thumbnail(ThumbnailService(store: store))
        let warm = Perf.stopRecording()
        #expect((warm.durations["thumb.storeRead"]?.count ?? 0) >= 1)
    }

    /// Reading a folder's marks and healing it are timed in the catalog.
    @Test func catalogReadsAreSignposted() throws {
        let folder = try TemporaryFolder()
        let file = try folder.file("a.jpg")
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [file])
        Perf.startRecording()
        _ = catalog.marks(for: [file])
        catalog.heal(folder: folder.url)
        let recording = Perf.stopRecording()
        #expect((recording.durations["catalog.marks"]?.count ?? 0) >= 1)
        #expect((recording.durations["catalog.heal"]?.count ?? 0) >= 1)
    }
}
