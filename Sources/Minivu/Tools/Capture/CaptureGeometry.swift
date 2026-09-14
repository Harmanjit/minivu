import CoreGraphics
import Foundation
import MinivuCore

/// A screen as the capture code needs it, taken from `NSScreen` so the
/// geometry can be tested with made-up arrangements of displays.
nonisolated struct CaptureScreen: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    /// In AppKit's global coordinates: points, origin at the bottom left of
    /// the main screen, y upwards. Other screens can be left of or below it
    /// (negative origins).
    var frame: CGRect
    var scale: CGFloat

    var pixelSize: CGSize { MontageOutput.pixelSize(points: frame.size, backingScale: scale) }
}

/// The arithmetic between AppKit's screen coordinates, ScreenCaptureKit's
/// and pixels, kept apart from windows so it can be tested exactly.
nonisolated enum CaptureGeometry {
    /// ScreenCaptureKit's `sourceRect` for a rectangle in global AppKit
    /// coordinates on `screen`: points relative to that display's top left,
    /// with y downwards.
    static func sourceRect(for rect: CGRect, on screen: CaptureScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rectangle's size in the display's pixels.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: max(1, (rect.width * scale).rounded()), height: max(1, (rect.height * scale).rounded()))
    }

    /// The screen a point (global coordinates) is on; the screen under the
    /// pointer is the one Entire Screen captures. A point on no screen (it
    /// can sit exactly on an outer edge) picks the nearest.
    static func screen(containing point: CGPoint, in screens: [CaptureScreen]) -> CaptureScreen? {
        if let hit = screens.first(where: { $0.frame.contains(point) }) { return hit }
        return screens.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// The dragged rectangle between two points in an overlay view, kept on
    /// the view (a drag may leave the screen) and snapped outwards to whole
    /// pixels, so the size label and the capture agree.
    static func selection(from start: CGPoint, to end: CGPoint, bounds: CGRect, scale: CGFloat) -> CGRect {
        let clamp = { (p: CGPoint) in
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let a = clamp(start), b = clamp(end)
        let scale = max(scale, 1)
        let minX = (min(a.x, b.x) * scale).rounded(.down) / scale
        let minY = (min(a.y, b.y) * scale).rounded(.down) / scale
        let maxX = (max(a.x, b.x) * scale).rounded(.up) / scale
        let maxY = (max(a.y, b.y) * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Too small to be meant: a click without a drag.
    static func isUsable(_ rect: CGRect) -> Bool {
        rect.width >= 4 && rect.height >= 4
    }

    /// "1200 × 800": the selection in pixels, as the capture will be.
    static func sizeLabel(for rect: CGRect, scale: CGFloat) -> String {
        let size = pixelSize(of: rect, scale: scale)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// Where the size label goes (view coordinates, y up): just below the
    /// selection's bottom right corner, moved inside the view when that
    /// would put it off screen, or inside the selection's bottom edge when
    /// there is no room below.
    static func labelFrame(for selection: CGRect, labelSize: CGSize, bounds: CGRect, margin: CGFloat = 8) -> CGRect {
        var x = selection.maxX - labelSize.width
        var y = selection.minY - margin - labelSize.height
        if y < bounds.minY + margin { y = selection.minY + margin }
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - labelSize.width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - labelSize.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
    }
}

/// Names and places for captures.
nonisolated enum CaptureFiles {
    static let folderName = "minivu Captures"

    /// "Capture 2026-09-14 at 10.30.05.png"
    static func fileName(date: Date, timeZone: TimeZone = .current) -> String {
        "Capture \(MontageOutput.timestamp(date, timeZone: timeZone)).png"
    }
}
