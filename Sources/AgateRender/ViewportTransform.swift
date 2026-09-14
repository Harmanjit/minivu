import Foundation
import CoreGraphics
import simd

/// Where an image sits on screen: how large, and which part is centred.
///
/// Two numbers describe every zoom and pan state:
///
/// - `zoom`: screen (device) pixels per image pixel. 1.0 is "actual size":
///   one image pixel per screen pixel.
/// - `center`: the image point shown at the centre of the view.
///
/// Screen coordinates are device pixels with a top-left origin, matching
/// the Metal drawable. Image coordinates are pixels of the oriented image,
/// also top-left. Adapted from Latent's ViewportTransform, minus the sensor
/// and crop concepts a viewer doesn't need.
public struct ViewportTransform: Equatable, Sendable {
    public var zoom: CGFloat
    public var center: CGPoint

    /// 32x: individual pixels become large squares; nothing more to see.
    public static let maximumZoom: CGFloat = 32
    /// Smallest zoom allowed when zooming out past fit.
    public static let minimumZoom: CGFloat = 0.02

    public init(zoom: CGFloat, center: CGPoint) {
        self.zoom = zoom
        self.center = center
    }

    // MARK: - Fit

    /// The zoom that shows the whole image as large as the view allows.
    public static func fitZoom(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// "Best fit": the whole image, centred. Small images are shown at
    /// actual size rather than blown up, unless `enlargeSmall` is set.
    public static func bestFit(imageSize: CGSize, viewSize: CGSize, enlargeSmall: Bool = false) -> ViewportTransform {
        var z = fitZoom(imageSize: imageSize, viewSize: viewSize)
        if !enlargeSmall { z = min(z, 1) }
        return ViewportTransform(zoom: z, center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }

    /// Actual size, keeping the image point under `screenPoint` where it is.
    public func actualSize(about screenPoint: CGPoint, viewSize: CGSize) -> ViewportTransform {
        zoomed(by: 1 / zoom, about: screenPoint, viewSize: viewSize)
    }

    // MARK: - Mapping

    public func screenPoint(forImagePoint p: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * zoom + viewSize.width / 2,
                y: (p.y - center.y) * zoom + viewSize.height / 2)
    }

    public func imagePoint(forScreenPoint p: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - viewSize.width / 2) / zoom + center.x,
                y: (p.y - viewSize.height / 2) / zoom + center.y)
    }

    /// Where the image rectangle lands on screen.
    public func screenRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        let origin = screenPoint(forImagePoint: .zero, viewSize: viewSize)
        return CGRect(x: origin.x, y: origin.y, width: imageSize.width * zoom, height: imageSize.height * zoom)
    }

    /// The part of the image currently visible (may extend past the edges).
    public func visibleImageRect(viewSize: CGSize) -> CGRect {
        let tl = imagePoint(forScreenPoint: .zero, viewSize: viewSize)
        return CGRect(x: tl.x, y: tl.y, width: viewSize.width / zoom, height: viewSize.height / zoom)
    }

    /// The affine map the shader uses: screen pixel -> normalised texture
    /// coordinate (0...1 across the image). Column-major 3x2, as Metal's
    /// `float3x2`: uv = M * (x, y, 1).
    public func screenToUV(imageSize: CGSize, viewSize: CGSize) -> simd_float3x2 {
        guard imageSize.width > 0, imageSize.height > 0, zoom > 0 else { return simd_float3x2() }
        // u = ((x - vw/2) / zoom + cx) / iw
        let sx = Float(1 / (zoom * imageSize.width))
        let sy = Float(1 / (zoom * imageSize.height))
        let tx = Float((-viewSize.width / 2 / zoom + center.x) / imageSize.width)
        let ty = Float((-viewSize.height / 2 / zoom + center.y) / imageSize.height)
        return simd_float3x2(columns: (SIMD2(sx, 0), SIMD2(0, sy), SIMD2(tx, ty)))
    }

    // MARK: - Gestures

    /// Zooms by `factor`, keeping the image point under `screenPoint` fixed.
    public func zoomed(by factor: CGFloat, about screenPoint: CGPoint, viewSize: CGSize) -> ViewportTransform {
        let anchor = imagePoint(forScreenPoint: screenPoint, viewSize: viewSize)
        let newZoom = zoom * factor
        let newCenter = CGPoint(x: anchor.x - (screenPoint.x - viewSize.width / 2) / newZoom,
                                y: anchor.y - (screenPoint.y - viewSize.height / 2) / newZoom)
        return ViewportTransform(zoom: newZoom, center: newCenter)
    }

    /// Moves the content by a screen delta (content follows the pointer).
    public func panned(by d: CGSize) -> ViewportTransform {
        ViewportTransform(zoom: zoom, center: CGPoint(x: center.x - d.width / zoom, y: center.y - d.height / zoom))
    }

    /// Keeps the state sensible: zoom within limits, and the image never
    /// panned off screen. An axis narrower than the view is centred.
    public func clamped(imageSize: CGSize, viewSize: CGSize) -> ViewportTransform {
        let fit = Self.fitZoom(imageSize: imageSize, viewSize: viewSize)
        let z = min(max(zoom, min(Self.minimumZoom, fit)), Self.maximumZoom)
        let halfW = viewSize.width / z / 2
        let halfH = viewSize.height / z / 2
        func axis(_ v: CGFloat, _ half: CGFloat, _ extent: CGFloat) -> CGFloat {
            half >= extent / 2 ? extent / 2 : min(max(v, half), extent - half)
        }
        return ViewportTransform(zoom: z, center: CGPoint(x: axis(center.x, halfW, imageSize.width),
                                                          y: axis(center.y, halfH, imageSize.height)))
    }

    /// True when the whole image is visible.
    public func showsWholeImage(imageSize: CGSize, viewSize: CGSize) -> Bool {
        zoom <= Self.fitZoom(imageSize: imageSize, viewSize: viewSize) + 1e-6
    }
}
