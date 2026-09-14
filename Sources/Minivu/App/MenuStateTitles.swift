import AppKit

/// Titles of the menu items that say what choosing them will do, the way
/// Finder's Show and Hide items do, rather than toggling behind a checkmark.
///
/// Whichever controller answers the command sets the title as it validates
/// the item, in the menu bar and the grid's context menu alike. An item no
/// controller answers is disabled without being asked, so the Image menu
/// puts the first titles back before each validation (`reset(_:)`).
enum MenuStateTitles {
    static func tag(isTagged: Bool) -> String { isTagged ? "Remove Tag" : "Tag" }
    static func playback(isPlaying: Bool) -> String { isPlaying ? "Pause Animation" : "Play Animation" }

    /// Clear Rating, then Rate 1 Star to Rate 5 Stars.
    static func rating(_ stars: Int) -> String {
        switch stars {
        case ...0: "Clear Rating"
        case 1: "Rate 1 Star"
        default: "Rate \(min(stars, 5)) Stars"
        }
    }

    /// The titles an item has when nothing has validated it.
    static func reset(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case .toggleTag: item.showTag(isTagged: false)
            case .togglePlayback: item.showPlayback(isPlaying: false)
            default: break
            }
        }
    }
}

extension NSMenuItem {
    /// Tag, or Remove Tag when the image, or every selected one, is tagged.
    /// The title says it, so there is no checkmark as well.
    func showTag(isTagged: Bool) {
        title = MenuStateTitles.tag(isTagged: isTagged)
        state = .off
    }

    func showPlayback(isPlaying: Bool) {
        title = MenuStateTitles.playback(isPlaying: isPlaying)
    }
}
