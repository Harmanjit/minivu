import AppKit

// minivu's entry point. A plain AppKit application built by SwiftPM: no nib,
// no storyboard. The menu bar and windows are made in code (AppDelegate).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
