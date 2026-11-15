import AppKit
import MinivuCore
import MinivuRender

/// File > Save Edits as Preset… in the viewer (G6): the image's edits as a
/// named Batch Convert preset, so the same adjustments can be applied to a
/// whole selection. The sheet shows which steps travel and which stay
/// behind (`BatchEdits`).
extension ViewerWindowController {
    /// Enabled while the image on screen has edits, committed or in an open
    /// tool, and no sheet is up.
    func validateBatchPresetAction(_ action: Selector?) -> Bool? {
        guard action == .saveEditsAsPreset else { return nil }
        guard canEditCurrent, window?.attachedSheet == nil, let session = editSession else { return false }
        return !session.document.operations.isEmpty || activeTool?.hasPendingChanges == true
    }

    /// An open tool's change is applied first, as Save As applies it: the
    /// preset is made of what the photo shows.
    @objc func saveEditsAsPreset(_ sender: Any?) {
        guard validateBatchPresetAction(.saveEditsAsPreset) == true, let window, let session = editSession else {
            return NSSound.beep()
        }
        closeTool(applying: true)
        let operations = session.document.operations
        guard !operations.isEmpty else { return NSSound.beep() }
        let model = EditsPresetModel(operations: operations,
                                     suggestedName: EditsPresetModel.suggestedName(for: session.document.entry.url),
                                     store: BatchTools.store)
        Self.presentEditsPreset(model, window)
    }

    /// Shows the sheet; a hook so tests can take the model instead.
    static var presentEditsPreset: (_ model: EditsPresetModel, _ window: NSWindow) -> Void = { model, window in
        EditsPresetSheet(model: model).begin(on: window)
    }
}
