import Foundation
import CoreGraphics

/// One of nine places in a rectangle: where Canvas Size keeps the image and
/// where a watermark goes.
public enum EditAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// 0 at the left, 0.5 in the middle, 1 at the right.
    public var x: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: 0
        case .top, .center, .bottom: 0.5
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// 0 at the top, 0.5 in the middle, 1 at the bottom.
    public var y: Double {
        switch self {
        case .topLeft, .top, .topRight: 0
        case .left, .center, .right: 0.5
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }

    /// For the anchor grid's VoiceOver labels and menus.
    public var title: String {
        switch self {
        case .topLeft: localized(.init("Top Left", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .top: localized(.init("Top", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .topRight: localized(.init("Top Right", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .left: localized(.init("Left", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .center: localized(.init("Center", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .right: localized(.init("Right", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .bottomLeft: localized(.init("Bottom Left", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .bottom: localized(.init("Bottom", comment: "Canvas anchor: where the picture sits on the new canvas"))
        case .bottomRight: localized(.init("Bottom Right", comment: "Canvas anchor: where the picture sits on the new canvas"))
        }
    }
}

/// A new canvas: the image kept at full resolution, placed at `anchor` on a
/// canvas of exactly `width` x `height` pixels filled with `fill`. A larger
/// canvas adds borders; a smaller one crops about the anchor.
public struct CanvasSize: Codable, Hashable, Sendable {
    /// The largest side accepted, the cap Resize and Batch Convert use.
    public static let maximumSide = 32768

    public var width: Int
    public var height: Int
    public var anchor = EditAnchor.center
    /// Alpha 0 is transparent, which only formats with alpha keep (others
    /// flatten it when saving).
    public var fill = EditColor.white

    public init(width: Int, height: Int, anchor: EditAnchor = .center, fill: EditColor = .white) {
        self.width = width
        self.height = height
        self.anchor = anchor
        self.fill = fill
    }

    private enum CodingKeys: String, CodingKey { case width, height, anchor, fill }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        anchor = try c.effectsValue(.anchor, default: .center)
        fill = try c.effectsValue(.fill, default: .white)
    }

    /// A canvas that can't be made. Whether it matches the image's own size
    /// isn't known here (the operation doesn't know its input); the sheet
    /// refuses an unchanged size, as Resize does.
    public var isIdentity: Bool {
        width <= 0 || height <= 0 || width > Self.maximumSide || height > Self.maximumSide
    }

    /// Where the image's top-left corner goes on the canvas, in whole pixels
    /// of the full-resolution image (negative when the canvas is smaller
    /// and the image is cropped). Rounded down, so when a centred image's
    /// border can't be split evenly the odd pixel goes to the right or the
    /// bottom.
    public func photoOrigin(photoWidth: Int, photoHeight: Int) -> (x: Int, y: Int) {
        func offset(_ spare: Int, _ fraction: Double) -> Int {
            Int((Double(spare) * fraction).rounded(.down))
        }
        return (offset(width - photoWidth, anchor.x), offset(height - photoHeight, anchor.y))
    }
}
