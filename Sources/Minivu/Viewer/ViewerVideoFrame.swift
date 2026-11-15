import AppKit
import MinivuCore

/// A video's frame as a picture (G18): Edit > Copy Frame puts it on the
/// clipboard, File > Save Frame As… writes it through Save As.
///
/// The frame is the one on screen: where the player stands when there is
/// one (playing or paused), else the first frame, which is the still the
/// viewer shows before anything plays. It is taken from the file at the
/// video's own size, not from the screen, so a 4K clip gives a 4K picture
/// whatever the window's size; and in standard range, as Copy and Save As
/// give every picture, since the formats and the apps it is pasted into are
/// SDR.
///
/// Copy (⌘C) stays off for a video, as it was: its still is not the video,
/// and a command named for the frame says what the user gets.
extension ViewerWindowController {
    /// Seconds into the video of the frame on screen.
    var shownVideoFrameTime: Double {
        guard let time = videoPlayback?.player.currentTime(), time.isNumeric else { return 0 }
        return max(time.seconds, 0)
    }

    @objc func copyFrame(_ sender: Any?) {
        copyVideoFrame(to: .general)
    }

    /// Takes the frame on screen and puts it on `pasteboard`. Returns the
    /// work so tests can wait for it; the pasteboard is a parameter so that
    /// nothing but the command itself ever writes to the person's own
    /// clipboard. As with Copy, the pasteboard is written only once the
    /// pixels are there, so a frame that can't be decoded leaves the
    /// clipboard as it was and beeps.
    @discardableResult
    func copyVideoFrame(to pasteboard: NSPasteboard) -> Task<Void, Never>? {
        guard canTakeVideoFrame, let entry = model.current else { return nil }
        let url = entry.url, seconds = shownVideoFrameTime
        return Task {
            guard let image = await BlockingWork.run({ VideoFrames.still(of: url, at: seconds) }) else {
                NSSound.beep()
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        }
    }

    @objc func saveFrameAs(_ sender: Any?) {
        guard canTakeVideoFrame, let entry = model.current, let window, window.attachedSheet == nil else { return }
        // Paused, so the frame being saved is the one the user is looking at
        // while the panel is up.
        pauseVideo()
        Self.presentSaveFrameAs(entry, shownVideoFrameTime, window) { [weak self] _ in self?.updateChrome() }
    }

    /// Shows Save As for a frame; a hook so tests can record it instead of
    /// a panel.
    static var presentSaveFrameAs: (_ entry: FolderEntry, _ seconds: Double, _ window: NSWindow,
                                    _ completion: @escaping (URL?) -> Void) -> Void = { entry, seconds, window, completion in
        SavePresenter.presentSaveFrameAs(entry: entry, seconds: seconds, on: window, completion: completion)
    }

    /// A video is shown and minivu could show it.
    private var canTakeVideoFrame: Bool {
        isShowingVideo && displayed == current && canvas.image != nil && errorLabel.isHidden && !isClosing
    }

    /// Copy Frame and Save Frame As; nil for any other command.
    func validateVideoFrameAction(_ action: Selector?) -> Bool? {
        switch action {
        case .copyFrame: canTakeVideoFrame
        case .saveFrameAs: canTakeVideoFrame && window?.attachedSheet == nil
        default: nil
        }
    }
}
