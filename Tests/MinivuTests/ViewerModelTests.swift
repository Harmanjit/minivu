import Testing
import AppKit
import ImageIO
import MinivuCore
@testable import Minivu
import MinivuRender

/// A folder of `count` made-up entries, a.jpg, b.jpg, ... (no files needed).
private func entries(_ count: Int) -> [FolderEntry] {
    (0..<count).map { i in
        let name = "\(Character(UnicodeScalar(UInt8(97 + i)))).jpg"
        return FolderEntry(url: URL(fileURLWithPath: "/tmp/minivu-viewer-tests/\(name)"), name: name,
                           isDirectory: false, kind: .raster, fileSize: 1, modified: .distantPast,
                           created: .distantPast)
    }
}

private func names(_ list: [FolderEntry]) -> [String] { list.map(\.name) }

@Suite struct ViewerModelTests {
    @Test func startsClampedAndReportsPosition() {
        #expect(ViewerModel(images: entries(3), index: 7).index == 2)
        #expect(ViewerModel(images: entries(3), index: -1).index == 0)
        let model = ViewerModel(images: entries(120), index: 2)
        #expect(model.current?.name == "c.jpg")
        #expect(model.positionText == "3 / 120")
        #expect(model.subtitleText == "3 of 120")
        let empty = ViewerModel(images: [], index: 0)
        #expect(empty.current == nil)
        #expect(empty.positionText.isEmpty)
    }

    @Test func stopsAtTheEndsWithoutWrap() {
        var model = ViewerModel(images: entries(3), index: 0)
        #expect(!model.canGoPrevious)
        let movedBeforeStart = model.previous()
        #expect(!movedBeforeStart)
        model.next()
        let moved = model.next()
        #expect(moved)
        #expect(model.index == 2)
        #expect(!model.canGoNext)
        let movedPastEnd = model.next()
        #expect(!movedPastEnd)
        #expect(model.index == 2)
    }

    @Test func wrapsAroundWhenAllowed() {
        var model = ViewerModel(images: entries(3), index: 2, wrapAround: true)
        #expect(model.canGoNext)
        model.next()
        #expect(model.index == 0)
        let movedBack = model.previous()
        #expect(movedBack)
        #expect(model.index == 2)
        #expect(model.direction == .backward)
    }

    @Test func singleImageNeverMoves() {
        var model = ViewerModel(images: entries(1), index: 0, wrapAround: true)
        #expect(!model.canGoNext && !model.canGoPrevious)
        let moved = model.next() || model.last()
        #expect(!moved)
        #expect(model.prefetchList.isEmpty)
    }

    @Test func firstLastAndJumpsSetDirection() {
        var model = ViewerModel(images: entries(5), index: 2)
        model.last()
        #expect(model.index == 4 && model.direction == .forward)
        model.first()
        #expect(model.index == 0 && model.direction == .backward)
        let movedToSame = model.first()
        #expect(!movedToSame)
        model.move(to: 3)
        #expect(model.index == 3 && model.direction == .forward)
        let movedOutOfRange = model.move(to: 9)
        #expect(!movedOutOfRange)
    }

    @Test func prefetchFollowsTheDirectionOfTravel() {
        var model = ViewerModel(images: entries(10), index: 4)
        model.next()   // at 5, moving forward
        #expect(names(model.prefetchList) == ["g.jpg", "h.jpg", "e.jpg"])
        model.previous()   // at 4, moving backward
        #expect(names(model.prefetchList) == ["d.jpg", "c.jpg", "f.jpg"])
    }

    @Test func prefetchClampsOrWrapsAtTheEnds() {
        var model = ViewerModel(images: entries(5), index: 3)
        model.next()   // at the last image, forward
        #expect(names(model.prefetchList) == ["d.jpg"])
        model.wrapAround = true
        #expect(names(model.prefetchList) == ["a.jpg", "b.jpg", "d.jpg"])
    }

    /// In a folder of two, +1 and -1 are the same image: asked for once.
    @Test func prefetchSkipsDuplicatesAndTheCurrentImage() {
        var model = ViewerModel(images: entries(2), index: 0, wrapAround: true)
        model.next()
        #expect(names(model.prefetchList) == ["a.jpg"])
    }

    @Test func removingTheCurrentImageShowsTheNext() {
        let list = entries(4)
        var model = ViewerModel(images: list, index: 1)
        let left = model.remove(list[1])
        #expect(left)
        #expect(model.current?.name == "c.jpg")
        #expect(model.count == 3)
    }

