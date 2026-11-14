import Testing
import AppKit
import ImageIO
import VisionKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// Recognises nothing and records what it was asked, so the tests decide
/// what text a picture holds and can count every analysis.
@MainActor final class FakeTextAnalyzer: LiveTextAnalyzing {
    var isSupported = true
    var transcript = "Twenty minutes past nine"
    /// The size of each picture analysed, in order.
    private(set) var sizes: [CGSize] = []

    func analyze(_ image: CGImage) async throws -> LiveTextResult {
        sizes.append(CGSize(width: image.width, height: image.height))
        return LiveTextResult(transcript: transcript, analysis: nil)
    }
}

extension AppWindowTests {
    /// Live Text in the viewer: analysed lazily, only for the picture on
    /// screen, never while it is turned off, and Copy Text. Every pasteboard
    /// here is a private one; nothing names the person's own clipboard.
    @MainActor @Suite(.serialized) struct LiveTextTests {
        init() { _ = NSApplication.shared }

        func scratchboard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("minivu-livetext-tests-\(UUID().uuidString)"))
        }

        /// Closes whatever viewer is open without asking about edits.
        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// A viewer on `count` small JPEGs, the first one decoded, with a
        /// fake analyser and a short settling time.
        func openViewer(_ folder: ScratchFolder, count: Int = 3, width: Int = 120,
                        height: Int = 80) async throws -> (ViewerWindowController, FakeTextAnalyzer) {
            let list = try (0..<count).map { index in
                try #require(FolderEntry(url: try folder.jpeg("p\(index).jpg", width: width, height: height)))
            }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            let fake = FakeTextAnalyzer()
            viewer.liveText.analyzer = fake
            viewer.liveText.settleDelay = 0.05
            await TestTiming.waitUntil { viewer.canEditCurrent && viewer.liveText.shown != nil }
            return (viewer, fake)
        }

        /// Waits for every main-queue turn already asked for, and a little
        /// longer than the settling time.
        func pause(_ seconds: Double = 0.2) async {
            try? await Task.sleep(for: .seconds(seconds))
        }

        /// The pointer moving over the viewer, as its tracking area reports it.
        func movePointer(_ viewer: ViewerWindowController) {
            viewer.flyouts.onPointerMoved?()
        }

        // MARK: - When

        /// Flipping through with the keyboard costs no analysis however long
        /// each picture stays up: only the pointer, which might select
        /// something, asks for one, and then only once per picture.
        @Test func pictureIsAnalysedOnlyWhenThePointerMovesAndOnlyOnce() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t)
            defer { closeViewer() }
            #expect(viewer.liveText.isActive)

            viewer.nextImage(nil)
            await TestTiming.waitUntil { viewer.displayed?.entry.name == "p1.jpg" }
            viewer.nextImage(nil)
            await TestTiming.waitUntil { viewer.displayed?.entry.name == "p2.jpg" }
            await pause()
            #expect(fake.sizes.isEmpty, "nothing was analysed while flipping")
            #expect(viewer.liveText.runningTask == nil && !viewer.liveText.isWaitingToSettle)

            movePointer(viewer)
            await TestTiming.waitUntil { viewer.liveText.result != nil }
            #expect(fake.sizes == [CGSize(width: 120, height: 80)])
            #expect(viewer.liveText.result?.subject.url.lastPathComponent == "p2.jpg")

            // The same picture is never analysed twice.
            for _ in 0..<5 { movePointer(viewer) }
            await pause()
            #expect(fake.sizes.count == 1)
        }

        /// A picture the user moves away from before it settles is never
        /// analysed.
        @Test func movingOnCancelsAnAnalysisStillWaitingToStart() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t)
            defer { closeViewer() }
            viewer.liveText.settleDelay = 30

            movePointer(viewer)
            #expect(viewer.liveText.isWaitingToSettle)
            viewer.nextImage(nil)
            #expect(!viewer.liveText.isWaitingToSettle, "cancelled with the move")
            await TestTiming.waitUntil { viewer.displayed?.entry.name == "p1.jpg" }
            await pause()
            #expect(fake.sizes.isEmpty)
            #expect(viewer.liveText.result == nil)
        }

        /// An analysis cancelled (the page reloaded under new settings) and
        /// asked for again for the same picture: the cancelled one must not
        /// report in place of its successor, whose result is kept.
        @Test func anAnalysisCancelledAndStartedAgainKeepsTheNewResult() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t, count: 1)
            defer { closeViewer() }
            viewer.liveText.settleDelay = 0
            movePointer(viewer)
            let first = try #require(viewer.liveText.runningTask)
            viewer.liveText.cancelPending()
            movePointer(viewer)
            let second = try #require(viewer.liveText.runningTask)
            #expect(await first.value == nil, "cancelled")
            _ = await second.value
            #expect(viewer.liveText.result?.value.transcript == fake.transcript)
            #expect(viewer.liveText.runningTask == nil)
        }

        /// An edit changes the picture, so its render is analysed afresh:
        /// what is shown, not the file.
        @Test func anEditIsAnalysedAsItIsShown() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t, count: 1)
            defer { closeViewer() }
            movePointer(viewer)
            await TestTiming.waitUntil { fake.sizes.count == 1 }
            #expect(viewer.liveText.result?.subject.operations == [])

            viewer.rotateRight(nil)
            await TestTiming.waitUntil { viewer.liveText.shown?.subject.operations.isEmpty == false }
            #expect(viewer.liveText.result == nil, "the analysis of the unturned picture is dropped")
            movePointer(viewer)
            await TestTiming.waitUntil { fake.sizes.count == 2 }
            #expect(fake.sizes.last == CGSize(width: 80, height: 120), "the turned picture: \(fake.sizes)")
        }

        // MARK: - Turned off

        /// Off means off: no analysis, no overlay, and no Copy Text. Turning
        /// it back on brings it all back without reopening the viewer.
        @Test func turningLiveTextOffStopsEverything() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t)
            defer { closeViewer() }
            let was = Preferences.shared.liveText
            defer { Preferences.shared.liveText = was }
            let delegate = AppDelegate()
            let item = NSMenuItem(title: "Live Text", action: #selector(AppDelegate.toggleLiveText(_:)),
                                  keyEquivalent: "")
            Preferences.shared.liveText = true
            #expect(delegate.validateMenuItem(item) && item.state == .on)

            delegate.toggleLiveText(item)
            #expect(!Preferences.shared.liveText)
            #expect(delegate.validateMenuItem(item) && item.state == .off)
            await TestTiming.waitUntil { !viewer.liveText.isActive }
            #expect(viewer.liveText.host.isHidden)
            movePointer(viewer)
            await pause()
            #expect(fake.sizes.isEmpty)
            #expect(viewer.validateLiveTextAction(.copyText) == false)
            #expect(viewer.copyText(to: scratchboard()) == nil)

            delegate.toggleLiveText(item)
            await TestTiming.waitUntil { viewer.liveText.isActive }
            #expect(!viewer.liveText.host.isHidden)
            movePointer(viewer)
            await TestTiming.waitUntil { fake.sizes.count == 1 }
        }

        /// An open edit tool owns the pointer, so Live Text stands aside
        /// while it is open and comes back when it closes.
        @Test func anOpenToolPutsLiveTextAside() async throws {
            let t = try ScratchFolder()
            let (viewer, _) = try await openViewer(t, count: 1)
            defer { closeViewer() }
            viewer.adjustLighting(nil)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            #expect(!viewer.liveText.isActive && viewer.liveText.host.isHidden)
            viewer.closeTool()
            #expect(viewer.liveText.isActive && !viewer.liveText.host.isHidden)
        }

        // MARK: - Copy Text

        /// Copy Text analyses at once if it must (the user asked; there is
        /// no settling to wait for) and puts all the text on the pasteboard.
        @Test func copyTextPutsTheRecognisedTextOnThePasteboard() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t)
            defer { closeViewer() }
            viewer.liveText.settleDelay = 30
            let board = scratchboard()
            defer { board.releaseGlobally() }
            let menuItem = NSMenuItem(title: "Copy Text", action: .copyText, keyEquivalent: "")
            #expect(viewer.validateMenuItem(menuItem), "through the viewer's own chain")

            try await #require(viewer.copyText(to: board)).value
            #expect(board.string(forType: .string) == "Twenty minutes past nine")
            #expect(fake.sizes.count == 1)

            // Again: from the analysis already made.
            board.clearContents()
            try await #require(viewer.copyText(to: board)).value
            #expect(board.string(forType: .string) == "Twenty minutes past nine")
            #expect(fake.sizes.count == 1)
        }

        /// A picture without text leaves the pasteboard as it was, and says
        /// so rather than going quiet.
        @Test func copyTextWithNoTextLeavesThePasteboardAlone() async throws {
            let t = try ScratchFolder()
            let (viewer, fake) = try await openViewer(t)
            defer { closeViewer() }
            fake.transcript = ""
            var told = 0
            let hook = ViewerWindowController.noTextToCopy
            ViewerWindowController.noTextToCopy = { told += 1 }
            defer { ViewerWindowController.noTextToCopy = hook }
            let board = scratchboard()
            defer { board.releaseGlobally() }
            board.clearContents()
            board.setString("copied before", forType: .string)

            try await #require(viewer.copyText(to: board)).value
            #expect(board.string(forType: .string) == "copied before")
            #expect(told == 1)
        }

        /// The browser has no picture to read, so Copy Text is not offered
        /// there.
        @Test func copyTextIsTheViewersAlone() {
            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            defer { controller.window?.close() }
            #expect(!controller.responds(to: .copyText))
        }

        // MARK: - The overlay over the canvas

        /// The picture's place in the overlay, as a fraction of its bounds:
        /// past them on the sides cut off when zoomed in.
        @Test func contentsRectFollowsThePicture() {
            let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
            #expect(LiveTextController.contentsRect(of: CGRect(x: 50, y: 0, width: 100, height: 100), in: bounds)
                == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
            #expect(LiveTextController.contentsRect(of: CGRect(x: -200, y: -100, width: 600, height: 300), in: bounds)
                == CGRect(x: -1, y: -1, width: 3, height: 3))
        }

        /// With the system's own recogniser: real text in a picture is read,
        /// the overlay takes the pointer on that text and nowhere else, and
        /// the text stays under the overlay's selection as the picture is
        /// zoomed and panned.
        @Test(.enabled(if: ImageAnalyzer.isSupported))
        func realTextIsSelectableWhereItIsDrawnAtAnyZoom() async throws {
            let t = try ScratchFolder()
            let photo = try Self.textImage(in: t.url)
            ViewerWindowController.show(images: [try #require(FolderEntry(url: photo))], index: 0,
                                        fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            viewer.liveText.settleDelay = 0
            await TestTiming.waitUntil { viewer.canEditCurrent && viewer.liveText.shown != nil }

            let text = await viewer.liveText.recognisedText()
            #expect(text?.uppercased().contains("MINIVU") == true, "read: \(text ?? "nothing")")
            let overlay = viewer.liveText.overlay
            #expect(overlay.analysis != nil)

            // Text at the top of the picture, nothing below it: a picture
            // placed upside down in the overlay would have it the other way.
            let canvas = viewer.canvasView
            func takesPointer(atImagePoint point: CGPoint) -> Bool {
                let inCanvas = canvas.viewPoint(forImagePoint: point)
                let inContainer = viewer.container.convert(inCanvas, from: canvas)
                return viewer.liveText.host.hitTest(inContainer) != nil
            }
            await TestTiming.waitUntil { takesPointer(atImagePoint: Self.onText) }
            #expect(takesPointer(atImagePoint: Self.onText), "on the text")
            #expect(!takesPointer(atImagePoint: Self.belowText), "beside it the canvas keeps its clicks")

            // Zoomed in and panned to the picture's top left corner, so it
            // no longer sits evenly in the canvas: the text has moved on
            // screen, and the overlay with it.
            let before = canvas.viewPoint(forImagePoint: Self.onText)
            canvas.zoom(by: 3, at: nil)
            canvas.pan(byPoints: CGSize(width: 2000, height: 2000))
            #expect(canvas.viewPoint(forImagePoint: Self.onText) != before)
            await TestTiming.waitUntil { takesPointer(atImagePoint: Self.onText) }
            #expect(takesPointer(atImagePoint: Self.onText), "on the text, zoomed in")
            #expect(!takesPointer(atImagePoint: Self.belowText), "beside it, zoomed in")
        }

        /// An HDR photo in a full-screen viewer: its texture is analysed
        /// (tone mapped by `LiveTextImage`), the overlay keeps to the
        /// canvas's frame, and going back to a window keeps the analysis,
        /// since the picture hasn't changed, only where it is drawn.
        @Test func liveTextFollowsTheHDRCanvasInAndOutOfFullScreen() async throws {
            let frame = CGRect(x: 40_000, y: 40_000, width: 800, height: 500)
            let xdr = DisplayInfo(id: 21, frame: frame, backingScale: 2, headroom: 8, potentialHeadroom: 16,
                                  colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
            let options = FakePresentationOptions()
            let saved = (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared)
            Displays.provider = FakeScreens([xdr])
            Displays.choice = { .browserDisplay }
            Displays.browserWindow = { nil }
            FullScreenPresentation.shared = options.makeCoordinator()
            defer {
                closeViewer()
                (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared) = saved
            }
            let folder = try ScratchFolder()
            let url = try AppWindowTests.HDREditingTests.gainMapHEIC(in: folder, width: 600, height: 400)
            ViewerWindowController.show(images: [try #require(FolderEntry(url: url))], index: 0,
                                        fullScreen: true) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            let fake = FakeTextAnalyzer()
            viewer.liveText.analyzer = fake
            viewer.liveText.settleDelay = 0
            await TestTiming.waitUntil { viewer.canEditCurrent && viewer.liveText.shown != nil }
            #expect(viewer.isFullScreen && viewer.canvasTexture?.isHDR == true)
            #expect(viewer.liveText.host.frame == viewer.canvasView.frame)

            movePointer(viewer)
            await TestTiming.waitUntil { viewer.liveText.result != nil }
            #expect(fake.sizes.count == 1)

            viewer.toggleFullScreenViewer(nil)
            #expect(!viewer.isFullScreen)
            viewer.container.layoutSubtreeIfNeeded()
            #expect(viewer.liveText.host.frame == viewer.canvasView.frame)
            #expect(viewer.liveText.host.window === viewer.window)
            movePointer(viewer)
            await pause()
            #expect(fake.sizes.count == 1, "the same picture, analysed once")
            #expect(viewer.liveText.result != nil)
        }

        /// Where `textImage` draws its words, and a place well below them,
        /// in image pixels from the top left.
        static let onText = CGPoint(x: 180, y: 104)
        static let belowText = CGPoint(x: 180, y: 300)

        /// An 800 x 400 JPEG with large black words across the top and
        /// nothing below them.
        static func textImage(in folder: URL) throws -> URL {
            let width = 800, height = 400
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            // Core Graphics counts from the bottom: a baseline 270 up puts
            // the capitals between about 78 and 130 from the top.
            ("MINIVU TEXT" as NSString).draw(at: NSPoint(x: 40, y: 270), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 72), .foregroundColor: NSColor.black,
            ])
            NSGraphicsContext.restoreGraphicsState()
            let url = folder.appendingPathComponent("text.jpg")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString,
                                                                           1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(destination))
            return url
        }
    }
}
