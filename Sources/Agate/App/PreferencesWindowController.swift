import AppKit
import SwiftUI

extension Notification.Name {
    /// Settings > Thumbnails > Clear Thumbnail Cache. The thumbnail cache
    /// empties its memory and disk stores when it sees this.
    nonisolated static let agateClearThumbnailCache = Notification.Name("AgateClearThumbnailCache")
}

/// The Settings window: SwiftUI forms in AppKit's toolbar tabs.
///
/// Settings are a form, not a hot path, which is where SwiftUI is the
/// better tool (DESIGN.md 4.1). Every control binds straight to
/// `Preferences.shared`, so a change is saved and seen by the rest of the
/// app the moment it is made; there is no OK button.
///
/// The tabs are an `NSTabViewController` in toolbar style rather than a
/// SwiftUI `TabView`: outside a SwiftUI `Settings` scene, `TabView` draws
/// the old boxed tabs, while the toolbar style is the standard look of a
/// Mac settings window, and it resizes the window to each pane.
final class PreferencesWindowController: NSWindowController {
    init() {
        let tabs = SettingsTabsController()
        tabs.tabStyle = .toolbar
        // Keep the window titled "Settings" rather than the pane's name.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for pane in SettingsPane.allCases {
            let hosting = NSHostingController(rootView: PreferencesView(pane: pane))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsTabsController.savedIndex(count: tabs.tabViewItems.count)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "Settings"
        window.center()
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Reopens Settings on the pane the user last looked at, as Mac settings
/// windows do.
final class SettingsTabsController: NSTabViewController {
    nonisolated static let paneKey = "settingsPane"

    static func savedIndex(count: Int, defaults: UserDefaults = .standard) -> Int {
        let index = defaults.integer(forKey: paneKey)
        return (0..<count).contains(index) ? index : 0
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.paneKey)
    }
}

enum SettingsPane: CaseIterable {
    case general, viewer, magnifier, thumbnails

    var title: String {
        switch self {
        case .general: "General"
        case .viewer: "Viewer"
        case .magnifier: "Magnifier"
        case .thumbnails: "Thumbnails"
        }
    }

    /// SF Symbol shown in the toolbar.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .viewer: "photo"
        case .magnifier: "plus.magnifyingglass"
        case .thumbnails: "square.grid.3x3"
        }
    }
}

/// One pane of Settings, at the window's fixed width.
struct PreferencesView: View {
    var pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralSettings()
            case .viewer: ViewerSettings()
            case .magnifier: MagnifierSettings()
            case .thumbnails: ThumbnailSettings()
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Theme", selection: $prefs.theme) {
                ForEach(Preferences.Theme.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show hidden files", isOn: $prefs.showHiddenFiles)
            Toggle("Wrap around at end of folder", isOn: $prefs.wrapAround)
            Toggle("Open viewer in full screen", isOn: $prefs.openViewerFullScreen)
        }
        .settingsForm()
    }
}

private struct ViewerSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Background", selection: $prefs.viewerBackground) {
                ForEach(Preferences.ViewerBackground.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Enlarge small images to fit", isOn: $prefs.enlargeSmallImages)
            Toggle("Pixelated zoom above 200%", isOn: $prefs.pixelatedZoom)
            Picker("Mouse wheel", selection: $prefs.wheelAction) {
                ForEach(Preferences.WheelAction.allCases) { Text($0.title).tag($0) }
            }
        }
        .settingsForm()
    }
}

private struct MagnifierSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Zoom") {
                    HStack {
                        Slider(value: $prefs.magnifierZoom, in: 1.5...8)
                        ValueLabel(text: String(format: "%.1f×", prefs.magnifierZoom))
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $prefs.magnifierRadius, in: 60...300)
                        ValueLabel(text: "\(Int(prefs.magnifierRadius)) pt")
                    }
                }
            } footer: {
                Text("Press and hold on an image in the viewer to show the magnifier.")
                    .foregroundStyle(.secondary)
            }
            Section("Preview") {
                MagnifierPreview(zoom: prefs.magnifierZoom, radius: prefs.magnifierRadius)
                    .frame(height: 170)
            }
        }
        .settingsForm()
    }
}

/// A live picture of the loupe: a pattern with a circle that magnifies it.
///
/// Drawn at half size so the largest radius (300 pt) still fits, which the
/// caption says. SwiftUI's `Canvas` redraws only when zoom or radius
/// change, and costs a few path fills.
private struct MagnifierPreview: View {
    var zoom: Double
    var radius: Double

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = radius / 2
                let loupe = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
                drawPattern(in: &context, size: size, scale: 1, about: centre)
                var inside = context
                inside.clip(to: loupe)
                inside.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
                drawPattern(in: &inside, size: size, scale: zoom, about: centre)
                context.stroke(loupe, with: .color(.white.opacity(0.9)), lineWidth: 2)
                context.stroke(loupe, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            }
            Text("Shown at half size").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Dots on a 12 pt grid, scaled about `centre` so the magnified copy
    /// lines up with the plain one at the centre, as the real loupe does.
    private func drawPattern(in context: inout GraphicsContext, size: CGSize, scale: Double, about centre: CGPoint) {
        let spacing = 12 * scale
        let dot = 2.5 * scale
        var dots = Path()
        let startX = centre.x - (centre.x / spacing).rounded(.up) * spacing
        let startY = centre.y - (centre.y / spacing).rounded(.up) * spacing
        var y = startY
        while y <= size.height + spacing {
            var x = startX
            while x <= size.width + spacing {
                dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                x += spacing
            }
            y += spacing
        }
        context.fill(dots, with: .color(.secondary))
    }
}

private struct ThumbnailSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            LabeledContent("Size") {
                HStack {
                    // No `step`: on macOS it draws a tick mark per step.
                    Slider(value: $prefs.thumbnailSize, in: 80...320)
                    ValueLabel(text: "\(Int(prefs.thumbnailSize)) pt")
                }
            }
            Section {
                LabeledContent("Thumbnail cache") {
                    Button("Clear Thumbnail Cache") {
                        NotificationCenter.default.post(name: .agateClearThumbnailCache, object: nil)
                    }
                }
            } footer: {
                Text("Thumbnails are rebuilt from the original files the next time a folder is shown.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}

/// A slider's current value, in a fixed width so sliders above each other
/// line up and don't shift as the number changes.
private struct ValueLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
    }
}

private extension View {
    /// The grouped form style of current macOS settings panes. Scrolling is
    /// off so the form reports its real height and the window fits it.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
