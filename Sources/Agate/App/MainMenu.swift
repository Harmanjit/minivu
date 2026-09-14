import AppKit
import AgateCore

/// The menu bar, built in code (there is no nib).
///
/// Almost every item has a nil target and an `AgateActions` selector, so it
/// goes to whichever controller is active (see AgateActions.swift). The
/// exceptions are the standard AppKit commands (Hide, Undo, Copy, Minimize,
/// which AppKit's own objects handle) and Settings and Theme, which only the
/// app delegate implements.
enum MainMenu {
    /// Builds the menu bar and hands AppKit the menus it manages itself
    /// (Services, Window list, Help search).
    static func install() {
        let bar = make()
        NSApp.mainMenu = bar
        NSApp.servicesMenu = bar.submenu(.services)
        NSApp.windowsMenu = bar.submenu(.window)
        NSApp.helpMenu = bar.submenu(.help)
    }

    static func make() -> NSMenu {
        let bar = NSMenu(title: "Main Menu")
        let viewKeys = DisplayOnlyShortcuts()
        let menus = [appMenu(), fileMenu(), editMenu(), viewMenu(), imageMenu(), goMenu(viewKeys), windowMenu(), helpMenu()]
        for menu in menus {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            // A menu holds its delegate weakly; the item keeps it alive.
            item.representedObject = menu.delegate
            bar.addItem(item)
        }
        return bar
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Agate")
        menu.add("About Agate", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        menu.add("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        services.identifier = .services
        menu.add("Services", nil).submenu = services
        menu.addItem(.separator())
        menu.add("Hide Agate", #selector(NSApplication.hide(_:)), "h")
        menu.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        menu.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add("Quit Agate", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add("Open Folder…", .openFolder, "o")
        menu.add("Add Folder to Sidebar…", .addFolderToSidebar, "o", [.command, .shift])
        menu.addItem(.separator())
        menu.add("Open in Viewer", .openInViewer, Key.down)
        menu.add("Close Window", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        menu.add("Reveal in Finder", .revealInFinder, "r", [.command, .option])
        menu.add("Move to Trash", .moveToTrash, Key.backspace)
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // undo: and redo: are not declared in any Swift-visible class; NSWindow
        // routes them to the first responder's undo manager.
        menu.add("Undo", Selector(("undo:")), "z")
        menu.add("Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        menu.add("Cut", #selector(NSText.cut(_:)), "x")
        menu.add("Copy", #selector(NSText.copy(_:)), "c")
        menu.add("Paste", #selector(NSText.paste(_:)), "v")
        menu.add("Select All", #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")

        let sort = NSMenu(title: "Sort By")
        for (index, key) in SortKey.allCases.enumerated() {
            sort.add(key.menuTitle, .sortBy).tag = index
        }
        sort.addItem(.separator())
        sort.add("Ascending", .toggleSortDirection).tag = SortDirectionTag.ascending
        sort.add("Descending", .toggleSortDirection).tag = SortDirectionTag.descending
        menu.add("Sort By", nil).submenu = sort

        menu.add("Show Hidden Files", .toggleHiddenFiles, ".", [.command, .shift])
        menu.addItem(.separator())

        let theme = NSMenu(title: "Theme")
        for (index, value) in Preferences.Theme.allCases.enumerated() {
            theme.add(value.title, #selector(AppDelegate.selectTheme(_:))).tag = index
        }
        menu.add("Theme", nil).submenu = theme
        menu.addItem(.separator())

        // NSSplitViewController and NSWindow retitle these to "Hide Sidebar"
        // and "Exit Full Screen" themselves when they validate them.
        menu.add("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        menu.add("Show Preview Pane", .togglePreviewPane, "p", [.command, .option])
        menu.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        menu.add("Fit to Window", .fitToWindow, "9")
        menu.add("Actual Size", .actualSize, "0")
        menu.add("Zoom In", .zoomIn, "=")
        menu.add("Zoom Out", .zoomOut, "-")
        menu.addItem(.separator())

        // The viewer also takes bare 0-5 (FastStone's keys). Those can't be
        // menu equivalents: the menu would take digits from text fields.
        let rating = NSMenu(title: "Rating")
        rating.add("Clear Rating", .setRating, "0", [.control]).tag = 0
        for stars in 1...5 {
            rating.add(stars == 1 ? "Rate 1 Star" : "Rate \(stars) Stars", .setRating, "\(stars)", [.control]).tag = stars
        }
        menu.add("Rating", nil).submenu = rating
        return menu
    }

    private static func goMenu(_ viewKeys: DisplayOnlyShortcuts) -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.delegate = viewKeys
        viewKeys.add(menu.add("Next Image", .nextImage), key: Key.right)
        viewKeys.add(menu.add("Previous Image", .previousImage), key: Key.left)
        viewKeys.add(menu.add("First Image", .firstImage), key: Key.home)
        viewKeys.add(menu.add("Last Image", .lastImage), key: Key.end)
        menu.addItem(.separator())
        menu.add("Enclosing Folder", .goToEnclosingFolder, Key.up)
        menu.add("Back", .goBack, "[")
        menu.add("Forward", .goForward, "]")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.identifier = .window
        menu.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.add("Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        menu.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.identifier = .help
        // No action, so AppKit shows it disabled. Help will be bundled pages,
        // never a website (the app has no network access).
        menu.add("Agate Help", nil)
        return menu
    }

    // MARK: - Keys

    /// Non-printing keys, as the characters AppKit uses for them.
    enum Key {
        static let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        static let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        static let home = String(Character(UnicodeScalar(NSHomeFunctionKey)!))
        static let end = String(Character(UnicodeScalar(NSEndFunctionKey)!))
        static let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
    }
}

/// Shows a shortcut beside a menu item without letting the menu take the key.
///
/// Arrows, Home and End mean "move the selection" in the grid, "change
/// image" in the viewer and "move the insertion point" in a text field, and
/// those views handle them in `keyDown`. AppKit offers every key press to
/// the menu bar before the focused view, so a real → equivalent would send
/// `nextImage:` whenever a controller up the chain implements it, and a
/// rename field inside the browser would never see its arrow keys. Instead
/// each item has its equivalent only while its menu is on screen, where it
/// is just a label.
///
/// Tried and rejected: AppKit does not call `menuNeedsUpdate` while
/// searching for a key equivalent (so it can't hide them there), and it
/// searches the items even when `menuHasKeyEquivalent` returns false.
final class DisplayOnlyShortcuts: NSObject, NSMenuDelegate {
    private var shortcuts: [(item: NSMenuItem, key: String)] = []

    func add(_ item: NSMenuItem, key: String) {
        shortcuts.append((item, key))
    }

    /// Called before the menu is drawn; the place AppKit documents for
    /// changing items. Only drawing needs images, so this skips any other
    /// pass that might ask.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.propertiesToUpdate.contains(.propertyItemImage) {
            showShortcuts(true)
        }
    }

    /// Items must not change inside the close callback itself, so the
    /// shortcuts go one turn of the main queue later: long before any key
    /// press can arrive.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { self.showShortcuts(false) }
    }

    func showShortcuts(_ visible: Bool) {
        for (item, key) in shortcuts {
            item.keyEquivalent = visible ? key : ""
            item.keyEquivalentModifierMask = []
        }
    }
}

extension SortKey {
    var menuTitle: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .size: "Size"
        case .type: "Type"
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let services = NSUserInterfaceItemIdentifier("agate.menu.services")
    static let window = NSUserInterfaceItemIdentifier("agate.menu.window")
    static let help = NSUserInterfaceItemIdentifier("agate.menu.help")
}

private extension NSMenu {
    /// Adds an item with a nil target. Command is the default modifier, as
    /// it is for `NSMenuItem` itself.
    @discardableResult
    func add(_ title: String, _ action: Selector?, _ key: String = "",
             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }

    /// The submenu (at any depth) with this identifier.
    func submenu(_ id: NSUserInterfaceItemIdentifier) -> NSMenu? {
        for item in items {
            guard let sub = item.submenu else { continue }
            if sub.identifier == id { return sub }
            if let found = sub.submenu(id) { return found }
        }
        return nil
    }
}
