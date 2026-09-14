import AppKit
import MinivuCore

/// File > Print… in the browser: the selected images, or every image shown
/// when none is selected, laid out on as many sheets as they need.
extension BrowserWindowController {
    @objc func printImages(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let images = toolImages
        guard !images.isEmpty else { return }
        let items = images.map { LayoutItem(entry: $0) }
        PrintPresenter.present(items: items, title: PrintPresenter.jobTitle(for: items), on: window)
    }

    // MARK: - Snapshot harness (debug only)

    #if DEBUG
    /// Debug only, for the snapshot harness
    /// (`MINIVU_ACTIONS=printImages:;debugPrintFourUp:`): sets the open
    /// print panel's layout to four per page, filled, with name and date
    /// captions, without remembering it. No menu item or key sends it.
    @objc func debugPrintFourUp(_ sender: Any?) {
        guard let accessory = PrintPresenter.sessions.last?.accessory else { return }
        accessory.remembers = false
        var settings = accessory.model.settings
        settings.imagesPerPage = 4
        settings.scaling = .fill
        settings.caption = .nameAndDate
        accessory.model.settings = settings
    }

    /// Debug only, for the snapshot harness
    /// (`MINIVU_ACTIONS=debugPageSetupHalfScale:;printImages:`): sets Page
    /// Setup's scale to 50% for this run (the shared print info lives in
    /// memory; nothing is saved), so the panel's preview can be pictured
    /// with a scaled page. No menu item or key sends it.
    @objc func debugPageSetupHalfScale(_ sender: Any?) {
        NSPrintInfo.shared.scalingFactor = 0.5
    }

    /// Debug only, for the snapshot harness
    /// (`MINIVU_ACTIONS=debugRenderPrintPage:`): draws page 1 of what Print
    /// would print for the current images, with the remembered layout, on
    /// Page Setup's paper at 150 dpi, into the PNG named by
    /// `MINIVU_DEBUG_PRINT_PAGE` (default /tmp/minivu-print-page.png).
    /// Decodes on a background queue; no menu item or key sends it.
    @objc func debugRenderPrintPage(_ sender: Any?) {
        let items = toolImages.map { LayoutItem(entry: $0) }
        guard !items.isEmpty else { return }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MINIVU_DEBUG_PRINT_PAGE"]
            ?? "/tmp/minivu-print-page.png")
        let job = PrintJob(items: items, settings: PrintLayoutStore().settings, paper: PrintPaper(printInfo: .shared))
        Task {
            let page = await BlockingWork.run { () -> ImageBox? in
                let size = job.currentLayout.pageSize
                let scale = 150.0 / 72
                guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.scaleBy(x: scale, y: scale)
                job.drawPage(0, in: context)
                return context.makeImage().map(ImageBox.init)
            }
            guard let page else { return }
            FileWriteQueue.shared.enqueue(replacing: [url]) {
                try await BlockingWork.run {
                    try ImageEncoder.write(page.image, to: url, options: .defaults(for: .png), metadataSource: nil)
                }
            }
        }
    }
    #endif
}
