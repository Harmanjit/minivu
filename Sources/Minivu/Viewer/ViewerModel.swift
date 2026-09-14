import AppKit
import MinivuCore

/// Which image the viewer shows, and where it goes next.
///
/// Plain values and no AppKit, so every rule about moving through a folder
/// (wrap-around, what to prefetch, what happens after a delete) is unit
/// tested. The window controller owns one and turns its answers into loads.
/// `nonisolated` because it is plain data that needs no main actor.
nonisolated struct ViewerModel: Equatable {
    enum Direction: Equatable {
        case forward, backward
    }

    private(set) var images: [FolderEntry]
    private(set) var index: Int
    /// Loop from the last image to the first and back. The controller copies
    /// `Preferences.shared.wrapAround` in before moving, so a change in
    /// Settings applies to the next key press.
    var wrapAround: Bool
    /// The way the user last moved. Flipping forward usually continues
    /// forward, so prefetch spends its decodes ahead rather than behind.
    private(set) var direction: Direction = .forward
    /// The page of the current image on screen, from 0. Every image starts
    /// on its first page.
    private(set) var page = 0
    /// Pages in the current image: 1 until its header has been read (the
    /// controller does that off the main thread and reports it with
    /// `setPageCount`), and for everything that isn't a PDF or multi-page TIFF.
    private(set) var pageCount = 1

    init(images: [FolderEntry], index: Int, wrapAround: Bool = false) {
        self.images = images
        self.index = images.isEmpty ? 0 : min(max(index, 0), images.count - 1)
        self.wrapAround = wrapAround
    }

    var count: Int { images.count }
    var current: FolderEntry? { images.indices.contains(index) ? images[index] : nil }

    /// "3 / 120" for the HUD.
    var positionText: String { images.isEmpty ? "" : "\(index + 1) / \(count)" }
    /// "3 of 120" for the window subtitle.
    var subtitleText: String { images.isEmpty ? "" : "\(index + 1) of \(count)" }

    // MARK: - Moving

    var canGoNext: Bool { count > 1 && (wrapAround || index < count - 1) }
    var canGoPrevious: Bool { count > 1 && (wrapAround || index > 0) }

    /// Each returns whether the image changed, so the caller loads only then.
    @discardableResult mutating func next() -> Bool { move(by: 1) }
    @discardableResult mutating func previous() -> Bool { move(by: -1) }
    @discardableResult mutating func first() -> Bool { move(to: 0) }
    @discardableResult mutating func last() -> Bool { move(to: count - 1) }

    /// Moves by `offset` (the keys and the wheel send ±1). Past either end it
    /// wraps round when allowed and stops at the end otherwise.
    @discardableResult
    mutating func move(by offset: Int) -> Bool {
        guard offset != 0, !images.isEmpty else { return false }
        var target = index + offset
        if wrapAround {
            target = ((target % count) + count) % count
        } else {
            target = min(max(target, 0), count - 1)
        }
        guard target != index else { return false }
        index = target
        direction = offset > 0 ? .forward : .backward
        resetPages()
        return true
    }

    /// A jump (Home, End, a filmstrip click). The direction follows the jump,
    /// so prefetch looks the way the user is travelling.
    @discardableResult
    mutating func move(to target: Int) -> Bool {
        guard images.indices.contains(target), target != index else { return false }
        direction = target > index ? .forward : .backward
        index = target
        resetPages()
        return true
    }

    /// Shows another folder listing (the browser called `show` again).
    mutating func replace(images: [FolderEntry], index: Int) {
        self = ViewerModel(images: images, index: index, wrapAround: wrapAround)
    }

    // MARK: - Pages

    var isMultiPage: Bool { pageCount > 1 }
    var canGoNextPage: Bool { page < pageCount - 1 }
    var canGoPreviousPage: Bool { page > 0 }

    /// "2 / 10" for the control bar; empty for single-page images.
    var pageText: String { isMultiPage ? "\(page + 1) / \(pageCount)" : "" }
    /// "Page 2 of 10" for the HUD; nil for single-page images.
    var pageHUDText: String? { isMultiPage ? "Page \(page + 1) of \(pageCount)" : nil }

    /// The header of `entry` has been read. Ignored when the viewer has
    /// moved on to another image in the meantime.
    mutating func setPageCount(_ count: Int, for entry: FolderEntry) {
        guard current == entry else { return }
        pageCount = max(count, 1)
        page = min(page, pageCount - 1)
    }

    /// Option-arrows: the pages of this image only. Return whether the
    /// page changed.
    @discardableResult
    mutating func nextPage() -> Bool {
        guard canGoNextPage else { return false }
        page += 1
        return true
    }

    @discardableResult
    mutating func previousPage() -> Bool {
        guard canGoPreviousPage else { return false }
        page -= 1
        return true
    }

    /// What Page Down or Page Up did.
    enum PageStep: Equatable {
        case page, image, none
    }

    /// Page Down, as FastStone does it: the next page while there is one,
    /// then the next image.
    mutating func pageForward() -> PageStep {
        if nextPage() { return .page }
        return next() ? .image : .none
    }

    /// Page Up: the previous page, then the previous image (which opens on
    /// its first page; how many pages it has isn't known until it's read).
    mutating func pageBackward() -> PageStep {
        if previousPage() { return .page }
        return previous() ? .image : .none
    }

    private mutating func resetPages() {
        page = 0
        pageCount = 1
    }

    // MARK: - Prefetch

    /// Neighbours worth decoding now, nearest first: two ahead and one
    /// behind in the direction of travel. Out-of-range neighbours wrap when
    /// wrap-around is on and are dropped otherwise; the current image and
    /// duplicates (tiny folders, where +1 and -1 meet) are left out.
    var prefetchList: [FolderEntry] {
        guard count > 1 else { return [] }
        let steps = direction == .forward ? [1, 2, -1] : [-1, -2, 1]
        var seen: Set<Int> = [index]
        var result: [FolderEntry] = []
        for step in steps {
            var target = index + step
            if wrapAround {
                target = ((target % count) + count) % count
            } else if !images.indices.contains(target) {
                continue
            }
            if seen.insert(target).inserted { result.append(images[target]) }
        }
        return result
    }

    /// Everything worth decoding now, as (image, page): the current
    /// document's next page first (the likeliest next key press in a
    /// document), then the neighbouring images' first pages.
    var prefetchPages: [(entry: FolderEntry, page: Int)] {
        var result: [(entry: FolderEntry, page: Int)] = []
        if let current, canGoNextPage { result.append((current, page + 1)) }
        return result + prefetchList.map { ($0, 0) }
    }

    // MARK: - Removing

    /// Takes `entry` out of the list (it was moved to the Trash). When it was
    /// the image on screen, the next one takes its place, or the previous one
    /// if it was last. Returns false when nothing is left, so the viewer
    /// closes.
    @discardableResult
    mutating func remove(_ entry: FolderEntry) -> Bool {
        guard let removed = images.firstIndex(where: { $0.url == entry.url }) else { return !images.isEmpty }
        images.remove(at: removed)
        if removed < index {
            index -= 1   // an earlier image went; stay on the same one
        } else if removed == index {
            resetPages()   // another image takes its place
        }
        index = images.isEmpty ? 0 : min(index, images.count - 1)
        return !images.isEmpty
    }
}

