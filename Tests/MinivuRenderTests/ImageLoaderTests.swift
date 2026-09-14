import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

@MainActor @Suite(.serialized) struct ImageLoaderTests {
    /// A fresh 400x200 quadrant image on disk, and a loader with an empty cache.
    func makeEntry(width: Int = 400, height: Int = 200) -> FolderEntry {
        let url = Fixtures.write(Fixtures.quadrants(width: width, height: height), name: "loader-\(UUID()).tiff")
        return FolderEntry(url: url)!
    }

    func makeLoader() -> ImageLoader {
        ImageLoader(cache: TextureCache(budgetBytes: 256 << 20))
    }

    func load(_ loader: ImageLoader, _ entry: FolderEntry, pixelSize: Int) async -> Result<ImageTexture, Error> {
        await withCheckedContinuation { done in
            loader.load(entry, pixelSize: pixelSize) { done.resume(returning: $0) }
        }
    }

    @Test func secondLoadIsASynchronousCacheHit() async throws {
        let loader = makeLoader(), entry = makeEntry()
        let first = try await load(loader, entry, pixelSize: 100).get()
        #expect(first.imageSize == CGSize(width: 400, height: 200))
        #expect(first.texture.width == 100)
        #expect(!first.isFullResolution)

        var hit: ImageTexture?
        loader.load(entry, pixelSize: 100) { hit = try? $0.get() }
        #expect(hit === first)
        // A slightly larger need is still covered (the decoder's 3% tolerance).
        hit = nil
        loader.load(entry, pixelSize: 103) { hit = try? $0.get() }
        #expect(hit === first)
        #expect(loader.decodeCount == 1)
    }

    @Test func requestsSnapToTheCodecScaleOnceTheImageSizeIsKnown() async throws {
        let loader = makeLoader(), entry = makeEntry()
        // 100 px is exactly 1/4 of 400. Once that size is known, a 120 px
        // request snaps up to the codec's next scale, 1/2 (200 px).
        _ = try await load(loader, entry, pixelSize: 100).get()
        let snapped = try await load(loader, entry, pixelSize: 120).get()
        #expect(snapped.texture.width == 200)
        #expect(loader.decodeCount == 2)
    }

    @Test func cancelSuppressesUpdate() async {
        let loader = makeLoader(), entry = makeEntry()
        var called = false
        let handle = loader.load(entry, pixelSize: 100) { _ in called = true }
        handle.cancel()
        await loader.waitUntilIdle()
        #expect(!called)
        #expect(handle.isCancelled)
    }

    @Test func cancellingOneOfTwoRequestersKeepsTheOther() async throws {
        let loader = makeLoader(), entry = makeEntry()
        var cancelledCalled = false
        let cancelled = loader.load(entry, pixelSize: 100) { _ in cancelledCalled = true }
        let kept = await withCheckedContinuation { done in
            loader.load(entry, pixelSize: 100) { done.resume(returning: $0) }
            cancelled.cancel()
        }
        _ = try kept.get()
        #expect(!cancelledCalled)
        #expect(loader.decodeCount == 1)
    }

    @Test func loadJoinsAnInFlightPrefetch() async throws {
        let loader = makeLoader(), entry = makeEntry()
        loader.prefetch([entry], pixelSize: 100)
        #expect(loader.decodeCount == 1)
        _ = try await load(loader, entry, pixelSize: 100).get()
        #expect(loader.decodeCount == 1)
    }

    @Test func prefetchThenLoadHitsCache() async {
        let loader = makeLoader(), entry = makeEntry()
        loader.prefetch([entry], pixelSize: 100)
        await loader.waitUntilIdle()
        var hit = false
        loader.load(entry, pixelSize: 100) { hit = (try? $0.get()) != nil }
        #expect(hit)
        #expect(loader.decodeCount == 1)
    }

