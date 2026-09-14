import AppKit

/// Tools > Open in External Editor: one item per editor (tag = its index in
/// the list, sending `openInExternalEditor:`; the first with ⌘E), then a
/// separator and Edit Editor List….
enum ExternalEditorsMenu {
    static let title = "Open in External Editor"

    /// The menus made so far, each rebuilt when its store changes.
    ///
    /// Rebuilt on the store's notification, not in `menuNeedsUpdate`: AppKit
    /// looks for key equivalents without asking a menu to update, so ⌘E
    /// would do nothing until the menu had been opened once.
    private static var menus: [(menu: Weak<NSMenu>, store: ExternalEditorsStore)] = []
    private static var observer: NSObjectProtocol?

    static func make(store: ExternalEditorsStore = .shared) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.items = items(for: store.editors)
        menus.removeAll { $0.menu.value == nil }
        menus.append((Weak(menu), store))
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ExternalEditorsStore.didChange, object: nil,
                                                              queue: .main) { note in
                let changed = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { storeChanged(changed) }
            }
        }
        return menu
    }

    private static func storeChanged(_ changed: ObjectIdentifier?) {
        menus.removeAll { $0.menu.value == nil }
        for (menu, store) in menus where ObjectIdentifier(store) == changed {
            menu.value?.items = items(for: store.editors)
        }
    }

    /// The items for `editors`, in order. Icons are the applications' own,
    /// at the 16 pt of menu images.
    static func items(for editors: [ExternalEditor],
                      icon: (ExternalEditor) -> NSImage? = { ExternalEditorsStore.icon(for: $0, size: 16) }) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, editor) in editors.enumerated() {
            let item = NSMenuItem(title: editor.name, action: .openInExternalEditor, keyEquivalent: index == 0 ? "e" : "")
            item.keyEquivalentModifierMask = index == 0 ? .command : []
            item.tag = index
            item.image = icon(editor)
            items.append(item)
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(NSMenuItem(title: "Edit Editor List…", action: .manageExternalEditors, keyEquivalent: ""))
        return items
    }
}

/// A weak reference that can sit in an array, so the list of menus doesn't
/// keep closed menu bars alive.
final class Weak<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}
