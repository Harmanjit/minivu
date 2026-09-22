import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// Displays that don't exist: connected, disconnected and notched at will.
/// A window is on the display it overlaps most, as AppKit decides.
@MainActor final class FakeScreens: ScreenProviding {
    var displays: [DisplayInfo]

    init(_ displays: [DisplayInfo]) { self.displays = displays }

    var mainDisplay: DisplayInfo? { displays.first }

    func display(of window: NSWindow) -> DisplayInfo? {
        DisplayPlacement.display(for: window.frame, in: displays)
    }

    /// As the system does when a display comes or goes.
    func postChange() {
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }
}

/// Presentation options that never reach the app, with every write recorded.
@MainActor final class FakePresentationOptions {
    var value: NSApplication.PresentationOptions = []
    var writes: [NSApplication.PresentationOptions] = []

    func makeCoordinator() -> FullScreenPresentation {
        FullScreenPresentation(read: { [unowned self] in value }, write: { [unowned self] in
            value = $0
            writes.append($0)
        })
    }
}

/// Far from any real display, so test windows never cover the screen.
private func display(_ id: UInt32, x: CGFloat, width: CGFloat = 800, height: CGFloat = 500, safeAreaTop: CGFloat = 0,
                     potentialHeadroom: CGFloat = 1, colorSpace: CFString = CGColorSpace.sRGB) -> DisplayInfo {
    let frame = CGRect(x: 40_000 + x, y: 40_000, width: width, height: height)
    var visible = frame
    visible.size.height -= 25   // a menu bar
    return DisplayInfo(id: id, frame: frame, visibleFrame: visible, safeAreaTop: safeAreaTop, backingScale: 2,
                       headroom: 1, potentialHeadroom: potentialHeadroom, colorSpace: CGColorSpace(name: colorSpace))
}

@MainActor @Suite struct DisplayPlacementTests {
    let left = display(7, x: 0)
    let right = display(3, x: 800, width: 1000, height: 600)
    let below = display(9, x: 0, height: 400)

    @Test func nextDisplayWalksLeftToRightAndWraps() {
        // Listed in the system's order, not the desk's.
        let displays = [right, left]
        #expect(DisplayPlacement.ordered(displays).map(\.id) == [7, 3])
        #expect(DisplayPlacement.next(after: left, in: displays)?.id == 3)
        #expect(DisplayPlacement.next(after: right, in: displays)?.id == 7)
        #expect(DisplayPlacement.next(after: left, in: [left])?.id == 7)
        // A display that has gone: start again from the first.
        #expect(DisplayPlacement.next(after: below, in: displays)?.id == 7)
        #expect(DisplayPlacement.next(after: nil, in: []) == nil)
    }

    @Test func aWindowIsOnTheDisplayItOverlapsMost() {
        let displays = [left, right]
        let mostlyRight = CGRect(x: right.frame.minX - 100, y: right.frame.minY, width: 400, height: 300)
        #expect(DisplayPlacement.display(for: mostlyRight, in: displays)?.id == 3)
        #expect(DisplayPlacement.display(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: displays) == nil)
    }