    @Test func replacingThePrefetchSetDropsWaitingDecodes() async {
        let loader = makeLoader()
        let entries = (0..<5).map { _ in makeEntry() }
        loader.prefetch(entries, pixelSize: 100)
        #expect(loader.decodeCount == ImageLoader.maximumConcurrentPrefetches)   // the rest wait for a slot
        loader.prefetch([], pixelSize: 100)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == ImageLoader.maximumConcurrentPrefetches)
    }

    @Test func prefetchesLeaveASlotForTheUser() async throws {
        let loader = makeLoader()
        loader.prefetch((0..<5).map { _ in makeEntry() }, pixelSize: 100)
        #expect(loader.decodeCount == ImageLoader.maximumConcurrentPrefetches)
        // A photo outside the prefetch set starts at once, not after a neighbour.
        let far = makeEntry()
        var result: Result<ImageTexture, Error>?
        loader.load(far, pixelSize: 100) { result = $0 }
        #expect(loader.decodeCount == ImageLoader.maximumConcurrentDecodes)
        await loader.waitUntilIdle()
        _ = try #require(result).get()
    }

    /// The viewer may replace the prefetch set before asking for the photo
    /// it flipped to. The decode already running for that photo must be
    /// picked up, not stopped and started again.
    @Test func loadPicksUpADecodeTheLastPrefetchLetGo() async throws {
        let loader = makeLoader(), next = makeEntry(), other = makeEntry()
        loader.prefetch([next], pixelSize: 100)
        loader.prefetch([other], pixelSize: 100)   // `next` is no longer wanted...
        var result: Result<ImageTexture, Error>?
        loader.load(next, pixelSize: 100) { result = $0 }   // ...until it is
        #expect(loader.decodeCount == 2)   // joined, nothing new started
        await loader.waitUntilIdle()
        // Never a cancellation, even if the decode gave up just before the join.
        #expect(try #require(result).get().texture.width == 100)
    }

    @Test func invalidateStopsWaitingPrefetchesOfTheFile() async {
        let loader = makeLoader()
        let entries = (0..<3).map { _ in makeEntry() }
        loader.prefetch(entries, pixelSize: 100)   // the third waits
        loader.invalidate(entries[2].url)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == 2)
    }

    @Test func fullResolutionLoadCoversScreenRequests() async throws {
        let loader = makeLoader(), entry = makeEntry()
        let full = try await withCheckedContinuation { done in
            loader.loadFullResolution(entry) { done.resume(returning: $0) }
        }.get()
        #expect(full.isFullResolution)
        #expect(full.texture.width == 400)

        var again: ImageTexture?, screen: ImageTexture?
        loader.loadFullResolution(entry) { again = try? $0.get() }
        loader.load(entry, pixelSize: 100) { screen = try? $0.get() }
        #expect(again === full)
        #expect(screen === full)
        #expect(loader.decodeCount == 1)
    }

    @Test func invalidateForgetsTheFile() async throws {
        let loader = makeLoader(), entry = makeEntry()
        _ = try await load(loader, entry, pixelSize: 100).get()
        loader.invalidate(entry.url)
        var hit = false
        let handle = loader.load(entry, pixelSize: 100) { _ in hit = true }
        #expect(!hit)
        handle.cancel()
        #expect(loader.cache.usedBytes == 0)
    }

    @Test func unreadableFilesReportAnError() async {
        let loader = makeLoader()
        let url = Fixtures.directory.appendingPathComponent("broken-\(UUID()).jpg")
        try? Data("not a jpeg".utf8).write(to: url)
        let result = await load(loader, FolderEntry(url: url)!, pixelSize: 100)
        #expect(throws: (any Error).self) { try result.get() }
    }

    /// Loader to pixels: the loaded texture drawn at fit and read back as an
    /// sRGB image, as the canvas view's snapshot does.
    @Test func snapshotOfALoadedImage() async throws {
        let loader = makeLoader(), entry = makeEntry()
        let texture = try await load(loader, entry, pixelSize: 200).get()
        let view = CGSize(width: 100, height: 50)
        let frame = CanvasFrame(image: texture, transform: .bestFit(imageSize: texture.imageSize, viewSize: view),
                                background: SIMD3(0, 0, 0))
        let image = try #require(try CanvasRenderer().snapshot(frame, width: 100, height: 50))
        #expect(image.width == 100 && image.height == 50)
        let data = try #require(image.dataProvider?.data) as Data
        func rgb(_ x: Int, _ y: Int) -> [UInt8] {
            let i = y * image.bytesPerRow + x * image.bitsPerPixel / 8
            return [data[i], data[i + 1], data[i + 2]]
        }
        func near(_ a: [UInt8], _ b: [UInt8]) -> Bool { zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 3 } }
        #expect(near(rgb(10, 10), [255, 0, 0]))
        #expect(near(rgb(90, 10), [0, 255, 0]))
        #expect(near(rgb(10, 40), [0, 0, 255]))
        #expect(near(rgb(90, 40), [255, 255, 255]))
    }

    /// Real photos, when the sample folder is present: a prefetched neighbour
    /// is shown without a second decode.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Users/harman/latent/TestAssets")))
    func realPhotosPrefetchThenLoad() async throws {
        let folder = URL(fileURLWithPath: "/Users/harman/latent/TestAssets")
        let entries = ["HSB_6548.jpg", "HSB_2615.NEF", "HSB_6548.heic"]
            .compactMap { FolderEntry(url: folder.appendingPathComponent($0)) }
        let loader = makeLoader()
        loader.prefetch(entries, pixelSize: 1512)
        for entry in entries {
            let texture = try await load(loader, entry, pixelSize: 1512).get()
            #expect(Double(max(texture.texture.width, texture.texture.height)) >= 1512 * 0.97)
        }
        #expect(loader.decodeCount == entries.count)
    }

    // MARK: - Settings and RAW

    @Test func rawPlanFollowsTheSettings() {
        #expect(ImageLoader.rawPlan(settings: DisplaySettings()) == .previewOrRender)
        #expect(ImageLoader.rawPlan(settings: DisplaySettings(rawDecoding: .fullRaw)) == .render(hdr: false))
        // HDR RAW needs a render whatever the decoding choice, and HDR on.
        #expect(ImageLoader.rawPlan(settings: DisplaySettings(hdrRaw: true)) == .render(hdr: true))
        #expect(ImageLoader.rawPlan(settings: DisplaySettings(showHDR: false, hdrRaw: true)) == .previewOrRender)
        #expect(ImageLoader.rawPlan(settings: DisplaySettings(hdrRaw: true, hdrRawAmount: 0)) == .previewOrRender)
    }

    @Test func aPreviewCoversWhatItHoldsWithThreePercentSlack() {
        func preview(longEdge: Int, full: Bool) -> DecodedImage {
            let image = Fixtures.quadrants(width: longEdge, height: longEdge / 2)
            return DecodedImage(image: image, orientation: .up, imageSize: CGSize(width: 6016, height: 3008),
                                isFullResolution: full, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        }
        #expect(ImageLoader.previewCovers(preview(longEdge: 6000, full: true), pixelSize: nil))
        #expect(!ImageLoader.previewCovers(preview(longEdge: 1620, full: false), pixelSize: nil))
        #expect(ImageLoader.previewCovers(preview(longEdge: 1512, full: false), pixelSize: 1512))
        #expect(ImageLoader.previewCovers(preview(longEdge: 1620, full: false), pixelSize: 1670))
        #expect(!ImageLoader.previewCovers(preview(longEdge: 1620, full: false), pixelSize: 3008))
    }

    @Test func rawHeadroomScalesWithTheAmount() {
        #expect(DisplaySettings(hdrRawAmount: 1).rawHeadroom == RawRenderer.maximumHeadroom)
        #expect(DisplaySettings(hdrRawAmount: 0).rawHeadroom == 1)
        #expect(abs(DisplaySettings(hdrRawAmount: 0.5).rawHeadroom - 1.4142) < 1e-3)
        #expect(DisplaySettings(hdrRawAmount: 7).rawHeadroom == RawRenderer.maximumHeadroom)
    }

    /// A decode running when the settings change still reaches its
    /// requester, but isn't cached or joined: it was made the old way.
    @Test func settingsChangeStopsInFlightResultsBeingReused() async throws {
        let loader = makeLoader(), entry = makeEntry()
        var first: Result<ImageTexture, Error>?
        loader.load(entry, pixelSize: 100) { first = $0 }
        loader.settings.rawDecoding = .fullRaw
        var second: Result<ImageTexture, Error>?
        loader.load(entry, pixelSize: 100) { second = $0 }
        #expect(loader.decodeCount == 2)
        await loader.waitUntilIdle()
        _ = try #require(first).get()
        let fresh = try #require(second).get()
        var hit: ImageTexture?
        loader.load(entry, pixelSize: 100) { hit = try? $0.get() }
        #expect(hit === fresh)
    }

    // MARK: - RAW render limits

    /// Files named like RAWs but holding no image: every load of one goes
    /// to the RAW engine (under `.fullRaw`), fails there quickly, and
    /// reports an error, which is all the scheduling tests need.
    func makeFakeRaw() -> FolderEntry {
        let url = Fixtures.directory.appendingPathComponent("fake-\(UUID()).nef")
        try? Data("not a raw file".utf8).write(to: url)
        return FolderEntry(url: url)!
    }

    @Test func rawRendersTakeOneSlotOfTheirOwn() async {
        let loader = makeLoader()
        loader.settings = DisplaySettings(rawDecoding: .fullRaw)
        for raw in (0..<3).map({ _ in makeFakeRaw() }) {
            loader.load(raw, pixelSize: 100) { _ in }
        }
        #expect(loader.rawRenderCount == 1)   // the other two wait
        // Ordinary decodes don't wait behind them, and leave the renders their slot.
        loader.load(makeEntry(), pixelSize: 100) { _ in }
        loader.load(makeEntry(), pixelSize: 100) { _ in }
        #expect(loader.decodeCount == 3)
        #expect(loader.rawRenderCount == 1)
        await loader.waitUntilIdle()
        #expect(loader.rawRenderCount == 3)
        #expect(loader.peakConcurrentRawRenders == 1)
    }

    /// Only the nearest RAW file is prefetched as a render; the other
    /// neighbours still decode.
    @Test func rawRenderPrefetchIsForTheNearestRawFileOnly() async {
        for allowed in [true, false] {
            let loader = makeLoader()
            loader.settings = DisplaySettings(rawDecoding: .fullRaw)
            loader.prefetchesRawRenders = allowed
            loader.prefetch([makeFakeRaw(), makeEntry(), makeFakeRaw()], pixelSize: 100)
            #expect(loader.rawRenderCount == (allowed ? 1 : 0))
            await loader.waitUntilIdle()
            #expect(loader.rawRenderCount == (allowed ? 1 : 0))
            #expect(loader.decodeCount == (allowed ? 2 : 1))
        }
    }

    /// Under "Embedded preview", a RAW file goes to the render slot only once
    /// its preview has fallen short, handing its decode slot back on the
    /// way. Three at once: all three previews use decode slots, the renders
    /// then run one by one, nothing is left waiting, every requester hears
    /// back, and photos asked for meanwhile still decode.
    @Test func previewsThatFallShortQueueForTheRenderSlot() async {
        let loader = makeLoader()
        var results: [Bool] = []
        for raw in (0..<3).map({ _ in makeFakeRaw() }) {
            loader.load(raw, pixelSize: 100) { results.append((try? $0.get()) != nil) }
        }
        #expect(loader.decodeCount == 3 && loader.rawRenderCount == 0)   // previews first, in decode slots
        await loader.waitUntilIdle()
        #expect(results == [false, false, false])
        #expect(loader.rawRenderCount == 3 && loader.peakConcurrentRawRenders == 1)
        #expect(loader.decodeCount == 3)   // each render carried on its job

        // The previews are known to fall short now: straight to the render
        // slot, leaving every decode slot to other photos.
        let raws = (0..<2).map { _ in makeFakeRaw() }
        for raw in raws { loader.load(raw, pixelSize: 100) { _ in } }
        await loader.waitUntilIdle()
        for raw in raws { loader.load(raw, pixelSize: 100) { _ in } }
        #expect(loader.rawRenderCount == 6 && loader.decodeCount == 6)   // one running, one waiting
        var decoded = 0
        for entry in (0..<3).map({ _ in makeEntry() }) {
            loader.load(entry, pixelSize: 100) { if (try? $0.get()) != nil { decoded += 1 } }
        }
        #expect(loader.decodeCount == 9)   // all three at once
        await loader.waitUntilIdle()
        #expect(decoded == 3 && loader.rawRenderCount == 7 && loader.peakConcurrentRawRenders == 1)
    }

    @Test func rawRenderPrefetchNeedsMoreThanEightGigabytes() {
        #expect(!ImageLoader.allowsRawRenderPrefetch(physicalMemory: 8 << 30))
        #expect(!ImageLoader.allowsRawRenderPrefetch(physicalMemory: 4 << 30))
        #expect(ImageLoader.allowsRawRenderPrefetch(physicalMemory: 16 << 30))
    }

    nonisolated static let assets = URL(fileURLWithPath: "/Users/harman/latent/TestAssets")
    nonisolated static let hasAssets = FileManager.default.fileExists(atPath: assets.path)

    /// These Nikon files embed a full-size preview, so full resolution stays
    /// on the fast ImageIO path and counts as full resolution.
    @Test(.enabled(if: hasAssets))
    func fullResolutionRawUsesAFullSizeEmbeddedPreview() async throws {
        let loader = makeLoader()
        let entry = try #require(FolderEntry(url: Self.assets.appendingPathComponent("HSB_2615.NEF")))
        let full = try await withCheckedContinuation { done in
            loader.loadFullResolution(entry) { done.resume(returning: $0) }
        }.get()
        #expect(full.isFullResolution)
        #expect(full.imageSize == CGSize(width: 4016, height: 6016))
        #expect(full.texture.width == 4016 && full.texture.height == 6016)
        #expect(full.texture.pixelFormat == .bgra8Unorm_srgb)
    }

    @Test(.enabled(if: hasAssets))
    func fullRawModeRendersScreenSizedAndHDRTextures() async throws {
        let loader = makeLoader()
        loader.settings = DisplaySettings(rawDecoding: .fullRaw)
        let entry = try #require(FolderEntry(url: Self.assets.appendingPathComponent("HSB_2615.NEF")))
        let screen = try await load(loader, entry, pixelSize: 1512).get()
        #expect(max(screen.texture.width, screen.texture.height) == 1512)
        #expect(screen.imageSize == CGSize(width: 4016, height: 6016))
        #expect(!screen.isFullResolution)

        loader.settings.hdrRaw = true
        let hdr = try await withCheckedContinuation { done in
            loader.loadFullResolution(entry) { done.resume(returning: $0) }
        }.get()
        #expect(hdr.isFullResolution)
        #expect(hdr.texture.pixelFormat == .rgba16Float)   // only RawRenderer makes these for a RAW
    }

    func loadFull(_ loader: ImageLoader, _ entry: FolderEntry) async -> Result<ImageTexture, Error> {
        await withCheckedContinuation { done in
            loader.loadFullResolution(entry) { done.resume(returning: $0) }
        }
    }

    /// A camera that embeds only a 1620 px preview: it is used where it is
    /// big enough, and the RAW data is rendered where it isn't. ImageIO's
    /// decode would hand a 2800 px screen request the 1620 px preview, and
    /// the canvas would ask for more forever.
    @Test(.enabled(if: hasAssets))
    func smallEmbeddedPreviewIsRenderedWhereItFallsShort() async throws {
        let loader = makeLoader()
        let url = try Fixtures.smallPreviewNEF(from: Self.assets.appendingPathComponent("HSB_2639.NEF"))
        defer { try? FileManager.default.removeItem(at: url) }   // 34 MB
        let entry = try #require(FolderEntry(url: url))

        let small = try await load(loader, entry, pixelSize: 1512).get()
        #expect(max(small.texture.width, small.texture.height) == 1512)
        #expect(!small.isFullResolution)

        let screen = try await load(loader, entry, pixelSize: 2800).get()
        #expect(max(screen.texture.width, screen.texture.height) >= 2800)
        #expect(screen.imageSize == CGSize(width: 6016, height: 4016))
        #expect(!screen.isFullResolution)
        #expect(!CanvasInteraction.needsHigherResolution(isFullResolution: screen.isFullResolution,
                                                          currentZoom: 2800.0 / 6016,
                                                          imageLongEdge: 6016, textureLongEdge: screen.textureSize.width))

        let full = try await loadFull(loader, entry).get()
        #expect(full.isFullResolution)
        #expect(full.texture.width == 6016 && full.texture.height == 4016)
        #expect(loader.decodeCount == 3)
        #expect(loader.rawRenderCount == 2)
    }

    /// A neighbour whose embedded preview is too small is prefetched as a
    /// render only where renders may be prefetched. Where not, its preview
    /// isn't decoded again at every prefetch just to fall short again.
    @Test(.enabled(if: hasAssets))
    func smallPreviewNeighboursRenderOnlyWhereAllowed() async throws {
        let url = try Fixtures.smallPreviewNEF(from: Self.assets.appendingPathComponent("HSB_2639.NEF"))
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try #require(FolderEntry(url: url))
        let loader = makeLoader()
        loader.prefetchesRawRenders = false
        loader.prefetch([entry], pixelSize: 2800)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == 1 && loader.rawRenderCount == 0)
        #expect(loader.cache.anyTexture(url: url, modified: entry.modified, page: 0) == nil)
        loader.prefetch([entry], pixelSize: 2800)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == 1)

        loader.prefetchesRawRenders = true
        loader.prefetch([entry], pixelSize: 2800)
        await loader.waitUntilIdle()
        #expect(loader.decodeCount == 2 && loader.rawRenderCount == 1)   // straight to the render
        let texture = try #require(loader.cache.anyTexture(url: url, modified: entry.modified, page: 0))
        #expect(max(texture.texture.width, texture.texture.height) >= 2800)
    }

    /// A camera the RAW engine doesn't know: its preview is all there is,
    /// at every size, and saying so ends the canvas's requests for more.
    @Test(.enabled(if: hasAssets))
    func unknownCameraShowsItsPreviewAsTheWholeImage() async throws {
        let url = try Fixtures.smallPreviewNEF(from: Self.assets.appendingPathComponent("HSB_2639.NEF"),
                                               unknownCamera: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try #require(FolderEntry(url: url))
        for settings in [DisplaySettings(), DisplaySettings(rawDecoding: .fullRaw)] {
            let loader = makeLoader()
            loader.settings = settings
            let screen = try await load(loader, entry, pixelSize: 2800).get()
            #expect(screen.textureSize == CGSize(width: 1620, height: 1080))
            #expect(screen.imageSize == screen.textureSize)
            #expect(screen.isFullResolution)
            let full = try await loadFull(loader, entry).get()
            #expect(full === screen)   // a cache hit
        }
    }
}
