import Testing
import AppKit
@testable import Minivu

@MainActor @Suite struct LaunchTests {
    /// Runs `body` with a private defaults domain, deleted afterwards, so
    /// tests never touch the app's settings or leave files behind.
    func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "minivu-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// A fresh folder in the temporary directory, removed afterwards.
    func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func readableFolderCheck() throws {
        try withTemporaryFolder { folder in
            #expect(AppDelegate.isReadableFolder(folder))
            #expect(!AppDelegate.isReadableFolder(folder.appendingPathComponent("missing")))

            // A file is not a folder.
            let file = folder.appendingPathComponent("photo.jpg")
            FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
            #expect(!AppDelegate.isReadableFolder(file))
        }
    }

    @Test func startsAtLastFolderWhenStillThere() throws {
        try withTemporaryFolder { folder in
            withScratchDefaults { defaults in
                defaults.set(folder.path, forKey: AppDelegate.lastFolderKey)
                #expect(AppDelegate.startFolder(defaults: defaults).standardizedFileURL.path
                    == folder.standardizedFileURL.path)
            }
        }
    }

    @Test func fallsBackToPictures() {
        withScratchDefaults { defaults in
            #expect(AppDelegate.startFolder(defaults: defaults) == BookmarkStore.picturesFolder)
            defaults.set("/no/such/folder", forKey: AppDelegate.lastFolderKey)
            #expect(AppDelegate.startFolder(defaults: defaults) == BookmarkStore.picturesFolder)
        }
    }

    @Test func openTargetsAreClassified() throws {
        try withTemporaryFolder { folder in
            let file = folder.appendingPathComponent("photo.jpg")
            FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
            #expect(AppDelegate.OpenTarget(folder) == .folder)
            #expect(AppDelegate.OpenTarget(file) == .file)
            #expect(AppDelegate.OpenTarget(folder.appendingPathComponent("gone.jpg")) == .missing)
        }
    }

    /// `-key value` pairs are defaults overrides, even when the value
    /// happens to be a real path; missing paths are dropped.
    @Test func commandLinePaths() throws {
        try withTemporaryFolder { folder in
            let other = folder.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let paths = AppDelegate.paths(fromArguments: [
                "-lastFolder", other.path, folder.path, "/no/such/folder", "-NSQuitAlwaysKeepsWindows", "NO",
            ])
            #expect(paths.map(\.path) == [folder.path])
        }
    }

    /// `@Published` tells subscribers before the property changes, so the
    /// theme colours must follow what was applied, not the preference.
    @Test func themeColoursFollowTheAppliedTheme() {
        _ = NSApplication.shared
        let saved = ThemeColors.current
        defer { ThemeColors.apply(saved) }
        func contentRed() -> CGFloat {
            var red: CGFloat = 0
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                red = ThemeColors.contentBackground.usingColorSpace(.sRGB)!.redComponent
            }
            return red
        }
        ThemeColors.apply(.gray)
        #expect(abs(contentRed() - 0.24) < 0.01)
        ThemeColors.apply(.dark)
        #expect(abs(contentRed() - 0.12) < 0.01)
    }

    @Test func settingsReopensOnSavedPane() {
        withScratchDefaults { defaults in
            #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 0)
            defaults.set(2, forKey: SettingsTabsController.paneKey)
            #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 2)
            defaults.set(9, forKey: SettingsTabsController.paneKey)
            #expect(SettingsTabsController.savedIndex(count: 4, defaults: defaults) == 0)
        }
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
