import AppKit
import AgateCore
import AgateRender
import os

let log = Logger(subsystem: "com.agate.viewer", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let start = ContinuousClock.now
        _ = GPU.shared
        log.info("Metal ready in \(ContinuousClock.now - start, privacy: .public)")
        if ProcessInfo.processInfo.environment["AGATE_TRACE"] != nil { FileHandle.standardError.write(Data("Metal ready in \(ContinuousClock.now - start)\n".utf8)) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Agate"
        window.center()
        window.makeKeyAndOrderFront(nil)
        browserWindow = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agate", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Agate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
