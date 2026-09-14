import Foundation
import CoreGraphics
import CoreImage

/// One object of the drawing layer: text, a line or arrow, a highlighter
/// mark, a rectangle, an oval or a callout (DESIGN.md 4.7).
///
/// **Geometry** is normalised to the image as it is at the operation's place
/// in the list (top-left origin), like a crop: `frame` for boxes, text and
/// callouts, `start` and `end` for lines and arrows, `tailPoint` for a
/// callout's tail. `rotation` turns boxes and text clockwise about their
/// centre. Normalised positions need no scaling on a proxy.
///
/// **Lengths** are fractions of the image, not pixels, so a drawing keeps its
/// look at every resolution: `strokeWidth` of the image's short side,
/// `fontSize` of its height. Rotation happens in pixel space, so a turned
/// square stays square on a non-square image.
///
/// **Colours** are sRGB (`EditColor`); an alpha of 0 means "none" (no fill,
/// no outline). Every field decodes with its kind's default when missing, so
/// documents saved before a field existed keep loading.
public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, line, arrow, highlight, rectangle, oval, callout

        /// Lines and arrows are two points; everything else is a box.
        public var isLine: Bool { self == .line || self == .arrow }
        public var hasText: Bool { self == .text || self == .callout }
        /// Callouts don't turn: their tail points at a place in the image.
        public var canRotate: Bool { !isLine && self != .callout }

        public var title: String {
            switch self {
            case .text: "Text"
            case .line: "Line"
            case .arrow: "Arrow"
            case .highlight: "Highlight"
            case .rectangle: "Rectangle"
            case .oval: "Oval"
            case .callout: "Callout"
            }
        }
    }

    public enum Dash: String, Codable, CaseIterable, Sendable {
        case solid, dashed, dotted
    }

    public enum Arrowheads: String, Codable, CaseIterable, Sendable {
        case none, end, both
    }

    public enum Alignment: String, Codable, CaseIterable, Sendable {
        case left, center, right
    }

    public enum FontWeight: String, Codable, CaseIterable, Sendable {
        case light, regular, medium, semibold, bold, heavy

        /// Core Text's weight trait, -1...1.
        public var trait: Double {
            switch self {
            case .light: -0.4
            case .regular: 0
            case .medium: 0.23
            case .semibold: 0.3
            case .bold: 0.4
            case .heavy: 0.56
            }
        }

        public var title: String { rawValue.capitalized }
    }

    /// The family name that means the system font (San Francisco), which has
    /// no public family name of its own.
    public static let systemFontFamily = "System"

    public var id: UUID
    public var kind: Kind
    public var frame: CGRect
    public var start: CGPoint
    public var end: CGPoint
    public var tailPoint: CGPoint
    /// Degrees, clockwise on screen.
    public var rotation: Double
    public var strokeColor: EditColor
    public var fillColor: EditColor
    /// A fraction of the image's short side.
    public var strokeWidth: Double
    public var dash: Dash
    public var arrowheads: Arrowheads
    /// Arrowhead length in stroke widths.
    public var arrowheadSize: Double
    /// 0...1, for the whole object (fill, outline and text together).
    public var opacity: Double
    public var shadow: Bool
    public var text: String
    public var fontFamily: String
    public var fontWeight: FontWeight
    /// A fraction of the image's height.
    public var fontSize: Double
    public var alignment: Alignment
    public var textColor: EditColor
    /// Drawn around the letters, for legibility over a busy photo; alpha 0
    /// for none. (A text object's background is its `fillColor`.)
    public var textOutlineColor: EditColor
    /// The editor keeps the frame's height fitted to the text as it changes.
    public var autoresizesHeight: Bool

    /// An object of `kind` with that kind's defaults.
    public init(kind: Kind = .rectangle, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        frame = CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.3)
        start = CGPoint(x: 0.3, y: 0.5)
        end = CGPoint(x: 0.7, y: 0.5)
        tailPoint = CGPoint(x: 0.25, y: 0.85)
        rotation = 0
        strokeColor = EditColor(red: 1, green: 0.231, blue: 0.188)   // system red
        fillColor = EditColor(red: 1, green: 1, blue: 1, alpha: 0)
        strokeWidth = 0.006
        dash = .solid
        arrowheads = .none
        arrowheadSize = 4
        opacity = 1
        shadow = false
        text = ""
        fontFamily = Self.systemFontFamily
        fontWeight = .semibold
        fontSize = 0.05
        alignment = .left
        textColor = .white
        textOutlineColor = EditColor(red: 0, green: 0, blue: 0, alpha: 0)
        autoresizesHeight = true
        switch kind {
        case .arrow:
            arrowheads = .end
        case .highlight:
            // A highlighter multiplies, so an opaque yellow already lets the
            // picture show through.
            fillColor = EditColor(red: 1, green: 0.9, blue: 0.2)
            strokeColor = EditColor(red: 0, green: 0, blue: 0, alpha: 0)
            strokeWidth = 0
            frame = CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.1)
        case .text:
            strokeColor = EditColor(red: 0, green: 0, blue: 0, alpha: 0)
            strokeWidth = 0
            shadow = true
            frame = CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.1)
        case .callout:
            fillColor = .white
            strokeColor = .black
            strokeWidth = 0.003
            textColor = .black
            fontWeight = .medium
            alignment = .center
            frame = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.15)
        case .line, .rectangle, .oval:
            break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, start, end, tailPoint, rotation, strokeColor, fillColor, strokeWidth, dash, arrowheads,
             arrowheadSize, opacity, shadow, text, fontFamily, fontWeight, fontSize, alignment, textColor,
             textOutlineColor, autoresizesHeight
    }

    /// Missing keys take the kind's defaults. So do enum values this version
    /// doesn't know (a dash style or weight added later): one unfamiliar
    /// word shouldn't make a whole document fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .rectangle
        let d = Annotation(kind: kind, id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID())
        self = d
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame) ?? d.frame
        start = try c.decodeIfPresent(CGPoint.self, forKey: .start) ?? d.start
        end = try c.decodeIfPresent(CGPoint.self, forKey: .end) ?? d.end
        tailPoint = try c.decodeIfPresent(CGPoint.self, forKey: .tailPoint) ?? d.tailPoint
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? d.rotation
        strokeColor = try c.decodeIfPresent(EditColor.self, forKey: .strokeColor) ?? d.strokeColor
        fillColor = try c.decodeIfPresent(EditColor.self, forKey: .fillColor) ?? d.fillColor
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        dash = (try? c.decodeIfPresent(Dash.self, forKey: .dash)) ?? d.dash
        arrowheads = (try? c.decodeIfPresent(Arrowheads.self, forKey: .arrowheads)) ?? d.arrowheads
        arrowheadSize = try c.decodeIfPresent(Double.self, forKey: .arrowheadSize) ?? d.arrowheadSize
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontWeight = (try? c.decodeIfPresent(FontWeight.self, forKey: .fontWeight)) ?? d.fontWeight
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        alignment = (try? c.decodeIfPresent(Alignment.self, forKey: .alignment)) ?? d.alignment
        textColor = try c.decodeIfPresent(EditColor.self, forKey: .textColor) ?? d.textColor
        textOutlineColor = try c.decodeIfPresent(EditColor.self, forKey: .textOutlineColor) ?? d.textOutlineColor
        autoresizesHeight = try c.decodeIfPresent(Bool.self, forKey: .autoresizesHeight) ?? d.autoresizesHeight
    }
}

