import AppKit

/// The menu bar and Dock, hidden while a full-screen viewer or a slideshow is
/// the key window, and back whenever neither is.
///
/// One owner for both windows, because each saving and restoring
/// `NSApp.presentationOptions` on its own goes wrong with two of them: a
/// slideshow on one display and a full-screen viewer on another hand the key
/// window back and forth, and whichever saved second saved "hidden" as the
/// state to go back to, leaving the user without a menu bar. Here the options
/// from before the first window hid them are kept until the last one lets go.
///
/// Letting go restores on the next turn of the main queue, not at once. When
/// a slideshow ends over a full-screen viewer, the show lets go and the
/// viewer becomes key a moment later; restoring in between would flash the
/// menu bar and Dock in and out.
final class FullScreenPresentation {
    /// Tests put in one with fake options and put the app's back.
    static var shared = FullScreenPresentation()

    /// The Dock is hidden outright rather than auto-hidden: an auto-hidden
    /// Dock slides up over the viewer's bottom control bar whenever the
    /// pointer reaches for it.
    static let hiding: NSApplication.PresentationOptions = [.autoHideMenuBar, .hideDock]

    private let read: () -> NSApplication.PresentationOptions
    private let write: (NSApplication.PresentationOptions) -> Void
    private var owners: Set<ObjectIdentifier> = []
    /// The options before anything hid them; nil while nothing is hidden.
    private var saved: NSApplication.PresentationOptions?

    init(read: @escaping () -> NSApplication.PresentationOptions = { NSApp.presentationOptions },
         write: @escaping (NSApplication.PresentationOptions) -> Void = { NSApp.presentationOptions = $0 }) {
        self.read = read
        self.write = write
    }

    /// Whether some window is keeping the menu bar and Dock hidden.
    var isHiding: Bool { !owners.isEmpty }

    /// `owner` became key: hide the menu bar and Dock.
    func hide(for owner: AnyObject) {
        owners.insert(ObjectIdentifier(owner))
        if saved == nil { saved = read() }
        if read() != Self.hiding { write(Self.hiding) }
    }

    /// `owner` resigned key, left full screen or closed. Safe to call when it
    /// wasn't hiding anything.
    func release(_ owner: AnyObject) {
        guard owners.remove(ObjectIdentifier(owner)) != nil, owners.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.restoreIfReleased() }
    }

    /// Puts the saved options back if nothing has hidden them again since.
    func restoreIfReleased() {
        guard owners.isEmpty, let saved else { return }
        self.saved = nil
        write(saved)
    }
}
