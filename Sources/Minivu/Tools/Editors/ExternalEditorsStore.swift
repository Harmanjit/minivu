import AppKit
import UniformTypeIdentifiers

/// An application the user opens images in from minivu.
nonisolated struct ExternalEditor: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var bundleIdentifier: String?
    /// Where the application was when it was added.
    var path: String
    /// An app-scoped security-scoped bookmark, when the application was
    /// chosen in an open panel: it finds the application again after it
    /// moves, and carries the sandbox's permission to it.
    var bookmark: Data?

    var id: String { bundleIdentifier ?? path }
}

/// The ordered list of external editors (Settings > Editors), saved in its
/// own defaults key. The first opens with ⌘E.
///
/// Observable for the settings pane; the menu listens for `didChange`, so
/// Open in External Editor is rebuilt the moment the list changes rather
/// than when the menu next opens (⌘E must work before it ever has).
@MainActor @Observable final class ExternalEditorsStore {
    static var shared = ExternalEditorsStore(defaults: .standard)
    nonisolated static let didChange = Notification.Name("MinivuExternalEditorsChanged")
    nonisolated static let defaultsKey = "externalEditors"

    private(set) var editors: [ExternalEditor]
    /// nil keeps the list in memory only.
    @ObservationIgnored private var defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        editors = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([ExternalEditor].self, from: $0) } ?? []
    }

    /// Adds an application unless it is already in the list (by bundle
    /// identifier, or path for an application without one). Returns whether
    /// it was added.
    @discardableResult
    func add(_ editor: ExternalEditor) -> Bool {
        guard !editors.contains(where: { $0.id == editor.id || $0.path == editor.path }) else { return false }
        editors.append(editor)
        changed()
        return true
    }

    @discardableResult
    func add(applicationAt url: URL, makeBookmark: Bool = true) -> Bool {
        guard let editor = Self.editor(forApplicationAt: url, makeBookmark: makeBookmark) else { return false }
        return add(editor)
    }

    func remove(at index: Int) {
        guard editors.indices.contains(index) else { return }
        editors.remove(at: index)
        changed()
    }

    func move(from source: IndexSet, to destination: Int) {
        editors.move(fromOffsets: source, toOffset: destination)
        changed()
    }

    /// Moves one editor up (-1) or down (+1) the list.
    func move(at index: Int, by offset: Int) {
        let target = index + offset
        guard editors.indices.contains(index), editors.indices.contains(target) else { return }
        editors.swapAt(index, target)
        changed()
    }

    private func changed() {
        if let defaults, let data = try? JSONEncoder().encode(editors) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Debug only, for the snapshot harness: stops saving, so a sample list
    /// never reaches the user's settings.
    func detachFromDefaults() {
        defaults = nil
    }

    func replaceAll(with editors: [ExternalEditor]) {
        self.editors = editors
        changed()
    }

    // MARK: - Applications

    /// An editor entry for the application at `url`; nil if it isn't one.
    nonisolated static func editor(forApplicationAt url: URL, makeBookmark: Bool = true) -> ExternalEditor? {
        guard url.pathExtension.lowercased() == "app" || (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?.conforms(to: .application) == true else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let bookmark = makeBookmark
            ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return ExternalEditor(name: name, bundleIdentifier: bundle?.bundleIdentifier, path: url.path, bookmark: bookmark)
    }

    /// Where the editor's application is now: the bookmark (which follows a
    /// move), else the path it was added from, else wherever Launch Services
    /// knows its bundle identifier to be. `isScoped` says whether the URL
    /// must be paired with start/stopAccessingSecurityScopedResource.
    static func applicationURL(for editor: ExternalEditor) -> (url: URL, isScoped: Bool)? {
        if let bookmark = editor.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return (url, true)
            }
        }
        if FileManager.default.fileExists(atPath: editor.path) {
            return (URL(fileURLWithPath: editor.path), false)
        }
        if let identifier = editor.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return (url, false)
        }
        return nil
    }

    /// The application's icon at `size` points.
    static func icon(for editor: ExternalEditor, size: CGFloat) -> NSImage {
        let icon = FileManager.default.fileExists(atPath: editor.path)
            ? NSWorkspace.shared.icon(forFile: editor.path)
            : NSWorkspace.shared.icon(for: .application)
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

/// Installed applications worth suggesting as editors.
nonisolated enum ExternalEditorSuggestions {
    /// Well-known image editors, by bundle identifier prefix, in the order
    /// they are suggested.
    static let knownEditors = [
        "com.apple.Preview",
        "com.pixelmatorteam.pixelmator",
        "com.seriflabs.affinityphoto",
        "com.adobe.Photoshop",
        "com.adobe.LightroomClassic",
        "com.adobe.lightroomCC",
        "com.flyingmeat.Acorn",
        "com.skylum.",
        "com.captureone.",
        "com.phaseone.captureone",
        "com.dxo.",
        "org.gimp.",
        "org.darktable",
        "org.kde.krita",
    ]

    /// Applications that open JPEGs and are either a known image editor or
    /// declare themselves an Editor of images, minus any copy of minivu and
    /// those already in the list; known editors first.
    static func find(excluding existing: Set<String>, limit: Int = 6) -> [ExternalEditor] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var ranked: [(rank: Int, editor: ExternalEditor)] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: UTType.jpeg) {
            guard let editor = ExternalEditorsStore.editor(forApplicationAt: url, makeBookmark: false),
                  editor.bundleIdentifier != own, !existing.contains(editor.id), !existing.contains(editor.path),
                  seen.insert(editor.id).inserted else { continue }
            let identifier = editor.bundleIdentifier ?? ""
            guard !identifier.hasPrefix("com.minivu.") else { continue }
            if let rank = knownEditors.firstIndex(where: { identifier.hasPrefix($0) }) {
                ranked.append((rank, editor))
            } else if !identifier.hasPrefix("com.apple."), declaresImageEditor(Bundle(url: url)) {
                // Apple's own apps that claim images (ColorSync Utility,
                // QuickTime Player) aren't photo editors; Preview is listed.
                ranked.append((knownEditors.count, editor))
            }
        }
        return ranked.sorted { ($0.rank, $0.editor.name) < ($1.rank, $1.editor.name) }.prefix(limit).map(\.editor)
    }

    /// Whether the application's Info.plist claims the Editor role for
    /// JPEG or images in general (a viewer, a browser, doesn't).
    static func declaresImageEditor(_ bundle: Bundle?) -> Bool {
        guard let types = bundle?.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
            return false
        }
        return types.contains { type in
            let role = type["CFBundleTypeRole"] as? String
            let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
            return role == "Editor" && contentTypes.contains { ["public.jpeg", "public.image"].contains($0) }
        }
    }
}
