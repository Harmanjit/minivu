import AppKit
import SwiftUI

/// Tools > Open in External Editor: one item per editor (tag = its index in
/// the list, sending `openInExternalEditor:`), then Edit Editor List….
/// A placeholder with only the last item until external editors are built.
enum ExternalEditorsMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: "Open in External Editor")
        menu.addItem(NSMenuItem(title: "Edit Editor List…", action: .manageExternalEditors, keyEquivalent: ""))
        return menu
    }
}

/// Settings > Editors. A placeholder until external editors are built.
struct ExternalEditorsSettingsView: View {
    var body: some View {
        Form {
            Text("External editors").foregroundStyle(.secondary)
        }
        .settingsForm()
    }
}
