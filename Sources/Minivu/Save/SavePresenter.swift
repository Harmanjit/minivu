import AppKit
import MinivuCore
import MinivuRender

/// PLACEHOLDER: the Save, Save As and comment UI. The save UI work package
/// replaces this file; the signatures are the contract the viewer and the
/// browser call.
enum SavePresenter {
    /// Save As, as a sheet on `window`: format, quality with a side-by-side
    /// preview and live size estimate, colour profile, metadata. `document`
    /// is nil to re-encode the original pixels. Calls `completion` on the
    /// main actor with the written file, or nil when cancelled or failed
    /// (failures are shown to the user by the presenter). On success the
    /// presenter invalidates thumbnails and textures for the written URL.
    static func presentSaveAs(entry: FolderEntry, document: EditDocument?, on window: NSWindow,
                              completion: @escaping (URL?) -> Void) {
        completion(nil)
    }

    /// Save (⌘S): writes the edited image over its original, in the original's
    /// format with the options last used for that format, after confirming the
    /// overwrite (with "Don't ask again"). Formats minivu can't write (camera
    /// RAW, WebP, JPEG XL, AVIF, PDF, SVG, PSD, animated files) fall back to
    /// Save As. On success calls `document.markSaved()`, invalidates caches and
    /// calls `completion(true)`.
    static func save(entry: FolderEntry, document: EditDocument, on window: NSWindow,
                     completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}

/// PLACEHOLDER: the JPEG comment editor sheet (same work package).
enum CommentEditor {
    /// Edits the COM comment of a JPEG. Calls `completion(true)` after writing.
    static func present(for url: URL, on window: NSWindow, completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}