    @Test func removingTheLastImageShowsThePrevious() {
        let list = entries(3)
        var model = ViewerModel(images: list, index: 2)
        model.remove(list[2])
        #expect(model.current?.name == "b.jpg")
    }

    @Test func removingAnEarlierImageKeepsTheCurrentOne() {
        let list = entries(4)
        var model = ViewerModel(images: list, index: 2)
        model.remove(list[0])
        #expect(model.current?.name == "c.jpg")
        #expect(model.index == 1)
        // Something not in the list changes nothing.
        let left = model.remove(entries(6)[5])
        #expect(left)
        #expect(model.count == 3 && model.index == 1)
    }

    @Test func removingEverythingEmptiesTheModel() {
        let list = entries(1)
        var model = ViewerModel(images: list, index: 0)
        let left = model.remove(list[0])
        #expect(!left)
        #expect(model.current == nil)
    }

    @Test func replaceKeepsTheWrapSetting() {
        var model = ViewerModel(images: entries(3), index: 1, wrapAround: true)
        model.replace(images: entries(8), index: 6)
        #expect(model.index == 6 && model.count == 8 && model.wrapAround)
    }

    // MARK: - Pages

    @Test func pagesAreKnownOnlyForTheCurrentImage() {
        let list = entries(3)
        var model = ViewerModel(images: list, index: 0)
        #expect(!model.isMultiPage && model.pageText.isEmpty && model.pageHUDText == nil)
        model.setPageCount(10, for: list[1])   // a late answer for another image
        #expect(model.pageCount == 1)
        model.setPageCount(10, for: list[0])
        #expect(model.isMultiPage && model.pageText == "1 / 10" && model.pageHUDText == "Page 1 of 10")
        #expect(!model.canGoPreviousPage && model.canGoNextPage)
    }

    @Test func optionArrowsStayWithinTheDocument() {
        let list = entries(3)
        var model = ViewerModel(images: list, index: 1)
        model.setPageCount(2, for: list[1])
        let backFromFirst = model.previousPage()
        #expect(!backFromFirst)
        let forward = model.nextPage()
        #expect(forward && model.page == 1 && model.pageText == "2 / 2")
        let pastLast = model.nextPage()
        #expect(!pastLast)
        #expect(model.index == 1)
        let back = model.previousPage()
        #expect(back && model.page == 0)
    }

    @Test func pageKeysTurnPagesThenMoveOn() {
        let list = entries(3)
        var model = ViewerModel(images: list, index: 1)
        model.setPageCount(3, for: list[1])
        var steps: [ViewerModel.PageStep] = []
        steps.append(model.pageForward())
        steps.append(model.pageForward())
        #expect(steps == [.page, .page] && model.page == 2)
        // The last page: on to the next image, which starts on its first page.
        steps = [model.pageForward()]
        #expect(steps == [.image])
        #expect(model.index == 2 && model.page == 0 && model.pageCount == 1)
        steps = [model.pageForward()]
        #expect(steps == [.none])
        // Back into the document (its page count is read again) and out.
        steps = [model.pageBackward()]
        #expect(steps == [.image] && model.index == 1 && model.page == 0)
        model.setPageCount(3, for: list[1])
        model.nextPage()
        steps = [model.pageBackward(), model.pageBackward(), model.pageBackward()]
        #expect(steps == [.page, .image, .none] && model.index == 0)
    }

    @Test func movingOrRemovingResetsThePage() {
        let list = entries(4)
        var model = ViewerModel(images: list, index: 1)
        model.setPageCount(5, for: list[1])
        model.nextPage()
        model.move(to: 3)
        #expect(model.page == 0 && model.pageCount == 1)

        model.setPageCount(5, for: list[3])
        model.nextPage()
        model.remove(list[0])   // an earlier image: same document, same page
        #expect(model.current == list[3] && model.page == 1)
        model.remove(list[3])   // the document itself: the next one starts over
        #expect(model.page == 0 && model.pageCount == 1)
    }

    @Test func prefetchPutsTheNextPageFirst() {
        let list = entries(5)
        var model = ViewerModel(images: list, index: 2)
        #expect(model.prefetchPages.map { "\($0.entry.name):\($0.page)" } == ["d.jpg:0", "e.jpg:0", "b.jpg:0"])
        model.setPageCount(3, for: list[2])
        #expect(model.prefetchPages.map { "\($0.entry.name):\($0.page)" }
                == ["c.jpg:1", "d.jpg:0", "e.jpg:0", "b.jpg:0"])
        model.nextPage()
        model.nextPage()
        #expect(model.prefetchPages.first?.entry.name == "d.jpg")
    }
}

