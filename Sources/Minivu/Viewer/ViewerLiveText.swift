import AppKit
import MinivuCore
import MinivuRender

/// Live Text in the viewer (LiveText.swift): the overlay over the canvas,
/// what it is told about the picture, and Edit > Copy Text.
extension ViewerWindowController {
    func setUpLiveText() {
        liveText.canvas = canvas
        liveText.pictureRect = { [weak self] in
            guard let self, let image = self.canvas.image else { return nil }
            return self.canvas.viewRect(forImageRect: CGRect(origin: .zero, size: image.imageSize))
        }
        canvas.onTextOverlayViewChange = { [weak self] in self?.liveText.viewChanged() }
        container.textOverlay = liveText.host
    }

    /// The picture on the canvas: the page shown, with the edit drawn over
    /// it when the session's edits are this page's (an open tool's
    /// unapplied change included, as Copy takes it), and the frame of a
    /// paused animation.
    var liveTextSubject: LiveTextController.Subject? {
        guard let shown = displayed, canvas.image != nil else { return nil }
        let open = editSession?.document
        let edited = open?.entry == shown.entry && open?.page == shown.page ? open : nil
        return LiveTextController.Subject(url: shown.entry.url, modified: shown.entry.modified, page: shown.page,
                                          operations: edited?.shownSnapshot().operations ?? [],
                                          frame: player.map(\.currentFrame))
    }

    /// Live Text is offered while it is on, no edit tool is open (the tool
    /// owns the pointer, and its picture changes with every slider step)
    /// and no animation plays (the text would move under the pointer).
    /// Runs with every chrome update, so it compares and returns.
    func updateLiveTextAvailability() {
        liveText.setActive(Preferences.shared.liveText && !isClosing && activeTool == nil
                           && player?.isPlaying != true)
    }

    /// Edit > Copy Text (⇧⌘C): all the text recognised in the picture.
    @objc func copyText(_ sender: Any?) {
        copyText(to: .general)
    }

    /// Puts the picture's text on `pasteboard` as a string, analysing the
    /// picture first if that hasn't been done. Returns the work so tests
    /// can wait for it; the pasteboard is a parameter so that nothing but
    /// the command itself ever writes to the person's own clipboard.
    ///
    /// Written only when there is text, as Copy writes only when its render
    /// worked: a picture with no text in it leaves whatever was copied
    /// before, and beeps rather than going quiet. A copy the user moved on
    /// from (another picture before the text was read) ends without a word:
    /// a beep would say the picture had no text, which nobody found out.
    @discardableResult
    func copyText(to pasteboard: NSPasteboard) -> Task<Void, Never>? {
        guard validateLiveTextAction(.copyText) == true else { return nil }
        return Task {
            switch await liveText.recognisedText() {
            case .text(let text) where !text.isEmpty:
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            case .cancelled:
                break
            case .text, .failed:
                Self.noTextToCopy()
            }
        }
    }

    /// Whether `windowPoint` is over the picture's canvas and nothing in
    /// front of it (a panel, the control bar, the filmstrip): only there
    /// does a pointer movement ask Live Text to read the picture.
    func isOverCanvas(windowPoint: CGPoint) -> Bool {
        guard let contentView = window?.contentView, let superview = contentView.superview,
              canvas.bounds.contains(canvas.convert(windowPoint, from: nil)) else { return false }
        let hit = contentView.hitTest(superview.convert(windowPoint, from: nil))
        return hit === canvas || hit?.isDescendant(of: liveText.host) == true
    }

    /// Copy Text found nothing to copy. A hook so tests can tell without a
    /// beep sounding.
    static var noTextToCopy: () -> Void = { NSSound.beep() }

    /// Whether the viewer handles `action`, or nil to let the rest of the
    /// chain answer.
    func validateLiveTextAction(_ action: Selector?) -> Bool? {
        guard action == .copyText else { return nil }
        return liveText.isActive && liveText.analyzer.isSupported && displayed != nil && canvas.image != nil
    }
}
