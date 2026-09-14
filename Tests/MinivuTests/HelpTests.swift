import Testing
import AppKit
import SwiftUI
@testable import Minivu

/// Help > minivu Help: the bundled pages, the Markdown blocks they become,
/// search, and the generated Keyboard Shortcuts page.
@MainActor @Suite struct HelpTests {
    init() {
        _ = NSApplication.shared
    }

    // MARK: - Pages

    /// Every page but the generated one is in the resource bundle, parses,
    /// and starts with its own title.
    @Test func everyPageLoads() throws {
        for page in HelpPage.allCases where page != .shortcuts {
            let text = try #require(HelpLibrary.markdown(for: page), "\(page.rawValue).md is not in the bundle")
            let blocks = try HelpMarkdown.blocks(from: text)
            #expect(blocks.count > 5, "\(page.rawValue) is nearly empty")
            #expect(blocks.first?.kind == .heading(level: 1))
            #expect(blocks.first?.plainText == page.title)
        }
        #expect(HelpLibrary.markdown(for: .shortcuts) == nil)
    }

    @Test func loadAllReadsEveryMarkdownPage() async {
        let pages = await HelpLibrary.loadAll()
        #expect(Set(pages.keys) == Set(HelpPage.allCases.filter { $0 != .shortcuts }))
    }

