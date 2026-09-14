import Testing
import AppKit
import AgateCore
@testable import Agate

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
        #expect(bar.items.map(\.title) == ["Agate", "File", "Edit", "View", "Image", "Go", "Window", "Help"])
    }

    /// Two items with the same shortcut would make one of them unreachable.
    @Test func noShortcutIsUsedTwice() {
        var seen: [String: String] = [:]
        for item in allItems where !item.keyEquivalent.isEmpty {
            let shortcut = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            #expect(seen[shortcut] == nil, "\(item.title) reuses the shortcut of \(seen[shortcut] ?? "")")
            seen[shortcut] = item.title
        }
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
            .togglePreviewPane, .setRating,
        ]
        for selector in expected {
            #expect(inMenu.contains(selector), "\(selector) missing")
        }
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
        let rightArrow = keyEvent(MainMenu.Key.right, keyCode: 124, modifiers: [.function, .numericPad])

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

    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    final class Recorder: NSObject {
        var calls: [String] = []
        @objc func nextImage(_ sender: Any?) { calls.append("nextImage:") }
        @objc func goBack(_ sender: Any?) { calls.append("goBack:") }
    }
}
