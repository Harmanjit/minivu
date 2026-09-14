import AppKit

/// Bright, Gray and Dark themes (DESIGN.md 5).
///
/// Bright and Dark are the system's own Aqua and Dark Aqua appearances, so
/// every standard control already looks right. Gray is Dark Aqua with
/// lighter surfaces: views that paint their own background use the dynamic
/// colours below, which read the current theme when they are drawn.
enum ThemeColors {
    /// Applies `theme` app-wide. Call on launch and whenever it changes.
    static func apply(_ theme: Preferences.Theme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .gray, .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // Views using the dynamic colours need a redraw to pick up Gray vs Dark,
        // which share an appearance.
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.contentView?.subviews.forEach { $0.needsDisplay = true }
        }
    }

    private static var isGray: Bool { Preferences.shared.theme == .gray }

    /// Background behind the thumbnail grid and other content areas.
    static let contentBackground = NSColor(name: "agate.content") { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua { return .textBackgroundColor }
        return isGray ? NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 1)
                      : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    }

    /// Selected thumbnail cell fill.
    static let selectionFill = NSColor(name: "agate.selection") { _ in
        NSColor.controlAccentColor.withAlphaComponent(0.35)
    }

    /// Unselected thumbnail cell hover fill.
    static let hoverFill = NSColor(name: "agate.hover") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor.black.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.08)
    }
}