    @Test func fullScreenOnTheBrowsersDisplay() {
        let displays = [left, right]
        // From the browser: its display. From a viewer window elsewhere: that one.
        #expect(DisplayPlacement.fullScreenDisplay(choice: .browserDisplay, browser: left, current: left,
                                                   displays: displays)?.id == 7)
        #expect(DisplayPlacement.fullScreenDisplay(choice: .browserDisplay, browser: left, current: right,
                                                   displays: displays)?.id == 3)
        #expect(DisplayPlacement.fullScreenDisplay(choice: .browserDisplay, browser: nil, current: nil,
                                                   displays: displays)?.id == 7)
        #expect(DisplayPlacement.fullScreenDisplay(choice: .browserDisplay, browser: nil, current: nil,
                                                   displays: []) == nil)
    }

    @Test func fullScreenOnAnotherDisplay() {
        let displays = [left, right, below]
        // From the browser: the display after the browser's.
        #expect(DisplayPlacement.fullScreenDisplay(choice: .anotherDisplay, browser: left, current: left,
                                                   displays: displays)?.id == 9)
        #expect(DisplayPlacement.fullScreenDisplay(choice: .anotherDisplay, browser: right, current: right,
                                                   displays: displays)?.id == 7)
        // Already away from the browser (a slideshow from a full-screen
        // viewer, a viewer window dragged across): stays there.
        #expect(DisplayPlacement.fullScreenDisplay(choice: .anotherDisplay, browser: left, current: right,
                                                   displays: displays)?.id == 3)
        // One display: that one.
        #expect(DisplayPlacement.fullScreenDisplay(choice: .anotherDisplay, browser: left, current: left,
                                                   displays: [left])?.id == 7)
        // The browser's display has gone: nothing to avoid.
        #expect(DisplayPlacement.fullScreenDisplay(choice: .anotherDisplay, browser: below, current: nil,
                                                   displays: [left, right])?.id == 7)
    }

    @Test func aMovedWindowKeepsItsPlaceAndFits() {
        // Top right of the left display's usable area...
        let visible = left.visibleFrame
        let frame = CGRect(x: visible.maxX - 300, y: visible.maxY - 200, width: 300, height: 200)
        let moved = DisplayPlacement.movedFrame(frame, from: left, to: right)
        // ...is top right of the right display's.
        #expect(moved == CGRect(x: right.visibleFrame.maxX - 300, y: right.visibleFrame.maxY - 200,
                                width: 300, height: 200))
        // Too big for the new display: shrinks to its usable area.
        let big = CGRect(x: right.visibleFrame.minX, y: right.visibleFrame.minY, width: 1000, height: 575)
        #expect(DisplayPlacement.movedFrame(big, from: right, to: below) == below.visibleFrame)
    }

    /// The picture stays below a camera housing, in either kind of view.
    @Test func pictureAreaClearsTheCameraHousing() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(DisplayPlacement.pictureArea(in: bounds, safeAreaTop: 38, flipped: false)
            == CGRect(x: 0, y: 0, width: 1512, height: 944))
        #expect(DisplayPlacement.pictureArea(in: bounds, safeAreaTop: 38, flipped: true)
            == CGRect(x: 0, y: 38, width: 1512, height: 944))
        #expect(DisplayPlacement.pictureArea(in: bounds, safeAreaTop: 0, flipped: true) == bounds)
        #expect(DisplayPlacement.pictureArea(in: CGRect(x: 0, y: 0, width: 10, height: 20), safeAreaTop: 50,
                                             flipped: false).height == 0)
    }

    @Test func thumbnailsFollowTheBrowsersDisplay() {
        let p3 = display(1, x: 0, colorSpace: CGColorSpace.displayP3)
        let srgb = display(2, x: 800, colorSpace: CGColorSpace.sRGB)
        let screens = FakeScreens([srgb, p3])
        let browser = NSWindow(contentRect: CGRect(x: p3.frame.minX + 10, y: p3.frame.minY + 10, width: 300,
                                                   height: 200), styleMask: [.borderless], backing: .buffered,
                               defer: true)
        #expect(AppServices.thumbnailColorSpace(browser: browser, provider: screens).name == CGColorSpace.displayP3)
        browser.setFrameOrigin(CGPoint(x: srgb.frame.minX + 10, y: srgb.frame.minY + 10))
        #expect(AppServices.thumbnailColorSpace(browser: browser, provider: screens).name == CGColorSpace.sRGB)
        // No browser: the main display's.
        screens.displays = [p3, srgb]
        #expect(AppServices.thumbnailColorSpace(browser: nil, provider: screens).name == CGColorSpace.displayP3)
    }

    @Test func windowMenuMovesToTheNextDisplay() throws {
        _ = NSApplication.shared
        let window = try #require(MainMenu.make().items.first { $0.title == "Window" }?.submenu)
        let item = try #require(window.items.first { $0.title == "Move to Next Display" })
        #expect(item.action == .moveToNextDisplay)
        #expect(item.keyEquivalent == MainMenu.Key.right)
        #expect(item.keyEquivalentModifierMask == [.control, .option, .command])
    }
}

