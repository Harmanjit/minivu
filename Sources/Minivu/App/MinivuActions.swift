import AppKit

/// Every command the menu bar and toolbars send, as responder-chain actions.
///
/// Menu items have a nil target. AppKit then asks the first responder, its
/// superviews, the window, its controller and finally the app delegate, and
/// the first object that implements the selector handles it. So the grid
/// and the viewer each implement the commands that make sense for them, no
/// menu code knows which one is active, and an item nobody implements is
/// greyed out automatically.
///
/// Nothing needs to conform: the protocol exists so `#selector` can name
/// each action once, and the compiler checks the spelling. Conforming does
/// document which commands a controller handles. A handler that shows a
/// checkmark (sort key, direction, hidden files) sets `menuItem.state` in
/// its `validateMenuItem(_:)`.
@objc protocol MinivuActions {
    @objc optional func openFolder(_ sender: Any?)
    @objc optional func addFolderToSidebar(_ sender: Any?)
    @objc optional func revealInFinder(_ sender: Any?)
    @objc optional func moveToTrash(_ sender: Any?)
    @objc optional func openInViewer(_ sender: Any?)
    @objc optional func fitToWindow(_ sender: Any?)
    @objc optional func actualSize(_ sender: Any?)
    @objc optional func zoomIn(_ sender: Any?)
    @objc optional func zoomOut(_ sender: Any?)
    @objc optional func nextImage(_ sender: Any?)
    @objc optional func previousImage(_ sender: Any?)
    @objc optional func firstImage(_ sender: Any?)
    @objc optional func lastImage(_ sender: Any?)
    /// Pages of a PDF or multi-page TIFF; only the viewer has pages.
    @objc optional func nextPage(_ sender: Any?)
    @objc optional func previousPage(_ sender: Any?)
    /// Plays or pauses an animated image in the viewer.
    @objc optional func togglePlayback(_ sender: Any?)
    @objc optional func goToEnclosingFolder(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    /// The sender's `tag` is the index of the key in `SortKey.allCases`.
    @objc optional func sortBy(_ sender: Any?)
    /// Sender tag `SortDirectionTag.ascending` or `.descending` picks that
    /// direction; any other sender (a toolbar button) flips it.
    @objc optional func toggleSortDirection(_ sender: Any?)
    @objc optional func toggleHiddenFiles(_ sender: Any?)
    @objc optional func togglePreviewPane(_ sender: Any?)
    @objc optional func toggleFullScreenViewer(_ sender: Any?)
    @objc optional func exitViewer(_ sender: Any?)
    /// The sender's `tag` is the rating, 0 (none) to 5 stars.
    @objc optional func setRating(_ sender: Any?)

    // MARK: Editing (Phase 4)
    // The viewer implements these for the image it shows; the browser
    // implements the lossless ones (rotate, flip, comment) for its selection.
    @objc optional func saveImage(_ sender: Any?)
    @objc optional func saveImageAs(_ sender: Any?)
    @objc optional func revertToSaved(_ sender: Any?)
    @objc optional func rotateLeft(_ sender: Any?)
    @objc optional func rotateRight(_ sender: Any?)
    @objc optional func flipHorizontal(_ sender: Any?)
    @objc optional func flipVertical(_ sender: Any?)
    @objc optional func resizeImage(_ sender: Any?)
    @objc optional func cropImage(_ sender: Any?)
    @objc optional func straightenImage(_ sender: Any?)
    @objc optional func adjustLighting(_ sender: Any?)
    @objc optional func adjustColors(_ sender: Any?)
    @objc optional func adjustCurves(_ sender: Any?)
    @objc optional func adjustLevels(_ sender: Any?)
    @objc optional func sharpenImage(_ sender: Any?)
    @objc optional func blurImage(_ sender: Any?)
    @objc optional func applyGrayscale(_ sender: Any?)
    @objc optional func applySepia(_ sender: Any?)
    @objc optional func applyNegative(_ sender: Any?)
    @objc optional func editComment(_ sender: Any?)
}

/// Tags on the View > Sort By direction items. Zero is left out on purpose:
/// it is every control's default tag, so it means "no direction given".
enum SortDirectionTag {
    static let ascending = 1
    static let descending = 2
}

extension Selector {
    static let openFolder = #selector(MinivuActions.openFolder(_:))
    static let addFolderToSidebar = #selector(MinivuActions.addFolderToSidebar(_:))
    static let revealInFinder = #selector(MinivuActions.revealInFinder(_:))
    static let moveToTrash = #selector(MinivuActions.moveToTrash(_:))
    static let openInViewer = #selector(MinivuActions.openInViewer(_:))
    static let fitToWindow = #selector(MinivuActions.fitToWindow(_:))
    static let actualSize = #selector(MinivuActions.actualSize(_:))
    static let zoomIn = #selector(MinivuActions.zoomIn(_:))
    static let zoomOut = #selector(MinivuActions.zoomOut(_:))
    static let nextImage = #selector(MinivuActions.nextImage(_:))
    static let previousImage = #selector(MinivuActions.previousImage(_:))
    static let firstImage = #selector(MinivuActions.firstImage(_:))
    static let lastImage = #selector(MinivuActions.lastImage(_:))
    static let nextPage = #selector(MinivuActions.nextPage(_:))
    static let previousPage = #selector(MinivuActions.previousPage(_:))
    static let togglePlayback = #selector(MinivuActions.togglePlayback(_:))
    static let goToEnclosingFolder = #selector(MinivuActions.goToEnclosingFolder(_:))
    static let goBack = #selector(MinivuActions.goBack(_:))
    static let goForward = #selector(MinivuActions.goForward(_:))
    static let sortBy = #selector(MinivuActions.sortBy(_:))
    static let toggleSortDirection = #selector(MinivuActions.toggleSortDirection(_:))
    static let toggleHiddenFiles = #selector(MinivuActions.toggleHiddenFiles(_:))
    static let togglePreviewPane = #selector(MinivuActions.togglePreviewPane(_:))
    static let toggleFullScreenViewer = #selector(MinivuActions.toggleFullScreenViewer(_:))
    static let exitViewer = #selector(MinivuActions.exitViewer(_:))
    static let setRating = #selector(MinivuActions.setRating(_:))
    static let saveImage = #selector(MinivuActions.saveImage(_:))
    static let saveImageAs = #selector(MinivuActions.saveImageAs(_:))
    static let revertToSaved = #selector(MinivuActions.revertToSaved(_:))
    static let rotateLeft = #selector(MinivuActions.rotateLeft(_:))
    static let rotateRight = #selector(MinivuActions.rotateRight(_:))
    static let flipHorizontal = #selector(MinivuActions.flipHorizontal(_:))
    static let flipVertical = #selector(MinivuActions.flipVertical(_:))
    static let resizeImage = #selector(MinivuActions.resizeImage(_:))
    static let cropImage = #selector(MinivuActions.cropImage(_:))
    static let straightenImage = #selector(MinivuActions.straightenImage(_:))
    static let adjustLighting = #selector(MinivuActions.adjustLighting(_:))
    static let adjustColors = #selector(MinivuActions.adjustColors(_:))
    static let adjustCurves = #selector(MinivuActions.adjustCurves(_:))
    static let adjustLevels = #selector(MinivuActions.adjustLevels(_:))
    static let sharpenImage = #selector(MinivuActions.sharpenImage(_:))
    static let blurImage = #selector(MinivuActions.blurImage(_:))
    static let applyGrayscale = #selector(MinivuActions.applyGrayscale(_:))
    static let applySepia = #selector(MinivuActions.applySepia(_:))
    static let applyNegative = #selector(MinivuActions.applyNegative(_:))
    static let editComment = #selector(MinivuActions.editComment(_:))
}