@Suite struct ViewerDocumentRulesTests {
    func entry(_ name: String, _ kind: ImageKind) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: false, kind: kind,
                    fileSize: 1, modified: .distantPast, created: .distantPast)
    }

    @Test func onlyFormatsWithPagesOrFramesAreInspected() {
        #expect(ViewerWindowController.mayHavePagesOrFrames(entry("a.pdf", .pdf)))
        #expect(ViewerWindowController.mayHavePagesOrFrames(entry("a.TIF", .raster)))
        #expect(ViewerWindowController.mayHavePagesOrFrames(entry("a.gif", .raster)))
        #expect(ViewerWindowController.mayHavePagesOrFrames(entry("a.webp", .raster)))
        #expect(!ViewerWindowController.mayHavePagesOrFrames(entry("a.jpg", .raster)))
        #expect(!ViewerWindowController.mayHavePagesOrFrames(entry("a.nef", .raw)))
        #expect(!ViewerWindowController.mayHavePagesOrFrames(entry("a.svg", .svg)))
    }

    @Test func sharpeningRules() {
        typealias C = ViewerWindowController
        // Zoomed in: full resolution.
        #expect(!C.wantsScreenSizedSharpening(fitted: false, kind: .raster, imageLongEdge: 6000, textureLongEdge: 2880,
                                              canvasLongEdge: 2880))
        #expect(!C.wantsScreenSizedSharpening(fitted: false, kind: .pdf, imageLongEdge: 6740, textureLongEdge: 1000,
                                              canvasLongEdge: 2880))
        // Fitted, the window outgrew the texture (or a stand-in is up): screen size.
        #expect(C.wantsScreenSizedSharpening(fitted: true, kind: .raster, imageLongEdge: 6000, textureLongEdge: 1600,
                                             canvasLongEdge: 2880))
        #expect(C.wantsScreenSizedSharpening(fitted: true, kind: .pdf, imageLongEdge: 6740, textureLongEdge: 1600,
                                             canvasLongEdge: 2880))
        // Fitted with a texture that covers the canvas: the magnifier wants
        // detail, which only full resolution has (a screen-sized load would
        // hand back the texture already showing).
        #expect(!C.wantsScreenSizedSharpening(fitted: true, kind: .raster, imageLongEdge: 6000, textureLongEdge: 2880,
                                              canvasLongEdge: 2880))
        #expect(!C.wantsScreenSizedSharpening(fitted: true, kind: .pdf, imageLongEdge: 6740, textureLongEdge: 2880,
                                              canvasLongEdge: 2880))
        // A vector smaller than the canvas always takes full resolution.
        #expect(!C.wantsScreenSizedSharpening(fitted: true, kind: .svg, imageLongEdge: 200, textureLongEdge: 800,
                                              canvasLongEdge: 2880))
    }
}

