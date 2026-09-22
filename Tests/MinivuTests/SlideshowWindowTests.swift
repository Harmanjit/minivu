import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// Real slideshow windows over real viewer windows: stepping, pausing,
    /// skipping files that won't load, ending, and where the viewer lands.
    /// Settings come from a scratch defaults suite, music is off (and would
    /// be silent), and the display-sleep assertion is checked to end.
    @MainActor @Suite(.serialized) struct SlideshowWindowTests {
        init() { _ = NSApplication.shared }

        /// Runs `body` with slideshow settings from a suite of its own.
        func withSettings(_ change: (inout SlideshowSettings) -> Void,
                          _ body: () async throws -> Void) async rethrows {
            let scratchDefaults = ScratchDefaults("minivu-slideshow-window-tests")
            let store = SlideshowSettingsStore(defaults: scratchDefaults.defaults)
            change(&store.settings)
            let savedStore = SlideshowWindowController.settingsStore
            let savedPlayer = SlideshowWindowController.makeAudioPlayer
            SlideshowWindowController.settingsStore = store
            SlideshowWindowController.makeAudioPlayer = { FakeSlideshowAudioPlayer() }
            defer {
                SlideshowWindowController.settingsStore = savedStore
                SlideshowWindowController.makeAudioPlayer = savedPlayer
                scratchDefaults.remove()
            }
            try await body()
        }

        func press(_ character: Int, in slideshow: SlideshowWindowController) throws {
            let window = try #require(slideshow.window)
            let characters = String(Character(UnicodeScalar(character)!))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            window.contentView?.keyDown(with: event)
        }

        /// Waits for `index` to be on screen with its transition over and the
        /// display link stopped.
        func settle(on index: Int, _ slideshow: SlideshowWindowController) async {
            await TestTiming.waitUntil { slideshow.shownIndex == index && !slideshow.isTransitioning && !slideshow.isAnimating }
        }

        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        @Test func stepsPausesAndEndsOnTheViewersImage() async throws {
            try await withSettings({
                $0.interval = 60   // no slide changes on its own during the test
                $0.transition = .fixed(.push)
                $0.transitionDuration = 0.3
                $0.caption = .name
            }) {
                let folder = try ScratchFolder()
                let list = try ["a.jpg", "b.jpg", "c.jpg"].map {
                    try #require(FolderEntry(url: try folder.jpeg($0, width: 600, height: 400)))
                }
                ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
                defer { closeViewer() }
                let viewer = try #require(ViewerWindowController.current)
                #expect(viewer.validateMenuItem(NSMenuItem(title: "", action: .startSlideshow, keyEquivalent: "")))

                viewer.startSlideshow(nil)
                let slideshow = try #require(SlideshowWindowController.current)
                // A failed expectation below mustn't leave a show running into the next test.
                defer { slideshow.end() }
                #expect(slideshow.window?.frame == viewer.window?.screen?.frame)
                #expect(slideshow.keepsDisplayAwake)
                await settle(on: 0, slideshow)
                #expect(slideshow.shownIndex == 0 && !slideshow.isAnimating)
                #expect(slideshow.captionText == "a.jpg")

                // Waited for rather than assumed, so a busy machine can't fail it.
                await TestTiming.waitUntil { slideshow.hasDecoded(1) }
                try press(NSRightArrowFunctionKey, in: slideshow)
                #expect(slideshow.isTransitioning)   // started at once: b was decoded ahead
                await settle(on: 1, slideshow)
                #expect(slideshow.shownIndex == 1)
                #expect(slideshow.captionText == "b.jpg")
                try press(NSLeftArrowFunctionKey, in: slideshow)
                await settle(on: 0, slideshow)
                #expect(slideshow.shownIndex == 0)
                // ← from the first slide loops round to the last.
                try press(NSLeftArrowFunctionKey, in: slideshow)
                await settle(on: 2, slideshow)
                #expect(slideshow.shownIndex == 2)

                try press(0x20, in: slideshow)
                #expect(slideshow.isPaused)
                #expect(slideshow.areControlsShown)   // the bar says so
                try press(0x20, in: slideshow)
                #expect(!slideshow.isPaused)
                try press(0x20, in: slideshow)
                #expect(slideshow.isPaused)

                try press(0x1B, in: slideshow)
                #expect(SlideshowWindowController.current == nil)
                #expect(slideshow.hasEnded && !slideshow.keepsDisplayAwake && !slideshow.isAnimating)
                #expect(slideshow.window?.isVisible != true)
                await TestTiming.waitUntil { viewer.model.index == 2 }
                #expect(viewer.model.index == 2)
                #expect(viewer.window?.title == "c.jpg")
                #expect(ViewerWindowController.current === viewer)
            }
        }

        @Test func skipsFilesThatWontLoadAndEndsAfterTheLastSlide() async throws {
            try await withSettings({
                $0.interval = 1
                $0.transitionDuration = 0.3
                $0.loop = false
            }) {
                let folder = try ScratchFolder()
                let good = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 300, height: 200)))
                let broken = try #require(FolderEntry(url: try folder.file("b.jpg", bytes: 64)))
                let last = try #require(FolderEntry(url: try folder.jpeg("c.jpg", width: 200, height: 300)))
                var ended: [FolderEntry?] = []
                let started = SlideshowWindowController.start(images: [good, broken, last], startIndex: 0,
                                                              from: nil) { ended.append($0) }
                let slideshow = try #require(started)
                defer { slideshow.end() }
                // A second start while one runs brings that one forward.
                #expect(SlideshowWindowController.start(images: [good], startIndex: 0, from: nil) { _ in }
                    === slideshow)
                await settle(on: 0, slideshow)
                // After the interval: past b, which won't decode, to c.
                await TestTiming.waitUntil { slideshow.shownIndex == 2 }
                #expect(slideshow.shownIndex == 2)
                #expect(slideshow.sequence.failed == [1])
                // After c's interval the show ends by itself, reporting c.
                await TestTiming.waitUntil { slideshow.hasEnded }
                #expect(ended == [last])
                #expect(SlideshowWindowController.current == nil)
                #expect(!slideshow.keepsDisplayAwake)
            }
        }

        #if DEBUG
        @Test func freezesATransitionForSnapshots() async throws {
            try await withSettings({ $0.interval = 60 }) {
                let folder = try ScratchFolder()
                let list = try ["a.jpg", "b.jpg"].map {
                    try #require(FolderEntry(url: try folder.jpeg($0, width: 400, height: 300)))
                }
                let slideshow = try #require(SlideshowWindowController.start(images: list, startIndex: 0,
                                                                            from: nil) { _ in })
                defer { slideshow.end() }
                await settle(on: 0, slideshow)
                slideshow.debugFreezeSlideshowTransition(nil)
                await TestTiming.waitUntil { slideshow.isTransitioning }
                #expect(slideshow.isTransitioning && slideshow.isPaused && slideshow.areControlsShown)
                try? await Task.sleep(for: .milliseconds(100))
                #expect(slideshow.isTransitioning && !slideshow.isAnimating)   // held, and nothing redraws
                let content = try #require(slideshow.window?.contentView)
                let view = try #require(content.subviews.compactMap { $0 as? SlideshowView }.first)
                #expect(view.snapshotImage() != nil)
            }
        }
        #endif

        /// Volume and Play Music changed in Settings while a show plays reach
        /// its music at once.
        @Test func settingsReachTheMusicOfARunningShow() async throws {
            let folder = try ScratchFolder()
            let item = try #require(SlideshowPlaylistResolver.item(for: try folder.file("song.mp3")))
            try await withSettings({
                $0.interval = 60
                $0.musicEnabled = true
                $0.playlist = [item]
                $0.volume = 0.8
            }) {
                let player = FakeSlideshowAudioPlayer()
                SlideshowWindowController.makeAudioPlayer = { player }
                let only = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 300, height: 200)))
                let slideshow = try #require(SlideshowWindowController.start(images: [only], startIndex: 0,
                                                                            from: nil) { _ in })
                defer { slideshow.end() }
                let music = try #require(slideshow.musicPlayer)
                await music.startTask?.value
                #expect(player.playing == "song.mp3")

                let store = SlideshowWindowController.settingsStore
                store.settings.volume = 0.25
                #expect(player.calls.last == .volume(0.25, SlideshowMusic.volumeFadeDuration))
                store.settings.musicEnabled = false
                #expect(player.calls.last == .volume(0, SlideshowMusic.muteFadeDuration))
                store.settings.musicEnabled = true
                #expect(player.calls.last == .volume(0.25, SlideshowMusic.muteFadeDuration))
            }
        }

        /// A looping show of one image keeps showing it when its interval is
        /// up, and File > Close Window (⌘W) is enabled and ends the show,
        /// though the borderless window has no close button.
        @Test func aSingleImageLoopsOnAndCloseWindowEndsTheShow() async throws {
            try await withSettings({
                $0.interval = 1
                $0.transitionDuration = 0.3
                $0.loop = true
            }) {
                let folder = try ScratchFolder()
                let only = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 300, height: 200)))
                var ended: [FolderEntry?] = []
                let slideshow = try #require(SlideshowWindowController.start(images: [only], startIndex: 0,
                                                                            from: nil) { ended.append($0) })
                defer { slideshow.end() }
                await settle(on: 0, slideshow)
                // Past the interval: still up, and idle.
                try? await Task.sleep(for: .milliseconds(1600))
                #expect(!slideshow.hasEnded && slideshow.shownIndex == 0 && !slideshow.isAnimating)

                let window = try #require(slideshow.window)
                let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)),
                                       keyEquivalent: "w")
                #expect(window.validateMenuItem(close))
                window.performClose(close)
                #expect(slideshow.hasEnded && SlideshowWindowController.current == nil)
                #expect(ended == [only])
            }
        }
    }
}