@MainActor @Suite struct FullScreenPresentationTests {
    func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func hidesWhileAnyOwnerIsKeyAndRestoresTheOriginalOptions() async {
        let options = FakePresentationOptions()
        options.value = [.autoHideToolbar]
        let presentation = options.makeCoordinator()
        let viewer = NSObject(), slideshow = NSObject()

        presentation.hide(for: viewer)
        #expect(options.value == FullScreenPresentation.hiding)
        // The key window goes to a slideshow on another display, and AppKit
        // tells the slideshow first: the viewer letting go afterwards must
        // not bring the menu bar back, nor save "hidden" to go back to.
        presentation.hide(for: slideshow)
        presentation.release(viewer)
        await nextTurn()
        #expect(options.value == FullScreenPresentation.hiding && presentation.isHiding)
        presentation.release(slideshow)
        #expect(presentation.isHiding == false)
        await nextTurn()
        #expect(options.value == [.autoHideToolbar])
        // Letting go of nothing changes nothing.
        presentation.release(viewer)
        await nextTurn()
        #expect(options.writes == [FullScreenPresentation.hiding, [.autoHideToolbar]])
    }

    /// A slideshow ending over a full-screen viewer lets go just before the
    /// viewer becomes key again: the menu bar mustn't flash in between.
    @Test func aSlideshowEndingOverTheViewerDoesNotFlashTheMenuBar() async {
        let options = FakePresentationOptions()
        let presentation = options.makeCoordinator()
        let viewer = NSObject(), slideshow = NSObject()
        presentation.hide(for: viewer)
        presentation.release(viewer)
        presentation.hide(for: slideshow)
        presentation.release(slideshow)
        presentation.hide(for: viewer)
        await nextTurn()
        #expect(options.writes == [FullScreenPresentation.hiding])
        presentation.release(viewer)
        await nextTurn()
        #expect(options.value == [] && options.writes == [FullScreenPresentation.hiding, []])
    }
}

extension AppWindowTests {
    /// The viewer and slideshow on displays that don't exist: which display
    /// they open on, moving between displays, a display unplugged, and a
    /// notched one. Displays sit far from the real ones, so nothing covers
    /// the screen, and presentation options are fake.
    @MainActor @Suite(.serialized) struct DisplayWindowTests {
        init() { _ = NSApplication.shared }

        struct Setup {
            let screens: FakeScreens
            let options: FakePresentationOptions
            let browser: NSWindow
            let images: [FolderEntry]
            let folder: ScratchFolder
        }

