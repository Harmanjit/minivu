import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
@testable import Minivu

@Suite struct ThumbnailLayoutTests {
    @Test func sizesAndFrames() {
        let layout = ThumbnailLayout(side: 150)
        #expect(layout.itemSize.width == 150 + 2 * ThumbnailLayout.inset)
        #expect(layout.thumbnailArea == CGRect(x: 8, y: 8, width: 150, height: 150))
        #expect(layout.nameFrame.minY == layout.thumbnailArea.maxY + ThumbnailLayout.labelGap)
        #expect(layout.detailFrame.maxY <= layout.itemSize.height)
        // Out-of-range and fractional sizes are clamped and rounded.
        #expect(ThumbnailLayout(side: 10).side == 80)
        #expect(ThumbnailLayout(side: 999).side == 320)
        #expect(ThumbnailLayout(side: 150.4).side == 150)
    }

    @Test func aspectFitCentresOnWholePoints() {
        let area = CGRect(x: 8, y: 8, width: 150, height: 150)
        #expect(ThumbnailLayout.aspectFit(CGSize(width: 6000, height: 4000), in: area)
            == CGRect(x: 8, y: 33, width: 150, height: 100))
        #expect(ThumbnailLayout.aspectFit(CGSize(width: 4000, height: 6000), in: area)
            == CGRect(x: 33, y: 8, width: 100, height: 150))
        #expect(ThumbnailLayout.aspectFit(.zero, in: area) == area)
    }

    @Test func zoomStepsLandOnRoundSizes() {
        #expect(ThumbnailLayout.stepped(150, larger: true) == 160)
        #expect(ThumbnailLayout.stepped(160, larger: true) == 180)
        #expect(ThumbnailLayout.stepped(150, larger: false) == 140)
        #expect(ThumbnailLayout.stepped(140, larger: false) == 120)
        #expect(ThumbnailLayout.stepped(320, larger: true) == 320)
        #expect(ThumbnailLayout.stepped(80, larger: false) == 80)
    }

    @Test func typeSelectAcceptsOnlyPrintableText() {
        #expect(GridCollectionView.isTypeSelectText("a", continuing: false))
        #expect(GridCollectionView.isTypeSelectText("É", continuing: false))
        #expect(!GridCollectionView.isTypeSelectText(" ", continuing: false))
        #expect(GridCollectionView.isTypeSelectText(" ", continuing: true))
        #expect(!GridCollectionView.isTypeSelectText("\r", continuing: true))
        #expect(!GridCollectionView.isTypeSelectText(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                                                    continuing: true))
    }

    @Test func dimensionsText() {
        #expect(ThumbnailCell.dimensions(CGSize(width: 6016, height: 4016)) == "6016 × 4016")
    }
}

