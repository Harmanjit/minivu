import Testing
import AppKit
import AVFoundation
import MinivuCore
import MinivuRender
@testable import Minivu

/// Videos among the photos (G18), as the browser and its tools see them:
/// the file type filter, which tools leave videos out, the grid cell's
/// badge and what VoiceOver reads, and the viewer's keys for a video.
@MainActor @Suite struct VideoBrowserTests {
    let catalog = Catalog.inMemory()

    func entry(_ name: String) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: false,
                    kind: ImageFormats.kind(of: URL(fileURLWithPath: name)), fileSize: 1, modified: .distantPast,
                    created: .distantPast)
    }

    @Test func fileTypeFilterShowsPhotosOrVideos() async throws {
        let t = try ScratchFolder()
        try t.folder("Sub")
        for name in ["a.jpg", "b.mov", "c.mp4", "d.NEF"] { try t.file(name) }
        let model = BrowserModel(sortOrder: FileSortOrder(), invalidate: { _ in }, watchesFolder: false, catalog: catalog)
        model.navigate(to: t.url)
        await model.work?.value
        #expect(model.entries.map(\.name) == ["Sub", "a.jpg", "b.mov", "c.mp4", "d.NEF"])
        #expect(model.imageCount == 4 && model.videoCount == 2)

        model.marksFilter.fileType = .videos
        #expect(model.entries.map(\.name) == ["Sub", "b.mov", "c.mp4"], "folders stay")
        #expect(model.marksFilter.isActive)
        #expect(model.statusText == "3 of 5 shown")
        #expect(model.videoCount == 2)
        model.marksFilter.fileType = .photos
        #expect(model.entries.map(\.name) == ["Sub", "a.jpg", "d.NEF"])
        #expect(model.videoCount == 0)
        // Show All clears it with the rest.
        model.marksFilter = MarksFilter()
        #expect(model.entries.count == 5)
    }

    @Test func fileTypeFilterPassesByKind() {
        #expect(FileTypeFilter.videos.passes(entry("a.mov")))
        #expect(!FileTypeFilter.videos.passes(entry("a.jpg")))
        #expect(FileTypeFilter.photos.passes(entry("a.pdf")))
        #expect(!FileTypeFilter.photos.passes(entry("a.m4v")))
        #expect(FileTypeFilter.all.passes(entry("a.mov")))
        #expect(MarksFilter(fileType: .videos).isActive)
    }

    @Test func filterMenusOfferPhotosAndVideosOnly() throws {
        let view = try #require(MainMenu.make().items.first { $0.title == "View" }?.submenu)
        let filter = try #require(view.items.first { $0.title == "Filter" }?.submenu)
        let items = filter.items.filter { $0.action == .filterByFileType }
        #expect(items.map(\.title) == ["Photos Only", "Videos Only"])
        #expect(items.map(\.tag) == [FileTypeFilter.photos.rawValue, FileTypeFilter.videos.rawValue])
        let toolbar = BrowserToolbar.filterMenu(.init(isActive: false, finderTags: [], selectedTag: nil), target: nil)
        #expect(toolbar.items.filter { $0.action == .filterByFileType }.map(\.title) == ["Photos Only", "Videos Only"])
    }

    /// A slideshow skips videos, starting from the next picture when a video
    /// was chosen, and is empty when there is nothing but video.
    @Test func slideshowLeavesVideosOut() {
        let list = ["a.jpg", "b.mov", "c.jpg", "d.mp4", "e.jpg"].map(entry)
        let fromPhoto = SlideshowSequence.withoutVideos(list, start: 2)
        #expect(fromPhoto.images.map(\.name) == ["a.jpg", "c.jpg", "e.jpg"])
        #expect(fromPhoto.start == 1)
        #expect(SlideshowSequence.withoutVideos(list, start: 1).start == 1, "b.mov starts at c.jpg")
        #expect(SlideshowSequence.withoutVideos(list, start: 3).start == 2, "d.mp4 starts at e.jpg")
        let endsOnVideo = ["a.jpg", "b.mov"].map(entry)
        #expect(SlideshowSequence.withoutVideos(endsOnVideo, start: 1).start == 0, "wraps to the first")
        #expect(SlideshowSequence.withoutVideos(["b.mov"].map(entry), start: 0).images.isEmpty)
    }

    @Test func cellReadsAsAVideo() {
        #expect(ThumbnailCellView.accessibilityText(name: "clip.mov", isFolder: false, rating: 2, isTagged: false,
                                                    finderTags: [], dimensions: "1920 × 1080", video: "0:12")
                == "clip.mov, video, 0:12, 2 stars, 1920 × 1080")
        #expect(ThumbnailCellView.accessibilityText(name: "clip.mov", isFolder: false, rating: 0, isTagged: false,
                                                    finderTags: [], dimensions: "", video: "")
                == "clip.mov, video")
        #expect(ThumbnailCellView.accessibilityText(name: "a.jpg", isFolder: false, rating: 0, isTagged: false,
                                                    finderTags: [], dimensions: "") == "a.jpg")
    }

    @Test func badgeSitsInThePicturesCorner() {
        let layout = ThumbnailLayout(side: 150)
        let picture = CGRect(x: 8, y: 30, width: 150, height: 90)
        let badge = layout.videoBadgeFrame(imageFrame: picture, width: 40)
        #expect(badge.maxX == picture.maxX - ThumbnailLayout.badgeInset)
        #expect(badge.maxY == picture.maxY - ThumbnailLayout.badgeInset)
        #expect(badge.height == VideoBadgeView.height)
        // Never wider than a narrow picture.
        let narrow = layout.videoBadgeFrame(imageFrame: CGRect(x: 60, y: 8, width: 20, height: 150), width: 40)
        #expect(narrow.width == 20 - 2 * ThumbnailLayout.badgeInset)
    }

    /// On a video Space plays and pauses and M mutes; the arrows and
    /// Delete still move between items. On a photo nothing changes.
    @Test func videoKeys() {
        func key(_ characters: String, video: Bool) -> ViewerKeyCommand? {
            ViewerKeyCommand.command(characters: characters, modifiers: [], zoomedIn: false, isVideo: video)
        }
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        #expect(key(" ", video: true) == .togglePlayback)
        #expect(key(" ", video: false) == .next)
        #expect(key("p", video: true) == .togglePlayback)
        #expect(key("m", video: true) == .toggleMute)
        #expect(key("m", video: false) == nil)
        #expect(key(right, video: true) == .next)
        #expect(key(String(Character(UnicodeScalar(NSDeleteCharacter)!)), video: true) == .previous)
        #expect(ViewerKeyCommand.command(characters: "m", modifiers: .command, zoomedIn: false, isVideo: true) == nil,
                "⌘M is Minimize")
    }

    @Test func muteItemHasADisplayOnlyM() throws {
        let image = try #require(MainMenu.make().items.first { $0.title == "Image" }?.submenu)
        let mute = try #require(image.items.first { $0.action == .toggleMute })
        #expect(mute.title == "Mute Video")
        #expect(mute.keyEquivalent.isEmpty, "a bare M would be taken from text fields")
        (image.delegate as? DisplayOnlyShortcuts)?.showShortcuts(true)
        #expect(mute.keyEquivalent == "m" && mute.keyEquivalentModifierMask.isEmpty)
        (image.delegate as? DisplayOnlyShortcuts)?.showShortcuts(false)
    }
}

