import AppKit

/// Tools > Montage Wallpaper… in the browser: the selected images, or every
/// image shown when none is selected (at most 200; the sheet says so).
extension BrowserWindowController {
    @objc func makeMontage(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let images = toolImages
        guard !images.isEmpty else { return }
        let fromSelection = model.selectedEntries.contains { !$0.isDirectory }
        let displays = MontageModel.currentDisplays()
        let preferred = window.screen.flatMap { screen in displays.first { $0.displayID == screen.displayID }?.id } ?? 0
        let model = MontageModel(images: images, fromSelection: fromSelection, displays: displays,
                                 preferredDisplay: preferred)
        MontageSheetController(model: model).begin(on: window)
    }
}