@Suite struct PreviewColourTests {
    @Test func sRGBToLinear() {
        let white = PreviewPaneController.linearRGB(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #expect(abs(white.x - 1) < 1e-4)
        let mid = PreviewPaneController.linearRGB(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(abs(mid.y - 0.214) < 0.001)
        let dark = PreviewPaneController.linearRGB(NSColor(srgbRed: 0.02, green: 0, blue: 0, alpha: 1))
        #expect(abs(dark.x - 0.02 / 12.92) < 1e-5)
    }
}

@Suite struct PreviewRefineTests {
    /// The magnifier on a fitted preview whose texture already covers the
    /// canvas needs the full image, not the same screen size again.
    @Test func screenSizeOnlyWhenTheTextureIsTooSmall() {
        #expect(PreviewPaneController.wantsScreenSizedRefine(fitted: true, textureEdge: 500, canvasEdge: 900))
        #expect(!PreviewPaneController.wantsScreenSizedRefine(fitted: true, textureEdge: 900, canvasEdge: 900))
        #expect(!PreviewPaneController.wantsScreenSizedRefine(fitted: true, textureEdge: 880, canvasEdge: 900))
        #expect(!PreviewPaneController.wantsScreenSizedRefine(fitted: false, textureEdge: 500, canvasEdge: 900))
    }
}

@Suite struct PixelSizeTests {
    /// A 30 × 20 JPEG tagged "rotate 90°" is shown 20 wide and 30 tall.
    @Test func readsOrientedSize() throws {
        let t = try ScratchFolder()
        let url = t.url.appendingPathComponent("rotated.jpg")
        let context = try #require(CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        #expect(PixelSizeCache.readPixelSize(of: url) == CGSize(width: 20, height: 30))
        #expect(PixelSizeCache.readPixelSize(of: t.url.appendingPathComponent("missing.jpg")) == nil)
        #expect(PixelSizeCache.readPixelSize(of: try t.file("doc.pdf")) == nil)
    }

    @MainActor @Test func cachesAndDelivers() async throws {
        let t = try ScratchFolder()
        let url = try t.file("broken.jpg", bytes: 10)
        let entry = try #require(FolderEntry(url: url))
        let cache = PixelSizeCache()
        let size: CGSize? = await withCheckedContinuation { done in
            cache.request(entry) { done.resume(returning: $0) }
        }
        #expect(size == nil)
        #expect(cache.cachedSize(for: entry) == nil)
    }
}

@Suite struct SidebarPathTests {
    let root = URL(fileURLWithPath: "/Photos", isDirectory: true)

    @Test func chainFromRootToTarget() {
        let target = URL(fileURLWithPath: "/Photos/Trips/2024/")
        #expect(SidebarPaths.chain(from: root, to: target)?.map(\.path) == ["/Photos", "/Photos/Trips", "/Photos/Trips/2024"])
        #expect(SidebarPaths.chain(from: root, to: root)?.map(\.path) == ["/Photos"])
        #expect(SidebarPaths.chain(from: root, to: URL(fileURLWithPath: "/PhotosOld/x")) == nil)
        #expect(SidebarPaths.chain(from: root, to: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func deepestRootWins() {
        let trips = URL(fileURLWithPath: "/Photos/Trips")
        let other = URL(fileURLWithPath: "/Elsewhere")
        let target = URL(fileURLWithPath: "/Photos/Trips/2024")
        #expect(SidebarPaths.bestRoot(for: target, among: [root, trips, other]) == 1)
        #expect(SidebarPaths.bestRoot(for: URL(fileURLWithPath: "/Photos/Family"), among: [root, trips]) == 0)
        #expect(SidebarPaths.bestRoot(for: URL(fileURLWithPath: "/tmp"), among: [root, trips]) == nil)
    }
}

/// The real sidebar in an offscreen window: revealing a folder deep under a
/// favourite lists and expands each level, then selects the folder's row.
@MainActor @Suite struct SidebarRevealTests {
    @Test func revealsDeepFolder() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        let trips = try t.folder("Trips")
        let year = try t.folder("2024", in: trips)
        let iceland = try t.folder("Iceland", in: year)
        try t.folder("Rejects", in: iceland)
        try t.folder("Family")
        let pictures = try t.folder("Pictures")

        let sidebar = SidebarViewController(picturesFolder: pictures, favoriteFolders: { [t.url] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = sidebar
        window.setContentSize(NSSize(width: 240, height: 360))
        var navigated: [URL] = []
        sidebar.onNavigate = { navigated.append($0) }

        sidebar.reveal(iceland)
        let deadline = ContinuousClock.now + .seconds(5)
        while sidebar.selectedFolder.map({ BrowserModel.samePath($0, iceland) }) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sidebar.selectedFolder.map { BrowserModel.samePath($0, iceland) } == true)
        #expect(navigated.isEmpty, "a reveal must not navigate")

        sidebar.reveal(URL(fileURLWithPath: "/usr/bin"))
        #expect(sidebar.selectedFolder == nil)

        if let directory = ProcessInfo.processInfo.environment["MINIVU_BROWSER_SNAPSHOT_DIR"] {
            sidebar.reveal(iceland)
            try await Task.sleep(for: .milliseconds(300))
            let image = try #require(SnapshotHarness.capture(window))
            _ = SnapshotHarness.write(image, to: URL(fileURLWithPath: directory).appendingPathComponent("browser-sidebar.png"))
        }
    }
}

/// The preview pane's placeholder states, in an offscreen window.
@MainActor @Suite struct PreviewPaneTests {
    @Test func placeholdersForFoldersAndSelections() async throws {
        _ = NSApplication.shared
        let t = try ScratchFolder()
        let folder = try #require(FolderEntry(url: try t.folder("Holiday")))
        let preview = PreviewPaneController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = preview
        window.setContentSize(NSSize(width: 320, height: 640))

        let snapshots = ProcessInfo.processInfo.environment["MINIVU_BROWSER_SNAPSHOT_DIR"]
        let states: [(String, PreviewPaneController.Content)] = [
            ("none", .none), ("folder", .folder(folder)), ("multiple", .multiple(count: 12, bytes: 84_100_000)),
        ]
        for (name, content) in states {
            preview.show(content)
            window.contentView?.layoutSubtreeIfNeeded()
            let texts = allText(in: preview.view)
            switch content {
            case .none: #expect(texts.contains("No Selection"))
            case .folder: #expect(texts.contains("Holiday"))
            default: #expect(texts.contains("12 items selected"))
            }
            if let snapshots {
                try await Task.sleep(for: .milliseconds(300))
                let image = try #require(SnapshotHarness.capture(window))
                _ = SnapshotHarness.write(image, to: URL(fileURLWithPath: snapshots)
                    .appendingPathComponent("browser-preview-\(name).png"))
            }
        }
    }

    /// Visible label strings under `view`.
    func allText(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(allText(in:))
    }
}

@Suite struct SidebarDiffTests {
    func urls(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/Photos/\($0)", isDirectory: true) }
    }

    /// Removing `removed` from `old`, then inserting `new`'s rows at
    /// `inserted`, must give `new`: what the outline view will do.
    func applied(_ diff: SidebarDiff, old: [URL], new: [URL]) -> [String] {
        var rows = old.indices.filter { !diff.removed.contains($0) }.map { old[$0].path }
        for index in diff.inserted { rows.insert(new[index].path, at: index) }
        return rows
    }

    @Test func insertionsAndRemovalsByURL() throws {
        let old = urls("Alpha", "Charlie", "Echo")
        let new = urls("Alpha", "Bravo", "Echo", "Foxtrot")
        let diff = try #require(SidebarDiff.between(old, new))
        #expect(diff.removed == [1])
        #expect(diff.inserted == [1, 3])
        #expect(applied(diff, old: old, new: new) == new.map(\.path))
    }

    @Test func emptyAndUnchangedLists() throws {
        let some = urls("A", "B")
        #expect(SidebarDiff.between(some, some)?.isEmpty == true)
        #expect(SidebarDiff.between([], some) == SidebarDiff(removed: [], inserted: [0, 1]))
        #expect(SidebarDiff.between(some, []) == SidebarDiff(removed: [0, 1], inserted: []))
        // A directory URL with or without its trailing slash is the same folder.
        let bare = [URL(fileURLWithPath: "/Photos/A", isDirectory: false)]
        #expect(SidebarDiff.between(bare, urls("A"))?.isEmpty == true)
    }

    /// Rows both lists keep, in another order, can't be animated as removals
    /// and insertions: the level is reloaded instead.
    @Test func reorderedOrDuplicatedNeedsReload() {
        #expect(SidebarDiff.between(urls("A", "B", "C"), urls("B", "A", "C")) == nil)
        #expect(SidebarDiff.between(urls("A", "A"), urls("A")) == nil)
    }

    @Test func manyEditsApplyCleanly() throws {
        let names = (0..<40).map { String(format: "F%02d", $0) }
        let old = names.enumerated().filter { $0.offset % 3 != 0 }.map { URL(fileURLWithPath: "/P/\($0.element)") }
        let new = names.enumerated().filter { $0.offset % 2 != 0 }.map { URL(fileURLWithPath: "/P/\($0.element)") }
        let diff = try #require(SidebarDiff.between(old, new))
        #expect(applied(diff, old: old, new: new) == new.map(\.path))
    }
}

@Suite struct GridPrefetchTests {
    /// Prefetches within a screenful of the visible items stay; ones the
    /// grid has flown past are cancelled.
    @Test func nearMeansWithinAScreenful() {
        let visible = 100...139   // 40 items on screen
        #expect(GridViewController.isNear(120, visible: visible))
        #expect(GridViewController.isNear(179, visible: visible))
        #expect(GridViewController.isNear(60, visible: visible))
        #expect(!GridViewController.isNear(180, visible: visible))
        #expect(!GridViewController.isNear(59, visible: visible))
    }
}

/// Folders made or deleted in Finder appear in and leave the sidebar
/// without disturbing expanded rows or the selection.
@MainActor @Suite struct SidebarRefreshTests {
    let t: ScratchFolder
    let pictures: ScratchFolder
    let sidebar: SidebarViewController
    let window: NSWindow
    let rootTitle: String

    init() throws {
        _ = NSApplication.shared
        t = try ScratchFolder()
        pictures = try ScratchFolder()
        sidebar = SidebarViewController(picturesFolder: pictures.url, favoriteFolders: { [t] in [t.url] })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = sidebar
        window.setContentSize(NSSize(width: 240, height: 480))
        rootTitle = FileManager.default.displayName(atPath: t.url.path)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func node(_ url: URL) -> SidebarNode? {
        let outline = sidebar.outlineView
        return (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarNode }
            .first { $0.url.map { BrowserModel.samePath($0, url) } ?? false }
    }

    func isSelected(_ url: URL) -> Bool {
        sidebar.selectedFolder.map { BrowserModel.samePath($0, url) } ?? false
    }

    @Test func changesOnDiskKeepExpansionAndSelection() async throws {
        let alpha = try t.folder("Alpha")
        let inner = try t.folder("Inner", in: alpha)
        let charlie = try t.folder("Charlie")
        var navigated: [URL] = []
        sidebar.onNavigate = { navigated.append($0) }

        sidebar.reveal(inner)
        try await waitUntil { isSelected(inner) }
        sidebar.reveal(alpha)
        #expect(isSelected(alpha))
        #expect(sidebar.rowOutline == ["Pictures", rootTitle, "  Alpha", "    Inner", "  Charlie"])
        let alphaNode = try #require(node(alpha))

        try FileManager.default.removeItem(at: charlie)
        try t.folder("Bravo")
        try t.folder("Delta")
        sidebar.folderChangedOnDisk(t.url)
        try await waitUntil { sidebar.rowOutline.contains("  Delta") }

        #expect(sidebar.rowOutline == ["Pictures", rootTitle, "  Alpha", "    Inner", "  Bravo", "  Delta"])
        #expect(node(alpha) === alphaNode, "rows still there keep their objects")
        #expect(sidebar.outlineView.isItemExpanded(alphaNode))
        #expect(isSelected(alpha))
        #expect(navigated.isEmpty, "a refresh must not navigate")
    }

    /// A refresh doesn't reopen a row the user collapsed above the folder.
    @Test func refreshLeavesCollapsedRowsAlone() async throws {
        let alpha = try t.folder("Alpha")
        let inner = try t.folder("Inner", in: alpha)
        sidebar.reveal(inner)
        try await waitUntil { isSelected(inner) }
        let alphaNode = try #require(node(alpha))
        sidebar.outlineView.collapseItem(alphaNode)

        try t.folder("Bravo")
        sidebar.folderChangedOnDisk(t.url)
        try await waitUntil { sidebar.rowOutline.contains("  Bravo") }
        #expect(sidebar.rowOutline == ["Pictures", rootTitle, "  Alpha", "  Bravo"])
        #expect(!sidebar.outlineView.isItemExpanded(alphaNode))
    }

    @Test func expandingAgainListsAgain() async throws {
        let alpha = try t.folder("Alpha")
        let inner = try t.folder("Inner", in: alpha)
        sidebar.reveal(inner)
        try await waitUntil { isSelected(inner) }
        let alphaNode = try #require(node(alpha))

        sidebar.outlineView.collapseItem(alphaNode)
        try t.folder("Second", in: alpha)
        try FileManager.default.removeItem(at: inner)
        sidebar.outlineView.expandItem(alphaNode)
        try await waitUntil { sidebar.rowOutline.contains("    Second") }
        #expect(sidebar.rowOutline == ["Pictures", rootTitle, "  Alpha", "    Second"])
    }

    /// A collapsed row refreshed by its watcher shows the new rows as soon
    /// as it opens, and a folder that gains its first subfolder gets a
    /// disclosure triangle.
    @Test func collapsedRowsAndTriangles() async throws {
        let alpha = try t.folder("Alpha")
        let inner = try t.folder("Inner", in: alpha)
        let echo = try t.folder("Echo")
        sidebar.reveal(inner)
        try await waitUntil { isSelected(inner) }
        let alphaNode = try #require(node(alpha))
        sidebar.outlineView.collapseItem(alphaNode)

        try t.folder("Third", in: alpha)
        sidebar.folderChangedOnDisk(alpha)
        try await waitUntil { alphaNode.children?.count == 2 }
        sidebar.outlineView.expandItem(alphaNode)
        #expect(sidebar.rowOutline == ["Pictures", rootTitle, "  Alpha", "    Inner", "    Third", "  Echo"])

        let echoNode = try #require(node(echo))
        #expect(!sidebar.outlineView.isExpandable(echoNode))
        try t.folder("Sub", in: echo)
        sidebar.folderChangedOnDisk(echo)
        try await waitUntil { sidebar.outlineView.isExpandable(echoNode) }
        #expect(sidebar.outlineView.isExpandable(echoNode))
    }

    /// Going to a folder made after its parent was listed lists the parent
    /// again, once, and selects the new row.
    @Test func revealingANewFolderListsItsParentAgain() async throws {
        let alpha = try t.folder("Alpha")
        sidebar.reveal(alpha)
        try await waitUntil { isSelected(alpha) }

        let late = try t.folder("Late")
        sidebar.reveal(late)
        try await waitUntil { isSelected(late) }
        #expect(isSelected(late))

        // A hidden folder is never found; revealing it must settle, not loop.
        let hidden = try t.folder(".hidden")
        sidebar.reveal(hidden)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sidebar.selectedFolder == nil)
        #expect(!(node(t.url)?.isListing ?? true))
    }
}