extension AppWindowTests {
    /// The browser's tools with videos in the folder: the picture tools
    /// leave them out and turn off when nothing else is chosen.
    @MainActor @Suite(.serialized, .batchToolsReset) struct VideoBrowserWindowTests {
        let catalog = Catalog.inMemory()

        init() { _ = NSApplication.shared }

        func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

        @Test func pictureToolsLeaveVideosOut() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 64, height: 48)
            let video = try t.file("b.mov")
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value

            // Nothing selected: every item shown, the video left out of the
            // picture tools but renamed with the rest.
            #expect(controller.toolImages.map(\.url.lastPathComponent) == ["a.jpg", "b.mov"])
            #expect(controller.toolStills.map(\.url.lastPathComponent) == ["a.jpg"])
            #expect(controller.slideshowImages.images.map(\.url.lastPathComponent) == ["a.jpg"])

            // The video alone selected. A slideshow from it still plays the
            // folder's pictures, from the next one.
            controller.model.select(video)
            #expect(controller.slideshowImages.images.map(\.url.lastPathComponent) == ["a.jpg"])
            for action in [Selector.batchConvert, .printImages, .makeContactSheet, .makeMontage,
                           .setAsDesktopPicture, .saveImageAs, .rotateLeft, .editMetadata] {
                #expect(!controller.validateMenuItem(item(action)), "\(action)")
            }
            for action in [Selector.batchRename, .moveToTrash, .setRating, .toggleTag, .setColorLabel,
                           .revealInFinder, .renameItem, .openInExternalEditor] {
                #expect(controller.validateMenuItem(item(action)), "\(action)")
            }

