import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

extension Benchmarks {
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
            #expect((cold.durations["thumb.diskLockWait"]?.count ?? 0) >= 1)
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

        /// Find's filter times itself and each header it reads, and the
        /// catalog's cache, so the cold and cached runs can be told apart.
        /// At least: other suites may read headers while this one records.
        @Test func findReadsAreSignposted() throws {
            let folder = try TemporaryFolder()
            let url = TestImages.write(TestImages.gradient(width: 800, height: 600),
                                       to: folder.url.appendingPathComponent("photo.jpg"))
            let entry = try #require(FolderEntry(url: url))
            var criteria = MetadataCriteria()
            criteria.minimumWidth = 500
            let query = SearchQuery(scope: folder.url, criteria: criteria)
            let catalog = Catalog.inMemory()
            Perf.startRecording()
            let found = ImageSearch.filter([entry], query: query, catalog: catalog)
            let cold = Perf.stopRecording()
            #expect(found == [entry])
            #expect((cold.durations["search.filter"]?.count ?? 0) >= 1)
            #expect((cold.durations["filter.metadataRead"]?.count ?? 0) >= 1)
            #expect((cold.durations["filter.metadataStore"]?.count ?? 0) >= 1)
            Perf.startRecording()
            _ = ImageSearch.filter([entry], query: query, catalog: catalog)
            let cached = Perf.stopRecording()
            #expect((cached.durations["filter.metadataCached"]?.count ?? 0) >= 1)
        }

        /// Find Duplicates times each hash and print, and the thumbnail
        /// store its prune and the prune's scan.
        @Test func duplicatesAndPruneAreSignposted() throws {
            let folder = try TemporaryFolder()
            let a = TestImages.write(TestImages.gradient(width: 200, height: 100), to: folder.url.appendingPathComponent("a.jpg"))
            let b = folder.url.appendingPathComponent("b.jpg")
            try FileManager.default.copyItem(at: a, to: b)
            let entries = try [a, b].map { try #require(FolderEntry(url: $0)) }
            let store = try ThumbnailStore.inMemory()
            Perf.startRecording()
            let groups = DuplicateFinder.exactGroups(in: entries, cache: store)
            _ = DuplicateFinder.featurePrints(for: entries, store: store, make: { _, _ in nil })
            store.prune(maxBytes: 1_000_000)
            let recording = Perf.stopRecording()
            #expect(groups.count == 1)
            #expect((recording.durations["duplicates.hash"]?.count ?? 0) >= 2)
            #expect((recording.durations["duplicates.print"]?.count ?? 0) >= 2)
            #expect((recording.durations["thumb.prune"]?.count ?? 0) >= 1)
            #expect((recording.durations["thumb.pruneTotal"]?.count ?? 0) >= 1)
        }
    }
}
