import AppKit
import Combine
import MinivuCore
import MinivuRender

extension Notification.Name {
    /// A setting that changes how images decode (HDR, RAW rendering) was
    /// changed. By the time this is posted `ImageLoader.shared` has the new
    /// settings and has emptied its texture cache, so whoever shows an image
    /// (the viewer, the browser's preview pane) should observe it and load
    /// that image again; the canvas can't, since it doesn't know the file.
    nonisolated static let minivuDisplaySettingsChanged = Notification.Name("MinivuDisplaySettingsChanged")
}

/// Every user setting, stored in UserDefaults and observable by SwiftUI.
///
/// One object for the whole app so there is a single place to look up what
/// a setting is called and what its default is. Views observe it; AppKit
/// controllers subscribe to `objectWillChange` or read values when needed.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, gray, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Bright"
            case .gray: "Gray"
            case .dark: "Dark"
            }
        }
    }

    /// What the scroll wheel does over an image.
    enum WheelAction: String, CaseIterable, Identifiable {
        /// Next/previous image; hold Command to zoom.
        case navigate
        /// Zoom; hold Command to change image.
        case zoom
        var id: String { rawValue }
        var title: String { self == .navigate ? "Previous / next image" : "Zoom in / out" }
    }

    /// The surround behind the image in the viewer.
    enum ViewerBackground: String, CaseIterable, Identifiable {
        case black, darkGray, gray, white
        var id: String { rawValue }
        var title: String {
            switch self {
            case .black: "Black"
            case .darkGray: "Dark gray"
            case .gray: "Gray"
            case .white: "White"
            }
        }
        /// Linear-light grey level (what the canvas shader wants).
        var linearLevel: Float {
            switch self {
            case .black: 0
            case .darkGray: 0.012   // sRGB ~ 0.1
            case .gray: 0.133       // sRGB ~ 0.4
            case .white: 1
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    @Published var wheelAction: WheelAction { didSet { defaults.set(wheelAction.rawValue, forKey: Keys.wheelAction) } }
    /// Zoom inside the magnifier, relative to actual size (2 = 200%).
    @Published var magnifierZoom: Double { didSet { defaults.set(magnifierZoom, forKey: Keys.magnifierZoom) } }
    /// Magnifier radius in points.
    @Published var magnifierRadius: Double { didSet { defaults.set(magnifierRadius, forKey: Keys.magnifierRadius) } }
    /// Scale images smaller than the window up to fit it.
    @Published var enlargeSmallImages: Bool { didSet { defaults.set(enlargeSmallImages, forKey: Keys.enlargeSmall) } }
    /// Show crisp pixel squares when zoomed in past 200%.
    @Published var pixelatedZoom: Bool { didSet { defaults.set(pixelatedZoom, forKey: Keys.pixelatedZoom) } }
    @Published var viewerBackground: ViewerBackground { didSet { defaults.set(viewerBackground.rawValue, forKey: Keys.viewerBackground) } }
    /// Grid thumbnail size in points (square cell side).
    @Published var thumbnailSize: Double { didSet { defaults.set(thumbnailSize, forKey: Keys.thumbnailSize) } }
    @Published var sortOrder: FileSortOrder {
        didSet { defaults.set(try? JSONEncoder().encode(sortOrder), forKey: Keys.sortOrder) }
    }
    @Published var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: Keys.showHidden) } }
    /// Double-click / Return opens the viewer in full screen rather than a window.
    @Published var openViewerFullScreen: Bool { didSet { defaults.set(openViewerFullScreen, forKey: Keys.openFullScreen) } }
    /// Loop from the last image back to the first when navigating.
    @Published var wrapAround: Bool { didSet { defaults.set(wrapAround, forKey: Keys.wrapAround) } }
    /// Show HDR photos (gain maps, PQ, HLG) with highlights brighter than
    /// white, on screens that can. Off: they are tone mapped to SDR.
    @Published var showHDR: Bool {
        didSet { defaults.set(showHDR, forKey: Keys.showHDR); displaySettingsChanged() }
    }
    /// Render RAW files with extended dynamic range (from the sensor data).
    @Published var hdrRaw: Bool {
        didSet { defaults.set(hdrRaw, forKey: Keys.hdrRaw); displaySettingsChanged() }
    }
    /// How much of the RAW engine's extended range HDR RAW uses, 0...1. Not
    /// in Settings; `defaults write` it to tame RAW highlights.
    @Published var hdrRawAmount: Double {
        didSet { defaults.set(hdrRawAmount, forKey: Keys.hdrRawAmount); displaySettingsChanged() }
    }
    /// Embedded preview (fast) or a render of the sensor data for RAW files.
    @Published var rawDecoding: RawDecoding {
        didSet { defaults.set(rawDecoding.rawValue, forKey: Keys.rawDecoding); displaySettingsChanged() }
    }

    /// The decoding settings the image loader follows.
    var displaySettings: DisplaySettings {
        DisplaySettings(rawDecoding: rawDecoding, showHDR: showHDR, hdrRaw: hdrRaw,
                        hdrRawAmount: Float(min(max(hdrRawAmount, 0), 1)))
    }

    private init() {
        let d = UserDefaults.standard
        theme = Theme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        wheelAction = WheelAction(rawValue: d.string(forKey: Keys.wheelAction) ?? "") ?? .navigate
        magnifierZoom = d.object(forKey: Keys.magnifierZoom) as? Double ?? 2
        magnifierRadius = d.object(forKey: Keys.magnifierRadius) as? Double ?? 140
        enlargeSmallImages = d.bool(forKey: Keys.enlargeSmall)
        pixelatedZoom = d.object(forKey: Keys.pixelatedZoom) as? Bool ?? true
        viewerBackground = ViewerBackground(rawValue: d.string(forKey: Keys.viewerBackground) ?? "") ?? .black
        thumbnailSize = d.object(forKey: Keys.thumbnailSize) as? Double ?? 150
        sortOrder = (d.data(forKey: Keys.sortOrder)).flatMap { try? JSONDecoder().decode(FileSortOrder.self, from: $0) } ?? FileSortOrder()
        showHiddenFiles = d.bool(forKey: Keys.showHidden)
        openViewerFullScreen = d.object(forKey: Keys.openFullScreen) as? Bool ?? true
        wrapAround = d.bool(forKey: Keys.wrapAround)
        showHDR = d.object(forKey: Keys.showHDR) as? Bool ?? true
        hdrRaw = d.bool(forKey: Keys.hdrRaw)
        hdrRawAmount = d.object(forKey: Keys.hdrRawAmount) as? Double ?? 1
        rawDecoding = RawDecoding(rawValue: d.string(forKey: Keys.rawDecoding) ?? "") ?? .embeddedPreview
        // Before anything loads: the app delegate reads the theme at launch,
        // well ahead of the first image.
        ImageLoader.shared.settings = displaySettings
    }

    /// Hands the new settings to the loader, which empties its texture
    /// cache, then tells the image views to reload.
    private func displaySettingsChanged() {
        let settings = displaySettings
        guard ImageLoader.shared.settings != settings else { return }
        ImageLoader.shared.settings = settings
        NotificationCenter.default.post(name: .minivuDisplaySettingsChanged, object: self)
    }

    enum Keys {
        static let theme = "theme"
        static let wheelAction = "wheelAction"
        static let magnifierZoom = "magnifierZoom"
        static let magnifierRadius = "magnifierRadius"
        static let enlargeSmall = "enlargeSmallImages"
        static let pixelatedZoom = "pixelatedZoom"
        static let viewerBackground = "viewerBackground"
        static let thumbnailSize = "thumbnailSize"
        static let sortOrder = "sortOrder"
        static let showHidden = "showHiddenFiles"
        static let openFullScreen = "openViewerFullScreen"
        static let wrapAround = "wrapAround"
        static let showHDR = "showHDR"
        static let hdrRaw = "hdrRaw"
        static let hdrRawAmount = "hdrRawAmount"
        static let rawDecoding = "rawDecoding"
    }
}