    /// Links between pages name pages that exist, and nothing links out of
    /// the app.
    @Test func linksNamePages() throws {
        var links = 0
        for page in HelpPage.allCases where page != .shortcuts {
            let blocks = try HelpMarkdown.blocks(from: try #require(HelpLibrary.markdown(for: page)))
            for block in blocks {
                for run in block.text.runs {
                    guard let url = run.link else { continue }
                    links += 1
                    #expect(HelpPage(link: url) != nil, "\(page.rawValue) links to \(url)")
                }
            }
        }
        #expect(links >= 8)
        #expect(HelpPage(link: URL(string: "help:KeyboardShortcuts")!) == .shortcuts)
        #expect(HelpPage(link: URL(string: "https://example.com")!) == nil)
        #expect(HelpPage(link: URL(string: "help:Nowhere")!) == nil)
    }

    // MARK: - Markdown

    @Test func markdownBecomesBlocks() throws {
        let blocks = try HelpMarkdown.blocks(from: """
            # Title

            A paragraph
            over two lines with **bold** and `code`.

            ## Section

            - one
            - two
              continued

              second paragraph
              - nested

            1. first
            2. second

            > A note.

            ```
            let x = 1
            ```
            """)
        #expect(blocks.map(\.kind) == [
            .heading(level: 1), .paragraph, .heading(level: 2),
            .listItem(depth: 1, marker: "•"), .listItem(depth: 1, marker: "•"), .listItem(depth: 1, marker: nil),
            .listItem(depth: 2, marker: "•"),
            .listItem(depth: 1, marker: "1."), .listItem(depth: 1, marker: "2."),
            .note, .code,
        ])
        #expect(blocks[1].plainText == "A paragraph over two lines with bold and code.")
        #expect(blocks[4].plainText == "two continued")
        #expect(blocks[10].plainText == "let x = 1")
        // Inline styles stay for the view to draw.
        let bold = blocks[1].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(blocks[1].text[$0.range].characters) } == "bold")
        #expect(Set(blocks.map(\.id)).count == blocks.count, "ids identify blocks in the view")
    }

    // MARK: - Search

    @Test func searchCountsAndHighlights() {
        #expect(HelpMarkdown.matchCount(of: "photo", in: "Photos and photo, PHOTO") == 3)
        #expect(HelpMarkdown.matchCount(of: "cafe", in: "Café") == 1)
        #expect(HelpMarkdown.matchCount(of: "  ", in: "anything") == 0)

        let highlighted = HelpHighlight.highlighting("tag", in: AttributedString("Tag or untag"))
        let marked = highlighted.runs.filter { $0.backgroundColor != nil }.map { String(highlighted[$0.range].characters) }
        #expect(marked == ["Tag", "tag"])
        #expect(HelpHighlight.highlighting("", in: AttributedString("Tag")) == AttributedString("Tag"))
    }

    @Test func modelFiltersPagesWhileSearching() async {
        let model = HelpModel()
        model.refreshShortcuts()
        model.load()
        for _ in 0..<500 where !model.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isLoaded)
        #expect(model.visiblePages == HelpPage.allCases)
        model.query = "Batch Rename"
        #expect(model.visiblePages.contains(.tools))
        #expect(model.visiblePages.contains(.shortcuts))
        #expect(!model.visiblePages.contains(.gettingStarted))
        #expect(model.matchCount(.tools) > 0)
        model.query = "zzqxv"
        #expect(model.visiblePages.isEmpty)
    }

    @Test func shortcutSectionFilter() {
        let section = ShortcutSection(title: "Viewer", rows: [
            ShortcutRow(title: "Next image", keys: "→"), ShortcutRow(title: "Zoom in", keys: "+"),
        ])
        #expect(section.filtered(by: "") == section)
        #expect(section.filtered(by: "zoom")?.rows.map(\.title) == ["Zoom in"])
        #expect(section.filtered(by: "viewer") == section)
        #expect(section.filtered(by: "slideshow") == nil)
    }

    // MARK: - Keyboard Shortcuts

    /// The page lists every menu item that has a shortcut, with the keys the
    /// menu shows, display-only ones (arrows, P, Option-arrows) included.
    @Test func shortcutsPageListsEveryMenuShortcut() {
        let page = KeyboardShortcutsPage.sections(menuBar: MainMenu.make())
        let listed = Set(page.flatMap(\.rows))

        let bar = MainMenu.make()
        for item in bar.items { (item.submenu?.delegate as? DisplayOnlyShortcuts)?.showShortcuts(true) }
        var expected = 0
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    walk(submenu, path: path + [item.title])
                } else if !item.keyEquivalent.isEmpty {
                    expected += 1
                    let row = ShortcutRow(title: (path + [item.title]).joined(separator: " › "),
                                          keys: KeyboardShortcutsPage.keys(for: item))
                    #expect(listed.contains(row), "\(row.title) (\(row.keys)) is missing")
                }
            }
        }
        for top in bar.items { if let menu = top.submenu { walk(menu, path: []) } }
        #expect(expected > 40)
        #expect(page.first?.title == "minivu")
        #expect(listed.contains(ShortcutRow(title: "Next Image", keys: "→")))
        #expect(listed.contains(ShortcutRow(title: "Next Page", keys: "⌥→")))
        #expect(listed.contains(ShortcutRow(title: "Play Animation", keys: "P")))
        #expect(listed.contains(ShortcutRow(title: "Adjust › Levels…", keys: "⇧⌘L")))
        #expect(listed.contains(ShortcutRow(title: "Keyboard Shortcuts", keys: "⌘/")))
    }

    /// Reading the page leaves a menu bar's display-only shortcuts shown,
    /// which is why it is given a fresh bar; the installed one is untouched.
    @Test func pageDoesNotTouchTheInstalledMenuBar() throws {
        MainMenu.install()
        _ = KeyboardShortcutsPage.sections()
        let next = try #require(NSApp.mainMenu?.items.first { $0.title == "Go" }?.submenu?.items.first)
        #expect(next.title == "Next Image" && next.keyEquivalent.isEmpty)
    }

    @Test func keysAreWrittenAsMenusShowThem() {
        func keys(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return KeyboardShortcutsPage.keys(for: item)
        }
        #expect(keys("s", [.command, .shift]) == "⇧⌘S")
        #expect(keys("S", .command) == "⇧⌘S")
        #expect(keys("h", [.command, .option]) == "⌥⌘H")
        #expect(keys("3", .control) == "⌃3")
        #expect(keys(MainMenu.Key.f2, [.shift]) == "⇧F2")
        #expect(keys(MainMenu.Key.backspace, .command) == "⌘⌫")
        #expect(keys(MainMenu.Key.up, .command) == "⌘↑")
        #expect(keys(MainMenu.Key.home, []) == "Home")
        #expect(keys(",", .command) == "⌘,")
    }

    @Test func helpMenuItems() throws {
        let help = try #require(MainMenu.make().items.last?.submenu)
        #expect(help.title == "Help")
        let items = help.items.map { ($0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask, $0.action) }
        #expect(items.count == 2)
        #expect(items[0] == ("minivu Help", "?", .command, #selector(AppDelegate.showMinivuHelp(_:))))
        #expect(items[1] == ("Keyboard Shortcuts", "/", .command, #selector(AppDelegate.showKeyboardShortcuts(_:))))
        // NSApplication's own showHelp: would come first in the responder
        // chain and look for a Help Book.
        #expect(!NSApplication.instancesRespond(to: #selector(AppDelegate.showMinivuHelp(_:))))
    }

    /// The keys listed outside the menus are the ones the code takes. Each
    /// listed key is pressed through the same tables the views use.
    @Test func directKeysMatchTheKeyTables() throws {
        func viewer(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], zoomedIn: Bool = false) -> ViewerKeyCommand? {
            ViewerKeyCommand.command(characters: characters, modifiers: modifiers, zoomedIn: zoomedIn)
        }
        let character = { (code: Int) in String(Character(UnicodeScalar(code)!)) }
        #expect(viewer(character(NSRightArrowFunctionKey)) == .next && viewer(character(NSDownArrowFunctionKey)) == .next)
        #expect(viewer(" ") == .next)
        #expect(viewer(character(NSLeftArrowFunctionKey)) == .previous && viewer(character(NSDeleteCharacter)) == .previous)
        #expect(viewer(character(NSRightArrowFunctionKey), zoomedIn: true) == .pan(x: 1, y: 0))
        #expect(viewer(character(NSHomeFunctionKey)) == .first && viewer(character(NSEndFunctionKey)) == .last)
        #expect(viewer(character(NSPageDownFunctionKey)) == .pageForward)
        #expect(viewer(character(NSPageDownFunctionKey), .option) == .nextPage)
        #expect(viewer("+") == .zoomIn && viewer("-") == .zoomOut && viewer("/") == .actualSize && viewer("*") == .fit)
        #expect(viewer("3") == .rating(3) && viewer("t") == .toggleTag && viewer("`") == .toggleTag)
        #expect(viewer("i") == .toggleHUD && viewer("f") == .toggleFilmstrip && viewer("p") == .togglePlayback)
        #expect(viewer("\r") == .toggleFullScreen && viewer("\u{1B}") == .close)
        #expect(viewer("/", .command) == nil, "⌘/ is Help > Keyboard Shortcuts")

        #expect(GridCollectionView.markKey("4", continuingName: false) == .rate(4))
        #expect(GridCollectionView.markKey("`", continuingName: false) == .toggleTag)

        func compare(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> CompareKeyCommand? {
            CompareKeyCommand.command(characters: characters, modifiers: modifiers)
        }
        #expect(compare("2", .command) == .focus(1))
        #expect(compare("\t") == .cycleFocus(backward: false))
        #expect(compare(character(NSLeftArrowFunctionKey)) == .replace(-1))
        #expect(compare("5") == .rate(5) && compare("t") == .toggleTag)
        #expect(compare(character(NSDeleteCharacter)) == .trash)
        #expect(compare("f") == .toggleFullScreen && compare("\r") == .toggleFullScreen && compare("\u{1B}") == .close)

        let titles = KeyboardShortcutsPage.directKeySections.map(\.title)
        #expect(titles == ["Browser", "Viewer", "Viewer Mouse and Trackpad", "Compare", "Slideshow", "Editing Tools"])
    }
}
