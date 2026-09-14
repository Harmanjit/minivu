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

    /// One step at a time, wrapping only when allowed. Offsets beyond one
    /// (not sent today) clamp at the ends rather than wrapping twice.
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
        return true
    }

    /// A jump (Home, End, a filmstrip click). The direction follows the jump,
    /// so prefetch looks the way the user is travelling.
    @discardableResult
    mutating func move(to target: Int) -> Bool {
        guard images.indices.contains(target), target != index else { return false }
        direction = target > index ? .forward : .backward
        index = target
        return true
    }

    /// Shows another folder listing (the browser called `show` again).
    mutating func replace(images: [FolderEntry], index: Int) {
        self = ViewerModel(images: images, index: index, wrapAround: wrapAround)
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
        }
        index = images.isEmpty ? 0 : min(index, images.count - 1)
        return !images.isEmpty
    }
}

/// What a key press means in the viewer. Kept apart from the window so the
/// keyboard map (DESIGN.md 5) is a table that tests can read.
nonisolated enum ViewerKeyCommand: Equatable {
    case next, previous, first, last
    /// Move the image by a tenth of the view per step: x and y are -1, 0 or
    /// +1 in the direction the user wants to look (right arrow: see more of
    /// the right side).
    case pan(x: Int, y: Int)
    case toggleFullScreen, close
    case zoomIn, zoomOut, actualSize, fit
    case toggleHUD, toggleFilmstrip

    /// The fraction of the view one arrow press pans.
    static let panFraction: CGFloat = 0.1

    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers` of the key event.
    ///   - modifiers: Command, Control or Option make it a shortcut for
    ///     someone else (the menu), so those return nil.
    ///   - zoomedIn: the image overflows the view, so arrows pan it.
    static func command(characters: String, modifiers: NSEvent.ModifierFlags, zoomedIn: Bool) -> ViewerKeyCommand? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty,
              let scalar = characters.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey: return zoomedIn ? .pan(x: 1, y: 0) : .next
        case NSLeftArrowFunctionKey: return zoomedIn ? .pan(x: -1, y: 0) : .previous
        case NSDownArrowFunctionKey: return zoomedIn ? .pan(x: 0, y: 1) : .next
        case NSUpArrowFunctionKey: return zoomedIn ? .pan(x: 0, y: -1) : .previous
        case NSPageDownFunctionKey: return .next
        case NSPageUpFunctionKey: return .previous
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
        // 0-5 will set ratings (a later phase); nothing else is ours.
        default: return nil
        }
    }
}
