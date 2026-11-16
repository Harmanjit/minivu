import AppKit

/// One shortcut on the Keyboard Shortcuts page.
nonisolated struct ShortcutRow: Identifiable, Hashable, Sendable {
    /// What it does: the menu item's title (with its submenu, "Adjust ›
    /// Levels…") or a description.
    var title: String
    /// The keys, as the menus show them ("⇧⌘S").
    var keys: String

    var id: String { "\(title)|\(keys)" }
}

/// A group of shortcuts: one menu, or one part of the app.
nonisolated struct ShortcutSection: Identifiable, Equatable, Sendable {
    /// Stable whatever the language: "menu.3" (the menu bar's fourth menu)
    /// or a name for the views' own keys.
    var id: String
    var title: String
    /// A line under the title, for keys that depend on where you are.
    var note: String?
    var rows: [ShortcutRow]

    /// The rows whose title, keys or section match `query`; all of them for
    /// an empty query.
    func filtered(by query: String) -> ShortcutSection? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        if HelpMarkdown.matchCount(of: query, in: title) > 0 { return self }
        let rows = rows.filter { HelpMarkdown.matchCount(of: query, in: "\($0.title) \($0.keys)") > 0 }
        return rows.isEmpty ? nil : ShortcutSection(id: id, title: title, note: note, rows: rows)
    }

    var plainText: String {
        ([title, note ?? ""] + rows.map { "\($0.title) \($0.keys)" }).joined(separator: "\n")
    }
}

/// Help > Keyboard Shortcuts, generated rather than written.
///
/// The menu part is read from a menu bar made by `MainMenu.make()`, so a
/// shortcut added, changed or removed there shows here with nothing else to
/// update. Keys that no menu item carries (the grid's and viewer's own
/// keys, the compare window, slideshow and tools) can't be read from
/// anywhere, so they are listed below from DESIGN.md section 5 and the key
/// tables in the code, and HelpTests presses them through those tables.
enum KeyboardShortcutsPage {
    /// The whole page: the menus first, then the keys views take directly.
    static func sections(menuBar: NSMenu = MainMenu.make()) -> [ShortcutSection] {
        menuSections(from: menuBar) + directKeySections
    }

    /// One section per menu with shortcuts, in menu bar order.
    ///
    /// Items that show their keys only while their menu is open (arrows, P,
    /// Option-arrows; see `DisplayOnlyShortcuts`) are shown here too, so
    /// `menuBar` must be a bar made for reading: a fresh `MainMenu.make()`,
    /// never the installed menu bar.
    static func menuSections(from menuBar: NSMenu) -> [ShortcutSection] {
        for item in menuBar.items {
            (item.submenu?.delegate as? DisplayOnlyShortcuts)?.showShortcuts(true)
        }
        return menuBar.items.enumerated().compactMap { index, top -> ShortcutSection? in
            guard let menu = top.submenu else { return nil }
            let rows = rows(in: menu, path: [])
            return rows.isEmpty ? nil : ShortcutSection(id: "menu.\(index)", title: menu.title, rows: rows)
        }
    }

