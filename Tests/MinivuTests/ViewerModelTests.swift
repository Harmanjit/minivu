import Testing
import AppKit
import MinivuCore
@testable import Minivu

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
        #expect(command(key(NSPageDownFunctionKey)) == .next)
        #expect(command(key(NSLeftArrowFunctionKey)) == .previous)
        #expect(command(key(NSDeleteCharacter)) == .previous)
        #expect(command(key(NSPageUpFunctionKey)) == .previous)
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
        #expect(command(key(NSPageUpFunctionKey), zoomedIn: true) == .previous)
        #expect(command(key(NSDeleteCharacter), zoomedIn: true) == .previous)
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
        #expect(command(key(NSRightArrowFunctionKey), .option) == nil)
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
    }

    @Test func zoomText() {
        #expect(ViewerHUD.zoomText(100) == "100%")
        #expect(ViewerHUD.zoomText(33.3) == "33%")
        #expect(ViewerHUD.zoomText(5) == "5.0%")
    }
}

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
