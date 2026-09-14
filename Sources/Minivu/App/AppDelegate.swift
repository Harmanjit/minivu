import AppKit
import Combine
import MinivuCore
import MinivuRender
import os

/// The app's log. `nonisolated` because `Logger` is thread-safe and
/// background work (the GPU warm-up below, decoders) logs too.
nonisolated let log = Logger(subsystem: "com.minivu.app", category: "app")

extension Notification.Name {
    /// Posted after a folder is added to the sidebar's favourites.
    nonisolated static let minivuFavoritesChanged = Notification.Name("MinivuFavoritesChanged")
}

/// Starts the app, owns the browser window and handles the commands that
/// don't belong to any window: opening folders, Settings and the theme.
///
/// It sits at the very end of the responder chain, so its `MinivuActions`
/// run only when no window controller implements them first.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, MinivuActions {
    private var browser: BrowserWindowController?
    private var settings: PreferencesWindowController?
    private var themeSubscription: AnyCancellable?
    /// Files opened before the browser exists (a launch by double-clicking
    /// an image in Finder delivers them before `didFinishLaunching`).
    private var pendingOpens: [URL] = []
    /// The folder panel on screen, so a second ⌘O brings it forward
    /// instead of stacking another panel.
    private var folderPanel: NSOpenPanel?

    /// UserDefaults key for the folder the browser showed last. The browser
    /// writes it; launch reads it.
    nonisolated static let lastFolderKey = "lastFolder"

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the menu exists when the first
        // open-file event arrives. minivu has one browser, not tabs.
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `$theme` publishes its current value on subscription, so this also
        // applies the saved theme before the first window appears.
        themeSubscription = Preferences.shared.$theme
            .removeDuplicates()
            .sink { ThemeColors.apply($0) }
        // Increase Contrast turned on or off: views that draw their own
        // selection (the grid's cells) redraw with or without outlines.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeColors.apply(ThemeColors.current) }
        }

        warmUpGPU()
        AppServices.start()

        // Resolving the bookmarks restores access to the sidebar folders,
        // which the last folder may be inside.
        _ = BookmarkStore.shared

        let browser = BrowserWindowController()
        self.browser = browser
        let requested = pendingOpens + Self.paths(fromArguments: Array(CommandLine.arguments.dropFirst()))
        pendingOpens = []
        // Shown first so a refusal can appear as a sheet on it. If nothing
        // requested could be opened, the browser still needs a folder.
        browser.showWindow(nil)
        NSApp.activate()
        if requested.isEmpty || !open(requested) {
            browser.open(folder: Self.startFolder())
        }

        #if DEBUG
        SnapshotHarness.startIfRequested(app: self)
        #endif
    }

    /// Compiles the shaders on a background thread so the window appears
    /// without waiting for Metal. If the canvas asks for `GPU.shared` first,
    /// it just waits for this same one-time setup.
    private func warmUpGPU() {
        // Compiling shaders blocks for tens of ms: on GCD (BlockingWork),
        // where it can't hold up a cooperative thread a listing needs.
        Task { await BlockingWork.run {
            let start = ContinuousClock.now
            _ = GPU.shared
            let elapsed = ContinuousClock.now - start
            log.info("Metal ready in \(elapsed, privacy: .public)")
            if ProcessInfo.processInfo.environment["MINIVU_TRACE"] != nil {
                FileHandle.standardError.write(Data("Metal ready in \(elapsed)\n".utf8))
            }
        } }
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

    /// Existing paths given on the command line (`open minivu.app --args
    /// ~/Photos`), without the program name. An argument starting with "-"
    /// is a defaults override that takes the next argument as its value
    /// (`-lastFolder /tmp`), so both are skipped.
    static func paths(fromArguments arguments: [String]) -> [URL] {
        var remaining = arguments[...]
        var paths: [URL] = []
        while let argument = remaining.popFirst() {
            if argument.hasPrefix("-") {
                _ = remaining.popFirst()
            } else if FileManager.default.fileExists(atPath: argument) {
                paths.append(URL(fileURLWithPath: argument))
            }
        }
        return paths
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ratings, tags and Custom Order changes are written on their own queue
    /// a moment after the key press; one pressed just before ⌘Q must still
    /// reach the catalog. Blocks the main thread only for what is queued.
    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.catalogWrites.sync {}
    }

    /// Quitting must not lose work. Three things can be at risk:
    ///
    /// 1. Unsaved edits in the viewer: ask, exactly as moving to another
    ///    image does (Save / Don't Save / Cancel).
    /// 2. Writes still running (a Save, Save As, comment or batch rotate):
    ///    wait for them, so the file the user just saved is really on disk
    ///    and no hidden temporary file is left behind.
    /// 3. A copy or move under way: it stops after the item it is on (its
    ///    hidden temporary copy would otherwise stay in the destination),
    ///    leaving every item either transferred or where it was. A batch
    ///    rename under way finishes (a swap hides a file for a moment).
    ///
    /// `.terminateLater` keeps the app alive until `reply` is called.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let viewer = ViewerWindowController.current
        let hasEdits = viewer?.hasUnsavedEdits == true
        let writes = FileWriteQueue.shared
        guard hasEdits || writes.pendingCount > 0 || FileTransfer.isActive || BatchTools.renamesRunning > 0 else {
            return .terminateNow
        }

        func finishWritesThenQuit() {
            FileTransfer.cancelActive()
            Task {
                await FileTransfer.waitUntilInactive()
                await BatchTools.waitForRenames()
                await writes.waitUntilIdle()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        if let viewer, hasEdits {
            viewer.reviewUnsavedEditsBeforeQuitting { mayQuit in
                if mayQuit { finishWritesThenQuit() } else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
        } else {
            finishWritesThenQuit()
        }
        return .terminateLater
    }

    // MARK: - Opening files and folders

    func application(_ application: NSApplication, open urls: [URL]) {
        guard browser != nil else {
            pendingOpens += urls
            return
        }
        open(urls)
    }

    /// What opening one URL means.
    enum OpenTarget: Equatable {
        case folder, file
        /// Gone, or unreadable.
        case missing
        /// On a volume `VolumePolicy` refuses.
        case external

        init(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                self = .missing
                return
            }
            guard VolumePolicy.isAllowed(url) else {
                self = .external
                return
            }
            self = values.isDirectory == true ? .folder : .file
        }
    }

    /// Opens folders and files from Finder, the Dock, the command line or
    /// the snapshot harness, and explains any it refuses. The browser shows
    /// one folder at a time, so of several items only the last allowed one
    /// is opened (opening each in turn would start and cancel a folder load
    /// per item). Returns whether anything was opened.
    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        guard let browser else { return false }
        let targets = urls.map { ($0, OpenTarget($0)) }
        let external = targets.filter { $0.1 == .external }.map(\.0)
        let missing = targets.filter { $0.1 == .missing }.map(\.0)
        if !external.isEmpty {
            explain(external, "minivu only works with files on this Mac’s internal storage. Copy the photos "
                + "from the external drive, memory card or network share to a folder on this Mac first.")
        }
        if !missing.isEmpty {
            explain(missing, "The item may have been moved or deleted, or minivu may not have permission to read it.")
        }
        guard let (url, target) = targets.last(where: { $0.1 == .folder || $0.1 == .file }) else { return false }
        if target == .folder {
            browser.open(folder: url)
        } else {
            browser.open(file: url)
        }
        return true
    }

    private func explain(_ urls: [URL], _ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let names = urls.map { "“\($0.lastPathComponent)”" }.formatted(.list(type: .and))
        alert.messageText = "minivu can’t open \(names)"
        alert.informativeText = reason
        if let window = browser?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - MinivuActions

    /// Chooses a folder, adds it to the sidebar and shows it.
    @objc func openFolder(_ sender: Any?) {
        chooseFolder(prompt: "Open") { [weak self] url in
            if BookmarkStore.shared.add(url) {
                NotificationCenter.default.post(name: .minivuFavoritesChanged, object: nil)
            }
            self?.browser?.open(folder: url)
        }
    }

    @objc func addFolderToSidebar(_ sender: Any?) {
        chooseFolder(prompt: "Add") { url in
            if BookmarkStore.shared.add(url) {
                NotificationCenter.default.post(name: .minivuFavoritesChanged, object: nil)
            }
        }
    }

    /// Runs an open panel for one folder, as a sheet on the browser.
    ///
    /// The bookmark must be made from the URL the panel returns: that URL
    /// carries the sandbox permission the user just granted.
    private func chooseFolder(prompt: String, then handle: @escaping (URL) -> Void) {
        if let folderPanel {
            folderPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        // The panel holds its delegate weakly; the completion handler below
        // keeps it alive exactly as long as the panel is up.
        let delegate = InternalVolumesOnly()
        panel.delegate = delegate
        folderPanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            withExtendedLifetime(delegate) {}
            self?.folderPanel = nil
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

    /// Opens Settings on one pane.
    func showSettings(pane: SettingsPane) {
        showSettings(nil)
        settings?.select(pane)
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
/// can't pick a folder minivu would then refuse (VolumePolicy).
final class InternalVolumesOnly: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        VolumePolicy.isAllowed(url)
    }
}
