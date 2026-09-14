import Testing
import AppKit
import MinivuCore
@testable import Minivu

@MainActor @Suite struct MainMenuTests {
    let bar: NSMenu

    init() {
        _ = NSApplication.shared
        bar = MainMenu.make()
    }

    /// Every item at any depth.
    var allItems: [NSMenuItem] {
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) }
        }
        return walk(bar)
    }

    func item(_ title: String) throws -> NSMenuItem {
        try #require(allItems.first { $0.title == title })
    }

    @Test func topLevelOrder() {
        #expect(bar.items.map(\.title) == ["minivu", "File", "Edit", "View", "Image", "Go", "Tools", "Window", "Help"])
    }

    /// Two items with the same shortcut would make one of them unreachable.
    /// Checked across the whole menu bar with the display-only shortcuts
    /// shown too, since those are real equivalents while their menu is open.
    /// An uppercase letter is the same key as Shift and the lowercase one.
    @Test func noShortcutIsUsedTwice() {
        let displayOnly = bar.items.compactMap { $0.submenu?.delegate as? DisplayOnlyShortcuts }
        #expect(displayOnly.count == 2)
        displayOnly.forEach { $0.showShortcuts(true) }
        defer { displayOnly.forEach { $0.showShortcuts(false) } }

        var seen: [String: String] = [:]
        for item in allItems where !item.keyEquivalent.isEmpty {
            var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            let shortcut = "\(modifiers.rawValue)-\(item.keyEquivalent.lowercased())"
            #expect(seen[shortcut] == nil, "\(item.title) reuses the shortcut of \(seen[shortcut] ?? "")")
            seen[shortcut] = item.title
        }
    }

    /// Every action in the menu bar is either one of minivu's commands,
    /// declared in `MinivuActions`, or a standard AppKit one.
    @Test func everyActionIsDeclared() {
        let appKitOwners: [AnyClass] = [NSApplication.self, NSWindow.self, NSTextView.self, NSSplitViewController.self,
                                        AppDelegate.self]
        // NSWindow answers undo: and redo: without declaring them to Swift;
        // the viewer's window declares the same selectors, so they can be
        // named with #selector (a Selector made from a string warns).
        let undo = [#selector(ViewerWindow.undo(_:)), #selector(ViewerWindow.redo(_:))]
        // AppKit gives items with a submenu its own `submenuAction:`.
        for item in allItems where item.submenu == nil {
            guard let action = item.action else { continue }
            let declared = protocol_getMethodDescription(MinivuActions.self, action, false, true).name != nil
            let standard = undo.contains(action) || appKitOwners.contains { $0.instancesRespond(to: action) }
            #expect(declared || standard, "\(item.title): \(action) is not declared anywhere")
        }
    }

    @Test func editingItems() throws {
        let image = try #require(bar.items.first { $0.title == "Image" }?.submenu)
        let titles = image.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Fit to Window", "Actual Size", "Zoom In", "Zoom Out", "-",
                           "Rotate Left", "Rotate Right", "Flip Horizontal", "Flip Vertical", "-",
                           "Resize/Resample…", "Crop…", "Straighten…", "-", "Adjust", "Effects", "Retouch",
                           "Text and Shapes…", "-", "Edit Comment…", "-",
                           "Play/Pause Animation", "-", "Rating", "Toggle Tag", "-",
                           "Compare Selected", "Histogram", "Count Colors"])
        let adjust = try #require(image.items.first { $0.title == "Adjust" }?.submenu)
        #expect(adjust.items.compactMap(\.action) == [.adjustLighting, .adjustColors, .adjustCurves, .adjustLevels,
                                                      .sharpenImage, .blurImage])
        let effects = try #require(image.items.first { $0.title == "Effects" }?.submenu)
        #expect(effects.items.compactMap(\.action) == [.applyGrayscale, .applySepia, .applyNegative, .addDropShadow,
                                                       .addFrame, .applyBumpMap, .applySketch, .applyOilPaint, .applyLens])
        let retouch = try #require(image.items.first { $0.title == "Retouch" }?.submenu)
        #expect(retouch.items.compactMap(\.action) == [.cloneStamp, .healingBrush, .removeRedEye])
        let file = try #require(bar.items.first { $0.title == "File" }?.submenu)
        #expect(file.items.compactMap(\.action).filter { [.saveImage, .saveImageAs, .revertToSaved].contains($0) }
            == [.saveImage, .saveImageAs, .revertToSaved])
    }

    /// The editing shortcuts, as key presses, reach the right commands.
    /// Letters need real key events (AppKit matches Shift combinations from
    /// the key code), so a press is skipped on a layout where that key code
    /// isn't the letter.
    @Test func editingShortcutsResolve() throws {
        let recorder = Recorder()
        for item in allItems where item.action.map({ recorder.responds(to: $0) }) == true {
            item.target = recorder
        }
        let presses: [(letter: String, keyCode: CGKeyCode, flags: CGEventFlags, expected: String)] = [
            ("s", 1, .maskCommand, "saveImage:"),
            ("s", 1, [.maskCommand, .maskShift], "saveImageAs:"),
            ("l", 37, .maskCommand, "rotateLeft:"),
            ("r", 15, .maskCommand, "rotateRight:"),
            ("i", 34, [.maskCommand, .maskAlternate], "resizeImage:"),
            ("k", 40, .maskCommand, "cropImage:"),
            ("l", 37, [.maskCommand, .maskAlternate], "adjustLighting:"),
            ("c", 8, [.maskCommand, .maskAlternate], "adjustColors:"),
            ("m", 46, [.maskCommand, .maskShift], "adjustCurves:"),
            ("l", 37, [.maskCommand, .maskShift], "adjustLevels:"),
            ("r", 15, [.maskCommand, .maskAlternate], "revealInFinder:"),
        ]
        var checked = 0
        for press in presses {
            let event = keyPress(press.keyCode, press.flags)
            guard event.charactersIgnoringModifiers?.lowercased() == press.letter else { continue }
            recorder.calls = []
            #expect(bar.performKeyEquivalent(with: event), "\(press.expected) not taken")
            #expect(recorder.calls == [press.expected])
            checked += 1
        }
        // S, L and R sit on these key codes in QWERTY, QWERTZ and AZERTY alike.
        #expect(checked >= 6)
    }

    @Test func sortItemTagsFollowSortKeyOrder() {
        let sortItems = allItems.filter { $0.action == .sortBy }
        #expect(sortItems.map(\.tag) == Array(SortKey.allCases.indices))
        #expect(sortItems.map(\.title) == SortKey.allCases.map(\.menuTitle))
        let direction = allItems.filter { $0.action == .toggleSortDirection }.map(\.tag)
        #expect(direction == [SortDirectionTag.ascending, SortDirectionTag.descending])
    }

    @Test func ratingAndThemeTags() {
        #expect(allItems.filter { $0.action == .setRating }.map(\.tag) == [0, 1, 2, 3, 4, 5])
        let themes = allItems.filter { $0.action == #selector(AppDelegate.selectTheme(_:)) }
        #expect(themes.map(\.title) == ["System", "Bright", "Gray", "Dark"])
        #expect(themes.map(\.tag) == [0, 1, 2, 3])
    }

    /// Commands that only have keyboard or toolbar routes are left out.
    @Test func everyMenuActionIsInTheMenu() {
        let inMenu = Set(allItems.compactMap(\.action))
        let expected: [Selector] = [
            .openFolder, .addFolderToSidebar, .revealInFinder, .moveToTrash, .openInViewer, .fitToWindow,
            .actualSize, .zoomIn, .zoomOut, .nextImage, .previousImage, .firstImage, .lastImage,
            .goToEnclosingFolder, .goBack, .goForward, .sortBy, .toggleSortDirection, .toggleHiddenFiles,
            .togglePreviewPane, .setRating, .nextPage, .previousPage, .togglePlayback,
            .saveImage, .saveImageAs, .revertToSaved, .rotateLeft, .rotateRight, .flipHorizontal, .flipVertical,
            .resizeImage, .cropImage, .straightenImage, .adjustLighting, .adjustColors, .adjustCurves, .adjustLevels,
            .sharpenImage, .blurImage, .applyGrayscale, .applySepia, .applyNegative, .editComment,
            .toggleTag, .filterByRating, .toggleTaggedFilter, .renameItem, .newFolder, .copyToFolder, .moveToFolder,
            .compareSelected, .toggleHistogram, .countColors,
            .addDropShadow, .addFrame, .applyBumpMap, .applySketch, .applyOilPaint, .applyLens, .drawAnnotations,
            .cloneStamp, .healingBrush, .removeRedEye,
            .startSlideshow, .batchConvert, .batchRename, .printImages, .makeContactSheet, .makeMontage,
            .setAsDesktopPicture, .captureScreen, .captureWindow, .captureSelection, .manageExternalEditors,
            #selector(NSApplication.runPageLayout(_:)),
        ]
        for selector in expected {
            #expect(inMenu.contains(selector), "\(selector) missing")
        }
    }

    /// File gains New Folder, Rename and the Copy To and Move To submenus
    /// (recent folders, then Choose Folder…); View gains Filter.
    @Test func managementItems() throws {
        let file = try #require(bar.items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Open Folder…", "Add Folder to Sidebar…", "New Folder", "-", "Open in Viewer", "Close Window",
                           "Save", "Save As…", "Revert to Saved", "-", "Rename", "Copy To", "Move To", "-",
                           "Reveal in Finder", "Move to Trash", "-", "Page Setup…", "Print…"])
        let copyTo = try #require(file.items.first { $0.title == "Copy To" }?.submenu)
        let moveTo = try #require(file.items.first { $0.title == "Move To" }?.submenu)
        #expect(copyTo.items.last?.title == "Choose Folder…" && copyTo.items.last?.action == .copyToFolder)
        #expect(moveTo.items.last?.title == "Choose Folder…" && moveTo.items.last?.action == .moveToFolder)
        #expect(copyTo.delegate is RecentDestinationsMenu, "the recent folders are filled in when it opens")

        let view = try #require(bar.items.first { $0.title == "View" }?.submenu)
        let filter = try #require(view.items.first { $0.title == "Filter" }?.submenu)
        #expect(filter.items.map { $0.isSeparatorItem ? "-" : $0.title }
            == ["Show All", "-", "★ or More", "★★ or More", "★★★ or More", "★★★★ or More", "★★★★★", "-", "Tagged Only"])
        #expect(filter.items.filter { $0.action == .filterByRating }.map(\.tag) == [0, 1, 2, 3, 4, 5])
    }

    /// The management shortcuts, pressed as keys, reach their commands.
    @Test func managementShortcutsResolve() throws {
        let recorder = Recorder()
        for item in allItems where item.action.map({ recorder.responds(to: $0) }) == true {
            item.target = recorder
        }
        let presses: [(letter: String?, keyCode: CGKeyCode, flags: CGEventFlags, expected: String)] = [
            ("n", 45, [.maskCommand, .maskShift], "newFolder:"),
            (nil, 120, [], "renameItem:"),                                   // F2
            ("t", 17, .maskCommand, "toggleTag:"),
            ("k", 40, [.maskCommand, .maskAlternate], "compareSelected:"),
            ("h", 4, [.maskCommand, .maskShift], "toggleHistogram:"),
            (nil, 20, .maskControl, "setRating:"),                           // ⌃3
        ]
        var checked = 0
        for press in presses {
            let event = keyPress(press.keyCode, press.flags)
            if let letter = press.letter, event.charactersIgnoringModifiers?.lowercased() != letter { continue }
            recorder.calls = []
            #expect(bar.performKeyEquivalent(with: event), "\(press.expected) not taken")
            #expect(recorder.calls == [press.expected])
            checked += 1
        }
        #expect(checked >= 3)
        // Bare digits, T and ` stay with the grid and the viewer.
        recorder.calls = []
        for code: CGKeyCode in [20, 17, 50] { #expect(!bar.performKeyEquivalent(with: keyPress(code))) }
        #expect(recorder.calls.isEmpty)
    }

    /// Tools (Phase 7): the commands, their shortcuts, and the submenus.
    @Test func toolsItems() throws {
        let tools = try #require(bar.items.first { $0.title == "Tools" }?.submenu)
        let titles = tools.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Start Slideshow", "-", "Batch Convert…", "Batch Rename…", "-", "Contact Sheet…",
                           "Montage Wallpaper…", "Set as Desktop Picture", "-", "Capture", "-",
                           "Open in External Editor"])
        let slideshow = try item("Start Slideshow")
        #expect(slideshow.keyEquivalent == "f" && slideshow.keyEquivalentModifierMask == [.command, .shift])
        let rename = try item("Batch Rename…")
        #expect(rename.keyEquivalent == MainMenu.Key.f2 && rename.keyEquivalentModifierMask == [.shift])
        let capture = try #require(tools.items.first { $0.title == "Capture" }?.submenu)
        #expect(capture.items.compactMap(\.action) == [.captureScreen, .captureWindow, .captureSelection])
        let editors = try #require(tools.items.last?.submenu)
        #expect(editors.items.last?.action == .manageExternalEditors)
        #expect(try item("Print…").keyEquivalent == "p")
    }

    @Test func menuItemsHaveNoTarget() {
        // A nil target is what sends them down the responder chain. (AppKit
        // makes an item's submenu its target, so those are skipped.)
        #expect(allItems.filter { $0.submenu == nil }.allSatisfy { $0.target == nil })
    }

    @Test func specialMenusAreFound() {
        MainMenu.install()
        #expect(NSApp.servicesMenu?.title == "Services")
        #expect(NSApp.windowsMenu?.title == "Window")
        #expect(NSApp.helpMenu?.title == "Help")
    }

    /// The arrows are shown in the Go menu but must never be taken from the
    /// grid or viewer by the menu.
    @Test func arrowShortcutsAreDisplayOnly() throws {
        let next = try item("Next Image")
        let go = try #require(next.menu)
        #expect(next.keyEquivalent.isEmpty)
        let viewKeys = try #require(go.delegate as? DisplayOnlyShortcuts)

        viewKeys.showShortcuts(true)
        #expect(next.keyEquivalent == MainMenu.Key.right)
        #expect(next.keyEquivalentModifierMask.isEmpty)
        viewKeys.showShortcuts(false)
        #expect(next.keyEquivalent.isEmpty)
    }

    /// The viewer's page and playback keys are in the menus, shown with
    /// their modifiers only while the menu is open, each by its own menu.
    @Test func pageAndPlaybackShortcutsAreDisplayOnly() throws {
        let nextPage = try item("Next Page"), previousPage = try item("Previous Page")
        let play = try item("Play/Pause Animation")
        #expect(nextPage.action == .nextPage && previousPage.action == .previousPage)
        #expect(play.action == .togglePlayback)
        #expect(nextPage.menu?.title == "Go" && play.menu?.title == "Image")
        for item in [nextPage, previousPage, play] {
            #expect(item.keyEquivalent.isEmpty)
        }

        let goKeys = try #require(nextPage.menu?.delegate as? DisplayOnlyShortcuts)
        let imageKeys = try #require(play.menu?.delegate as? DisplayOnlyShortcuts)
        #expect(goKeys !== imageKeys)
        goKeys.showShortcuts(true)
        #expect(nextPage.keyEquivalent == MainMenu.Key.right && nextPage.keyEquivalentModifierMask == .option)
        #expect(previousPage.keyEquivalent == MainMenu.Key.left && previousPage.keyEquivalentModifierMask == .option)
        #expect(try item("Next Image").keyEquivalentModifierMask.isEmpty)
        #expect(play.keyEquivalent.isEmpty)   // the Image menu isn't open
        goKeys.showShortcuts(false)
        #expect(nextPage.keyEquivalent.isEmpty && nextPage.keyEquivalentModifierMask.isEmpty)

        imageKeys.showShortcuts(true)
        #expect(play.keyEquivalent == "p" && play.keyEquivalentModifierMask.isEmpty)
        imageKeys.showShortcuts(false)
        #expect(play.keyEquivalent.isEmpty)
    }

    /// With the menus closed, a bare P and Option-arrows reach the focused
    /// view (the viewer, or a text field) rather than the menu.
    @Test func pageAndPlaybackKeysReachViews() throws {
        let recorder = Recorder()
        for title in ["Next Page", "Previous Page", "Play/Pause Animation"] {
            try item(title).target = recorder
        }
        #expect(!bar.performKeyEquivalent(with: keyPress(124, .maskAlternate)))   // ⌥→
        #expect(!bar.performKeyEquivalent(with: keyPress(123, .maskAlternate)))   // ⌥←
        #expect(!bar.performKeyEquivalent(with: keyPress(35)))                    // P
        #expect(recorder.calls.isEmpty)
    }

    /// Drives AppKit's real key-equivalent search. While the Go menu shows
    /// its arrows, the menu would take the key (which is why they're only
    /// shown while it is open); once it closes the key reaches the views,
    /// and ordinary shortcuts keep working.
    @Test func arrowsReachViewsOnceTheMenuCloses() async throws {
        let recorder = Recorder()
        let next = try item("Next Image")
        let back = try item("Back")
        next.target = recorder
        back.target = recorder
        let go = try #require(next.menu)
        let viewKeys = try #require(go.delegate as? DisplayOnlyShortcuts)
        let rightArrow = keyPress(124)

        viewKeys.showShortcuts(true)
        #expect(bar.performKeyEquivalent(with: rightArrow))
        #expect(recorder.calls == ["nextImage:"])

        viewKeys.menuDidClose(go)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(next.keyEquivalent.isEmpty)
        #expect(!bar.performKeyEquivalent(with: rightArrow))
        #expect(recorder.calls == ["nextImage:"])

        #expect(bar.performKeyEquivalent(with: keyEvent("[", keyCode: 33, modifiers: .command)))
        #expect(recorder.calls == ["nextImage:", "goBack:"])
    }

    /// Non-printing keys and their shortcuts, as the keyboard sends them.
    @Test func shortcutsOnSpecialKeys() throws {
        let recorder = Recorder()
        for title in ["Move to Trash", "Open in Viewer", "Enclosing Folder"] {
            try item(title).target = recorder
        }
        #expect(bar.performKeyEquivalent(with: keyPress(51, .maskCommand)))    // ⌘⌫
        #expect(bar.performKeyEquivalent(with: keyPress(125, .maskCommand)))   // ⌘↓
        #expect(bar.performKeyEquivalent(with: keyPress(126, .maskCommand)))   // ⌘↑
        #expect(recorder.calls == ["moveToTrash:", "openInViewer:", "goToEnclosingFolder:"])
        // A bare Delete must stay with the focused view.
        #expect(!bar.performKeyEquivalent(with: keyPress(51)))
    }

    /// A key event made the way the window server makes one, so AppKit
    /// matches it exactly as it would a real key press. (Events built from
    /// characters alone match differently: ⌘⌫ arrives as DEL, 0x7F, and
    /// only a real event matches the menu's backspace, 0x08.) Only for keys
    /// whose code means the same on every keyboard layout.
    func keyPress(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return NSEvent(cgEvent: event)!
    }

    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    final class Recorder: NSObject {
        var calls: [String] = []
        @objc func nextImage(_ sender: Any?) { calls.append("nextImage:") }
        @objc func goBack(_ sender: Any?) { calls.append("goBack:") }
        @objc func moveToTrash(_ sender: Any?) { calls.append("moveToTrash:") }
        @objc func openInViewer(_ sender: Any?) { calls.append("openInViewer:") }
        @objc func goToEnclosingFolder(_ sender: Any?) { calls.append("goToEnclosingFolder:") }
        @objc func nextPage(_ sender: Any?) { calls.append("nextPage:") }
        @objc func previousPage(_ sender: Any?) { calls.append("previousPage:") }
        @objc func togglePlayback(_ sender: Any?) { calls.append("togglePlayback:") }
        @objc func revealInFinder(_ sender: Any?) { calls.append("revealInFinder:") }
        @objc func saveImage(_ sender: Any?) { calls.append("saveImage:") }
        @objc func saveImageAs(_ sender: Any?) { calls.append("saveImageAs:") }
        @objc func rotateLeft(_ sender: Any?) { calls.append("rotateLeft:") }
        @objc func rotateRight(_ sender: Any?) { calls.append("rotateRight:") }
        @objc func resizeImage(_ sender: Any?) { calls.append("resizeImage:") }
        @objc func cropImage(_ sender: Any?) { calls.append("cropImage:") }
        @objc func adjustLighting(_ sender: Any?) { calls.append("adjustLighting:") }
        @objc func adjustColors(_ sender: Any?) { calls.append("adjustColors:") }
        @objc func adjustCurves(_ sender: Any?) { calls.append("adjustCurves:") }
        @objc func adjustLevels(_ sender: Any?) { calls.append("adjustLevels:") }
        @objc func newFolder(_ sender: Any?) { calls.append("newFolder:") }
        @objc func renameItem(_ sender: Any?) { calls.append("renameItem:") }
        @objc func toggleTag(_ sender: Any?) { calls.append("toggleTag:") }
        @objc func compareSelected(_ sender: Any?) { calls.append("compareSelected:") }
        @objc func toggleHistogram(_ sender: Any?) { calls.append("toggleHistogram:") }
        @objc func setRating(_ sender: Any?) { calls.append("setRating:") }
    }
}
