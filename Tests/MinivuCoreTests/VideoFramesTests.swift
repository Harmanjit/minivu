import Testing
import Foundation
import CoreGraphics
@testable import MinivuCore

/// Videos among the photos (G18): which files count, what is read from
/// them, their thumbnails and the viewer's first frame. Every movie is made
/// by the test (`TestVideos`), silent, and never played.
///
/// The readers block on AVFoundation and are meant for GCD threads, so the
/// tests call them through `BlockingWork`, as the app does.
@Suite struct VideoFramesTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    @Test func recognisesTheCommonMovieTypesAndNothingElse() {
        for ext in ["mov", "mp4", "m4v"] {
            #expect(ImageFormats.videoExtensions.contains(ext))
            #expect(ImageFormats.kind(of: URL(fileURLWithPath: "/x/clip.\(ext.uppercased())")) == .video)
        }
        // AVFoundation reports these, but they are subtitles, audio, a
        // container it rarely plays, and in most folders TypeScript.
        for ext in ["ts", "vtt", "mpa", "avi", "scc"] {
            #expect(ImageFormats.kind(of: URL(fileURLWithPath: "/x/file.\(ext)")) == nil)
        }
        #expect(ImageFormats.videoExtensions.isSubset(of: ImageFormats.videoCandidates))
        #expect(ImageFormats.allExtensions.isSuperset(of: ImageFormats.videoExtensions))
        #expect(ImageFormats.isVideo(URL(fileURLWithPath: "/x/a.mov")))
        #expect(!ImageFormats.isVideo(URL(fileURLWithPath: "/x/a.jpg")))
    }

    @Test func listingShowsVideosAmongThePhotos() throws {
        for name in ["a.jpg", "b.mov", "c.MP4", "d.m4v", "e.ts", "f.txt"] { try folder.file(name) }
        let contents = try FolderListing.contents(of: folder.url)
        let kinds = Dictionary(uniqueKeysWithValues: contents.images.map { ($0.name, $0.kind) })
        #expect(kinds == ["a.jpg": .raster, "b.mov": .video, "c.MP4": .video, "d.m4v": .video])
    }

    @Test func readsSizeLengthAndOrientation() async throws {
        let landscape = try await TestVideos.make(at: folder.url.appendingPathComponent("wide.mov"), seconds: 3)
        let portrait = try await TestVideos.make(at: folder.url.appendingPathComponent("tall.mp4"), seconds: 2,
                                                 portrait: true)
        let wide = try #require(await BlockingWork.run { VideoFrames.info(for: landscape) })
        #expect(wide.pixelSize == CGSize(width: 160, height: 96))
        #expect(abs(wide.duration - 3) < 0.05)
        #expect(wide.isPlayable)
        #expect(!wide.hasAudio)
        #expect(!wide.isHDR)
        #expect(wide.codec == "avc1")
        let tall = try #require(await BlockingWork.run { VideoFrames.info(for: portrait) })
        #expect(tall.pixelSize == CGSize(width: 96, height: 160))

        // The same, through the image decoder the browser and viewer use.
        let info = try #require(await BlockingWork.run { ImageDecoder.info(for: portrait) })
        #expect(info.kind == .video)
        #expect(info.pixelSize == CGSize(width: 96, height: 160))
        #expect(info.documentPageCount == 1)
        #expect(!info.isAnimated)
    }

    /// Find Duplicates' Similar mode leaves a video out, so a Live Photo's
    /// MOV never pairs with its HEIC by its poster frame; identical-file
    /// groups still size a video, so Highest Resolution doesn't rank it 0 px.
    @Test func duplicatesLeaveVideosOutOfSimilarAndSizeThem() async throws {
        let clip = try await TestVideos.make(at: folder.url.appendingPathComponent("IMG_1.mov"), width: 320, height: 192)
        let still = SyntheticScenes.write(SyntheticScenes.scene(seed: 1, width: 160, height: 96),
                                          to: folder.url.appendingPathComponent("IMG_1.jpg"))
        let entries = try [clip, still].map { try #require(FolderEntry(url: $0)) }
        let made = Tally()
        let prints = await BlockingWork.run {
            DuplicateFinder.featurePrints(for: entries, store: nil, workers: 1, make: { entry, thumbnails in
                made.add()
                return FeaturePrint.make(for: entry, thumbnails: thumbnails)
            })
        }
        #expect(made.count == 1 && prints[clip] == nil && prints[still] != nil)

        let sizes = await BlockingWork.run { DuplicateFinder.pixelSizes(of: entries) }
        #expect(sizes[clip] == CGSize(width: 320, height: 192))
        #expect(KeepRule.highestResolution.keeper(of: entries, pixelSizes: sizes)?.url == clip)
    }

    @Test func aFileThatIsNoMovieReadsAsNothing() async throws {
        let fake = try folder.file("broken.mov", bytes: 512)
        #expect(await BlockingWork.run { VideoFrames.info(for: fake) } == nil)
        #expect(await BlockingWork.run { ImageDecoder.thumbnail(for: fake, maxPixelSize: 256) } == nil)
        await #expect(throws: DecodeError.self) {
            try await BlockingWork.run { try ImageDecoder.decode(fake, fitting: CGSize(width: 800, height: 600)) }
        }
    }

    /// The thumbnail comes from a little way in, so a clip that opens on
    /// black still shows what it is of; the viewer's still is the very
    /// first frame, where playing starts.
    @Test func thumbnailIsTakenALittleInAndTheViewerStillAtTheStart() async throws {
        let url = try await TestVideos.make(at: folder.url.appendingPathComponent("clip.mov"), width: 320,
                                            height: 192, seconds: 3)
        let thumbnail = try #require(await BlockingWork.run { ImageDecoder.thumbnail(for: url, maxPixelSize: 64) })
        #expect(max(thumbnail.width, thumbnail.height) <= 64)
        #expect(thumbnail.width > thumbnail.height)
        let colour = TestVideos.centreColor(of: thumbnail)
        #expect(colour.red > 150 && colour.green < 80, "the thumbnail should show the clip, not its black start")

        let still = try await BlockingWork.run { try ImageDecoder.decode(url, fitting: CGSize(width: 2000, height: 2000)) }
        #expect(still.imageSize == CGSize(width: 320, height: 192))
        #expect(still.isFullResolution)
        #expect(!still.isHDR)
        let first = TestVideos.centreColor(of: still.image)
        #expect(first.red < 40 && first.green < 40 && first.blue < 40)

        // A screen-sized request decodes no more than it needs.
        let small = try await BlockingWork.run { try ImageDecoder.decode(url, fitting: CGSize(width: 100, height: 100)) }
        #expect(max(small.image.width, small.image.height) <= 100)
        #expect(!small.isFullResolution)
    }

    /// An HDR movie's still keeps its highlights: decoded as HDR with
    /// headroom above SDR white, so the viewer shows it as HDR before and
    /// apart from the player. With HDR off (Settings > Show HDR) it is tone
    /// mapped to SDR instead.
    @Test func anHDRMovieDecodesAsHDR() async throws {
        let url = try await TestVideos.make(at: folder.url.appendingPathComponent("hdr.mov"), width: 192,
                                            height: 108, seconds: 1, hdr: true)
        let info = try #require(await BlockingWork.run { VideoFrames.info(for: url) })
        #expect(info.isHDR)

        let still = try await BlockingWork.run { try ImageDecoder.decode(url, fitting: CGSize(width: 400, height: 400)) }
        #expect(still.isHDR)
        #expect(still.contentHeadroom > 1.5)
        #expect(still.needsDeepStorage)

        let sdr = try await BlockingWork.run {
            try ImageDecoder.decode(url, fitting: CGSize(width: 400, height: 400), allowHDR: false)
        }
        #expect(!sdr.isHDR)
        #expect(sdr.contentHeadroom == 1)
    }

    @Test func posterTimeIsALittleIn() {
        #expect(VideoFrames.posterTime(duration: 0) == 0)
        #expect(VideoFrames.posterTime(duration: 3) == 0.3)
        #expect(VideoFrames.posterTime(duration: 60) == 1)
        #expect(VideoFrames.posterTime(duration: .nan) == 0)
    }

    @Test func durationText() {
        #expect(VideoFrames.durationText(0) == "0:00")
        #expect(VideoFrames.durationText(9.9) == "0:09")
        #expect(VideoFrames.durationText(75) == "1:15")
        #expect(VideoFrames.durationText(3723) == "1:02:03")
        #expect(VideoFrames.durationText(.infinity) == "0:00")
    }

    @MainActor @Test func thumbnailsAreCachedLikeImages() async throws {
        let url = try await TestVideos.make(at: folder.url.appendingPathComponent("cached.mp4"))
        let entry = try #require(FolderEntry(url: url))
        #expect(entry.kind == .video)
        let store = try ThumbnailStore.inMemory()
        let service = ThumbnailService(store: store)
        let image: CGImage? = await withCheckedContinuation { continuation in
            service.request(entry, pixelSize: 200) { continuation.resume(returning: $0) }
        }
        let thumbnail = try #require(image)
        #expect(thumbnail.width == 160 && thumbnail.height == 96)   // never enlarged past the video
        #expect(service.cachedImage(for: entry, pixelSize: 200) === thumbnail)
        #expect(store.image(for: url, modified: entry.modified, fileSize: entry.fileSize, tier: 256) != nil)
    }

    /// A folder of videos opening asks for every thumbnail at once; the
    /// thumbnail service runs a worker per core, but no more than three
    /// frames ever decode together (a 4K HEVC frame holds tens of MB in
    /// the decoder), and every thumbnail still arrives. Thumbnails scrolled
    /// past before their turn are never decoded.
    @MainActor @Test func aFolderOfVideosDecodesAFewFramesAtATime() async throws {
        var entries: [FolderEntry] = []
        for index in 0..<10 {
            let url = try await TestVideos.make(at: folder.url.appendingPathComponent("clip\(index).mov"), seconds: 1)
            entries.append(try #require(FolderEntry(url: url)))
        }
        let service = ThumbnailService(store: nil, memoryCacheBytes: 50_000_000, workerLimit: 10)
        // Every request queued before any work starts, as when a folder
        // opens and the grid asks for a screenful.
        service.setSuspended(true)
        VideoFrames.decoding.resetPeak()
        var skippedDelivered = false
        let skipped = entries.prefix(2).map { service.request($0, pixelSize: 128) { _ in skippedDelivered = true } }
        skipped.forEach { $0.cancel() }
        var images: [Int: CGImage?] = [:]
        for (index, entry) in entries.enumerated().dropFirst(2) {
            service.request(entry, pixelSize: 128) { images[index] = $0 }
        }
        service.setSuspended(false)
        // Main-actor state, so waited for here rather than in `TestTiming`.
        let end = Date() + 20
        while images.count < 8, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(images.count == 8 && images.values.allSatisfy { $0 != nil })
        #expect(!skippedDelivered, "a cancelled thumbnail is never delivered")
        #expect((1...VideoFrames.frameSlotCount).contains(VideoFrames.decoding.peak),
                "\(VideoFrames.decoding.peak) frames decoded at once")
        // The two cancelled ones were never decoded.
        #expect(service.cachedImage(for: entries[0], pixelSize: 128) == nil)
        #expect(service.cachedImage(for: entries[1], pixelSize: 128) == nil)
    }

    /// The info panel's sections: a Video section of size, length, frame
    /// rate, codec and data rate in place of the Image section.
    @Test func infoPanelDescribesTheVideo() async throws {
        let url = try await TestVideos.make(at: folder.url.appendingPathComponent("clip.mov"), seconds: 2)
        let sections = await BlockingWork.run { MetadataReader.sections(for: url) }
        // The writer stamps the container with when it was made, which is
        // all the dating a movie without a camera's metadata has.
        #expect(sections.map(\.title) == ["File", "Video", "Dates"])
        let video = Dictionary(uniqueKeysWithValues: (sections[1].items).map { ($0.label, $0.value) })
        #expect(video["Dimensions"] == "160 × 96")
        #expect(video["Duration"] == "0:02")
        #expect(video["Frame rate"] == "10 fps")
        #expect(video["Codec"] == "avc1")
        #expect(video["Audio"] == "No")
        #expect(video["Data rate"]?.hasSuffix("kbit/s") == true)
        let summary = await BlockingWork.run { MetadataReader.summary(for: url) }
        #expect(summary.pixelSize == CGSize(width: 160, height: 96))
    }

    /// Data rate, the recording date in the camera's own zone, where it
    /// was made and the camera, as an iPhone writes them into a movie: shown
    /// in the info panel, and never written (see the next test).
    @Test func infoPanelShowsDataRateDateAndLocation() async throws {
        let url = try await TestVideos.make(at: folder.url.appendingPathComponent("phone.mov"), seconds: 2, metadata: [
            .quickTimeMetadataCreationDate: "2024-05-01T14:30:05+0200",
            .quickTimeMetadataLocationISO6709: "+48.8584+002.2945+035.000/",
            .quickTimeMetadataMake: "Apple",
            .quickTimeMetadataModel: "iPhone 15 Pro",
        ])
        let sections = await BlockingWork.run { MetadataReader.sections(for: url) }
        #expect(sections.map(\.title) == ["File", "Video", "Camera", "Dates", "GPS"])
        func items(_ title: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (sections.first { $0.title == title }?.items ?? []).map { ($0.label, $0.value) })
        }
        let bytes = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(items("Video")["Data rate"] == MetadataReader.formatDataRate(Double(bytes) * 8 / 2))
        #expect(items("Camera") == ["Make": "Apple", "Model": "iPhone 15 Pro"])
        // 14:30 on the camera's clock, two hours east of UTC, wherever the
        // Mac reading it is.
        let original = try #require(items("Dates")["Original"])
        #expect(original.contains("2:30:05") && original.hasSuffix("+02:00"), "\(original)")
        #expect(items("GPS") == ["Latitude": "48° 51′ 30.2″ N", "Longitude": "2° 17′ 40.2″ E", "Altitude": "35 m"])
        let metadata = try #require(await BlockingWork.run { VideoFrames.metadata(for: url) })
        #expect(metadata.created?.date == ISO8601DateFormatter().date(from: "2024-05-01T12:30:05Z"))
    }

    @Test func readsISO6709AndQuickTimeDates() throws {
        let decimal = try #require(VideoFrames.parseISO6709("+37.3349-122.0090+010.000/"))
        #expect(decimal == VideoMetadata.Location(latitude: 37.3349, longitude: -122.009, altitude: 10))
        #expect(VideoFrames.parseISO6709("-33.8568+151.2153/") == VideoMetadata.Location(latitude: -33.8568,
                                                                                         longitude: 151.2153))
        // Degrees and minutes, then degrees, minutes and seconds.
        let minutes = try #require(VideoFrames.parseISO6709("+4851.50+00217.67/"))
        #expect(abs(minutes.latitude - (48 + 51.5 / 60)) < 1e-9 && abs(minutes.longitude - (2 + 17.67 / 60)) < 1e-9)
        let seconds = try #require(VideoFrames.parseISO6709("-335124.5+1511255/"))
        #expect(abs(seconds.latitude + (33 + 51 / 60 + 24.5 / 3600)) < 1e-9)
        #expect(abs(seconds.longitude - (151 + 12 / 60 + 55 / 3600)) < 1e-9)
        for bad in ["", "37.3/", "+95.0+010.0/", "+37.3", "+3.3+10.0/", "hello"] {
            #expect(VideoFrames.parseISO6709(bad) == nil, "\(bad)")
        }

        let zoned = try #require(VideoFrames.parseCreationDate("2024-05-01T14:30:05+0200"))
        #expect(zoned.timeZone?.secondsFromGMT() == 7200)
        #expect(zoned.date == ISO8601DateFormatter().date(from: "2024-05-01T12:30:05Z"))
        #expect(VideoFrames.parseCreationDate("2024-05-01T14:30:05.123-05:00")?.timeZone?.secondsFromGMT() == -18000)
        #expect(VideoFrames.parseCreationDate("2024-05-01T14:30:05Z")?.timeZone?.secondsFromGMT() == 0)
        #expect(VideoFrames.parseCreationDate("2024-05-01T14:30:05")?.timeZone == nil)
        #expect(VideoFrames.parseCreationDate("2024") == nil)

        #expect(MetadataReader.formatDataRate(12_400_000) == "12.4 Mbit/s")
        #expect(MetadataReader.formatDataRate(850_400) == "850 kbit/s")
    }

    @Test func metadataOfAVideoIsNeitherWrittenNorGivenASidecar() throws {
        let url = try folder.file("clip.mov")
        #expect(MetadataWriter.method(for: url) == .unsupported)
        #expect(throws: MetadataWriter.Error.self) { try MetadataWriter.apply(MetadataEdit(), to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("xmp").path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("xmp").path))
    }
}
