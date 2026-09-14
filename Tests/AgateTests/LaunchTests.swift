import Testing
import AppKit
@testable import Agate

@MainActor @Suite struct LaunchTests {
    /// A private defaults domain so tests never touch the app's settings.
    func scratchDefaults() -> UserDefaults {
        let name = "agate-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func readableFolderCheck() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agate-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AppDelegate.isReadableFolder(folder))
        #expect(!AppDelegate.isReadableFolder(folder.appendingPathComponent("missing")))

        // A file is not a folder.
        let file = folder.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
        #expect(!AppDelegate.isReadableFolder(file))
    }

    @Test func startsAtLastFolderWhenStillThere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agate-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = scratchDefaults()
        defaults.set(folder.path, forKey: AppDelegate.lastFolderKey)
        #expect(AppDelegate.startFolder(defaults: defaults).standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func fallsBackToPictures() {
        let defaults = scratchDefaults()
        #expect(AppDelegate.startFolder(defaults: defaults) == BookmarkStore.picturesFolder)
        defaults.set("/no/such/folder", forKey: AppDelegate.lastFolderKey)
        #expect(AppDelegate.startFolder(defaults: defaults) == BookmarkStore.picturesFolder)
    }

    @Test func settingsReopensOnSavedPane() {
        let defaults = scratchDefaults()
        #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 0)
        defaults.set(2, forKey: SettingsTabsController.paneKey)
        #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 2)
        defaults.set(9, forKey: SettingsTabsController.paneKey)
        #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 0)
    }

    @Test func settingsWindowHasOneTabPerPane() throws {
        _ = NSApplication.shared
        let controller = PreferencesWindowController()
        let window = try #require(controller.window)
        #expect(window.title == "Settings")
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems.map(\.label) == SettingsPane.allCases.map(\.title))
        #expect(tabs.tabViewItems.allSatisfy { $0.image != nil })
    }
}
