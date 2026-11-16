import AppKit

/// Titles of the menu items that say what choosing them will do, the way
/// Finder's Show and Hide items do, rather than toggling behind a checkmark.
///
/// Whichever controller answers the command sets the title as it validates
/// the item, in the menu bar and the grid's context menu alike. An item no
/// controller answers is disabled without being asked, so the Image menu
/// puts the first titles back before each validation (`reset(_:)`).
enum MenuStateTitles {
    static func tag(isTagged: Bool) -> String {
        isTagged ? localized(.init("Remove Tag", comment: "Menu command: remove minivu's tag (a mark, like a flag)"))
            : localized(.init("Tag", comment: "Verb: menu command that tags the image (marks it, like a flag)"))
    }
    static func playback(isPlaying: Bool) -> String {
        isPlaying ? localized("Pause Animation") : localized("Play Animation")
    }
    /// The same item while the viewer shows a video (G18).
    static func videoPlayback(isPlaying: Bool) -> String {
        isPlaying ? localized("Pause Video") : localized("Play Video")
    }
    static func mute(isMuted: Bool) -> String { isMuted ? localized("Unmute Video") : localized("Mute Video") }

    /// Clear Rating, then Rate 1 Star to Rate 5 Stars.
    static func rating(_ stars: Int) -> String {
        stars <= 0 ? localized(.init("Clear Rating", comment: "Menu command: remove the image's star rating"))
            : localized(.init("Rate \(min(stars, 5)) Stars", comment: "Menu command: give the image this many stars"))
    }

    /// The titles an item has when nothing has validated it.
    static func reset(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case .toggleTag: item.showTag(isTagged: false)
            case .togglePlayback: item.showPlayback(isPlaying: false)
            case .toggleMute: item.title = mute(isMuted: false)
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