            controller.model.select(photo)
            for action in [Selector.batchConvert, .printImages, .startSlideshow, .setAsDesktopPicture, .saveImageAs] {
                #expect(controller.validateMenuItem(item(action)), "\(action)")
            }
        }

        @Test func filterItemsTickTheTypeInForce() async throws {
            let t = try ScratchFolder()
            try t.file("a.jpg"); try t.file("b.mov")
            let controller = BrowserWindowController(catalog: catalog)
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value

            let videos = item(.filterByFileType)
            videos.tag = FileTypeFilter.videos.rawValue
            #expect(controller.validateMenuItem(videos) && videos.state == .off)
            controller.filterByFileType(videos)
            #expect(controller.model.entries.map(\.name) == ["b.mov"])
            #expect(controller.validateMenuItem(videos) && videos.state == .on)
            // Chosen again: both kinds again.
            controller.filterByFileType(videos)
            #expect(controller.model.marksFilter.fileType == .all)
            #expect(controller.model.entries.count == 2)
        }
    }

    /// A video in the viewer: its first frame on the canvas, the commands
    /// that make no sense for it turned off, and a player made only when
    /// asked and let go when the user moves on or closes the viewer. The
    /// movies are silent and the player muted, so nothing can sound.
    @MainActor @Suite(.serialized) struct VideoViewerTests {
        init() {
            _ = NSApplication.shared
            VideoPlayback.mutedByUser = true
        }

        func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

        func closeViewer() { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }

        func open(_ list: [URL], at index: Int) async throws -> ViewerWindowController {
            let entries = try list.map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: entries, index: index, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canvasTexture != nil && viewer.displayed == viewer.current }
            return viewer
        }

        @Test func showsTheFirstFrameAndTurnsOffWhatMakesNoSense() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 320, height: 240)
            let video = try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"), width: 320, height: 192)
            defer { closeViewer() }
            let viewer = try await open([photo, video], at: 1)
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 320, height: 192))
            #expect(viewer.videoStage.showsPlayButton)
            #expect(viewer.videoPlayback == nil, "nothing plays until asked")

            let off: [Selector] = [
                .saveImageAs, .rotateLeft, .cropImage, .resizeImage, .adjustLighting, .adjustColors, .applySepia,
                .drawAnnotations, .cloneStamp, .addWatermark, .autoEnhance, .removeBackground, .editComment,
                .editMetadata, .copyText, .copySubject, #selector(NSText.copy(_:)), .toggleHistogram, .countColors,
                .printImages, .setAsDesktopPicture, .zoomIn, .actualSize,
            ]
            for action in off { #expect(!viewer.validateMenuItem(item(action)), "\(action)") }
            #expect(!viewer.canEditCurrent)

            let on: [Selector] = [.togglePlayback, .toggleMute, .moveToTrash, .setRating, .toggleTag, .setColorLabel,
                                  .revealInFinder, .shareFiles, .previousImage, .openInExternalEditor,
                                  .startSlideshow]
            for action in on { #expect(viewer.validateMenuItem(item(action)), "\(action)") }
            let play = item(.togglePlayback)
            _ = viewer.validateMenuItem(play)
            #expect(play.title == "Play Video")

            // The photo beside it: everything back as before.
            viewer.previousImage(nil)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 320, height: 240) }
            #expect(!viewer.videoStage.showsPlayButton)
            #expect(viewer.validateMenuItem(item(.startSlideshow)))
            #expect(viewer.validateMenuItem(item(.countColors)))
            #expect(!viewer.validateMenuItem(item(.toggleMute)))
            _ = viewer.validateMenuItem(play)
            #expect(play.title == "Play Animation")
        }

        @Test func playerIsMadeOnDemandAndReleasedOnNavigationAndClose() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 320, height: 240)
            let video = try await TestVideos.make(at: t.url.appendingPathComponent("b.mp4"), seconds: 5)
            defer { closeViewer() }
            let viewer = try await open([photo, video], at: 1)

            viewer.togglePlayback(nil)
            let playback = try #require(viewer.videoPlayback)
            let player = playback.player
            #expect(player.isMuted)
            #expect(player.currentItem != nil)
            #expect(viewer.videoPlayerView?.superview === viewer.videoStage)
            #expect(!viewer.videoStage.showsPlayButton)
            #expect(viewer.videoPlayerView?.acceptsFirstResponder == false, "the viewer keeps the keyboard")
            await TestTiming.waitUntil { playback.isPlaying }
            let pause = item(.togglePlayback)
            _ = viewer.validateMenuItem(pause)
            #expect(pause.title == "Pause Video")

            // Asked again (Space, P, the button), it pauses.
            viewer.togglePlayback(nil)
            await TestTiming.waitUntil { !playback.isPlaying }
            #expect(!playback.isPlaying)

            // Moving on stops and lets go of everything.
            viewer.togglePlayback(nil)
            viewer.previousImage(nil)
            #expect(viewer.videoPlayback == nil)
            #expect(player.rate == 0)
            #expect(player.currentItem == nil)
            #expect(playback.view.player == nil && playback.view.superview == nil)

            // Back, play, close: the same.
            viewer.nextImage(nil)
            await TestTiming.waitUntil { viewer.displayed == viewer.current && viewer.canvasTexture != nil }
            viewer.togglePlayback(nil)
            let second = try #require(viewer.videoPlayback).player
            closeViewer()
            #expect(ViewerWindowController.current == nil)
            #expect(second.rate == 0 && second.currentItem == nil)
        }

        @Test func muteFollowsTheUserAcrossVideos() async throws {
            let t = try ScratchFolder()
            let video = try await TestVideos.make(at: t.url.appendingPathComponent("a.mov"))
            defer {
                closeViewer()
                VideoPlayback.mutedByUser = true
            }
            let viewer = try await open([video], at: 0)
            let mute = item(.toggleMute)
            #expect(viewer.validateMenuItem(mute) && mute.title == "Unmute Video")
            // Unmuted only before any player exists, so nothing can sound.
            viewer.toggleMute(nil)
            #expect(!VideoPlayback.mutedByUser)
            #expect(viewer.validateMenuItem(mute) && mute.title == "Mute Video")
            viewer.toggleMute(nil)
            #expect(VideoPlayback.mutedByUser)
        }
    }
}
