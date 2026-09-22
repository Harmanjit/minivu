import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// The compare window driven the way AppKit drives it: key events sent
    /// to the window (so they start at the focused canvas), synced views
    /// that must not echo, a replaced image joining a zoomed set, and a
    /// closed window that must let go of its panes and textures.
    @MainActor @Suite(.serialized) struct CompareWindowBehaviourTests {
        init() { _ = NSApplication.shared }

        func folder(_ count: Int, width: Int = 600, height: Int = 400) throws -> (ScratchFolder, [FolderEntry]) {
            let scratch = try ScratchFolder()
            let entries = try (0..<count).map { i in
                let name = "\(Character(UnicodeScalar(UInt8(97 + i)))).jpg"
                return try #require(FolderEntry(url: scratch.jpeg(name, width: width, height: height)))
            }
            return (scratch, entries)
        }

        /// A key press delivered through the window, as a real one is.
        func send(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            window.sendEvent(event)
        }

        func special(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

        @Test func keysReachTheControllerFromTheFocusedCanvas() async throws {
            let catalog = Catalog.inMemory()
            let saved = CompareWindowController.catalog
            CompareWindowController.catalog = catalog
            defer { CompareWindowController.catalog = saved }
            let (scratch, all) = try folder(4)
            _ = scratch
            CompareWindowController.show(entries: [all[0], all[1]], allImages: all)
            defer { CompareWindowController.current?.window?.close() }
            let controller = try #require(CompareWindowController.current)
            let window = try #require(controller.window)
            #expect(window.firstResponder === controller.paneViews[0].canvas)

            try send(special(NSTabCharacter), to: window)
            #expect(controller.model.focus == 1)
            #expect(window.firstResponder === controller.paneViews[1].canvas)
            try send("3", to: window)
            #expect(catalog.marks(for: all[1].url).rating == 3)
            try send(special(NSRightArrowFunctionKey), to: window)
            #expect(controller.model.panes.map(\.name) == ["a.jpg", "c.jpg"])
            try send("1", .command, to: window)
            #expect(controller.model.focus == 0)
        }

        @Test func syncedViewsDoNotEcho() async throws {
            let (scratch, all) = try folder(4, width: 1600, height: 1000)
            _ = scratch
            CompareWindowController.show(entries: Array(all.prefix(4)), allImages: all)
            defer { CompareWindowController.current?.window?.close() }
            let controller = try #require(CompareWindowController.current)
            if !controller.isSynced { controller.toggleSync(nil) }
            await TestTiming.waitUntil { controller.paneViews.allSatisfy { $0.canvas.image != nil } }
            var reports = 0
            for pane in controller.paneViews {
                let forward = pane.onInteractiveViewChange
                pane.onInteractiveViewChange = { reports += 1; forward?($0) }
            }
            controller.paneViews[0].canvas.zoom(by: 3, at: nil)
            #expect(reports == 1)
            controller.paneViews[0].canvas.pan(byPoints: CGSize(width: 30, height: 12))
            #expect(reports == 2)
            let centre = try #require(controller.paneViews[0].relativeView())
            for pane in controller.paneViews.dropFirst() {
                let view = try #require(pane.relativeView())
                #expect(abs(view.zoomFactor - centre.zoomFactor) < 1e-6)
                #expect(abs(view.center.x - centre.center.x) < 1e-6)
            }
        }

        @Test func replacedImageJoinsTheZoomedPanes() async throws {
            let (scratch, all) = try folder(4, width: 1600, height: 1000)
            _ = scratch
            CompareWindowController.show(entries: [all[0], all[1]], allImages: all)
            defer { CompareWindowController.current?.window?.close() }
            let controller = try #require(CompareWindowController.current)
            if !controller.isSynced { controller.toggleSync(nil) }
            await TestTiming.waitUntil { controller.paneViews.allSatisfy { $0.canvas.image != nil } }
            controller.actualSize(nil)
            let zoomed = try #require(controller.paneViews[1].relativeView())
            #expect(!zoomed.isFit)
            controller.nextImage(nil)   // pane 1: a → c
            let pane = controller.paneViews[0]
            await TestTiming.waitUntil { pane.entry?.name == "c.jpg" && pane.canvas.image != nil && pane.relativeView()?.isFit == false }
            let view = try #require(pane.relativeView())
            #expect(!view.isFit)
            #expect(abs(view.zoomFactor - zoomed.zoomFactor) < 1e-6)
        }

        @Test func closedCompareWindowIsFreed() async throws {
            let (scratch, all) = try folder(3)
            _ = scratch
            weak var controller: CompareWindowController?
            weak var window: NSWindow?
            weak var pane: CompareImagePane?
            weak var texture: ImageTexture?
            autoreleasepool {
                CompareWindowController.show(entries: all, allImages: all)
                controller = CompareWindowController.current
                window = controller?.window
                pane = controller?.paneViews.first
            }
            await TestTiming.waitUntil { pane?.canvas.image != nil }
            texture = pane?.canvas.image
            #expect(texture != nil)
            autoreleasepool {
                controller?.toggleSync(nil)
                controller?.toggleSync(nil)
                controller?.window?.close()
            }
            await TestTiming.waitUntil { controller == nil && window == nil && pane == nil }
            #expect(CompareWindowController.current == nil)
            #expect(controller == nil)
            #expect(window == nil)
            #expect(pane == nil)
        }
    }
}
