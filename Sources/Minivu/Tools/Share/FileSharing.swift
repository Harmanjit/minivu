import AppKit

/// Shows the system's share sheet for files. `NSSharingServicePicker` in
/// the app; tests pass a fake, so no test ever opens AirDrop, Messages or
/// Mail.
protocol SharePresenting: AnyObject {
    /// Offers `urls` to the share services, from a popover pointing at
    /// `rect` in `view`.
    func share(_ urls: [URL], relativeTo rect: NSRect, of view: NSView)
}

/// The system's share sheet. Each service (AirDrop, Messages, Mail, Notes…)
/// runs in its own process and reads the files through the sandbox
/// extension the picker hands it; minivu sends nothing over a network
/// itself and needs no entitlement for it.
final class SharingServicePresenter: SharePresenting {
    func share(_ urls: [URL], relativeTo rect: NSRect, of view: NSView) {
        let picker = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
}

/// File > Share…, for the browser's selection and the viewer's image: the
/// question to ask first, then the share sheet.
///
/// Files are shared as they are on disk, which is what every share service
/// takes. With unsaved edits in the viewer that is the file as last saved,
/// and the user is told so first and can stop, exactly as Open in External
/// Editor tells them: sharing a rendered copy instead would mean writing a
/// file under a name, format and quality nobody chose, somewhere the
/// sandbox lets the service read, for as long as an AirDrop or a Mail draft
/// might take, and the picture shared would then exist nowhere the user can
/// see it. Saving first and sharing the saved file does the same with
/// choices they made.
@MainActor final class FileSharing {
    static let shared = FileSharing()

    var presenter: SharePresenting = SharingServicePresenter()
    /// Asks a yes-or-no question as a sheet on `window` (or an alert when
    /// there is none). A hook so tests can answer without an alert.
    var confirm: (_ question: ExternalEditorOpener.Question, _ window: NSWindow?,
                  _ answer: @escaping (Bool) -> Void) -> Void = { question, window, answer in
        ExternalEditorOpener.ask(question, on: window, answer: answer)
    }

    /// The question asked before sharing an image with unsaved edits.
    static func unsavedEditsQuestion(name: String) -> ExternalEditorOpener.Question {
        ExternalEditorOpener.Question(message: "“\(name)” has edits that aren’t saved.",
                                      detail: "The file is shared as it was last saved, without the edits made here. "
                                          + "To share the edits, save them first.",
                                      confirmTitle: "Share Saved File")
    }

    /// Shares `urls` from a popover pointing at `rect` in `view`.
    /// `unsavedEditsIn` names the image when the viewer has edits the file
    /// doesn't.
    func share(_ urls: [URL], from view: NSView, rect: NSRect, unsavedEditsIn name: String? = nil) {
        guard !urls.isEmpty else { return }
        guard let name else { return presenter.share(urls, relativeTo: rect, of: view) }
        confirm(Self.unsavedEditsQuestion(name: name), view.window) { [weak self, weak view] yes in
            guard yes else { return }
            // After the alert's sheet has gone, so the popover isn't
            // anchored to a window that is still dismissing a sheet.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let view, view.window != nil else { return }
                    self.presenter.share(urls, relativeTo: rect, of: view)
                }
            }
        }
    }
}