@Suite struct ViewerKeyCommandTests {
    func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    func command(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], zoomedIn: Bool = false)
        -> ViewerKeyCommand? {
        ViewerKeyCommand.command(characters: characters, modifiers: modifiers, zoomedIn: zoomedIn)
    }

    @Test func navigationKeys() {
        #expect(command(key(NSRightArrowFunctionKey)) == .next)
        #expect(command(" ") == .next)
        #expect(command(key(NSPageDownFunctionKey)) == .pageForward)
        #expect(command(key(NSLeftArrowFunctionKey)) == .previous)
        #expect(command(key(NSDeleteCharacter)) == .previous)
        #expect(command(key(NSPageUpFunctionKey)) == .pageBackward)
        #expect(command(key(NSDownArrowFunctionKey)) == .next)
        #expect(command(key(NSUpArrowFunctionKey)) == .previous)
        #expect(command(key(NSHomeFunctionKey)) == .first)
        #expect(command(key(NSEndFunctionKey)) == .last)
    }

    /// Zoomed in, arrows look around the image; the paging keys still flip.
    @Test func arrowsPanWhenZoomedIn() {
        #expect(command(key(NSRightArrowFunctionKey), zoomedIn: true) == .pan(x: 1, y: 0))
        #expect(command(key(NSLeftArrowFunctionKey), zoomedIn: true) == .pan(x: -1, y: 0))
        #expect(command(key(NSDownArrowFunctionKey), zoomedIn: true) == .pan(x: 0, y: 1))
        #expect(command(key(NSUpArrowFunctionKey), zoomedIn: true) == .pan(x: 0, y: -1))
        #expect(command(" ", zoomedIn: true) == .next)
        #expect(command(key(NSPageUpFunctionKey), zoomedIn: true) == .pageBackward)
        #expect(command(key(NSDeleteCharacter), zoomedIn: true) == .previous)
    }

    /// Option with the arrows or paging keys turns pages, zoomed in or not.
    @Test func optionKeysTurnPages() {
        #expect(command(key(NSRightArrowFunctionKey), .option) == .nextPage)
        #expect(command(key(NSPageDownFunctionKey), .option) == .nextPage)
        #expect(command(key(NSLeftArrowFunctionKey), [.option, .function], zoomedIn: true) == .previousPage)
        #expect(command(key(NSPageUpFunctionKey), .option) == .previousPage)
        #expect(command("p") == .togglePlayback)
        #expect(ViewerKeyCommand.nextPage.repeats && ViewerKeyCommand.pageForward.repeats)
        #expect(!ViewerKeyCommand.togglePlayback.repeats)
    }

    @Test func viewKeys() {
        #expect(command("\r") == .toggleFullScreen)
        #expect(command(key(NSEnterCharacter)) == .toggleFullScreen)
        #expect(command("\u{1b}") == .close)
        #expect(command("+") == .zoomIn)
        #expect(command("=") == .zoomIn)
        #expect(command("-") == .zoomOut)
        #expect(command("/") == .actualSize)
        #expect(command("*") == .fit)
        #expect(command("i") == .toggleHUD)
        #expect(command("I", .shift) == .toggleHUD)
        #expect(command("f") == .toggleFilmstrip)
    }

    @Test func onlyMovementAndZoomRepeat() {
        #expect(ViewerKeyCommand.next.repeats && ViewerKeyCommand.pan(x: 0, y: 1).repeats)
        #expect(ViewerKeyCommand.zoomIn.repeats)
        #expect(!ViewerKeyCommand.toggleFullScreen.repeats && !ViewerKeyCommand.toggleFilmstrip.repeats)
        #expect(!ViewerKeyCommand.close.repeats && !ViewerKeyCommand.last.repeats)
    }

    /// Ratings are a later phase, but their keys are taken so they don't beep.
    @Test func ratingKeysAreReserved() {
        for digit in 0...5 { #expect(command("\(digit)") == .rating(digit)) }
        #expect(command("6") == nil)
    }

    /// Shortcuts belong to the menu.
    @Test func leavesOtherKeysAlone() {
        #expect(command("w", .command) == nil)
        #expect(command("=", .command) == nil)
        #expect(command(key(NSRightArrowFunctionKey), [.option, .command]) == nil)
        #expect(command("p", .option) == nil)
        #expect(command(key(NSHomeFunctionKey), .option) == nil)
        #expect(command("") == nil)
        #expect(command("x") == nil)
    }
}

@Suite struct FlyoutGeometryTests {
    /// A 1000 x 600 area starting 20 pt up, as if something sat below it.
    let area = CGRect(x: 0, y: 20, width: 1000, height: 600)

