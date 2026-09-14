import AppKit

/// Open in External Editor in the browser: the selected images, or the lead
/// image. Unlike the other Tools it never falls back to every image shown:
/// opening a whole folder in an editor is never what ⌘E meant.
extension BrowserWindowController {
    @objc func openInExternalEditor(_ sender: Any?) {
        var urls = model.selectedEntries.filter { !$0.isDirectory }.map(\.url)
        if urls.isEmpty, let lead = toolLeadImage { urls = [lead.url] }
        ExternalEditorOpener.shared.open(urls, editorIndex: ExternalEditorOpener.editorIndex(sender), window: window)
    }
}