// MARK: - Pixel geometry

/// Everything here is in pixels of an image `size` (top-left origin), the
/// space both the graph and the editor's overlay draw in.
extension Annotation {
    public func pixelPoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    /// `frame` in pixels, standardised.
    public func pixelRect(in size: CGSize) -> CGRect {
        let r = frame.standardized
        return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width,
                      height: r.height * size.height)
    }

    public func strokePixelWidth(in size: CGSize) -> CGFloat {
        let w = strokeWidth.isFinite ? max(strokeWidth, 0) : 0
        return CGFloat(w) * min(size.width, size.height)
    }

    public func fontPixelSize(in size: CGSize) -> CGFloat {
        let s = fontSize.isFinite ? min(max(fontSize, 0.001), 2) : 0.05
        return CGFloat(s) * size.height
    }

    /// From the box's own coordinates (origin at its centre, unrotated) to
    /// image pixels. Lines have no box: identity.
    public func boxTransform(in size: CGSize) -> CGAffineTransform {
        guard !kind.isLine else { return .identity }
        let r = pixelRect(in: size)
        var t = CGAffineTransform(translationX: r.midX, y: r.midY)
        if kind.canRotate, rotation.isFinite, rotation != 0 {
            // y points down, so a positive angle turns clockwise on screen.
            t = t.rotated(by: CGFloat(rotation * .pi / 180))
        }
        return t
    }

    /// The box centred on the origin, in its own coordinates.
    public func localBox(in size: CGSize) -> CGRect {
        let r = pixelRect(in: size)
        return CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
    }

    public var clampedOpacity: CGFloat {
        CGFloat(opacity.isFinite ? min(max(opacity, 0), 1) : 1)
    }

    /// The drop shadow's darkness: black at this alpha where the object is
    /// opaque.
    public static let shadowAlpha: CGFloat = 0.5

    /// Offset (down and to the right) and blur of the drop shadow, in pixels.
    /// The blur is Core Graphics' measure, about twice the Gaussian's
    /// standard deviation.
    public func shadowGeometry(in size: CGSize) -> (offset: CGSize, blur: CGFloat) {
        let k = max(1.5, min(size.width, size.height) * 0.004)
        return (CGSize(width: k * 0.5, height: k), k * 2.5)
    }

    /// Everything the object paints, in pixels: stroke, arrowheads, a
    /// callout's tail, a text outline and the shadow. Culling, tiles and the
    /// overlay's redraw regions rely on it, so it errs on the large side.
    public func paintedBounds(in size: CGSize, includingShadow: Bool = true) -> CGRect {
        let w = strokePixelWidth(in: size)
        var r: CGRect
        if kind.isLine {
            let a = pixelPoint(start, in: size), b = pixelPoint(end, in: size)
            r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let head = arrowheads == .none ? 0 : AnnotationRenderer.arrowheadLength(self, in: size)
            r = r.insetBy(dx: -(w + head), dy: -(w + head))
        } else {
            // Text may reach a tenth of the font size past the box (the
            // renderer clips it there). That margin is in the box's own,
            // possibly turned, coordinates, so it goes on before turning.
            let margin = w + (kind.hasText ? fontPixelSize(in: size) * 0.1 : 0)
            let box = localBox(in: size).insetBy(dx: -margin, dy: -margin)
            let t = boxTransform(in: size)
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { $0.applying(t) }
            r = Self.boundingRect(corners)
            if kind == .callout {
                r = r.union(CGRect(origin: pixelPoint(tailPoint, in: size), size: .zero).insetBy(dx: -2 * w, dy: -2 * w))
            }
        }
        if shadow && includingShadow {
            let s = shadowGeometry(in: size)
            r = r.union(r.offsetBy(dx: s.offset.width, dy: s.offset.height).insetBy(dx: -s.blur * 1.5, dy: -s.blur * 1.5))
        }
        // Antialiasing reaches a pixel past any edge.
        return r.insetBy(dx: -2, dy: -2)
    }

    static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Graph

