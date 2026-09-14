import AppKit
import Combine
import MinivuCore

extension NSToolbarItem.Identifier {
    static let browserNavigation = NSToolbarItem.Identifier("minivu.browser.navigation")
    static let browserEnclosingFolder = NSToolbarItem.Identifier("minivu.browser.enclosing")
    static let browserSort = NSToolbarItem.Identifier("minivu.browser.sort")
    static let browserThumbnailSize = NSToolbarItem.Identifier("minivu.browser.size")
    static let browserPreviewPane = NSToolbarItem.Identifier("minivu.browser.preview")
    static let browserSearch = NSToolbarItem.Identifier("minivu.browser.search")
}

/// The browser window's unified toolbar.
///
/// Buttons send the same responder-chain actions as the menu bar, so the
/// window controller handles and validates both in one place.
final class BrowserToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    /// The search text changed.
    var onSearch: ((String) -> Void)?

    private(set) weak var searchItem: NSSearchToolbarItem?
    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private let slider = NSSlider(value: Preferences.shared.thumbnailSize,
                                  minValue: ThumbnailLayout.sizeRange.lowerBound,
                                  maxValue: ThumbnailLayout.sizeRange.upperBound, target: nil, action: nil)
    private var sizeSubscription: AnyCancellable?

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "minivu.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    /// Empties the search field (when a file is opened from Finder, it must
    /// not be hidden by an old search).
    func clearSearch() {
        searchItem?.searchField.stringValue = ""
    }

    func setNavigation(canGoBack: Bool, canGoForward: Bool) {
        if backItem?.isEnabled != canGoBack { backItem?.isEnabled = canGoBack }
        if forwardItem?.isEnabled != canGoForward { forwardItem?.isEnabled = canGoForward }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .browserNavigation, .browserEnclosingFolder, .flexibleSpace,
         .browserThumbnailSize, .browserSort, .browserPreviewPane, .browserSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .browserNavigation: navigationItem()
        case .browserEnclosingFolder:
            navigational(button(identifier, "Enclosing Folder", symbol: "arrow.up", action: .goToEnclosingFolder,
                                tip: "Show the enclosing folder"))
        case .browserSort: sortItem()
        case .browserThumbnailSize: sizeItem()
        case .browserPreviewPane:
            button(identifier, "Preview", symbol: "sidebar.right", action: .togglePreviewPane,
                   tip: "Show or hide the preview pane")
        case .browserSearch: searchItemMade()
        default: nil
        }
    }

    // MARK: - Items

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, symbol: String, action: Selector,
                        tip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.action = action
        return item
    }

    private func navigational(_ item: NSToolbarItem) -> NSToolbarItem {
        item.isNavigational = true
        return item
    }

    /// Back and Forward, drawn as one segmented control. Each half is an
    /// ordinary item with a responder-chain action. A group doesn't validate
    /// its halves, so `setNavigation` enables them when the history changes.
    ///
    /// Not a subclass made with `NSToolbarItemGroup`'s convenience
    /// initialiser: that factory allocates a plain group whatever class it is
    /// called on, so a subclass's stored properties would write past the end
    /// of the object.
    private func navigationItem() -> NSToolbarItem {
        let back = button(.init("minivu.browser.back"), "Back", symbol: "chevron.left", action: .goBack,
                          tip: "See folders you viewed previously")
        let forward = button(.init("minivu.browser.forward"), "Forward", symbol: "chevron.right", action: .goForward,
                             tip: "See folders you viewed next")
        for item in [back, forward] {
            item.autovalidates = false
            item.isEnabled = false
        }
        backItem = back
        forwardItem = forward
        let group = NSToolbarItemGroup(itemIdentifier: .browserNavigation)
        group.subitems = [back, forward]
        group.label = "Back/Forward"
        group.selectionMode = .momentary
        group.controlRepresentation = .expanded
        // Placed before the title, where Finder and Safari put them.
        group.isNavigational = true
        return group
    }

    /// The View > Sort By choices. Items have no target, so the window
    /// controller validates them and they show the same checkmarks.
    private func sortItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .browserSort)
        item.label = "Sort"
        item.toolTip = "Sort by"
        item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        item.showsIndicator = true
        let menu = NSMenu(title: "Sort By")
        for (index, key) in SortKey.allCases.enumerated() {
            menu.addItem(withTitle: key.menuTitle, action: .sortBy, keyEquivalent: "").tag = index
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ascending", action: .toggleSortDirection, keyEquivalent: "").tag = SortDirectionTag.ascending
        menu.addItem(withTitle: "Descending", action: .toggleSortDirection, keyEquivalent: "").tag = SortDirectionTag.descending
        item.menu = menu
        return item
    }

    private func sizeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .browserThumbnailSize)
        item.label = "Thumbnail Size"
        item.toolTip = "Thumbnail size"
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        item.view = slider
        // Follows ⌘= / ⌘- and Settings as well as its own drags.
        sizeSubscription = Preferences.shared.$thumbnailSize
            .removeDuplicates()
            .sink { [weak self] size in self?.slider.doubleValue = size }
        return item
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        // Whole points: fractional sizes would give blurry, uneven cells.
        let size = sender.doubleValue.rounded()
        if size != Preferences.shared.thumbnailSize { Preferences.shared.thumbnailSize = size }
    }

    private func searchItemMade() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .browserSearch)
        item.searchField.placeholderString = "Filter by Name"
        item.searchField.delegate = self
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.preferredWidthForSearchField = 180
        searchItem = item
        return item
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearch?(sender.stringValue)
    }
}
