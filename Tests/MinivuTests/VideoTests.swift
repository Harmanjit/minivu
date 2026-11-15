import Testing
import AppKit
import AVFoundation
import ImageIO
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

    /// The length usually arrives after the thumbnail (the thumbnail cache
    /// survives relaunch, the length is read again): the badge still widens
    /// to show it, and narrows again when the cell is reused for a photo.
    @Test func badgeWidensWhenTheLengthArrivesLate() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 150, height: 200))
        window.contentView?.addSubview(cell)
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cell.setImage(try #require(context.makeImage()), isIcon: false)
        cell.setVideo(true, duration: nil)
        cell.layoutSubtreeIfNeeded()
        let narrow = try #require(cell.videoBadgeFrame)

        cell.setVideo(true, duration: 12)
        cell.layoutSubtreeIfNeeded()
        let wide = try #require(cell.videoBadgeFrame)
        #expect(wide.width > narrow.width + 10)
        #expect(wide.maxX == narrow.maxX)

        cell.setVideo(true, duration: 3_725)
        cell.layoutSubtreeIfNeeded()
        #expect(try #require(cell.videoBadgeFrame).width > wide.width)

        cell.setVideo(false, duration: nil)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.videoBadgeFrame == nil)
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

    /// The browser's preview pane on a video: its first frame, the play
    /// mark and length beside the stars (read by VoiceOver), and the info
    /// panel's Video section below.
    @MainActor @Suite(.serialized) struct VideoPreviewPaneTests {
        @Test func showsTheStillWithTheLength() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let photo = try #require(FolderEntry(url: try t.jpeg("a.jpg", width: 320, height: 240)))
            let video = try #require(FolderEntry(url: try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"),
                                                                                width: 320, height: 192)))
            let preview = PreviewPaneController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = preview
            window.setContentSize(NSSize(width: 320, height: 640))
            window.contentView?.layoutSubtreeIfNeeded()
            defer { preview.isVisible = false }

            preview.show(.image(video, neighbours: []))
            await TestTiming.waitUntil(seconds: 30) {
                preview.canvasView?.image != nil && preview.videoBadge.duration != nil
            }
            #expect(preview.canvasView?.image?.imageSize == CGSize(width: 320, height: 192))
            #expect(!preview.videoBadge.isHidden && preview.videoBadge.duration == 3)
            #expect(preview.videoBadge.isAccessibilityElement()
                && preview.videoBadge.accessibilityLabel() == "Video, 0:03")

            preview.show(.image(photo, neighbours: []))
            #expect(preview.videoBadge.isHidden)
        }
    }

    /// Compare Selected with a video among the photos (G18): allowed, and
    /// the video compared by its still, said to be a video.
    @MainActor @Suite(.serialized) struct VideoCompareTests {
        init() { _ = NSApplication.shared }

        @Test func aVideoIsComparedByItsStill() async throws {
            let savedCatalog = CompareWindowController.catalog
            CompareWindowController.catalog = .inMemory()
            defer { CompareWindowController.catalog = savedCatalog }
            let t = try ScratchFolder()
            let photo = try #require(FolderEntry(url: try t.jpeg("a.jpg", width: 320, height: 240)))
            let video = try #require(FolderEntry(url: try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"),
                                                                                width: 320, height: 192)))
            CompareWindowController.show(entries: [photo, video], allImages: [photo, video])
            defer { CompareWindowController.current?.window?.close() }
            let controller = try #require(CompareWindowController.current)
            let panes = controller.paneViews
            #expect(panes.count == 2)
            await TestTiming.waitUntil { panes.allSatisfy { $0.canvas.image != nil } && panes[1].secondLine != "Video" }
            #expect(panes[1].canvas.image?.imageSize == CGSize(width: 320, height: 192))
            #expect(panes[1].secondLine == "Video, 0:03")
            #expect(!panes[0].secondLine.hasPrefix("Video"))
            // Nothing in the window plays it: no frame commands, no player.
            #expect(!controller.responds(to: .togglePlayback) && !controller.responds(to: .copyFrame))
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

        /// A control inside the player that would take the keyboard (AVKit's
        /// scrubber does with Keyboard navigation on) hands it back to the
        /// canvas, so the arrows and Space keep their viewer meaning. Other
        /// views, and anything once the player has gone, are left alone.
        @Test func playerControlsNeverKeepTheKeyboard() async throws {
            final class Control: NSView {
                override var acceptsFirstResponder: Bool { true }
            }
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 320, height: 240)
            let video = try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"), seconds: 2)
            defer { closeViewer() }
            let viewer = try await open([photo, video], at: 1)
            let window = try #require(viewer.window)
            viewer.togglePlayback(nil)
            let playerView = try #require(viewer.videoPlayerView)
            viewer.togglePlayback(nil)

            let control = Control(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            playerView.addSubview(control)
            #expect(window.makeFirstResponder(control))
            #expect(window.firstResponder === viewer.canvas)

            let outside = Control(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            window.contentView?.addSubview(outside)
            defer { outside.removeFromSuperview() }
            #expect(window.makeFirstResponder(outside))
            #expect(window.firstResponder === outside)

            viewer.previousImage(nil)
            #expect(viewer.keyboardRedirect(for: control) == nil)
            window.makeFirstResponder(viewer.canvas)
        }

        /// The picture on a pasteboard of the test's own, as a CGImage.
        func pastedImage(_ board: NSPasteboard) throws -> CGImage {
            let image = try #require(NSImage(pasteboard: board))
            return try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }

        /// Copy Frame and Save Frame As take the frame on screen, at the
        /// video's own size: the first frame (black) before anything plays,
        /// later where the player stands. Never for a photo.
        @Test func copyFrameAndSaveFrameAsTakeTheFrameOnScreen() async throws {
            let t = try ScratchFolder()
            let photo = try t.jpeg("a.jpg", width: 320, height: 240)
            let video = try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"), width: 480, height: 288,
                                                  seconds: 3, color: (20, 30, 230))
            let board = NSPasteboard(name: NSPasteboard.Name("minivu-video-tests-\(UUID().uuidString)"))
            defer {
                board.releaseGlobally()
                closeViewer()
            }
            let viewer = try await open([photo, video], at: 1)
            #expect(viewer.validateMenuItem(item(.copyFrame)) && viewer.validateMenuItem(item(.saveFrameAs)))
            #expect(!viewer.validateMenuItem(item(#selector(NSText.copy(_:)))), "⌘C stays off for a video")

            // Nothing played: the still on screen, which is the first frame.
            await viewer.copyVideoFrame(to: board)?.value
            let first = try pastedImage(board)
            #expect(first.width == 480 && first.height == 288)
            let black = TestVideos.centreColor(of: first)
            #expect(black.red < 30 && black.green < 30 && black.blue < 30, "\(black)")

            // Played, paused and moved to 1.5 s: that frame.
            viewer.togglePlayback(nil)
            let playback = try #require(viewer.videoPlayback)
            viewer.pauseVideo()
            await playback.player.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600), toleranceBefore: .zero,
                                       toleranceAfter: .zero)
            #expect(abs(viewer.shownVideoFrameTime - 1.5) < 0.01)
            await viewer.copyVideoFrame(to: board)?.value
            let later = TestVideos.centreColor(of: try pastedImage(board))
            #expect(later.blue > 180 && later.red < 80, "\(later)")

            // Save Frame As hands the same time to Save As, and pauses a
            // playing video so the panel saves what is on screen.
            var asked: (name: String, seconds: Double)?
            let present = ViewerWindowController.presentSaveFrameAs
            ViewerWindowController.presentSaveFrameAs = { entry, seconds, _, completion in
                asked = (entry.name, seconds)
                completion(nil)
            }
            defer { ViewerWindowController.presentSaveFrameAs = present }
            playback.play()
            viewer.saveFrameAs(nil)
            #expect(playback.player.rate == 0)
            #expect(asked?.name == "b.mov")
            #expect(abs((asked?.seconds ?? -1) - viewer.shownVideoFrameTime) < 0.01)

            // A photo has no frame to take.
            viewer.previousImage(nil)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 320, height: 240) }
            #expect(!viewer.validateMenuItem(item(.copyFrame)) && !viewer.validateMenuItem(item(.saveFrameAs)))
            #expect(viewer.copyVideoFrame(to: board) == nil)
        }

        /// One player at a time, and none while nothing is asked to play:
        /// flipping from one playing video to the next lets the first go
        /// before the second is made, and closing lets the last go.
        @Test func onePlayerAtATime() async throws {
            let t = try ScratchFolder()
            let first = try await TestVideos.make(at: t.url.appendingPathComponent("a.mov"))
            let second = try await TestVideos.make(at: t.url.appendingPathComponent("b.mov"), color: (20, 200, 40))
            defer { closeViewer() }
            #expect(VideoPlayback.liveCount == 0)
            let viewer = try await open([first, second], at: 0)
            #expect(VideoPlayback.liveCount == 0, "showing a video makes no player")

            viewer.togglePlayback(nil)
            #expect(VideoPlayback.liveCount == 1)
            viewer.nextImage(nil)
            #expect(VideoPlayback.liveCount == 0)
            await TestTiming.waitUntil { viewer.displayed == viewer.current && viewer.canvasTexture != nil }
            viewer.togglePlayback(nil)
            #expect(VideoPlayback.liveCount == 1)
            // Pausing and playing again keeps the one player.
            let playback = viewer.videoPlayback
            viewer.togglePlayback(nil)
            viewer.togglePlayback(nil)
            #expect(viewer.videoPlayback === playback && VideoPlayback.liveCount == 1)
            closeViewer()
            #expect(VideoPlayback.liveCount == 0)
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

/// Save Frame As (G18) through the Save As machinery, without the panel:
/// the frame at the time asked, at the video's own size, named after the
/// video and the time, and without the movie's metadata.
@MainActor @Suite struct VideoFrameSaveTests {
    @Test func savesTheFrameAtItsOwnSize() async throws {
        let t = try ScratchFolder()
        let video = try await TestVideos.make(at: t.url.appendingPathComponent("clip.mov"), width: 480, height: 288,
                                              seconds: 3, color: (20, 200, 40))
        let entry = try #require(FolderEntry(url: video))
        let scratchDefaults = ScratchDefaults("minivu-video-tests")
        defer { scratchDefaults.remove() }
        let model = SaveAsModel(videoFrameOf: entry, seconds: 1.2, store: SaveOptionsStore(defaults: scratchDefaults.defaults))
        defer { model.cancel() }
        #expect(model.suggestedName == "clip frame 0.01")
        #expect(SaveAsNaming.renamed(model.suggestedName, to: .png) == "clip frame 0.01.png")
        #expect(!model.carriesMetadata && model.source.metadataSource == nil)
        #expect(SaveAsModel.frameName(of: video, seconds: 3725) == "clip frame 1.02.05")

        let output = t.url.appendingPathComponent("frame.png")
        try await SavePresenter.write(model.source, options: .defaults(for: .png), to: output,
                                      metadataSource: model.source.metadataSource)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 480 && image.height == 288)
        let green = TestVideos.centreColor(of: image)
        #expect(green.green > 150 && green.red < 80, "\(green)")
        // The movie itself is untouched.
        #expect(FileManager.default.fileExists(atPath: video.path))

        // The first frame of the same clip is black: the time was honoured.
        let start = SaveImageSource(videoFrame: video, seconds: 0)
        let first = try await start.image(for: .defaults(for: .png))
        let black = TestVideos.centreColor(of: first)
        #expect(black.red < 30 && black.green < 30, "\(black)")
    }
}