    private static func rows(in menu: NSMenu, path: [String]) -> [ShortcutRow] {
        menu.items.flatMap { item -> [ShortcutRow] in
            if let submenu = item.submenu {
                return rows(in: submenu, path: path + [item.title])
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { return [] }
            return [ShortcutRow(title: (path + [item.title]).joined(separator: " › "), keys: keys(for: item))]
        }
    }

    /// The item's shortcut the way a menu draws it: modifiers in the order
    /// ⌃⌥⇧⌘, then the key. An uppercase key equivalent implies Shift.
    static func keys(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask
        if key != key.lowercased() { modifiers.insert(.shift) }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + name(ofKey: key)
    }

    static func name(ofKey key: String) -> String {
        switch key {
        case MainMenu.Key.up: "↑"
        case MainMenu.Key.down: "↓"
        case MainMenu.Key.left: "←"
        case MainMenu.Key.right: "→"
        case MainMenu.Key.home: localized(.init("Home", comment: "Keys or gesture; keep key names as the keyboard shows them"))
        case MainMenu.Key.end: localized(.init("help.key.end", defaultValue: "End", comment: "Keys or gesture; keep key names as the keyboard shows them"))
        case MainMenu.Key.backspace: "⌫"
        case MainMenu.Key.f2: "F2"
        case " ": localized(.init("Space", comment: "Keys or gesture; keep key names as the keyboard shows them"))
        default: key.uppercased()
        }
    }

    // MARK: - Keys outside the menus

    /// DESIGN.md section 5, and `GridCollectionView.keyDown`,
    /// `ViewerKeyCommand`, `CompareKeyCommand` and the slideshow's and
    /// tools' key handlers.
    ///
    /// Titles, notes and worded keys (Return, Page Down…) are localized; key
    /// symbols stay as the keys show them.
    static let directKeySections: [ShortcutSection] = [
        ShortcutSection(id: "browser", title: localized(.init("Browser", comment: "The window with the folder list and the thumbnail grid")),
                        note: localized("In the thumbnail grid."), rows: [
            ShortcutRow(title: localized("Move the selection"), keys: "↑ ↓ ← →"),
            ShortcutRow(title: localized("Extend the selection"),
                        keys: localized(.init("⇧ with an arrow", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Open in the viewer"),
                        keys: localized(.init("Return or double-click", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Select a file by name"),
                        keys: localized(.init("Type its name", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Rate the selection (0 clears)"), keys: "0–5"),
            ShortcutRow(title: localized("Tag or untag the selection"), keys: "`"),
            ShortcutRow(title: localized("Copy the files you drop"),
                        keys: localized(.init("⌥ while dropping", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Move the files you drop"),
                        keys: localized(.init("⌘ while dropping", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
        ShortcutSection(id: "viewer", title: localized(.init("Viewer", comment: "The window that shows one image")), note: localized("When the image is larger than the window, the arrows pan it instead."),
                        rows: [
            ShortcutRow(title: localized("Next image"), keys: localized(.init("→ ↓ Space", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Previous image"), keys: "← ↑ ⌫"),
            ShortcutRow(title: localized("First or last image"), keys: localized(.init("Home, End", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Next or previous page, then image"), keys: localized(.init("Page Down, Page Up", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Next or previous page only"), keys: localized(.init("⌥Page Down, ⌥Page Up", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Zoom in or out"), keys: "+ −"),
            ShortcutRow(title: localized("Actual size"), keys: "/"),
            ShortcutRow(title: localized("Fit to window"), keys: "*"),
            ShortcutRow(title: localized("Rate (0 clears)"), keys: "0–5"),
            ShortcutRow(title: localized("Tag or untag"),
                        keys: localized(.init("T or `", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Keep the info overlay up"), keys: "I"),
            ShortcutRow(title: localized("Keep the filmstrip open"), keys: "F"),
            ShortcutRow(title: localized("Play or pause an animation"), keys: "P"),
            // On a video, Space plays and pauses instead of moving on (G18);
            // P does too, and M mutes (both in the Image menu's section).
            ShortcutRow(title: MenuStateTitles.videoPlayback(isPlaying: false),
                        keys: localized(.init("Space", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Switch between window and full screen"), keys: localized(.init("Return", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Back to the browser"), keys: localized(.init("Esc", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
        ShortcutSection(id: "viewer.pointer", title: localized(.init("Viewer Mouse and Trackpad", comment: "Heading: what the mouse and trackpad do in the viewer")), rows: [
            ShortcutRow(title: localized("Fit or actual size at that point"),
                        keys: localized(.init("Click", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized(.init("Magnifier", comment: "The loupe that magnifies part of the image")),
                        keys: localized(.init("Press and hold", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized(.init("Pan", comment: "Verb: move a zoomed image around in the window")),
                        keys: localized(.init("Drag", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized(.init("image.zoom.verb", defaultValue: "Zoom", comment: "Verb: make the image larger or smaller")),
                        keys: localized(.init("Pinch", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Next image or zoom (Settings › Viewer)"),
                        keys: localized(.init("Scroll", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Show a panel"),
                        keys: localized(.init("Pointer to an edge", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
        ShortcutSection(id: "compare", title: localized(.init("help.shortcuts.compare", defaultValue: "Compare", comment: "Noun: the window that shows images side by side")), rows: [
            ShortcutRow(title: localized("Choose a pane"), keys: "⌘1–⌘4"),
            ShortcutRow(title: localized("Next or previous pane"), keys: localized(.init("Tab, ⇧Tab", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Previous or next image in the pane"), keys: "← →"),
            ShortcutRow(title: localized("Rate (0 clears)"), keys: "0–5"),
            ShortcutRow(title: localized("Tag or untag"), keys: "T"),
            ShortcutRow(title: localized("Move to Trash"), keys: "⌫"),
            ShortcutRow(title: localized("Full screen"),
                        keys: localized(.init("Return or F", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Close"), keys: localized(.init("Esc", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
        ShortcutSection(id: "slideshow", title: localized("Slideshow"), rows: [
            ShortcutRow(title: localized("Pause or resume"), keys: localized(.init("Space", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Next slide"), keys: localized(.init("→ ↓ Page Down", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Previous slide"), keys: localized(.init("← ↑ Page Up", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("End the show"), keys: localized(.init("Esc", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
        ShortcutSection(id: "tools", title: localized("Editing Tools"), rows: [
            ShortcutRow(title: localized("Clone Stamp, Healing Brush: set the source"),
                        keys: localized(.init("⌥-click", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Clone Stamp, Healing Brush: brush size"), keys: "[ ]"),
            ShortcutRow(title: localized("Text and Shapes: nudge the selection"),
                        keys: localized(.init("Arrows, ⇧ for more", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Text and Shapes: duplicate"), keys: "⌘D"),
            ShortcutRow(title: localized("Text and Shapes: deselect"), keys: localized(.init("Esc", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
            ShortcutRow(title: localized("Text and Shapes, Red-Eye: delete the selection"), keys: "⌫"),
            ShortcutRow(title: localized("Capture Selection: capture or cancel"), keys: localized(.init("Return, Esc", comment: "Keys or gesture; keep key names as the keyboard shows them"))),
        ]),
    ]
}