/// What a key press means in the viewer. Kept apart from the window so the
/// keyboard map (DESIGN.md 5) is a table that tests can read.
nonisolated enum ViewerKeyCommand: Equatable {
    case next, previous, first, last
    /// Option-arrows and Option-Page Down/Up: pages of this document only.
    case nextPage, previousPage
    /// Page Down/Up: pages first, then images (see `ViewerModel.pageForward`).
    case pageForward, pageBackward
    /// P: play or pause an animation.
    case togglePlayback
    /// Move the image by a tenth of the view per step: x and y are -1, 0 or
    /// +1 in the direction the user wants to look (right arrow: see more of
    /// the right side).
    case pan(x: Int, y: Int)
    case toggleFullScreen, close
    case zoomIn, zoomOut, actualSize, fit
    case toggleHUD, toggleFilmstrip
    /// 0 to 5: the image's star rating (0 clears it).
    case rating(Int)
    /// T or ` (backquote): tag or untag the image, FastStone's culling mark.
    case toggleTag

    /// The fraction of the view one arrow press pans.
    static let panFraction: CGFloat = 0.1

    /// Whether a held key repeats the command. Flipping, panning and zooming
    /// do; a held Return would swap windows back and forth, and a held F or
    /// I make their panel flicker.
    var repeats: Bool {
        switch self {
        case .next, .previous, .pan, .zoomIn, .zoomOut, .nextPage, .previousPage, .pageForward, .pageBackward: true
        default: false
        }
    }

    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers` of the key event.
    ///   - modifiers: Command or Control make it a shortcut for someone else
    ///     (the menu), so those return nil. Option is the viewer's own only
    ///     with the arrows and paging keys, where it means pages.
    ///   - zoomedIn: the image overflows the view, so arrows pan it.
    static func command(characters: String, modifiers: NSEvent.ModifierFlags, zoomedIn: Bool) -> ViewerKeyCommand? {
        let shortcut = modifiers.intersection([.command, .control, .option])
        guard shortcut.isEmpty || shortcut == .option, let scalar = characters.unicodeScalars.first else { return nil }
        if shortcut == .option {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey, NSPageDownFunctionKey: return .nextPage
            case NSLeftArrowFunctionKey, NSPageUpFunctionKey: return .previousPage
            default: return nil
            }
        }
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey: return zoomedIn ? .pan(x: 1, y: 0) : .next
        case NSLeftArrowFunctionKey: return zoomedIn ? .pan(x: -1, y: 0) : .previous
        case NSDownArrowFunctionKey: return zoomedIn ? .pan(x: 0, y: 1) : .next
        case NSUpArrowFunctionKey: return zoomedIn ? .pan(x: 0, y: -1) : .previous
        case NSPageDownFunctionKey: return .pageForward
        case NSPageUpFunctionKey: return .pageBackward
        case NSHomeFunctionKey: return .first
        case NSEndFunctionKey: return .last
        // The Mac's Delete key sends DEL; some keyboards send backspace.
        case NSDeleteCharacter, NSBackspaceCharacter: return .previous
        case NSCarriageReturnCharacter, NSEnterCharacter: return .toggleFullScreen
        case 0x1B: return .close   // Esc
        default: break
        }
        switch characters.lowercased() {
        case " ": return .next
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        case "/": return .actualSize
        case "*": return .fit
        case "i": return .toggleHUD
        case "f": return .toggleFilmstrip
        case "p": return .togglePlayback
        case "0", "1", "2", "3", "4", "5": return .rating(Int(characters)!)
        case "t", "`": return .toggleTag
        default: return nil
        }
    }
}