        /// Runs `body` with `displays` connected, the browser window on the
        /// first, and the full-screen display choice set.
        func withDisplays(_ displays: [DisplayInfo], choice: FullScreenDisplayChoice,
                          _ body: (Setup) async throws -> Void) async throws {
            let screens = FakeScreens(displays)
            let options = FakePresentationOptions()
            let first = displays[0].visibleFrame
            let browser = NSWindow(contentRect: CGRect(x: first.minX + 20, y: first.minY + 20, width: 400, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: true)
            browser.isReleasedWhenClosed = false
            let saved = (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared)
            Displays.provider = screens
            Displays.choice = { choice }
            Displays.browserWindow = { browser }
            FullScreenPresentation.shared = options.makeCoordinator()
            defer {
                ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
                SlideshowWindowController.current?.end()
                (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared) = saved
            }
            let folder = try ScratchFolder()
            let images = try ["a.jpg", "b.jpg"].map {
                try #require(FolderEntry(url: try folder.jpeg($0, width: 600, height: 400)))
            }
            try await body(Setup(screens: screens, options: options, browser: browser, images: images, folder: folder))
        }

        @Test func fullScreenViewerOpensOnAnotherDisplayAndMoves() async throws {
            let one = display(1, x: 0), two = display(2, x: 800, width: 1000, height: 600)
            try await withDisplays([one, two], choice: .anotherDisplay) { setup in
                ViewerWindowController.show(images: setup.images, index: 0, fullScreen: true) { _ in }
                let viewer = try #require(ViewerWindowController.current)
                let window = try #require(viewer.window)
                #expect(viewer.isFullScreen && window.frame == two.frame && viewer.fullScreenDisplayID == 2)
                let move = NSMenuItem(title: "", action: .moveToNextDisplay, keyEquivalent: "")
                #expect(viewer.validateMenuItem(move))

                viewer.moveToNextDisplay(nil)
                #expect(window.frame == one.frame && viewer.fullScreenDisplayID == 1)
                viewer.moveToNextDisplay(nil)
                #expect(window.frame == two.frame)

                // Unplugged: on to the display that's left, still showing.
                setup.screens.displays = [one]
                setup.screens.postChange()
                #expect(viewer.window === window && window.isVisible)
                #expect(window.frame == one.frame && viewer.fullScreenDisplayID == 1)
                #expect(!viewer.validateMenuItem(move))
                viewer.moveToNextDisplay(nil)
                #expect(window.frame == one.frame)

                // Same id, new resolution: still covers it.
                var larger = one
                larger.frame.size = CGSize(width: 1000, height: 700)
                setup.screens.displays = [larger]
                setup.screens.postChange()
                #expect(window.frame == larger.frame)
            }
        }

        @Test func fullScreenViewerOnTheBrowsersDisplayFitsBelowTheNotch() async throws {
            let notched = display(1, x: 0, width: 1512, height: 982, safeAreaTop: 38)
            let plain = display(2, x: 1512)
            try await withDisplays([notched, plain], choice: .browserDisplay) { setup in
                ViewerWindowController.show(images: setup.images, index: 0, fullScreen: true) { _ in }
                let viewer = try #require(ViewerWindowController.current)
                let window = try #require(viewer.window)
                #expect(window.frame == notched.frame)
                // Black across the whole screen, whatever the surround.
                #expect(window.backgroundColor == .black)
                viewer.container.layoutSubtreeIfNeeded()
                // The image fits below the camera housing; the HUD and the
                // top panel sit below it too.
                #expect(viewer.container.contentArea == CGRect(x: 0, y: 0, width: 1512, height: 944))
                #expect(viewer.canvasView.frame == CGRect(x: 0, y: 0, width: 1512, height: 944))
                #expect(viewer.hud.frame.maxY <= 944 - ViewerWindowController.hudMargin + 0.5)
                #expect(viewer.flyouts.area == viewer.container.contentArea)
                // The pointer at the very top, beside the camera, still opens the filmstrip.
                #expect(viewer.flyouts.reach == viewer.container.bounds)

                // On a display without one, the image has the full height.
                viewer.moveToNextDisplay(nil)
                viewer.container.layoutSubtreeIfNeeded()
                #expect(window.frame == plain.frame)
                #expect(viewer.canvasView.frame.height == plain.frame.height)
            }
        }

        /// AppKit keeps a titled window on a real display, so these two fake
        /// displays are the halves of the real main one.
        @Test func windowedViewerMovesToTheNextDisplay() async throws {
            let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
            let half = (screen.width / 2).rounded(.down)
            let one = DisplayInfo(id: 1, frame: CGRect(x: screen.minX, y: screen.minY, width: half, height: screen.height))
            let two = DisplayInfo(id: 2, frame: CGRect(x: screen.minX + half, y: screen.minY, width: half,
                                                       height: screen.height))
            try await withDisplays([one, two], choice: .anotherDisplay) { setup in
                ViewerWindowController.show(images: setup.images, index: 0, fullScreen: false) { _ in }
                let viewer = try #require(ViewerWindowController.current)
                let window = try #require(viewer.window)
                // The autosaved frame goes back as it was.
                let original = window.frame
                defer { window.setFrame(original, display: false) }
                let start = CGRect(x: one.frame.minX + 40, y: one.frame.minY + 40, width: min(640, half - 80),
                                   height: min(420, screen.height - 80))
                window.setFrame(start, display: false)
                viewer.moveToNextDisplay(nil)
                #expect(window.frame == DisplayPlacement.movedFrame(start, from: one, to: two))
                #expect(two.frame.contains(window.frame))

                // Full screen from a window away from the browser's display: stays on its display.
                viewer.toggleFullScreenViewer(nil)
                #expect(viewer.isFullScreen && viewer.window?.frame == two.frame)
                viewer.toggleFullScreenViewer(nil)
                #expect(!viewer.isFullScreen && viewer.window === window)
            }
        }

        @Test func slideshowFollowsTheViewerSettingMovesAndSurvivesUnplugging() async throws {
            let one = display(1, x: 0)
            let two = display(2, x: 800, width: 1512, height: 982, safeAreaTop: 38)
            let saved = SlideshowWindowController.makeAudioPlayer
            SlideshowWindowController.makeAudioPlayer = { FakeSlideshowAudioPlayer() }
            defer { SlideshowWindowController.makeAudioPlayer = saved }
            try await withDisplays([one, two], choice: .anotherDisplay) { setup in
                // From the browser on display one: plays on display two, below its notch.
                let slideshow = try #require(SlideshowWindowController.start(images: setup.images, startIndex: 0,
                                                                            from: setup.browser) { _ in })
                defer { slideshow.end() }
                let window = try #require(slideshow.window)
                #expect(window.frame == two.frame && slideshow.displayID == 2)
                #expect(slideshow.decodeFitSize == CGSize(width: 1512 * 2, height: 944 * 2))
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(slideshow.pictureFrame == CGRect(x: 0, y: 38, width: 1512, height: 944))
                #expect(window.backgroundColor == .black)

                #expect(slideshow.validateMenuItem(NSMenuItem(title: "", action: .moveToNextDisplay,
                                                              keyEquivalent: "")))
                slideshow.moveToNextDisplay(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(window.frame == one.frame && slideshow.pictureFrame == CGRect(origin: .zero, size: one.frame.size))

                // Display one unplugged: back on two, and the show goes on.
                setup.screens.displays = [two]
                setup.screens.postChange()
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(window.frame == two.frame && window.isVisible && !slideshow.hasEnded)
                #expect(slideshow.pictureFrame.minY == 38)
                await TestTiming.waitUntil { slideshow.shownIndex == 0 }
                #expect(slideshow.shownIndex == 0)
            }
        }

        /// A slideshow started from a full-screen viewer plays over it, and
        /// when it ends the menu bar stays hidden for the viewer and comes
        /// back, as it was, only when the viewer leaves full screen.
        @Test func slideshowOverAFullScreenViewerRestoresPresentationInOrder() async throws {
            let one = display(1, x: 0), two = display(2, x: 800)
            let saved = SlideshowWindowController.makeAudioPlayer
            SlideshowWindowController.makeAudioPlayer = { FakeSlideshowAudioPlayer() }
            defer { SlideshowWindowController.makeAudioPlayer = saved }
            try await withDisplays([one, two], choice: .anotherDisplay) { setup in
                setup.options.value = [.autoHideToolbar]
                let presentation = FullScreenPresentation.shared
                ViewerWindowController.show(images: setup.images, index: 0, fullScreen: true) { _ in }
                let viewer = try #require(ViewerWindowController.current)
                let viewerWindow = try #require(viewer.window)
                // The app may not be active under the test runner, so key
                // changes are told to the delegates as AppKit would.
                @MainActor func key(_ window: NSWindow, _ became: Bool) {
                    let name = became ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification
                    let note = Notification(name: name, object: window)
                    let delegate = window.delegate
                    if became { delegate?.windowDidBecomeKey?(note) } else { delegate?.windowDidResignKey?(note) }
                }
                key(viewerWindow, true)
                #expect(presentation.isHiding && setup.options.value == FullScreenPresentation.hiding)

                viewer.startSlideshow(nil)
                let slideshow = try #require(SlideshowWindowController.current)
                let showWindow = try #require(slideshow.window)
                #expect(showWindow.frame == two.frame)   // over the viewer, not on the browser's display
                key(showWindow, true)
                key(viewerWindow, false)
                slideshow.end()
                key(viewerWindow, true)
                try? await Task.sleep(for: .milliseconds(50))
                #expect(setup.options.value == FullScreenPresentation.hiding)
                #expect(!setup.options.writes.contains([.autoHideToolbar]))

                viewer.toggleFullScreenViewer(nil)
                await TestTiming.waitUntil { setup.options.value == [.autoHideToolbar] }
                #expect(setup.options.value == [.autoHideToolbar] && !presentation.isHiding)
            }
        }

        /// A small texture flagged HDR, headroom 4.
        func hdrTexture() throws -> ImageTexture {
            let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(gray: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let image = try #require(context.makeImage())
            return try TextureUploader.upload(DecodedImage(image: image, orientation: .up,
                                                           imageSize: CGSize(width: 64, height: 48),
                                                           isFullResolution: true, isHDR: true,
                                                           contentHeadroom: 4, needsDeepStorage: true))
        }

        /// A borderless window on `display` with a canvas filling it.
        func canvasWindow(on display: DisplayInfo) -> (NSWindow, ImageCanvasView) {
            let window = NSWindow(contentRect: CGRect(x: display.frame.minX + 10, y: display.frame.minY + 10, width: 320,
                                                      height: 240),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            window.contentView = canvas
            return (window, canvas)
        }

        /// The canvas (the viewer's, and each compare pane's) turns EDR on or
        /// off for the display its window moves to.
        @Test func canvasDynamicRangeFollowsTheDisplay() async throws {
            let sdr = display(1, x: 0, potentialHeadroom: 1), xdr = display(2, x: 800, potentialHeadroom: 16)
            try await withDisplays([sdr, xdr], choice: .browserDisplay) { setup in
                let hdr = try hdrTexture()
                let (window, canvas) = canvasWindow(on: sdr)
                defer {
                    window.contentView = nil
                    window.close()
                }
                canvas.setImage(hdr, preserveView: false)
                #expect(!canvas.isExtendedDynamicRange)

                window.setFrameOrigin(CGPoint(x: xdr.frame.minX + 10, y: xdr.frame.minY + 10))
                NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
                #expect(canvas.isExtendedDynamicRange)

                window.setFrameOrigin(CGPoint(x: sdr.frame.minX + 10, y: sdr.frame.minY + 10))
                NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
                #expect(!canvas.isExtendedDynamicRange)
            }
        }

        /// Every frame is tone mapped to the headroom the screen has when it
        /// is drawn, so a frame drawn while the headroom was low looks SDR
        /// until another one is drawn. The system says when the headroom
        /// changes, but its notification can come before the new value can
        /// be read, or not at all; the canvas still catches up by itself,
        /// without waiting for a click to redraw it, then goes idle again.
        @Test func canvasCatchesUpWithHeadroomChangesNobodyAnnounced() async throws {
            let xdr = display(2, x: 0, potentialHeadroom: 16)
            try await withDisplays([xdr], choice: .browserDisplay) { setup in
                let (window, canvas) = canvasWindow(on: xdr)
                defer {
                    window.contentView = nil
                    window.close()
                }
                @MainActor func headroom(_ value: CGFloat) { setup.screens.displays[0].headroom = value }
                @MainActor func refresh() { for _ in 0..<3 { canvas.displayRefreshed() } }

                // EDR comes on: the screen has no headroom yet.
                canvas.setImage(try hdrTexture(), preserveView: false)
                refresh()
                #expect(canvas.isExtendedDynamicRange && canvas.lastFrameHeadroom == 1)

                // The rise is announced before its value can be read.
                setup.screens.postChange()
                headroom(8)
                refresh()
                #expect(canvas.lastFrameHeadroom == 8)

                // A dip is announced, a new texture arrives during it (an
                // edit render), and the recovery isn't announced.
                headroom(1)
                setup.screens.postChange()
                refresh()
                canvas.setImage(try hdrTexture(), preserveView: true)
                refresh()
                #expect(canvas.lastFrameHeadroom == 1)
                headroom(6)
                refresh()
                #expect(canvas.lastFrameHeadroom == 6)

                // Steady for a while: the display link stops.
                try await Task.sleep(for: .seconds(ImageCanvasView.headroomSettleTime + 0.3))
                refresh()
                #expect(!canvas.isRefreshing)

                // Resized (a tools panel closing), then a change nobody announced.
                canvas.setFrameSize(NSSize(width: 280, height: 240))
                refresh()
                headroom(8)
                refresh()
                #expect(canvas.lastFrameHeadroom == 8)

                // An SDR image watches nothing.
                canvas.setImage(nil, preserveView: false)
                refresh()
                #expect(!canvas.isExtendedDynamicRange && !canvas.isRefreshing)
            }
        }

        /// A frame drawn for less headroom than the image can use (the
        /// screen's headroom dipped, or is lower than the image's) keeps the
        /// canvas checking the headroom a few times a second for as long as
        /// that lasts, so a rise nobody announces is caught however late it
        /// comes. A frame that shows the image whole needs nothing more, and
        /// the canvas goes idle.
        @Test func canvasCatchesAnUnannouncedRiseHoweverLateItComes() async throws {
            let xdr = display(2, x: 0, potentialHeadroom: 16)
            let settleTime = ImageCanvasView.headroomSettleTime
            ImageCanvasView.headroomSettleTime = 0.05
            defer { ImageCanvasView.headroomSettleTime = settleTime }
            try await withDisplays([xdr], choice: .browserDisplay) { setup in
                let (window, canvas) = canvasWindow(on: xdr)
                defer {
                    window.contentView = nil
                    window.close()
                }
                @MainActor func headroom(_ value: CGFloat) { setup.screens.displays[0].headroom = value }
                @MainActor func refresh() { for _ in 0..<3 { canvas.displayRefreshed() } }
                /// Past the settle time, refreshing as the display link would.
                @MainActor func wait(_ milliseconds: Int = 150) async throws {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                    refresh()
                }

                // Headroom 4 on a screen at 8: shown whole, so idle once settled.
                headroom(8)
                canvas.setImage(try hdrTexture(), preserveView: false)
                refresh()
                #expect(canvas.lastFrameHeadroom == 8)
                try await wait()
                #expect(!canvas.isRefreshing)

                // A dip, announced; the rise, long after the settle time, isn't.
                headroom(1)
                setup.screens.postChange()
                refresh()
                #expect(canvas.lastFrameHeadroom == 1)
                try await wait(400)
                #expect(canvas.isRefreshing && canvas.isRefreshingSlowly, "a frame below the image's headroom is followed")
                #expect(canvas.lastFrameHeadroom == 1, "nothing is redrawn while the headroom stays")
                headroom(8)
                refresh()
                #expect(canvas.lastFrameHeadroom == 8)
                try await wait()
                #expect(!canvas.isRefreshing)

                // A screen that stays below the image's headroom is followed,
                // slowly, through a partial rise; a redraw asked for meanwhile
                // (a pan) runs at the display's own rate.
                headroom(2)
                setup.screens.postChange()
                refresh()
                try await wait()
                #expect(canvas.lastFrameHeadroom == 2 && canvas.isRefreshingSlowly)
                headroom(3)
                refresh()
                #expect(canvas.lastFrameHeadroom == 3)
                try await wait()
                #expect(canvas.isRefreshingSlowly)
                canvas.setNeedsRedraw()
                #expect(canvas.isRefreshing && !canvas.isRefreshingSlowly)
                try await wait()
                #expect(canvas.isRefreshingSlowly)

                // The image gone, nothing is followed.
                canvas.setImage(nil, preserveView: false)
                try await wait()
                #expect(!canvas.isRefreshing)
            }
        }
    }
}