    @Test func touchingEdges() {
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 618), in: area) == .top)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 22), in: area) == .bottom)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 3, y: 300), in: area) == .left)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 998, y: 300), in: area) == .right)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 300), in: area) == nil)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 10, y: 300), in: area) == nil)
        // Outside the area altogether (the title bar above it).
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 640), in: area) == nil)
    }

    @Test func cornersPreferTheNearerEdgeThenTopAndBottom() {
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 1, y: 617), in: area) == .left)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 3, y: 619), in: area) == .top)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 2, y: 22), in: area) == .bottom)
    }

    @Test func openFramesHugTheirEdges() {
        #expect(FlyoutGeometry.openFrame(for: .top, thickness: 96, in: area) == CGRect(x: 0, y: 524, width: 1000, height: 96))
        #expect(FlyoutGeometry.openFrame(for: .bottom, thickness: 48, in: area) == CGRect(x: 0, y: 20, width: 1000, height: 48))
        #expect(FlyoutGeometry.openFrame(for: .left, thickness: 220, in: area) == CGRect(x: 0, y: 20, width: 220, height: 600))
        #expect(FlyoutGeometry.openFrame(for: .right, thickness: 320, in: area) == CGRect(x: 680, y: 20, width: 320, height: 600))
    }

    @Test func sidePanelsMakeRoomForPinnedPanels() {
        let frame = FlyoutGeometry.openFrame(for: .right, thickness: 320, in: area,
                                             pinnedThickness: [.top: 96, .bottom: 48])
        #expect(frame == CGRect(x: 680, y: 68, width: 320, height: 456))
    }

    /// Full screen on a notched display: the pointer rests at the top of the
    /// screen, above the panel area, and that must still reach the filmstrip.
    @Test func reachBeyondTheAreaCountsAsTheNearestEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 652)   // 32 pt camera strip above `area`
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 652), in: area, reach: screen) == .top)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 640), in: area, reach: screen) == .top)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 300), in: area, reach: screen) == .left)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 1000, y: 300), in: area, reach: screen) == .right)
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 300), in: area, reach: screen) == nil)
        // Without a reach (a window's title bar), the same point is nothing.
        #expect(FlyoutGeometry.edge(at: CGPoint(x: 500, y: 652), in: area) == nil)
    }

    @Test func hoverFramesStretchToTheReach() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 652)
        #expect(FlyoutGeometry.hoverFrame(for: .top, thickness: 96, in: area, reach: screen)
                == CGRect(x: 0, y: 524, width: 1000, height: 128))
        #expect(FlyoutGeometry.hoverFrame(for: .bottom, thickness: 48, in: area, reach: screen)
                == CGRect(x: 0, y: 0, width: 1000, height: 68))
        #expect(FlyoutGeometry.hoverFrame(for: .left, thickness: 220, in: area, reach: nil)
                == FlyoutGeometry.openFrame(for: .left, thickness: 220, in: area))
        #expect(FlyoutGeometry.contains(screen, CGPoint(x: 1000, y: 652)))
    }

    @Test func closedFramesSitJustPastTheEdge() {
        for edge in FlyoutEdge.allCases {
            let open = FlyoutGeometry.openFrame(for: edge, thickness: 100, in: area)
            let closed = FlyoutGeometry.closedFrame(for: edge, thickness: 100, in: area)
            #expect(closed.size == open.size)
            #expect(!closed.intersects(area.insetBy(dx: 0.5, dy: 0.5)), "\(edge)")
        }
    }
}

@Suite struct ViewerHUDTextTests {
    @Test func detailLine() {
        #expect(ViewerHUD.detailText(position: "3 / 120", pixelSize: CGSize(width: 6000, height: 4000),
                                     zoomPercent: 25) == "3 / 120  ·  6000 × 4000  ·  25%")
        #expect(ViewerHUD.detailText(position: "3 / 120", pixelSize: nil, zoomPercent: nil) == "3 / 120")
        #expect(ViewerHUD.detailText(position: "3 / 120", part: "Page 2 of 10", pixelSize: CGSize(width: 1190, height: 1684),
                                     zoomPercent: 50) == "3 / 120  ·  Page 2 of 10  ·  1190 × 1684  ·  50%")
    }

    @Test func zoomText() {
        #expect(ViewerHUD.zoomText(100) == "100%")
        #expect(ViewerHUD.zoomText(33.3) == "33%")
        #expect(ViewerHUD.zoomText(5) == "5.0%")
    }
}

extension AppWindowTests {
    /// The viewer's lifecycle in a real (windowed) window: close reports the
    /// image showing, and one viewer is ever alive.
    @MainActor @Suite(.serialized) struct ViewerLifecycleTests {
        init() { _ = NSApplication.shared }

        @Test func emptyFolderClosesAtOnce() {
            var closed: [FolderEntry?] = []
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { closed.append($0) }
            #expect(closed.count == 1 && closed[0] == nil)
            #expect(ViewerWindowController.current == nil)
        }

        @Test func escapeClosesWithTheCurrentImageAndRetargetingReusesTheViewer() throws {
            let list = entries(4)
            var closedWith: [String?] = []
            ViewerWindowController.show(images: list, index: 1, fullScreen: false) { closedWith.append($0?.name) }
            let viewer = try #require(ViewerWindowController.current)
            #expect(viewer.window?.title == "b.jpg")
            #expect(viewer.window?.subtitle == "2 of 4")
            #expect(!viewer.isFullScreen)

            // Showing again moves the same viewer; the new close handler wins.
            ViewerWindowController.show(images: list, index: 3, fullScreen: false) { closedWith.append("new:\($0?.name ?? "")") }
            #expect(ViewerWindowController.current === viewer)
            #expect(viewer.window?.title == "d.jpg")

            viewer.previousImage(nil)
            let window = try #require(viewer.window)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                       isARepeat: false, keyCode: 53))
            window.contentView?.keyDown(with: escape)
            #expect(closedWith == ["new:c.jpg"])
            #expect(ViewerWindowController.current == nil)
            #expect(!window.isVisible)
        }

