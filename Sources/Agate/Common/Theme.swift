import AppKit

/// Bright, Gray and Dark themes (DESIGN.md 5).
///
/// Bright and Dark are the system's own Aqua and Dark Aqua appearances, so
/// every standard control already looks right. Gray is Dark Aqua with
/// lighter surfaces: views that paint their own background use the dynamic
/// colours below, which read the current theme when they are drawn.
enum ThemeColors {
    /// The theme last passed to `apply`, which the dynamic colours read.
    ///
    /// Not `Preferences.shared.theme`: `apply` is called from a `$theme`
    /// subscriber, and `@Published` notifies before the property changes,
    /// so the preference still holds the old theme while views react to
    /// the new appearance.
    private(set) static var current: Preferences.Theme = .system

    /// Applies `theme` app-wide. Call on launch and whenever it changes.
    static func apply(_ theme: Preferences.Theme) {
        current = theme
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .gray, .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // Gray and Dark share an appearance, so switching between them gives
        // views no appearance change: every view is asked to redraw instead.
        // Only on a theme change, and only views that exist, so it's cheap.
        for window in NSApp.windows {
            if let root = window.contentView?.superview ?? window.contentView { redraw(root) }
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    private static var isGray: Bool { current == .gray }

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
