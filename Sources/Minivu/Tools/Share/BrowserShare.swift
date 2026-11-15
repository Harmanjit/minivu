import AppKit

/// File > Share… and the toolbar's Share button in the browser: the
/// selected images, or the lead image. Like Open in External Editor it
/// never falls back to every image shown, and folders are left out: an
/// AirDrop of a whole folder is a Finder job.
extension BrowserWindowController {
    var shareURLs: [URL] {
        var urls = model.selectedEntries.filter { !$0.isDirectory }.map(\.url)
        if urls.isEmpty, let lead = toolLeadImage { urls = [lead.url] }
        return urls
    }

    @objc func shareFiles(_ sender: Any?) {
        let urls = shareURLs
        guard !urls.isEmpty else { return }
        let (view, rect) = shareAnchor
        FileSharing.shared.share(urls, from: view, rect: rect)
    }

    /// Where the share sheet points: the lead cell when it is on screen,
    /// otherwise the top of the grid's visible part.
    var shareAnchor: (view: NSView, rect: NSRect) {
        let collection = grid.collectionView
        let visible = collection.visibleRect
        if let frame = grid.leadFrame(), frame.intersects(visible) {
            return (collection, frame.intersection(visible))
        }
        return (collection, NSRect(x: visible.midX, y: visible.minY, width: 1, height: 1))
    }
}
