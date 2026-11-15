import AppKit
import MinivuCore
import MinivuRender

/// Subjects in the viewer (G8): Remove Background, an inspector that cuts
/// the picture's subject out of its background, and Copy Subject, which puts
/// the subject alone on the clipboard.
///
/// Both ask Vision for the subject of the picture as it is on screen, on a
/// small rendering of it, once: the mask is kept on the document for that
/// picture and stored in the operation, so no render ever asks again.
extension ViewerWindowController {
    // MARK: - Remove Background

    /// Opens the tool at once, with the search for the subject under way;
    /// the cut-out shows as soon as Vision has found it.
    @objc func removeBackground(_ sender: Any?) { openRemoveBackground() }

    /// `then` runs with the tool's state as it opens (tests wait on it).
    func openRemoveBackground(then: ((RemoveBackgroundToolState) -> Void)? = nil) {
        if case .custom(let open as RemoveBackgroundToolState)? = activeTool {
            then?(open)
            return
        }
        guard let session = beginOpeningTool(replacing: true) else { return }
        let document = session.document
        let state = RemoveBackgroundToolState(document: document)
        presentTool(state, inspector: RemoveBackgroundInspectorView(state: state, actions: inspectorActions()))
        then?(state)
        let operations = document.operations
        // The state and session weakly: a tool closed (or a viewer closed)
        // meanwhile lets them go at once, and a late answer goes nowhere.
        Task { [weak self, weak state, weak session] in
            let mask = try? await EditRenderer.shared.subjectMask(for: document, operations: operations)
            guard let self, let state, let session, self.editSession === session,
                  document.operations == operations else { return }
            state.useMask(mask)
        }
    }

    // MARK: - Copy Subject

    @objc func copySubject(_ sender: Any?) {
        copySubject(to: .general)
    }

    /// Finds the subject of the picture on screen and puts it on
    /// `pasteboard`, cut out (transparent around it) and cropped to it, as
    /// PNG and TIFF. As Copy does, it renders what the canvas shows, an open
    /// tool's change included, through `renderForExport`, and writes the
    /// pasteboard only when the pixels are there: a picture with no subject,
    /// or a render that fails, beeps and leaves the clipboard as it was.
    /// The pasteboard is a parameter so that only the command itself ever
    /// writes to the person's own clipboard; returns the work for tests.
    @discardableResult
    func copySubject(to pasteboard: NSPasteboard) -> Task<Void, Never>? {
        guard let shown = displayed, canvas.image != nil, copySubjectTask == nil else { return nil }
        let open = editSession?.document
        let edited = open?.entry == shown.entry && open?.page == shown.page ? open : nil
        let document = edited ?? EditDocument(entry: shown.entry, page: shown.page)
        let operations = document.shownSnapshot().operations
        let task = Task { [weak self] in
            defer {
                self?.copySubjectTask = nil
                self?.updateChrome()
            }
            guard let mask = try? await EditRenderer.shared.subjectMask(for: document, operations: operations) else {
                NSSound.beep()
                return
            }
            // Taken after the search, so it holds the original the search
            // decoded; the picture must still be the one searched.
            let snapshot = document.shownSnapshot()
            guard snapshot.operations == operations else {
                NSSound.beep()
                return
            }
            let lifted = snapshot.appending([.removeBackground(RemoveBackground(mask: mask)), .crop(mask.bounds)])
            // Into the colour space Copy uses, for the same reasons.
            let space = await BlockingWork.run {
                SavePolicy.renderColorSpace(source: snapshot.kind == .raw ? nil
                                                : SavePolicy.sourceColorSpace(of: snapshot.url),
                                            isHDR: false, preferWideGamut: true)
            }
            guard let image = try? await EditRenderer.shared.renderForExport(lifted, colorSpace: space,
                                                                            bitsPerComponent: 8),
                  let item = Self.pasteboardItem(for: image) else {
                NSSound.beep()
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
        copySubjectTask = task
        updateChrome()
        return task
    }

    /// The image as PNG, which every app reads with its transparency, and
    /// TIFF, which older ones look for first.
    static func pasteboardItem(for image: CGImage) -> NSPasteboardItem? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return item
    }

    // MARK: - Snapshot harness (debug only)

    #if DEBUG
    /// Debug only, for the snapshot harness (`MINIVU_ACTIONS=debugEditRemoveBackground:`):
    /// Remove Background on a white background. No menu item or key sends it.
    @objc func debugEditRemoveBackground(_ sender: Any?) {
        openRemoveBackground { state in state.setColor(.white) }
    }
    #endif
}
