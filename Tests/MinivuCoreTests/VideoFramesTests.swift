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

    @Test func metadataOfAVideoIsNeitherWrittenNorGivenASidecar() throws {
        let url = try folder.file("clip.mov")
        #expect(MetadataWriter.method(for: url) == .unsupported)
        #expect(throws: MetadataWriter.Error.self) { try MetadataWriter.apply(MetadataEdit(), to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("xmp").path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("xmp").path))
    }
}
