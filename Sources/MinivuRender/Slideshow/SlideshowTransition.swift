import Foundation

/// The eight ways one slide gives way to the next (DESIGN.md 5, Tools).
///
/// The raw values are stored in settings, so they must never change; the
/// order of the cases is the shader's transition index
/// (`slideshowFragment` in Slideshow.metal), so a new case goes at the end.
public enum SlideshowTransition: String, Codable, CaseIterable, Sendable, Identifiable {
    case crossFade
    case fadeThroughBlack
    /// The new slide moves in over the old one.
    case slide
    /// The new slide pushes the old one out.
    case push
    /// A soft edge sweeps across.
    case wipe
    /// The old slide grows and fades while the new one settles from slightly smaller.
    case zoom
    /// A circle opens from the centre.
    case iris
    /// Blotches of the new slide appear and merge.
    case dissolve

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .crossFade: "Cross-Fade"
        case .fadeThroughBlack: "Fade Through Black"
        case .slide: "Slide"
        case .push: "Push"
        case .wipe: "Wipe"
        case .zoom: "Zoom"
        case .iris: "Iris"
        case .dissolve: "Dissolve"
        }
    }

    /// The index `slideshowFragment` switches on.
    var shaderIndex: Int { Self.allCases.firstIndex(of: self)! }

    /// A transition for the next slide in random mode: any of the eight but
    /// `previous`, so two slides in a row never change the same way.
    public static func random(after previous: SlideshowTransition?,
                              using generator: inout some RandomNumberGenerator) -> SlideshowTransition {
        let choices = allCases.filter { $0 != previous }
        return choices.randomElement(using: &generator)!
    }

    public static func random(after previous: SlideshowTransition?) -> SlideshowTransition {
        var generator = SystemRandomNumberGenerator()
        return random(after: previous, using: &generator)
    }
}

/// Which way the slideshow is moving, for transitions with a direction:
/// forward, the new slide arrives from the right; backward, from the left.
public enum SlideshowDirection: Sendable, Equatable {
    case forward, backward
}

/// Timing curves for transitions.
public enum SlideshowEasing {
    /// Slow in and out, symmetric (smoothstep): 0, ½ and 1 map to
    /// themselves, so a transition half way through in time is half way
    /// through on screen, and a cross-fade's midpoint is an even mix.
    public static func easeInOut(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
