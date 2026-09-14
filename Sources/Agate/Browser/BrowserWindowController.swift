import AppKit

/// PLACEHOLDER browser window: the app shell needs something to open.
/// The real browser (sidebar, thumbnail grid, preview pane) replaces this
/// file entirely, keeping `init()`, `open(folder:)` and `open(file:)`.
final class BrowserWindowController: NSWindowController {
    private let pathLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "browser")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.setFrameAutosaveName("BrowserWindow")

        pathLabel.textColor = .secondaryLabelColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(pathLabel)
        NSLayoutConstraint.activate([
            pathLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pathLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func open(folder: URL) {
        window?.title = folder.lastPathComponent
        pathLabel.stringValue = folder.path
        UserDefaults.standard.set(folder.path, forKey: AppDelegate.lastFolderKey)
    }

    func open(file: URL) {
        open(folder: file.deletingLastPathComponent())
        pathLabel.stringValue = file.path
    }
}