/// Draws annotations over the working image (DESIGN.md 4.7).
///
/// **Vector at every resolution.** The objects are drawn with Core Graphics
/// and Core Text at the working image's own size, so a proxy gets a
/// proxy-sized drawing and an export a full-resolution one: text and edges
/// are crisp at every size, never a scaled bitmap.
///
/// **Tiles.** Each drawing is a `CIImage` backed by an image provider rather
/// than one big bitmap: Core Image asks for tiles of it (1024 px) as it
/// renders, and each tile draws only the objects that reach into it. So an
/// output larger than a texture (above 16384 px) is never drawn in one
/// piece, and memory stays at a few tiles. Small tiles also suit exports:
/// Core Image renders a large output in pieces and asks again for the
/// provider tiles each piece touches (the context keeps no intermediates),
/// and with 4096 px tiles a 24 MP export drew 570 MP of tiles, 280 ms, where
/// 1024 px tiles draw 66 MP in 32 ms.
///
/// **Colour.** Tiles are 8-bit sRGB (annotation colours are sRGB, so nothing
/// is lost), premultiplied; Core Image converts them to the working space,
/// extended linear Display P3, and composites there. Source-over leaves
/// every pixel under a transparent region exactly as it was, HDR highlights
/// and wide-gamut values included.
///
/// **Layers.** Objects are drawn in layers (see `groups`), stacked in list
/// order: ordinary objects composite source-over and highlights multiply,
/// with a kernel of our own, since the result must not clamp. So a
/// highlight over a rectangle darkens the rectangle too, and overlapping
/// highlights multiply each other, as marker strokes do.
///
/// **Shadows blur on the GPU.** A Core Graphics shadow is a CPU blur: 7
/// shadowed objects of 20 took a 3024 px drawing from 3 ms to 37 ms (release;
/// blurring a small bitmap and scaling it up still took 17 ms, most of it
/// Core Graphics resampling). Under each layer goes the shadow of its
/// shadowed objects: their silhouettes drawn once more, turned into
/// translucent black, blurred with `CIGaussianBlur` and offset. A layer
/// never holds an object whose shadow would fall on an earlier object of
/// the same layer, so every shadow still lands exactly where list order
/// puts it. One approximation remains: shadows of one layer that overlap
/// each other merge like one silhouette's (half black) instead of darkening
/// each other, as the overlay's per-object Core Graphics shadows do while an
/// object is dragged.
///
/// **Measured** (debug build, `AnnotationGraphTests`), 20 objects of every
/// kind with labels, 7 of them shadowed:
///
///     Core Graphics drawing into a 3024 x 2016 tile     3 ms (release: 3 ms)
///     proxy render at 3024 px, composite and mips       22 ms (3.6 ms without the drawing)
///     24 MP export into an 8-bit sRGB CGImage           80 ms (36 ms without the drawing)
///
/// Previews render only when a drag starts or ends or a property changes;
/// the objects under the pointer are drawn by the editor's overlay.
enum AnnotationGraph {
    /// Tile edge the image providers are asked in. Tests make it small to
    /// check that tiles join seamlessly.
    nonisolated(unsafe) static var tileSize = 1024

