import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// The assembled window, never shown: model changes reach the grid, title
/// and menus, and the grid's selection reaches the model.
@MainActor @Suite struct BrowserWindowTests {
    /// Waits for the folder listing and one turn of the main queue.
    func settle(_ controller: BrowserWindowController) async {
        await controller.model.work?.value
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        return item
    }

    @Test func folderFlowsThroughTheWindow() async throws {
        _ = NSApplication.shared
        let savedLastFolder = UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey)
        defer { UserDefaults.standard.set(savedLastFolder, forKey: AppDelegate.lastFolderKey) }

        // Empty files: listed by extension, and never decoded into any cache.
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        try t.file("a.jpg"); let b = try t.file("b.jpg"); try t.file("c.jpg")
        let controller = BrowserWindowController()
        let window = try #require(controller.window)
        let grid = controller.grid
        _ = grid.view

        controller.open(folder: t.url)
        await settle(controller)
        #expect(window.title == t.url.lastPathComponent)
        #expect(window.subtitle == "3 images, 1 folder")
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 4)
        #expect(UserDefaults.standard.string(forKey: AppDelegate.lastFolderKey) == controller.model.folder?.path)

        // Model to view.
        controller.model.select(b)
        #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0)])
        #expect(controller.validateMenuItem(item(.moveToTrash)))
        #expect(!controller.validateMenuItem(item(.goBack)))

        // View to model, as a click reports it.
        let first = IndexPath(item: 1, section: 0)
        grid.collectionView.selectionIndexPaths = [first]
        grid.collectionView(grid.collectionView, didSelectItemsAt: [first])
        #expect(controller.model.lead?.lastPathComponent == "a.jpg")

        // Into the subfolder and back up, which selects it again.
        controller.model.navigate(to: sub)
        await settle(controller)
        #expect(controller.validateMenuItem(item(.goBack)))
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 0)
        controller.goToEnclosingFolder(nil)
        await settle(controller)
        #expect(controller.model.lead?.lastPathComponent == "Sub")
        #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 0, section: 0)])

        // Sort checkmarks follow the preference.
        let byName = item(.sortBy, tag: SortKey.allCases.firstIndex(of: .name)!)
        _ = controller.validateMenuItem(byName)
        #expect(byName.state == (Preferences.shared.sortOrder.key == .name ? .on : .off))
        let preview = item(.togglePreviewPane)
        _ = controller.validateMenuItem(preview)
        #expect(preview.title == (controller.previewItem.isCollapsed ? "Show Preview Pane" : "Hide Preview Pane"))

        // The search field's filter reaches the grid.
        controller.model.filter = "c.j"
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 1)
        window.close()
    }
}
