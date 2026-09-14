import Foundation
import CoreImage

// PLACEHOLDER: the vector drawing layer (text, lines and arrows, highlight,
// rectangles, ovals, callouts). The annotations work package fills it in.

public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

enum AnnotationGraph {
    /// Draws `objects` over `image` (the working image for an output of
    /// `fullSize` at `scale`).
    static func apply(_ objects: [Annotation], to image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        image
    }
}
