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
            await TestTiming.waitUntil { controller.paneViews.allSatisfy { $0.canvas.image != nil } }
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
            #expect(item.title == "Remove Tag")
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
            await TestTiming.waitUntil { CompareWindowController.current == nil }
            #expect(CompareWindowController.current == nil)
            #expect(controller.paneViews.isEmpty)
        }

        /// A change to Show HDR or RAW decoding reaches every pane at once, so
        /// two panes never disagree about the same setting. Each pane keeps the
        /// image and the zoom it already has while the new one decodes.
        @Test func reloadsEveryPaneWhenTheDisplaySettingsChange() async throws {
            let savedCatalog = CompareWindowController.catalog
            CompareWindowController.catalog = .inMemory()
            defer { CompareWindowController.catalog = savedCatalog }
            let (scratch, all) = try folder([(1200, 800), (1200, 800)])
            _ = scratch
            CompareWindowController.show(entries: all, allImages: all)
            defer { close() }
            let controller = try #require(CompareWindowController.current)
            let panes = controller.paneViews
            #expect(panes.count == 2)
            await TestTiming.waitUntil(seconds: 30) { panes.allSatisfy { $0.canvas.image != nil } }
            try #require(panes.allSatisfy { $0.canvas.image != nil })

            // Zoomed in, so a pane that lost its view would show it. The
            // sharpening the zoom asks for has to have landed before the
            // reload, or its texture would arrive during the reload and read
            // as the reload's own work.
            if !controller.isSynced { controller.toggleSync(nil) }
            controller.actualSize(nil)
            await TestTiming.waitUntil(seconds: 30) { panes.allSatisfy { $0.canvas.image?.isFullResolution == true } }
            try #require(panes.allSatisfy { $0.canvas.image?.isFullResolution == true })
            let before = panes.map { ($0.canvas.image, $0.canvas.transform, $0.canvas.zoomMode) }
            #expect(before.allSatisfy { $0.2 != .fit })

            // What Preferences does, for these two files only: the rest of the
            // app's cache is left alone for the tests running alongside.
            for entry in all { AppServices.images.invalidate(entry.url) }
            NotificationCenter.default.post(name: .minivuDisplaySettingsChanged, object: nil)
            var wentBlank = false
            await TestTiming.waitUntil(seconds: 30) {
                if panes.contains(where: { $0.canvas.image == nil }) { wentBlank = true }
                return zip(panes, before).allSatisfy { $0.canvas.image !== $1.0 }
            }
            // Both panes decoded again, neither went black on the way, and the
            // zoom and pan are where the user left them.
            #expect(zip(panes, before).allSatisfy { $0.canvas.image !== $1.0 })
            #expect(!wentBlank)
            for (pane, was) in zip(panes, before) {
                #expect(pane.canvas.transform == was.1)
                #expect(pane.canvas.zoomMode == was.2)
            }
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
            await TestTiming.waitUntil { browser.model.state == .loaded }
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
