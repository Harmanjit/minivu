import AppKit
import MinivuCore

/// Tools > Contact Sheet… in the browser: a sheet of the selected images,
/// or of every image shown when none is selected.
extension BrowserWindowController {
    @objc func makeContactSheet(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let images = toolImages
        guard !images.isEmpty else { return }
        let folderName = model.folder.map { FileManager.default.displayName(atPath: $0.path) }
        let controller = ContactSheetController(items: images.map { LayoutItem(entry: $0) }, folderName: folderName,
                                                startFolder: model.folder)
        controller.begin(on: window)
    }

    // MARK: - Snapshot harness (debug only)

    /// Debug only, for the snapshot harness
    /// (`MINIVU_ACTIONS=makeContactSheet:;debugWriteContactSheet:`): presses
    /// Save in the open Contact Sheet dialog, writing into the folder named
    /// by `MINIVU_DEBUG_CONTACT_SHEET_FOLDER` (default
    /// /tmp/minivu-contact-sheet) without a panel, through the same export
    /// path as a real save. No menu item or key sends it.
    ///
    /// `debugContactSheetDarkScreen:` before it sets a 4K landscape sheet on
    /// a dark background, pictures filling automatic rows, as a PDF, without
    /// remembering it.
    @objc func debugContactSheetDarkScreen(_ sender: Any?) {
        guard let window, let model = ContactSheetController.controller(for: window)?.model else { return }
        var settings = model.settings
        settings.pageSize = .uhd4K
        settings.orientation = .landscape
        settings.columns = 4
        settings.rows = 0
        settings.scaling = .fill
        settings.caption = .nameAndDimensions
        settings.background = ExportColor(red: 0.08, green: 0.08, blue: 0.09)
        settings.format = .pdf
        model.remembers = false
        model.settings = settings
    }

    @objc func debugWriteContactSheet(_ sender: Any?) {
        guard let window, let controller = ContactSheetController.controller(for: window) else { return }
        let path = ProcessInfo.processInfo.environment["MINIVU_DEBUG_CONTACT_SHEET_FOLDER"] ?? "/tmp/minivu-contact-sheet"
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.debugDestinationFolder = folder
        controller.save()
    }
}
