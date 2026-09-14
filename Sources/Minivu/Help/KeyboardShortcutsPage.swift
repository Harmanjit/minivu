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
    var title: String
    /// A line under the title, for keys that depend on where you are.
    var note: String?
    var rows: [ShortcutRow]

    var id: String { title }

    /// The rows whose title, keys or section match `query`; all of them for
    /// an empty query.
    func filtered(by query: String) -> ShortcutSection? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        if HelpMarkdown.matchCount(of: query, in: title) > 0 { return self }
        let rows = rows.filter { HelpMarkdown.matchCount(of: query, in: "\($0.title) \($0.keys)") > 0 }
        return rows.isEmpty ? nil : ShortcutSection(title: title, note: note, rows: rows)
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
        return menuBar.items.compactMap { top -> ShortcutSection? in
            guard let menu = top.submenu else { return nil }
            let rows = rows(in: menu, path: [])
            return rows.isEmpty ? nil : ShortcutSection(title: menu.title, rows: rows)
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
        case MainMenu.Key.home: "Home"
        case MainMenu.Key.end: "End"
        case MainMenu.Key.backspace: "⌫"
        case MainMenu.Key.f2: "F2"
        case " ": "Space"
        default: key.uppercased()
        }
    }

    // MARK: - Keys outside the menus

    /// DESIGN.md section 5, and `GridCollectionView.keyDown`,
    /// `ViewerKeyCommand`, `CompareKeyCommand` and the slideshow's and
    /// tools' key handlers.
    static let directKeySections: [ShortcutSection] = [
        ShortcutSection(title: "Browser", note: "In the thumbnail grid.", rows: [
            ShortcutRow(title: "Move the selection", keys: "↑ ↓ ← →"),
            ShortcutRow(title: "Extend the selection", keys: "⇧ with an arrow"),
            ShortcutRow(title: "Open in the viewer", keys: "Return or double-click"),
            ShortcutRow(title: "Select a file by name", keys: "Type its name"),
            ShortcutRow(title: "Rate the selection (0 clears)", keys: "0–5"),
            ShortcutRow(title: "Tag or untag the selection", keys: "`"),
            ShortcutRow(title: "Copy the files you drop", keys: "⌥ while dropping"),
            ShortcutRow(title: "Move the files you drop", keys: "⌘ while dropping"),
        ]),
        ShortcutSection(title: "Viewer", note: "When the image is larger than the window, the arrows pan it instead.",
                        rows: [
            ShortcutRow(title: "Next image", keys: "→ ↓ Space"),
            ShortcutRow(title: "Previous image", keys: "← ↑ ⌫"),
            ShortcutRow(title: "First or last image", keys: "Home, End"),
            ShortcutRow(title: "Next or previous page, then image", keys: "Page Down, Page Up"),
            ShortcutRow(title: "Next or previous page only", keys: "⌥Page Down, ⌥Page Up"),
            ShortcutRow(title: "Zoom in or out", keys: "+ −"),
            ShortcutRow(title: "Actual size", keys: "/"),
            ShortcutRow(title: "Fit to window", keys: "*"),
            ShortcutRow(title: "Rate (0 clears)", keys: "0–5"),
            ShortcutRow(title: "Tag or untag", keys: "T or `"),
            ShortcutRow(title: "Keep the info overlay up", keys: "I"),
            ShortcutRow(title: "Keep the filmstrip open", keys: "F"),
            ShortcutRow(title: "Play or pause an animation", keys: "P"),
            ShortcutRow(title: "Switch between window and full screen", keys: "Return"),
            ShortcutRow(title: "Back to the browser", keys: "Esc"),
        ]),
        ShortcutSection(title: "Viewer Mouse and Trackpad", rows: [
            ShortcutRow(title: "Fit or actual size at that point", keys: "Click"),
            ShortcutRow(title: "Magnifier", keys: "Press and hold"),
            ShortcutRow(title: "Pan", keys: "Drag"),
            ShortcutRow(title: "Zoom", keys: "Pinch"),
            ShortcutRow(title: "Next image or zoom (Settings › Viewer)", keys: "Scroll"),
            ShortcutRow(title: "Show a panel", keys: "Pointer to an edge"),
        ]),
        ShortcutSection(title: "Compare", rows: [
            ShortcutRow(title: "Choose a pane", keys: "⌘1–⌘4"),
            ShortcutRow(title: "Next or previous pane", keys: "Tab, ⇧Tab"),
            ShortcutRow(title: "Previous or next image in the pane", keys: "← →"),
            ShortcutRow(title: "Rate (0 clears)", keys: "0–5"),
            ShortcutRow(title: "Tag or untag", keys: "T"),
            ShortcutRow(title: "Move to Trash", keys: "⌫"),
            ShortcutRow(title: "Full screen", keys: "Return or F"),
            ShortcutRow(title: "Close", keys: "Esc"),
        ]),
        ShortcutSection(title: "Slideshow", rows: [
            ShortcutRow(title: "Pause or resume", keys: "Space"),
            ShortcutRow(title: "Next slide", keys: "→ ↓ Page Down"),
            ShortcutRow(title: "Previous slide", keys: "← ↑ Page Up"),
            ShortcutRow(title: "End the show", keys: "Esc"),
        ]),
        ShortcutSection(title: "Editing Tools", rows: [
            ShortcutRow(title: "Clone Stamp, Healing Brush: set the source", keys: "⌥-click"),
            ShortcutRow(title: "Clone Stamp, Healing Brush: brush size", keys: "[ ]"),
            ShortcutRow(title: "Text and Shapes: nudge the selection", keys: "Arrows, ⇧ for more"),
            ShortcutRow(title: "Text and Shapes: duplicate", keys: "⌘D"),
            ShortcutRow(title: "Text and Shapes: deselect", keys: "Esc"),
            ShortcutRow(title: "Text and Shapes, Red-Eye: delete the selection", keys: "⌫"),
            ShortcutRow(title: "Capture Selection: capture or cancel", keys: "Return, Esc"),
        ]),
    ]
}
