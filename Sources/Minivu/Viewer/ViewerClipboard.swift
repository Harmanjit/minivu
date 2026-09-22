import AppKit
import MinivuCore
import MinivuRender

/// Copy for the picture on screen. The Edit menu has had Copy since the
/// beginning, for the text fields; in the viewer, with no text being
/// edited, it belongs to the image the user is looking at.
///
/// Copy hands over the edited pixels, not the file: it renders the page
/// through `renderForExport`, the call Save itself writes from. That is the
/// point of doing it this way round: the viewer is where editing happens,
/// and a Copy that handed over the file behind a picture whose colours the
/// user had just changed would paste the wrong picture, silently.
///
/// What is copied is what the canvas is drawing, an open tool's unapplied
/// change included, because Save applies that change before it writes and
/// the two must not disagree: with the Lighting slider moved, the screen
/// shows the brightened photo and so does the copy. A crop being dragged is
/// the exception that proves it, and needs no special case: the frame is a
/// proposal the canvas draws over the whole picture rather than a change to
/// the pixels, so the copy is the whole picture too.
///
/// For the same reason the file's URL does not go on the pasteboard beside
/// the image. It would be a second, different answer to "what did I just
/// copy?" the moment there are unsaved edits, and Copy must mean one thing
/// every time. Finder gets files from the browser's Copy, which is about
/// files; this one is about a picture.
///
/// There is no Paste: nothing sensible can be pasted onto an image being
/// viewed, and the editing tools own that ground.
extension ViewerWindowController {
    @objc func copy(_ sender: Any?) {
        copyImage(to: .general)
    }

    /// Renders the page on screen and puts it on `pasteboard` as an image.
    /// Returns the work so tests can wait for it; the pasteboard is a
    /// parameter so that nothing but the command itself ever writes to the
    /// person's own clipboard.
    ///
    /// The render takes a decode and a GPU pass, so the pasteboard is
    /// written when the pixels are there rather than reserved first: a
    /// render that fails then leaves whatever was copied before untouched
    /// instead of emptying the clipboard, and beeps rather than going quiet.
    @discardableResult
    func copyImage(to pasteboard: NSPasteboard) -> Task<Void, Never>? {
        // `displayed`, not `current`: the picture on screen is the one to
        // copy, even in the moment a newly chosen image is still decoding.
        guard let shown = displayed, canvas.image != nil else { return nil }
        // The session's document when its edits are this page's, and
        // otherwise a document of this page alone, which renders the file
        // as it stands.
        let open = editSession?.document
        let edited = open?.entry == shown.entry && open?.page == shown.page ? open : nil
        let snapshot = (edited ?? EditDocument(entry: shown.entry, page: shown.page)).shownSnapshot()
        return Task {
            // The colour space a save would render into, so the copy keeps
            // the picture's own colours rather than being flattened to sRGB.
            // An HDR original needs no flag of its own here: its stored
            // space is wide or extended, which this already answers with
            // Display P3, and the render tone maps it to that space's
            // headroom exactly as a save does. Reading the file's header is
            // disk work, so it goes off the main thread with the render.
            let space = await BlockingWork.run {
                // Save As of an edited image asks for exactly this, so a copy
                // and a saved copy are the same picture. A RAW names no
                // stored space worth keeping, so it renders into Display P3
                // as Save As does rather than into whatever the decode gave.
                SavePolicy.renderColorSpace(source: snapshot.kind == .raw ? nil
                                                : SavePolicy.sourceColorSpace(of: snapshot.url),
                                            isHDR: false, preferWideGamut: true)
            }
            guard let image = try? await EditRenderer.shared.renderForExport(snapshot, colorSpace: space,
                                                                            bitsPerComponent: 8) else {
                NSSound.beep()
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(cgImage: image,
                                             size: NSSize(width: image.width, height: image.height))])
        }
    }

    /// Whether the viewer handles `action`, or nil to let the rest of the
    /// chain answer.
    func validateClipboardAction(_ action: Selector?) -> Bool? {
        guard action == #selector(NSText.copy(_:)) else { return nil }
        return displayed != nil && canvas.image != nil
    }
}
