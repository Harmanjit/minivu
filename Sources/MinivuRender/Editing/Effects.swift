import Foundation
import CoreImage

// PLACEHOLDER: payloads and a pass-through graph for the Phase 6 effects.
// The effects work package fills these in. Parameters are in normalised or
// full-resolution units, as for every other operation (DESIGN.md 4.7);
// new fields must decode with defaults so saved documents keep loading.

/// An sRGB colour with alpha, 0...1.
public struct EditColor: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = EditColor(red: 0, green: 0, blue: 0)
    public static let white = EditColor(red: 1, green: 1, blue: 1)
}

public struct DropShadow: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

public struct FrameStyle: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

public struct BumpMap: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

public struct Sketch: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

public struct OilPaint: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

public struct LensEffect: Codable, Hashable, Sendable {
    public init() {}
    public var isIdentity: Bool { false }
}

enum EffectsGraph {
    /// Size after a shadow or frame (which add margins); others keep it.
    static func fullSize(after op: EditOperation, from size: EditGraph.Size) -> EditGraph.Size {
        size
    }

    /// `outputWidth`/`outputHeight` are the working-image size the result
    /// must have (`EditGraph.workingLength` of `fullSize(after:)`).
    static func apply(_ op: EditOperation, to image: CIImage, outputWidth: Int, outputHeight: Int,
                      scale: Double) -> CIImage {
        image
    }
}
