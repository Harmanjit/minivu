import AppKit
import Combine
import AgateCore
import AgateRender
import os

/// The app's log. `nonisolated` because `Logger` is thread-safe and
/// background work (the GPU warm-up below, decoders) logs too.
nonisolated let log = Logger(subsystem: "com.agate.viewer", category: "app")

extension Notification.Name {
    /// Posted after a folder is added to the sidebar's favourites.
    nonisolated static let agateFavoritesChanged = Notification.Name("AgateFavoritesChanged")
}

/// Starts the app, owns the browser window and handles the commands that
/// don't belong to any window: opening folders, Settings and the theme.
///
/// It sits at the very end of the responder chain, so its `AgateActions`
/// run only when no window controller implements them first.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, AgateActions {
    private var browser: BrowserWindowController?
    private var settings: PreferencesWindowController?
    private var themeSubscription: AnyCancellable?
    /// Files opened before the browser exists (a launch by double-clicking
    /// an image in Finder delivers them before `didFinishLaunching`).
    private var pendingOpens: [URL] = []
    /// The open panel holds its delegate weakly.
    private var panelDelegate: InternalVolumesOnly?

    /// UserDefaults key for the folder the browser showed last. The browser
    /// writes it; launch reads it.
    nonisolated static let lastFolderKey = "lastFolder"

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the menu exists when the first
        // open-file event arrives. Agate has one browser, not tabs.
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `$theme` publishes its current value on subscription, so this also
        // applies the saved theme before the first window appears.
        themeSubscription = Preferences.shared.$theme
            .removeDuplicates()
            .sink { ThemeColors.apply($0) }

        warmUpGPU()

        // Resolving the bookmarks restores access to the sidebar folders,
        // which the last folder may be inside.
        _ = BookmarkStore.shared

        let browser = BrowserWindowController()
        self.browser = browser
        let requested = pendingOpens + Self.pathsFromArguments()
        pendingOpens = []
        if requested.isEmpty {
            browser.open(folder: Self.startFolder())
        }
        browser.showWindow(nil)
        NSApp.activate()
        if !requested.isEmpty { open(requested) }

        SnapshotHarness.startIfRequested(app: self)
    }

    /// Compiles the shaders on a background thread so the window appears
    /// without waiting for Metal. If the canvas asks for `GPU.shared` first,
    /// it just waits for this same one-time setup.
    private func warmUpGPU() {
        Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            _ = GPU.shared
            let elapsed = ContinuousClock.now - start
            log.info("Metal ready in \(elapsed, privacy: .public)")
            if ProcessInfo.processInfo.environment["AGATE_TRACE"] != nil {
                FileHandle.standardError.write(Data("Metal ready in \(elapsed)\n".utf8))
            }
        }
    }

    /// The last visited folder if it can still be read, else Pictures.
    static func startFolder(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: lastFolderKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isReadableFolder(url), VolumePolicy.isAllowed(url) { return url }
        }
        return BookmarkStore.picturesFolder
    }

    /// Whether the folder can be listed right now. Opening the directory is
    /// the honest test: under the sandbox a folder can exist and still be
    /// off limits, which `fileExists` would not reveal. One `open` call
    /// takes microseconds, so this is fine on the main thread at launch.
    static func isReadableFolder(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    /// Paths given on the command line (`open Agate.app --args ~/Photos`).
    /// Arguments starting with "-" are AppKit's own options.
    private static func pathsFromArguments() -> [URL] {
        CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Opening files and folders

    func application(_ application: NSApplication, open urls: [URL]) {
        guard browser != nil else {
            pendingOpens += urls
            return
        }
        open(urls)
    }

    /// Opens folders and files from Finder, the Dock, the command line or
    /// the snapshot harness. The browser shows one folder at a time, so if
    /// several items arrive the last allowed one wins.
    func open(_ urls: [URL]) {
        guard let browser else { return }
        var missing: [URL] = []
        var external: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard let values else {
                missing.append(url)
                continue
            }
            guard VolumePolicy.isAllowed(url) else {
                external.append(url)
                continue
            }
            if values.isDirectory == true {
                browser.open(folder: url)
            } else {
                browser.open(file: url)
            }
        }
        if !external.isEmpty {
            explain(external, "Agate only works with files on this Mac’s internal storage. Copy the photos "
                + "from the external drive, memory card or network share to a folder on this Mac first.")
        } else if !missing.isEmpty {
            explain(missing, "The item may have been moved or deleted, or Agate may not have permission to read it.")
        }
    }

    private func explain(_ urls: [URL], _ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let names = urls.map { "“\($0.lastPathComponent)”" }.formatted(.list(type: .and))
        alert.messageText = "Agate can’t open \(names)"
        alert.informativeText = reason
        if let window = browser?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - AgateActions

    /// Chooses a folder, adds it to the sidebar and shows it.
    @objc func openFolder(_ sender: Any?) {
        chooseFolder(prompt: "Open") { [weak self] url in
            if BookmarkStore.shared.add(url) {
                NotificationCenter.default.post(name: .agateFavoritesChanged, object: nil)
            }
            self?.browser?.open(folder: url)
        }
    }

    @objc func addFolderToSidebar(_ sender: Any?) {
        chooseFolder(prompt: "Add") { url in
            if BookmarkStore.shared.add(url) {
                NotificationCenter.default.post(name: .agateFavoritesChanged, object: nil)
            }
        }
    }

    /// Runs an open panel for one folder, as a sheet on the browser.
    ///
    /// The bookmark must be made from the URL the panel returns: that URL
    /// carries the sandbox permission the user just granted.
    private func chooseFolder(prompt: String, then handle: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        let delegate = InternalVolumesOnly()
        panelDelegate = delegate
        panel.delegate = delegate
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.panelDelegate = nil
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
        if let window = browser?.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: - Settings and theme

    /// App menu > Settings…. One window, created on first use.
    @objc func showSettings(_ sender: Any?) {
        let controller = settings ?? PreferencesWindowController()
        settings = controller
        controller.showWindow(sender)
    }

    /// The Settings window, once it has been opened.
    var settingsWindow: NSWindow? { settings?.window }

    /// View > Theme. The menu item's tag is the index in `Theme.allCases`.
    @objc func selectTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, Preferences.Theme.allCases.indices.contains(item.tag) else { return }
        Preferences.shared.theme = Preferences.Theme.allCases[item.tag]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTheme(_:)) {
            let current = Preferences.Theme.allCases.firstIndex(of: Preferences.shared.theme)
            menuItem.state = menuItem.tag == current ? .on : .off
        }
        return true
    }
}

/// Greys out anything on an external volume in the open panel, so the user
/// can't pick a folder Agate would then refuse (VolumePolicy).
final class InternalVolumesOnly: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        VolumePolicy.isAllowed(url)
    }
}
