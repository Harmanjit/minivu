import Foundation
import CoreImage

// PLACEHOLDER: clone stamp, healing brush and red-eye removal. The retouch
// work package fills these in.

public struct RetouchStroke: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case clone, heal }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
    public var isIdentity: Bool { false }
}

public struct RedEyeSpot: Codable, Hashable, Sendable {
    public init() {}
}

enum RetouchGraph {
    static func apply(_ strokes: [RetouchStroke], to image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        image
    }

    static func removeRedEye(_ spots: [RedEyeSpot], in image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        image
    }
}