        /// A browser with nothing left to show closes the viewer that is open,
        /// and hears about it with no image to select.
        @Test func showingNothingClosesAnOpenViewer() {
            var closed: [String] = []
            ViewerWindowController.show(images: entries(2), index: 0, fullScreen: false) { closed.append("old:\($0?.name ?? "nil")") }
            #expect(ViewerWindowController.current != nil)
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { closed.append("new:\($0?.name ?? "nil")") }
            #expect(ViewerWindowController.current == nil)
            #expect(closed == ["new:nil"])
        }

        func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// A real three-page PDF: its page count arrives from a background read,
        /// the option keys turn pages and Page Down carries on to the next file.
        @Test func documentPagesTurnWithTheKeys() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-viewer-pages-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let pdf = folder.appendingPathComponent("a.pdf")
            var box = CGRect(x: 0, y: 0, width: 120, height: 160)
            let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
            for _ in 0..<3 {
                context.beginPDFPage(nil)
                context.endPDFPage()
            }
            context.closePDF()
            let other = folder.appendingPathComponent("b.pdf")
            try FileManager.default.copyItem(at: pdf, to: other)
            let list = try [pdf, other].map { try #require(FolderEntry(url: $0)) }

            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            defer { viewer.exitViewer(nil) }
            await waitUntil { viewer.pageState.count == 3 }
            #expect(viewer.pageState == (0, 3))
            // The Go and Image menus' page and playback items follow along.
            func enabled(_ action: Selector) -> Bool {
                viewer.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
            }
            #expect(enabled(.nextPage) && !enabled(.previousPage) && !enabled(.togglePlayback))

            func press(_ key: Int, _ modifiers: NSEvent.ModifierFlags = []) throws {
                let window = try #require(viewer.window)
                let characters = String(Character(UnicodeScalar(key)!))
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                          characters: characters, charactersIgnoringModifiers: characters,
                                                          isARepeat: false, keyCode: 0))
                window.contentView?.keyDown(with: event)
            }
            try press(NSRightArrowFunctionKey, .option)
            #expect(viewer.pageState == (1, 3))
            #expect(viewer.window?.title == "a.pdf")
            try press(NSPageDownFunctionKey)
            #expect(viewer.pageState == (2, 3))
            try press(NSRightArrowFunctionKey, .option)   // the last page: stays
            #expect(viewer.pageState == (2, 3))
            try press(NSPageDownFunctionKey)               // on to the next file, page 1
            #expect(viewer.window?.title == "b.pdf")
            #expect(viewer.pageState.page == 0)
            viewer.previousImage(nil)
            #expect(viewer.pageState == (0, 1))            // not read again yet
        }

        /// An animated GIF plays by itself onto the canvas, P pauses it, and
        /// moving to another image or closing stops it.
        @Test func animationsPlayAndPause() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-viewer-gif-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("a.gif")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil))
            // Loops forever, so it is still playing whenever the test looks.
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                as CFDictionary)
            for level in [0.0, 0.5, 1.0] {
                let ctx = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(gray: level, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]]
                CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), props as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(destination))
            let still = folder.appendingPathComponent("b.png")
            let stillDestination = try #require(CGImageDestinationCreateWithURL(still as CFURL, "public.png" as CFString, 1, nil))
            let stillContext = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            CGImageDestinationAddImage(stillDestination, try #require(stillContext.makeImage()), nil)
            #expect(CGImageDestinationFinalize(stillDestination))
            let entries = try [url, still].map { try #require(FolderEntry(url: $0)) }

            ViewerWindowController.show(images: entries, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            defer { viewer.exitViewer(nil) }
            await waitUntil { (viewer.animationPlayer?.frameCount ?? 0) > 0 }
            let player = try #require(viewer.animationPlayer)
            #expect(player.frameCount == 3 && player.isPlaying)
            #expect(viewer.pageState.count == 1)   // frames aren't pages
            #expect(viewer.validateMenuItem(NSMenuItem(title: "", action: .togglePlayback, keyEquivalent: "")))

            // Frames reach the canvas: one texture per frame, where the still
            // decode is just one. A test run's window is usually not on screen,
            // which suspends the clock; let it play as if it were.
            player.isSuspended = false
            var textures: Set<ObjectIdentifier> = []
            await waitUntil {
                if let texture = viewer.canvasTexture { textures.insert(ObjectIdentifier(texture)) }
                return textures.count >= 3
            }
            #expect(textures.count >= 3)

            viewer.togglePlayback(nil)
            #expect(!player.isPlaying)
            viewer.togglePlayback(nil)
            #expect(player.isPlaying)

            // On to the still: the animation stops for good.
            viewer.nextImage(nil)
            #expect(!player.isPlaying && viewer.animationPlayer == nil)
            let frame = player.currentFrame
            try await Task.sleep(for: .milliseconds(150))
            #expect(player.currentFrame == frame)
            #expect(viewer.animationPlayer == nil)   // a still, so nothing started
        }

        /// The magnifier is held while the next photo arrives. The canvas asks
        /// for full resolution from inside `setImage`, once per texture; the
        /// viewer must already count the new photo as displayed, or that one
        /// request is dropped and the magnifier (and any zoom) stays blurry.
        @Test func magnifierOverTheNextPhotoLoadsItsFullResolution() async throws {
            // Larger than the small window's canvas, and different sizes so
            // each texture says which photo it is. Small enough to encode
            // quickly: this runs on the main actor, which other suites'
            // timing tests share.
            let folder = try ScratchFolder()
            let list = try [folder.jpeg("a.jpg", width: 2400, height: 1600), folder.jpeg("b.jpg", width: 2000, height: 1500)]
                .map { try #require(FolderEntry(url: $0)) }

            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            defer { viewer.exitViewer(nil) }
            let window = try #require(viewer.window)
            window.setContentSize(NSSize(width: 480, height: 320))
            await waitUntil { viewer.canvasTexture?.imageSize.width == 2400 }
            try #require(viewer.canvasTexture != nil)

            // Press and hold: a drag that hasn't moved once the hold delay is up.
            let canvas = viewer.canvasView
            let point = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
            let start = ProcessInfo.processInfo.systemUptime
            func mouse(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: start))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: start + 0.3))
            let release = try mouse(.leftMouseUp, at: start + 0.4)
            defer { canvas.mouseUp(with: release) }
            await waitUntil { viewer.canvasTexture?.isFullResolution == true }
            #expect(viewer.canvasTexture?.isFullResolution == true)

            // Whatever a prefetch at the old window size made of the next photo
            // goes, so it arrives screen-sized: smaller than the image, which
            // the magnifier needs.
            AppServices.images.invalidate(list[1].url)
            viewer.nextImage(nil)
            var firstOfNext: ImageTexture?
            await waitUntil {
                if firstOfNext == nil, let texture = viewer.canvasTexture, texture.imageSize.width == 2000 {
                    firstOfNext = texture
                }
                return firstOfNext != nil
            }
            #expect(firstOfNext?.isFullResolution == false)
            await waitUntil { viewer.canvasTexture?.isFullResolution == true }
            #expect(viewer.canvasTexture?.isFullResolution == true)
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 2000, height: 1500))
        }

        /// A display setting changed (the loader has dropped its textures): the
        /// photo on screen decodes again with its zoom and pan kept, and the
        /// neighbours are prefetched again.
        @Test func displaySettingsChangeReloadsThePhotoKeepingTheView() async throws {
            let folder = try ScratchFolder()
            let list = try [folder.jpeg("a.jpg", width: 2400, height: 1600), folder.jpeg("b.jpg", width: 2400, height: 1600)]
                .map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            defer { viewer.exitViewer(nil) }
            try #require(viewer.window).setContentSize(NSSize(width: 480, height: 320))
            let cache = AppServices.images.cache
            func neighbourCached() -> Bool {
                cache.anyTexture(url: list[1].url, modified: list[1].modified, page: 0) != nil
            }
            await waitUntil { viewer.canvasTexture != nil && neighbourCached() }
            try #require(neighbourCached())

            let canvas = viewer.canvasView
            viewer.zoomIn(nil)
            viewer.zoomIn(nil)
            canvas.pan(byPoints: CGSize(width: 40, height: 25))
            await waitUntil { viewer.canvasTexture?.isFullResolution == true }   // the zoom asked for it
            let view = (canvas.transform, canvas.zoomMode)
            #expect(view.1 != .fit)
            let old = try #require(viewer.canvasTexture)

            // What Preferences does, for these two files only: the rest of the
            // app's cache is left alone for the tests running alongside.
            AppServices.images.invalidate(list[0].url)
            AppServices.images.invalidate(list[1].url)
            NotificationCenter.default.post(name: .minivuDisplaySettingsChanged, object: nil)
            await waitUntil { viewer.canvasTexture.map { $0 !== old } ?? false }
            #expect(viewer.canvasTexture !== old)
            #expect(canvas.transform == view.0)
            #expect(canvas.zoomMode == view.1)
            await waitUntil(neighbourCached)
            #expect(neighbourCached())
        }

        /// Nothing (a display link, a work item, a panel callback) keeps a closed
        /// viewer, its canvas or its windows alive.
        @Test func closedViewerIsFreed() {
            weak var viewer: ViewerWindowController?
            weak var window: NSWindow?
            autoreleasepool {
                ViewerWindowController.show(images: entries(3), index: 1, fullScreen: false) { _ in }
                viewer = ViewerWindowController.current
                window = viewer?.window
                viewer?.nextImage(nil)
                viewer?.toggleInfoPanel(nil)
                viewer?.exitViewer(nil)
            }
            #expect(viewer == nil)
            #expect(window == nil)
        }

        /// ⌘W on the borderless window asks the delegate, as a titled one would.
        @Test func borderlessWindowPerformsClose() {
            final class Delegate: NSObject, NSWindowDelegate {
                var asked = false
                func windowShouldClose(_ sender: NSWindow) -> Bool { asked = true; return false }
            }
            let window = ViewerWindow(style: .fullScreen, frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let delegate = Delegate()
            window.delegate = delegate
            #expect(window.canBecomeKey && window.canBecomeMain)
            window.performClose(nil)
            #expect(delegate.asked)
            let item = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            #expect(window.validateMenuItem(item))
        }
    }
}

