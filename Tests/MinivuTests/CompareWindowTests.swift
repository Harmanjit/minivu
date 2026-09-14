import Testing
import AppKit
import ImageIO
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// The compare window with real files: panes load, zoom and pan follow
    /// the pane the user moves, keys focus, replace, rate and tag, and asking
    /// again retargets the one window.
    @MainActor @Suite(.serialized) struct CompareWindowTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                   in controller: CompareWindowController) throws {
            let window = try #require(controller.window)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            window.contentView?.keyDown(with: event)
        }

        func special(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

        /// A folder of flat JPEGs a.jpg ... in name order.
        func folder(_ sizes: [(Int, Int)]) throws -> (ScratchFolder, [FolderEntry]) {
            let scratch = try ScratchFolder()
            let entries = try sizes.enumerated().map { i, size in
                let name = "\(Character(UnicodeScalar(UInt8(97 + i)))).jpg"
                return try #require(FolderEntry(url: scratch.jpeg(name, width: size.0, height: size.1)))
            }
            return (scratch, entries)
        }

        func close() {
            CompareWindowController.current?.window?.close()
        }

        @Test func opensPanesAndSynchronisesZoom() async throws {
            let savedCatalog = CompareWindowController.catalog
            CompareWindowController.catalog = .inMemory()
            defer { CompareWindowController.catalog = savedCatalog }
            let (scratch, all) = try folder([(1200, 800), (600, 400), (1200, 800), (1200, 800)])
            _ = scratch
            CompareWindowController.show(entries: Array(all.prefix(3)), allImages: all)
            defer { close() }
            let controller = try #require(CompareWindowController.current)
            #expect(controller.paneViews.count == 3)
            #expect(controller.window?.subtitle == "3 images")
            await waitUntil { controller.paneViews.allSatisfy { $0.canvas.image != nil } }
            let panes = controller.paneViews
            #expect(panes.allSatisfy { $0.canvas.image != nil })
            #expect(panes[0].isFocused && !panes[1].isFocused)

            // Actual size in the first pane puts the others, the half-size
            // one included, at the same zoom relative to their fit.
            if !controller.isSynced { controller.toggleSync(nil) }
            controller.actualSize(nil)
            #expect(panes[0].canvas.zoomMode == .actualSize)
            #expect(abs(panes[0].canvas.zoomPercent - 100) < 0.01)
            let expected = panes[0].relativeView()
            for pane in panes.dropFirst() {
                #expect(pane.relativeView()?.isFit == false)
                #expect(abs((pane.relativeView()?.zoomFactor ?? 0) - (expected?.zoomFactor ?? 1)) < 1e-6)
            }
            // Panning follows too, as a fraction of each image.
            panes[0].canvas.pan(byPoints: CGSize(width: 40, height: 0))
            let centre = try #require(panes[0].relativeView()?.center)
            #expect(abs((panes[2].relativeView()?.center.x ?? 0) - centre.x) < 1e-6)

            // With Sync off the others stay where they are.
            controller.toggleSync(nil)
            #expect(!controller.isSynced)
            panes[0].canvas.fit()
            #expect(panes[0].canvas.zoomMode == .fit)
            #expect(panes[1].canvas.zoomMode != .fit)
            controller.toggleSync(nil)
            // Turning it back on brings them to the focused pane's view.
            #expect(panes[1].canvas.zoomMode == .fit)
        }

        @Test func keysFocusReplaceRateAndTag() async throws {
            let catalog = Catalog.inMemory()
            let savedCatalog = CompareWindowController.catalog
            CompareWindowController.catalog = catalog
            defer { CompareWindowController.catalog = savedCatalog }
            let (scratch, all) = try folder([(300, 200), (300, 200), (300, 200), (300, 200)])
            _ = scratch
            CompareWindowController.show(entries: [all[0], all[1]], allImages: all)
            defer { close() }
            let controller = try #require(CompareWindowController.current)

            try press("2", .command, in: controller)
            #expect(controller.model.focus == 1)
            #expect(controller.paneViews[1].isFocused && !controller.paneViews[0].isFocused)
            try press(special(NSTabCharacter), in: controller)
            #expect(controller.model.focus == 0)
            try press(special(NSTabCharacter), in: controller)
            #expect(controller.model.focus == 1)

            // → in pane 2 (b): c is the next image not shown.
            try press(special(NSRightArrowFunctionKey), in: controller)
            #expect(controller.model.panes.map(\.name) == ["a.jpg", "c.jpg"])
            #expect(controller.paneViews[1].entry?.name == "c.jpg")
            try press(special(NSLeftArrowFunctionKey), in: controller)
            #expect(controller.model.panes[1].name == "b.jpg")

            try press("4", in: controller)
            #expect(catalog.marks(for: all[1].url).rating == 4)
            #expect(catalog.marks(for: all[0].url).rating == 0)
            try press("t", in: controller)
            #expect(catalog.marks(for: all[1].url).isTagged)
            let item = NSMenuItem(title: "", action: .toggleTag, keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
            #expect(item.state == .on)
            // The menu's rating items act on the focused pane too.
            let rate = NSMenuItem(title: "", action: .setRating, keyEquivalent: "")
            rate.tag = 2
            controller.setRating(rate)
            #expect(catalog.marks(for: all[1].url).rating == 2)

            // Asking again retargets the same window.
            CompareWindowController.show(entries: [all[2], all[3], all[0]], allImages: all)
            #expect(CompareWindowController.current === controller)
            #expect(controller.paneViews.count == 3)
            #expect(controller.model.panes.map(\.name) == ["c.jpg", "d.jpg", "a.jpg"])

            // Esc closes.
            try press(special(0x1B), in: controller)
            await waitUntil { CompareWindowController.current == nil }
            #expect(CompareWindowController.current == nil)
            #expect(controller.paneViews.isEmpty)
        }

        @Test func browserComparesTwoToFourSelectedImages() async throws {
            let savedLastFolder = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
            defer { UserDefaults.standard.set(savedLastFolder, forKey: AppDelegate.lastFolderKey) }
            let (scratch, all) = try folder([(300, 200), (300, 200), (300, 200)])
            let browser = BrowserWindowController()
            defer {
                close()
                browser.close()
            }
            browser.open(folder: scratch.url)
            await browser.model.work?.value
            await waitUntil { browser.model.state == .loaded }
            let item = NSMenuItem(title: "", action: .compareSelected, keyEquivalent: "")
            browser.model.select(all[0].url)
            #expect(!browser.validateMenuItem(item))
            browser.model.selectAll()
            #expect(browser.validateMenuItem(item))
            browser.compareSelected(nil)
            let controller = try #require(CompareWindowController.current)
            #expect(controller.model.panes.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"])
            #expect(controller.model.allImages.count == 3)
        }
    }
}
