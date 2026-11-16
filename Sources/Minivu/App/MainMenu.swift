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
        menu.identifier = .app
        menu.add("About minivu", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        menu.add("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: localized("Services"))
        services.identifier = .services
        menu.add(submenu: services)
        menu.addItem(.separator())
        menu.add("Hide minivu", #selector(NSApplication.hide(_:)), "h")
        menu.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        menu.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add("Quit minivu", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("File", comment: "Menu bar menu")))
        menu.identifier = .file
        menu.add(.init("Open Folder…", comment: "Verb: choose a folder to browse"), .openFolder, "o")
        menu.add("Add Folder to Sidebar…", .addFolderToSidebar, "o", [.command, .shift])
        menu.add("New Folder", .newFolder, "n", [.command, .shift])
        menu.addItem(.separator())
        menu.add(.init("Open in Viewer", comment: "Open the selected image in the viewer window"),
                 .openInViewer, Key.down)
        menu.add("Close Window", #selector(NSWindow.performClose(_:)), "w")
        // The viewer saves the image it edits; the browser converts its
        // selection with Save As. Revert has no shortcut, as in every Mac app.
        menu.add("Save", .saveImage, "s")
        menu.add("Save As…", .saveImageAs, "s", [.command, .shift])
        // The frame of a video on screen, as a picture (G18). Without a
        // shortcut, like Copy Frame: both are occasional commands.
        menu.add(.init("Save Frame As…", comment: "Save the video frame on screen as a picture"), .saveFrameAs)
        menu.add("Revert to Saved", .revertToSaved)
        // The viewer's edits as a Batch Convert preset. No shortcut, like
        // the editing tools: it is an occasional command.
        menu.add("Save Edits as Preset…", .saveEditsAsPreset)
        menu.addItem(.separator())
        // F2 as in Windows Explorer and FastStone: Return opens the viewer
        // here (Finder's Return-to-rename is taken) and ⌘R rotates. A plain
        // function key is safe as a real equivalent: text fields ignore it.
        menu.add(.init("Rename", comment: "Verb: rename the selected file"), .renameItem, Key.f2, [])
        let copyTo = RecentDestinationsMenu.make(title: RecentDestinationsMenu.copyTitle, action: .copyToFolder)
        copyTo.identifier = .copyTo
        menu.add(submenu: copyTo)
        let moveTo = RecentDestinationsMenu.make(title: RecentDestinationsMenu.moveTitle, action: .moveToFolder)
        moveTo.identifier = .moveTo
        menu.add(submenu: moveTo)
        menu.addItem(.separator())
        // Collections and smart folders (G3), without shortcuts: commands
        // for organising, not for every photo.
        menu.add("New Collection…", .newCollection)
        menu.add(submenu: CollectionsMenu.make())
        menu.add("Remove from Collection", .removeFromCollection)
        menu.add("Save as Smart Folder…", .saveAsSmartFolder)
        menu.addItem(.separator())
        menu.add("Reveal in Finder", .revealInFinder, "r", [.command, .option])
        // Finder's place for it, and like Finder's without a shortcut.
        menu.add(.init("Share…", comment: "Verb: share the selected files"), .shareFiles)
        menu.add("Move to Trash", .moveToTrash, Key.backspace)
        menu.addItem(.separator())
        menu.add("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift])
        menu.add("Print…", .printImages, "p")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("Edit", comment: "Menu bar menu")))
        menu.identifier = .edit
        // undo: and redo: are not declared in any Swift-visible class; NSWindow
        // routes them to the first responder's undo manager.
        menu.add("Undo", Selector(("undo:")), "z")
        menu.add("Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        menu.add("Cut", #selector(NSText.cut(_:)), "x")
        menu.add(.init("Copy", comment: "Verb: copy to the clipboard"), #selector(NSText.copy(_:)), "c")
        // ⇧⌘C: free everywhere in minivu (no Colors panel), and beside Copy.
        // The viewer's key table ignores anything with Command.
        menu.add(.init("Copy Text", comment: "Copy the text Live Text found in the image"),
                 .copyText, "c", [.command, .shift])
        // The viewer's picture with its background cut away; nothing else
        // implements it, so it stays disabled in the browser.
        menu.add(.init("Copy Subject", comment: "Copy the image's subject without its background"), .copySubject)
        // A video's frame on screen; ⌘C stays off for a video, whose still
        // is not the video (G18).
        menu.add(.init("Copy Frame", comment: "Copy the video frame on screen as a picture"), .copyFrame)
        menu.add("Paste", #selector(NSText.paste(_:)), "v")
        menu.add("Select All", #selector(NSText.selectAll(_:)), "a")
        menu.add(.init("Select Tagged", comment: "Select the tagged images (minivu's tag is a mark, like a flag)"),
                 .selectTagged)
        menu.add("Invert Selection", .invertSelection, "i", [.command, .shift])
        menu.addItem(.separator())
        // ⌘F as in Finder, Photos and every Mac app; free in minivu (the
        // viewer's bare F is the filmstrip and ignores Command, and full
        // screen and the slideshow have ⌃⌘F and ⇧⌘F).
        menu.add(.init("Find…", comment: "Verb: search for images"), .findImages, "f")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("View", comment: "Menu bar menu")))
        menu.identifier = .view

        let sort = NSMenu(title: localized(.init("Sort By", comment: "Submenu: the order the files are listed in")))
        sort.identifier = .sortBy
        for (index, key) in SortKey.allCases.enumerated() {
            sort.add(title: key.menuTitle, .sortBy).tag = index
        }
        sort.addItem(.separator())
        sort.add(.init("Ascending", comment: "Sort direction"), .toggleSortDirection).tag = SortDirectionTag.ascending
        sort.add(.init("Descending", comment: "Sort direction"), .toggleSortDirection).tag = SortDirectionTag.descending
        menu.add(submenu: sort)

        menu.add("Show Hidden Files", .toggleHiddenFiles, ".", [.command, .shift])
        // ⌥⌘F: F for flat, beside Find's ⌘F; no other ⌥⌘F in minivu.
        menu.add(.init("Flat View", comment: "List the images of every subfolder together"),
                 .toggleFlatView, "f", [.command, .option])
        menu.add(submenu: filterMenu())
        menu.addItem(.separator())

        let theme = NSMenu(title: localized(.init("Theme", comment: "Noun: submenu of colour schemes")))
        theme.identifier = .theme
        for (index, value) in Preferences.Theme.allCases.enumerated() {
            theme.add(title: value.title, #selector(AppDelegate.selectTheme(_:))).tag = index
        }
        menu.add(submenu: theme)
        // Selectable text in the viewer's picture; a checkmark, since it is a
        // setting that outlasts the viewer.
        menu.add(.init("Live Text", comment: "Apple's feature name: use the name Apple uses in this language"),
                 #selector(AppDelegate.toggleLiveText(_:)))
        menu.addItem(.separator())

        // NSSplitViewController and NSWindow retitle these to "Hide Sidebar"
        // and "Exit Full Screen" themselves when they validate them.
        menu.add(.init("Show Sidebar", comment: "AppKit retitles it Hide Sidebar itself"),
                 #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        menu.add("Show Preview Pane", .togglePreviewPane, "p", [.command, .option])
        menu.add(.init("Enter Full Screen", comment: "AppKit retitles it Exit Full Screen itself"),
                 #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func imageMenu(_ viewKeys: DisplayOnlyShortcuts) -> NSMenu {
        let menu = NSMenu(title: localized(.init("Image", comment: "Menu bar menu")))
        menu.identifier = .image
        menu.delegate = viewKeys
        menu.add(.init("Fit to Window", comment: "Zoom: scale the image to fit the window"), .fitToWindow, "9")
        menu.add(.init("Actual Size", comment: "Zoom: show the image at 100%"), .actualSize, "0")
        menu.add("Zoom In", .zoomIn, "=")
        menu.add("Zoom Out", .zoomOut, "-")
        menu.addItem(.separator())
        addEditingItems(to: menu)
        menu.addItem(.separator())
        // A bare P as a real equivalent would be taken from text fields.
        // The item reads Play Video / Pause Video while a video is shown,
        // when Space does the same (G18).
        viewKeys.add(menu.add(title: MenuStateTitles.playback(isPlaying: false), .togglePlayback), key: "p")
        // A bare M, free in the viewer's key table (⇧⌘M is Curves, ⌘M
        // Minimize); display only, as P is.
        viewKeys.add(menu.add(title: MenuStateTitles.mute(isMuted: false), .toggleMute), key: "m")
        menu.addItem(.separator())

        // The grid and viewer also take bare 0-5 and ` (FastStone's keys).
        // Those can't be menu equivalents: the menu would take them from
        // text fields.
        let rating = NSMenu(title: localized(.init("Rating", comment: "Noun: star rating")))
        rating.identifier = .rating
        for stars in 0...5 {
            rating.add(title: MenuStateTitles.rating(stars), .setRating, "\(stars)", [.control]).tag = stars
        }
        menu.add(submenu: rating)
        // ⌘T: no tabs in minivu, and no Fonts panel to show.
        menu.add(title: MenuStateTitles.tag(isTagged: false), .toggleTag, "t")
        // ⌥⌘0 to ⌥⌘7, None then Finder's order of its colour tags. Free in
        // every window: ⌃0–⌃5 rate, ⌘1–⌘4 pick a compare pane, the ⌥⌘
        // letters are taken but no ⌥⌘ digit is, and the system's own ⌥⌘8
        // (Zoom) is past the last.
        menu.add(submenu: ColorLabelCommand.menu(withShortcuts: true))
        menu.addItem(.separator())
        // ⌥⌘K: ⌘K is Crop. ⇧⌘H: ⌘H and ⌥⌘H hide apps.
        menu.add(.init("Compare Selected", comment: "Show the selected images side by side"),
                 .compareSelected, "k", [.command, .option])
        menu.add(.init("Histogram", comment: "Show or hide the histogram panel"),
                 .toggleHistogram, "h", [.command, .shift])
        menu.add("Count Colors", .countColors)
        return menu
    }

    /// Rating and tag filters for the browser; the toolbar's Filter menu
    /// also lists the folder's Finder tags.
    private static func filterMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("Filter", comment: "Noun: submenu that shows only some images")))
        menu.identifier = .filter
        menu.add(title: RatingText.filterTitle(minimum: 0), .filterByRating).tag = 0
        menu.addItem(.separator())
        for minimum in 1...5 {
            menu.add(title: RatingText.filterTitle(minimum: minimum), .filterByRating).tag = minimum
        }
        menu.addItem(.separator())
        menu.add("Tagged Only", .toggleTaggedFilter)
        menu.addItem(.separator())
        for type in [FileTypeFilter.photos, .videos] {
            menu.add(title: type.menuTitle, .filterByFileType).tag = type.rawValue
        }
        menu.addItem(.separator())
        menu.add("More Filters…", .showMoreFilters)
        return menu
    }

    /// Rotate, flip, the edit tools, the comment and the metadata. The
    /// browser rotates, flips, comments and edits the metadata of its
    /// selection losslessly; the viewer does all of it to the image it shows.
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
        menu.add(.init("Canvas Size…", comment: "The size of the canvas around the image"), .changeCanvasSize)
        menu.add(.init("Crop…", comment: "Verb: crop the image"), .cropImage, "k")
        menu.add("Straighten…", .straightenImage)
        menu.add(.init("Perspective…", comment: "Correct the image's perspective"), .correctPerspective)
        menu.addItem(.separator())

        let adjust = NSMenu(title: localized(.init("Adjust", comment: "Submenu of colour and tone adjustments")))
        adjust.identifier = .adjust
        // RAW files only: the RAW engine's settings come before every edit.
        adjust.add("RAW Adjustments…", .adjustRaw)
        adjust.addItem(.separator())
        adjust.add(.init("Lighting…", comment: "Adjustment: exposure, highlights and shadows"),
                   .adjustLighting, "l", [.command, .option])
        adjust.add(.init("Colors…", comment: "Adjustment: saturation, temperature and tint"),
                   .adjustColors, "c", [.command, .option])
        adjust.add("Curves…", .adjustCurves, "m", [.command, .shift])
        adjust.add("Levels…", .adjustLevels, "l", [.command, .shift])
        adjust.add("Auto Enhance", .autoEnhance)
        adjust.addItem(.separator())
        adjust.add("Sharpen…", .sharpenImage)
        adjust.add("Blur…", .blurImage)
        adjust.add("Noise Reduction…", .reduceNoise)
        menu.add(submenu: adjust)

        let effects = NSMenu(title: localized(.init("Effects", comment: "Submenu of image effects")))
        effects.identifier = .effects
        effects.add("Grayscale", .applyGrayscale)
        effects.add("Sepia", .applySepia)
        effects.add(.init("Negative", comment: "Effect: invert the colours"), .applyNegative)
        effects.addItem(.separator())
        effects.add("Drop Shadow…", .addDropShadow)
        effects.add(.init("Frame…", comment: "Effect: a picture frame (border) around the image, not a video frame"),
                    .addFrame)
        effects.add(.init("Bump Map…", comment: "Effect: embossed relief"), .applyBumpMap)
        effects.add(.init("Sketch…", comment: "Effect: pencil drawing"), .applySketch)
        effects.add("Oil Painting…", .applyOilPaint)
        effects.add(.init("Lens…", comment: "Effect: magnifying-lens distortion"), .applyLens)
        effects.add("Vignette…", .addVignette)
        menu.add(submenu: effects)

        let retouch = NSMenu(title: localized(.init("Retouch", comment: "Submenu of retouching tools")))
        retouch.identifier = .retouch
        retouch.add("Clone Stamp…", .cloneStamp)
        retouch.add("Healing Brush…", .healingBrush)
        retouch.add("Red-Eye Removal…", .removeRedEye)
        menu.add(submenu: retouch)
        menu.add(.init("Text and Shapes…", comment: "Draw text, arrows and shapes on the image"), .drawAnnotations)
        menu.add("Watermark…", .addWatermark)
        menu.add("Remove Background…", .removeBackground)
        menu.addItem(.separator())
        menu.add(.init("Edit Comment…", comment: "Edit the image's comment (JPEG/EXIF comment)"), .editComment)
        // ⌘I as Get Info is in Finder and Info in Photos: the image's
        // details. The viewer's bare I (the HUD) ignores Command.
        menu.add("Edit Metadata…", .editMetadata, "i")
    }

    private static func goMenu(_ viewKeys: DisplayOnlyShortcuts) -> NSMenu {
        let menu = NSMenu(title: localized(.init("Go", comment: "Menu bar menu: moving between images and folders")))
        menu.identifier = .go
        menu.delegate = viewKeys
        viewKeys.add(menu.add("Next Image", .nextImage), key: Key.right)
        viewKeys.add(menu.add("Previous Image", .previousImage), key: Key.left)
        viewKeys.add(menu.add("First Image", .firstImage), key: Key.home)
        viewKeys.add(menu.add("Last Image", .lastImage), key: Key.end)
        menu.addItem(.separator())
        // Option-arrows move the insertion point by words in a text field.
        viewKeys.add(menu.add(.init("Next Page", comment: "Next page of a multi-page file (PDF, TIFF)"),
                              .nextPage), key: Key.right, modifiers: .option)
        viewKeys.add(menu.add(.init("Previous Page", comment: "Previous page of a multi-page file (PDF, TIFF)"),
                              .previousPage), key: Key.left, modifiers: .option)
        menu.addItem(.separator())
        menu.add(.init("Enclosing Folder", comment: "Go to the folder that holds this one"),
                 .goToEnclosingFolder, Key.up)
        menu.add(.init("Back", comment: "Go back to the previous folder"), .goBack, "[")
        menu.add(.init("Forward", comment: "Go forward to the next folder"), .goForward, "]")
        return menu
    }

    /// Slideshow, batch work, sheets and wallpaper, capture and external
    /// editors (Phase 7). ⇧⌘F starts a slideshow as in Preview; Batch
    /// Rename is ⇧F2 beside Rename's F2. The system keeps ⇧⌘3 to ⇧⌘5 for
    /// its own screenshots, so Capture has no shortcuts. Export Slideshow
    /// Video and Create Web Gallery, like the other dialogs that make files,
    /// have none.
    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("Tools", comment: "Menu bar menu")))
        menu.identifier = .tools
        menu.add("Start Slideshow", .startSlideshow, "f", [.command, .shift])
        menu.add("Export Slideshow Video…", .exportSlideshowVideo)
        menu.addItem(.separator())
        menu.add("Batch Convert…", .batchConvert, "b", [.command, .option])
        menu.add("Batch Rename…", .batchRename, Key.f2, [.shift])
        // The multi-page tools (G17) have no shortcuts, like Contact Sheet:
        // occasional commands, each opening a sheet.
        menu.add("Extract Pages…", .extractPages)
        // Without a shortcut, as Contact Sheet and Montage are: a tool for
        // a tidy-up now and then, not for every photo.
        menu.add("Find Duplicates…", .findDuplicates)
        menu.addItem(.separator())
        menu.add("Create Multi-Page File…", .createMultiPageFile)
        menu.add(.init("Image Strip…", comment: "Join images into one long strip"), .makeImageStrip)
        menu.add("Contact Sheet…", .makeContactSheet)
        menu.add("Create Web Gallery…", .createWebGallery)
        menu.add(.init("Montage Wallpaper…", comment: "Make a desktop picture from several images"), .makeMontage)
        menu.add("Set as Desktop Picture", .setAsDesktopPicture)
        menu.addItem(.separator())
        let capture = NSMenu(title: localized(.init("Capture", comment: "Noun: submenu of screen captures")))
        capture.identifier = .capture
        capture.add(.init("Entire Screen", comment: "Screen capture of the whole screen"), .captureScreen)
        capture.add(.init("Window…", comment: "Screen capture of one window"), .captureWindow)
        capture.add(.init("Selection…", comment: "Screen capture of a selected area"), .captureSelection)
        menu.add(submenu: capture)
        menu.addItem(.separator())
        menu.add(submenu: ExternalEditorsMenu.make())
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("Window", comment: "Menu bar menu")))
        menu.identifier = .window
        menu.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.add(.init("Zoom", comment: "Window command: zoom the window, not the image"),
                 #selector(NSWindow.performZoom(_:)))
        // FastStone's dual-monitor viewing: the viewer or slideshow goes to
        // the next display, left to right. ⌃⌥⌘ with an arrow is free of the
        // system's window tiling (fn⌃) and Spaces (⌃) shortcuts.
        menu.add(.init("Move to Next Display", comment: "Move the window to the next screen"),
                 .moveToNextDisplay, Key.right, [.control, .option, .command])
        menu.addItem(.separator())
        menu.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: localized(.init("Help", comment: "Menu bar menu")))
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
        case .name: localized(.init("Name", comment: "Sort key"))
        case .modified: localized(.init("Date Modified", comment: "Sort key"))
        case .created: localized(.init("Date Created", comment: "Sort key"))
        case .rating: localized(.init("Rating", comment: "Noun: star rating"))
        case .custom: localized(.init("Custom Order", comment: "Sort key"))
        case .size: localized(.init("Size", comment: "Sort key"))
        case .type: localized(.init("Type", comment: "Sort key"))
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let app = NSUserInterfaceItemIdentifier("minivu.menu.app")
    static let services = NSUserInterfaceItemIdentifier("minivu.menu.services")
    static let file = NSUserInterfaceItemIdentifier("minivu.menu.file")
    static let copyTo = NSUserInterfaceItemIdentifier("minivu.menu.copy-to")
    static let moveTo = NSUserInterfaceItemIdentifier("minivu.menu.move-to")
    static let edit = NSUserInterfaceItemIdentifier("minivu.menu.edit")
    static let view = NSUserInterfaceItemIdentifier("minivu.menu.view")
    static let sortBy = NSUserInterfaceItemIdentifier("minivu.menu.sort-by")
    static let filter = NSUserInterfaceItemIdentifier("minivu.menu.filter")
    static let theme = NSUserInterfaceItemIdentifier("minivu.menu.theme")
    static let image = NSUserInterfaceItemIdentifier("minivu.menu.image")
    static let rating = NSUserInterfaceItemIdentifier("minivu.menu.rating")
    static let adjust = NSUserInterfaceItemIdentifier("minivu.menu.adjust")
    static let effects = NSUserInterfaceItemIdentifier("minivu.menu.effects")
    static let retouch = NSUserInterfaceItemIdentifier("minivu.menu.retouch")
    static let go = NSUserInterfaceItemIdentifier("minivu.menu.go")
    static let tools = NSUserInterfaceItemIdentifier("minivu.menu.tools")
    static let capture = NSUserInterfaceItemIdentifier("minivu.menu.capture")
    static let window = NSUserInterfaceItemIdentifier("minivu.menu.window")
    static let help = NSUserInterfaceItemIdentifier("minivu.menu.help")
}

extension NSMenu {
    /// The submenu (at any depth) with this identifier: menus are found by
    /// identifier, never by their localized titles.
    func submenu(_ id: NSUserInterfaceItemIdentifier) -> NSMenu? {
        for item in items {
            guard let sub = item.submenu else { continue }
            if sub.identifier == id { return sub }
            if let found = sub.submenu(id) { return found }
        }
        return nil
    }
}

private extension NSMenu {
    /// Adds an item with a nil target, titled from Localizable.xcstrings:
    /// `add("Crop…", …)`, or `add(.init("Crop…", comment: "Verb"), …)`
    /// with a hint for translators. Command is the default modifier, as it
    /// is for `NSMenuItem` itself.
    @discardableResult
    func add(_ title: LocalizedStringResource, _ action: Selector?, _ key: String = "",
             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        add(title: localized(title), action, key, modifiers)
    }

    /// The same with a title that is already localized.
    @discardableResult
    func add(title: String, _ action: Selector?, _ key: String = "",
             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }

    /// Adds an item for `submenu`, titled as the submenu is.
    func add(submenu: NSMenu) {
        add(title: submenu.title, nil).submenu = submenu
    }
}