    /// Draws `objects` over `image` (the working image for an output of
    /// `fullSize` at `scale`). The drawing is sized from the image's own
    /// extent, which is `EditGraph.workingLength` of `fullSize`.
    static func apply(_ objects: [Annotation], to image: CIImage, fullSize: EditGraph.Size, scale: Double) -> CIImage {
        let width = image.extent.width.rounded(), height = image.extent.height.rounded()
        guard !objects.isEmpty, width > 0, height > 0 else { return image }
        let size = CGSize(width: width, height: height)
        let canvas = CGRect(origin: .zero, size: size)
        var result = image
        for group in groups(objects, in: size) {
            let casters = group.objects.filter(\.shadow)
            if !casters.isEmpty, let shadow = shadow(of: casters, size: size, canvas: canvas) {
                result = shadow.composited(over: result)
            }
            guard let layer = layer(group.objects, size: size, region: group.bounds.intersection(canvas)) else { continue }
            result = group.multiplies ? multiply(layer, over: result) : layer.composited(over: result)
        }
        return result.cropped(to: image.extent)
    }

    /// `objects` drawn (without shadows) into a provider-backed image of
    /// `region` (image pixels), placed in the working image's coordinates.
    private static func layer(_ objects: [Annotation], size: CGSize, region: CGRect) -> CIImage? {
        let bounds = region.integral
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let provider = AnnotationTileProvider(objects: objects, imageSize: size, region: bounds)
        return CIImage(imageProvider: provider, size: Int(bounds.width), Int(bounds.height), format: .BGRA8,
                       colorSpace: AnnotationRenderer.sRGB, options: [.providerTileSize: tileSize])
            // Providers fill rows top first; Core Image's y points up.
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: size.height - bounds.maxY))
    }

    /// The drop shadow of `casters`: their coverage as translucent black,
    /// blurred and offset down and to the right. The silhouettes reach past
    /// the picture by the blur, so a shadow falls in from an object partly
    /// outside it.
    private static func shadow(of casters: [Annotation], size: CGSize, canvas: CGRect) -> CIImage? {
        let geometry = casters[0].shadowGeometry(in: size)
        let reach = geometry.blur * 2
        let region = casters.reduce(CGRect.null) { $0.union($1.paintedBounds(in: size, includingShadow: false)) }
            .intersection(canvas.insetBy(dx: -reach, dy: -reach))
        guard let coverage = layer(casters, size: size, region: region) else { return nil }
        return coverage
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: Annotation.shadowAlpha),
            ])
            // Core Image's radius is about the standard deviation, Core
            // Graphics' blur (which the overlay uses) about twice it
            // (measured: blur 20, sigma 9).
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: geometry.blur * 0.45])
            .transformed(by: CGAffineTransform(translationX: geometry.offset.width, y: -geometry.offset.height))
            .cropped(to: canvas)
    }

    /// Objects drawn into one layer.
    struct Group {
        var multiplies: Bool
        var objects: [Annotation]
        /// Each object's painted bounds without its shadow, in image pixels.
        var objectBounds: [CGRect]
        /// Their union.
        var bounds: CGRect
        /// Their areas, summed.
        var area: CGFloat
    }

    /// Consecutive objects that composite the same way share a layer, in list
    /// order. Every layer costs Core Image a texture per tile and a pass, so
    /// objects share one wherever they can, except:
    /// - an object that would stretch the layer past twice the area of what it
    ///   holds (a label in each corner of a photo) starts another, so the
    ///   drawing doesn't clear and upload a photo's worth of empty pixels;
    /// - a shadowed object whose shadow reaches an earlier object of the layer
    ///   starts another, since the layer's shadows go under all of it.
    static func groups(_ objects: [Annotation], in size: CGSize) -> [Group] {
        var groups: [Group] = []
        for object in objects {
            let bounds = object.paintedBounds(in: size, includingShadow: false)
            let area = bounds.width * bounds.height
            let multiplies = object.kind == .highlight
            if let last = groups.last, last.multiplies == multiplies {
                let union = last.bounds.union(bounds)
                let shadow = object.shadow ? object.paintedBounds(in: size) : .null
                let shadowFallsOnLayer = object.shadow && last.objectBounds.contains { $0.intersects(shadow) }
                if !shadowFallsOnLayer, union.width * union.height <= (last.area + area) * 2 {
                    groups[groups.count - 1].objects.append(object)
                    groups[groups.count - 1].objectBounds.append(bounds)
                    groups[groups.count - 1].bounds = union
                    groups[groups.count - 1].area += area
                    continue
                }
            }
            groups.append(Group(multiplies: multiplies, objects: [object], objectBounds: [bounds], bounds: bounds,
                                area: area))
        }
        return groups
    }

    static let kernelSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // The separable multiply blend with alpha (premultiplied s over d), with
    // no clamp: a highlight over an HDR highlight keeps it above 1.
    [[stitchable]] float4 minivuAnnotationMultiply(coreimage::sample_t s, coreimage::sample_t d) {
        return float4(s.rgb * (1.0 - d.a) + d.rgb * (1.0 - s.a) + s.rgb * d.rgb, s.a + d.a * (1.0 - s.a));
    }
    """

    /// Compiled once, on first use (see `ToneKernels` for why at runtime).
    private static let multiplyKernel: CIColorKernel? = {
        do {
            return try CIKernel.kernels(withMetalString: kernelSource).first as? CIColorKernel
        } catch {
            fatalError("Annotation kernel failed to compile: \(error)")
        }
    }()

    static func multiply(_ layer: CIImage, over image: CIImage) -> CIImage {
        guard let kernel = multiplyKernel else { return layer.composited(over: image) }
        return kernel.apply(extent: image.extent, arguments: [layer, image]) ?? image
    }
}

/// Draws one layer of annotations into the tiles Core Image asks for. Immutable,
/// so Core Image may call it from any thread, and for several tiles at once.
final class AnnotationTileProvider: NSObject, @unchecked Sendable {
    let objects: [Annotation]
    let bounds: [CGRect]
    let imageSize: CGSize
    /// The part of the image this provider covers, in image pixels.
    let region: CGRect

    init(objects: [Annotation], imageSize: CGSize, region: CGRect) {
        self.objects = objects
        self.imageSize = imageSize
        self.region = region
        bounds = objects.map { $0.paintedBounds(in: imageSize, includingShadow: false) }
    }

    override func provideImageData(_ data: UnsafeMutableRawPointer, bytesPerRow: Int, origin x: Int, _ y: Int,
                                   size width: Int, _ height: Int, userInfo info: Any?) {
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: AnnotationRenderer.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // The tile is rows `y ..< y + height` (from the top) of the region.
        let tile = CGRect(x: region.minX + CGFloat(x), y: region.minY + CGFloat(y), width: CGFloat(width),
                          height: CGFloat(height))
        let visible = zip(objects, bounds).filter { $0.1.intersects(tile) }.map(\.0)
        guard !visible.isEmpty else { return }
        // Image pixels (y down) to the bitmap's user space (y up, tile origin).
        let base = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -tile.minX, ty: tile.maxY)
        AnnotationRenderer.draw(visible, in: context, imageSize: imageSize, baseTransform: base,
                                options: AnnotationRenderer.Options(castsShadows: false))
    }
}
