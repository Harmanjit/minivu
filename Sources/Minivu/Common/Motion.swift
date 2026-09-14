import AppKit

/// System Settings > Accessibility > Display > Reduce Motion and Increase
/// Contrast, read where they are used, so a change applies to the next
/// panel that opens or slide that changes without relaunching.
enum Motion {
    /// Panels fade in place rather than slide, and slideshow transitions
    /// that move the picture become cross-fades.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

enum Contrast {
    /// Selections and marks get solid outlines as well as tinted fills.
    static var isIncreased: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}
