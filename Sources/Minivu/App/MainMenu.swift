import AppKit
import MinivuCore

/// The menu bar, built in code (there is no nib).
///
/// Almost every item has a nil target and an `MinivuActions` selector, so it
/// goes to whichever controller is active (see MinivuActions.swift). The
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
        // One per menu: each shows only its own shortcuts while it is open.
        let imageKeys = DisplayOnlyShortcuts(), goKeys = DisplayOnlyShortcuts()
        let menus = [appMenu(), fileMenu(), editMenu(), viewMenu(), imageMenu(imageKeys), goMenu(goKeys),
                     toolsMenu(), windowMenu(), helpMenu()]
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
        let menu = NSMenu(title: "minivu")
        menu.add("About minivu", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        menu.add("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        services.identifier = .services
        menu.add("Services", nil).submenu = services
        menu.addItem(.separator())
        menu.add("Hide minivu", #selector(NSApplication.hide(_:)), "h")
        menu.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        menu.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add("Quit minivu", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add("Open Folder…", .openFolder, "o")
        menu.add("Add Folder to Sidebar…", .addFolderToSidebar, "o", [.command, .shift])
        menu.add("New Folder", .newFolder, "n", [.command, .shift])
        menu.addItem(.separator())
        menu.add("Open in Viewer", .openInViewer, Key.down)
        menu.add("Close Window", #selector(NSWindow.performClose(_:)), "w")
        // The viewer saves the image it edits; the browser converts its
        // selection with Save As. Revert has no shortcut, as in every Mac app.
        menu.add("Save", .saveImage, "s")
        menu.add("Save As…", .saveImageAs, "s", [.command, .shift])
        menu.add("Revert to Saved", .revertToSaved)
        menu.addItem(.separator())
        // F2 as in Windows Explorer and FastStone: Return opens the viewer
        // here (Finder's Return-to-rename is taken) and ⌘R rotates. A plain
        // function key is safe as a real equivalent: text fields ignore it.
        menu.add("Rename", .renameItem, Key.f2, [])
        menu.add("Copy To", nil).submenu = RecentDestinationsMenu.make(title: "Copy To", action: .copyToFolder)
        menu.add("Move To", nil).submenu = RecentDestinationsMenu.make(title: "Move To", action: .moveToFolder)
        menu.addItem(.separator())
        menu.add("Reveal in Finder", .revealInFinder, "r", [.command, .option])
        menu.add("Move to Trash", .moveToTrash, Key.backspace)
        menu.addItem(.separator())
        menu.add("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift])
        menu.add("Print…", .printImages, "p")
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
        menu.add("Select Tagged", .selectTagged)
        menu.add("Invert Selection", .invertSelection, "i", [.command, .shift])
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
        menu.add("Filter", nil).submenu = filterMenu()
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

    private static func imageMenu(_ viewKeys: DisplayOnlyShortcuts) -> NSMenu {
        let menu = NSMenu(title: "Image")
        menu.delegate = viewKeys
        menu.add("Fit to Window", .fitToWindow, "9")
        menu.add("Actual Size", .actualSize, "0")
        menu.add("Zoom In", .zoomIn, "=")
        menu.add("Zoom Out", .zoomOut, "-")
        menu.addItem(.separator())
        addEditingItems(to: menu)
        menu.addItem(.separator())
        // A bare P as a real equivalent would be taken from text fields.
        viewKeys.add(menu.add(MenuStateTitles.playback(isPlaying: false), .togglePlayback), key: "p")
        menu.addItem(.separator())

        // The grid and viewer also take bare 0-5 and ` (FastStone's keys).
        // Those can't be menu equivalents: the menu would take them from
        // text fields.
        let rating = NSMenu(title: "Rating")
        for stars in 0...5 {
            rating.add(MenuStateTitles.rating(stars), .setRating, "\(stars)", [.control]).tag = stars
        }
        menu.add("Rating", nil).submenu = rating
        // ⌘T: no tabs in minivu, and no Fonts panel to show.
        menu.add(MenuStateTitles.tag(isTagged: false), .toggleTag, "t")
        menu.addItem(.separator())
        // ⌥⌘K: ⌘K is Crop. ⇧⌘H: ⌘H and ⌥⌘H hide apps.
        menu.add("Compare Selected", .compareSelected, "k", [.command, .option])
        menu.add("Histogram", .toggleHistogram, "h", [.command, .shift])
        menu.add("Count Colors", .countColors)
        return menu
    }

    /// Rating and tag filters for the browser; the toolbar's Filter menu
    /// also lists the folder's Finder tags.
    private static func filterMenu() -> NSMenu {
        let menu = NSMenu(title: "Filter")
        menu.add(RatingText.filterTitle(minimum: 0), .filterByRating).tag = 0
        menu.addItem(.separator())
        for minimum in 1...5 {
            menu.add(RatingText.filterTitle(minimum: minimum), .filterByRating).tag = minimum
        }
        menu.addItem(.separator())
        menu.add("Tagged Only", .toggleTaggedFilter)
        return menu
    }

    /// Rotate, flip, the edit tools and the comment. The browser rotates,
    /// flips and comments its selection losslessly; the viewer does all of
    /// it to the image it shows.
    ///
    /// Shortcuts follow Preview where it has one (⌘L, ⌘R, ⌘K Crop, ⌥⌘C
    /// Adjust Color) and Photoshop's letters otherwise (Image Size ⌥⌘I,
    /// Levels L and Curves M, with Shift because ⌘L rotates and ⌘M
    /// minimizes). The full table is in DESIGN.md, section 5.
    private static func addEditingItems(to menu: NSMenu) {
        menu.add("Rotate Left", .rotateLeft, "l")
        menu.add("Rotate Right", .rotateRight, "r")
        menu.add("Flip Horizontal", .flipHorizontal)
        menu.add("Flip Vertical", .flipVertical)
        menu.addItem(.separator())
        menu.add("Resize/Resample…", .resizeImage, "i", [.command, .option])
        menu.add("Crop…", .cropImage, "k")
        menu.add("Straighten…", .straightenImage)
        menu.addItem(.separator())

        let adjust = NSMenu(title: "Adjust")
        adjust.add("Lighting…", .adjustLighting, "l", [.command, .option])
        adjust.add("Colors…", .adjustColors, "c", [.command, .option])
        adjust.add("Curves…", .adjustCurves, "m", [.command, .shift])
        adjust.add("Levels…", .adjustLevels, "l", [.command, .shift])
        adjust.addItem(.separator())
        adjust.add("Sharpen…", .sharpenImage)
        adjust.add("Blur…", .blurImage)
        menu.add("Adjust", nil).submenu = adjust

        let effects = NSMenu(title: "Effects")
        effects.add("Grayscale", .applyGrayscale)
        effects.add("Sepia", .applySepia)
        effects.add("Negative", .applyNegative)
        effects.addItem(.separator())
        effects.add("Drop Shadow…", .addDropShadow)
        effects.add("Frame…", .addFrame)
        effects.add("Bump Map…", .applyBumpMap)
        effects.add("Sketch…", .applySketch)
        effects.add("Oil Painting…", .applyOilPaint)
        effects.add("Lens…", .applyLens)
        menu.add("Effects", nil).submenu = effects

        let retouch = NSMenu(title: "Retouch")
        retouch.add("Clone Stamp…", .cloneStamp)
        retouch.add("Healing Brush…", .healingBrush)
        retouch.add("Red-Eye Removal…", .removeRedEye)
        menu.add("Retouch", nil).submenu = retouch
        menu.add("Text and Shapes…", .drawAnnotations)
        menu.addItem(.separator())
        menu.add("Edit Comment…", .editComment)
    }

    private static func goMenu(_ viewKeys: DisplayOnlyShortcuts) -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.delegate = viewKeys
        viewKeys.add(menu.add("Next Image", .nextImage), key: Key.right)
        viewKeys.add(menu.add("Previous Image", .previousImage), key: Key.left)
        viewKeys.add(menu.add("First Image", .firstImage), key: Key.home)
        viewKeys.add(menu.add("Last Image", .lastImage), key: Key.end)
        menu.addItem(.separator())
        // Option-arrows move the insertion point by words in a text field.
        viewKeys.add(menu.add("Next Page", .nextPage), key: Key.right, modifiers: .option)
        viewKeys.add(menu.add("Previous Page", .previousPage), key: Key.left, modifiers: .option)
        menu.addItem(.separator())
        menu.add("Enclosing Folder", .goToEnclosingFolder, Key.up)
        menu.add("Back", .goBack, "[")
        menu.add("Forward", .goForward, "]")
        return menu
    }

    /// Slideshow, batch work, sheets and wallpaper, capture and external
    /// editors (Phase 7). ⇧⌘F starts a slideshow as in Preview; Batch
    /// Rename is ⇧F2 beside Rename's F2. The system keeps ⇧⌘3 to ⇧⌘5 for
    /// its own screenshots, so Capture has no shortcuts.
    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        menu.add("Start Slideshow", .startSlideshow, "f", [.command, .shift])
        menu.addItem(.separator())
        menu.add("Batch Convert…", .batchConvert, "b", [.command, .option])
        menu.add("Batch Rename…", .batchRename, Key.f2, [.shift])
        menu.addItem(.separator())
        menu.add("Contact Sheet…", .makeContactSheet)
        menu.add("Montage Wallpaper…", .makeMontage)
        menu.add("Set as Desktop Picture", .setAsDesktopPicture)
        menu.addItem(.separator())
        let capture = NSMenu(title: "Capture")
        capture.add("Entire Screen", .captureScreen)
        capture.add("Window…", .captureWindow)
        capture.add("Selection…", .captureSelection)
        menu.add("Capture", nil).submenu = capture
        menu.addItem(.separator())
        let editors = ExternalEditorsMenu.make()
        menu.add(editors.title, nil).submenu = editors
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.identifier = .window
        menu.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.add("Zoom", #selector(NSWindow.performZoom(_:)))
        // FastStone's dual-monitor viewing: the viewer or slideshow goes to
        // the next display, left to right. ⌃⌥⌘ with an arrow is free of the
        // system's window tiling (fn⌃) and Spaces (⌃) shortcuts.
        menu.add("Move to Next Display", .moveToNextDisplay, Key.right, [.control, .option, .command])
        menu.addItem(.separator())
        menu.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.identifier = .help
        // Bundled pages in a window of minivu's own, never a website (the app
        // has no network access) and no Help Book. ⌘? is every Mac app's Help
        // item; ⌘/ is free everywhere in minivu (the viewer's bare / is
        // Actual Size, and it ignores Command).
        menu.add("minivu Help", #selector(AppDelegate.showMinivuHelp(_:)), "?")
        menu.add("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)), "/")
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
        static let f2 = String(Character(UnicodeScalar(NSF2FunctionKey)!))
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
/// is just a label. The viewer's P (play/pause) and Option-arrows (pages) are
/// shown the same way: a menu equivalent would take them from text fields.
///
/// Tried and rejected: AppKit does not call `menuNeedsUpdate` while
/// searching for a key equivalent (so it can't hide them there), and it
/// searches the items even when `menuHasKeyEquivalent` returns false.
final class DisplayOnlyShortcuts: NSObject, NSMenuDelegate {
    private var shortcuts: [(item: NSMenuItem, key: String, modifiers: NSEvent.ModifierFlags)] = []

    func add(_ item: NSMenuItem, key: String, modifiers: NSEvent.ModifierFlags = []) {
        shortcuts.append((item, key, modifiers))
        item.keyEquivalentModifierMask = []
    }

    /// Called before the menu is drawn; the place AppKit documents for
    /// changing items. Only drawing needs images, so this skips any other
    /// pass that might ask. It comes before validation, which gives the
    /// stateful titles back to the items a controller answers.
    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuStateTitles.reset(menu)
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
        for (item, key, modifiers) in shortcuts {
            item.keyEquivalent = visible ? key : ""
            item.keyEquivalentModifierMask = visible ? modifiers : []
        }
    }
}

extension SortKey {
    var menuTitle: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .rating: "Rating"
        case .custom: "Custom Order"
        case .size: "Size"
        case .type: "Type"
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let services = NSUserInterfaceItemIdentifier("minivu.menu.services")
    static let window = NSUserInterfaceItemIdentifier("minivu.menu.window")
    static let help = NSUserInterfaceItemIdentifier("minivu.menu.help")
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