/// The pointer rules of the fly-outs, driven with plain points: no window,
/// no tracking area events needed.
@MainActor @Suite struct FlyoutControllerTests {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let flyouts: FlyoutController

    init() {
        flyouts = FlyoutController(container: container)
        flyouts.add(NSView(), edge: .top, thickness: 96)
        flyouts.add(NSView(), edge: .bottom, thickness: 48)
        flyouts.add(NSView(), edge: .left, thickness: 220)
        flyouts.add(NSView(), edge: .right, thickness: 320)
        flyouts.layout(in: container.bounds)
    }

    @Test func edgeOpensAndLeavingCloses() {
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 598))
        #expect(flyouts.isOpen(.top))
        #expect(flyouts.hasTransientPanelOpen)
        // Still inside the panel: stays open.
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 520))
        #expect(flyouts.isOpen(.top))
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 300))
        #expect(!flyouts.isOpen(.top))
        #expect(!flyouts.hasTransientPanelOpen)
    }

    /// Sliding along the open filmstrip into the corner mustn't pull the
    /// tools panel out as well.
    @Test func openPanelBlocksOtherEdges() {
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 599))
        flyouts.pointerMoved(to: CGPoint(x: 1, y: 560))
        #expect(flyouts.isOpen(.top))
        #expect(!flyouts.isOpen(.left))
        // Out of the filmstrip and onto the left edge: the tools take over.
        flyouts.pointerMoved(to: CGPoint(x: 1, y: 300))
        #expect(!flyouts.isOpen(.top))
        #expect(flyouts.isOpen(.left))
    }

    /// Full screen with a camera strip above the panel area: the strip opens
    /// the filmstrip, and moving between the strip and the panel keeps it.
    @Test func reachAboveTheAreaOpensAndKeepsTheTopPanel() {
        flyouts.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 568),
                       reach: CGRect(x: 0, y: 0, width: 1000, height: 600))
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 600))
        #expect(flyouts.isOpen(.top))
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 500))
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 590))
        #expect(flyouts.isOpen(.top))
        flyouts.pointerMoved(to: CGPoint(x: 500, y: 300))
        #expect(!flyouts.isOpen(.top))
    }

    @Test func pinnedPanelsStayWhenThePointerLeavesOrTheImageIsPressed() {
        flyouts.setPinned(true, edge: .top, animated: false)
        flyouts.pointerMoved(to: CGPoint(x: 999, y: 300))
        #expect(flyouts.isOpen(.right))
        flyouts.hideTransientPanels(animated: false)
        #expect(flyouts.isOpen(.top) && flyouts.isPinned(.top))
        #expect(!flyouts.isOpen(.right))
        flyouts.togglePinned(.top)
        #expect(!flyouts.isOpen(.top))
    }
}
