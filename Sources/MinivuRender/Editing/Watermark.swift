import Foundation
import CoreGraphics
import CoreImage
import CoreText
import MinivuCore

/// Text or a picture (a logo, a signature) stamped over the photo, once at
/// one of nine places or tiled across it.
///
/// **Lengths** are fractions of the photo's short side, so a watermark
/// covers the same share of a 2 MP and a 50 MP photo, of a proxy and of the
/// saved file, and a preset made on one photo suits the next.
///
/// **The picture** is a file the user chose, kept as a read-only
/// security-scoped bookmark: the sandbox grants a chosen file only until the
/// app quits, and the bookmark lets a document or a saved preset render it
/// in a later session. Without the file (moved, deleted, on a volume that
/// isn't there) the watermark draws nothing rather than failing the render.
///
/// Every field decodes with its default when missing, so documents saved
/// before a field existed keep loading.
public struct Watermark: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, image

        public var title: String { self == .text ? localized("Text") : localized("Image") }
    }

    public var kind = Kind.text
    /// One line; line breaks are drawn as spaces.
    public var text = ""
    /// A family name, or `Annotation.systemFontFamily` for San Francisco.
    public var fontFamily = Annotation.systemFontFamily
    public var fontWeight = Annotation.FontWeight.semibold
    public var color = EditColor.white
    /// The picture: a bookmark to the file (see the type's notes).
    public var imageBookmark: Data?
    /// The file's name when it was chosen, for the inspector.
    public var imageName: String?
    /// The text's size, or the picture's height, 0.01...1 of the photo's
    /// short side.
    public var size = 0.05
    /// 0...1, on top of the colour's own alpha.
    public var opacity = 0.6
    public var position = EditAnchor.bottomRight
    /// Space between the watermark and the photo's edges, 0...0.25 of the
    /// short side. With tiling it is where the first tile starts.
    public var margin = 0.03
    /// Repeats the watermark across the whole photo.
    public var tiled = false
    /// The gap between tiles, 0.2...5 times the watermark's height.
    public var spacing = 1.5

    public static let sizeRange = 0.01...1.0
    public static let marginRange = 0.0...0.25
    public static let spacingRange = 0.2...5.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case kind, text, fontFamily, fontWeight, color, imageBookmark, imageName, size, opacity, position, margin
        case tiled, spacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Watermark()
        kind = try c.effectsValue(.kind, default: d.kind)
        text = try c.effectsValue(.text, default: d.text)
        fontFamily = try c.effectsValue(.fontFamily, default: d.fontFamily)
        fontWeight = try c.effectsValue(.fontWeight, default: d.fontWeight)
        color = try c.effectsValue(.color, default: d.color)
        imageBookmark = try c.decodeIfPresent(Data.self, forKey: .imageBookmark)
        imageName = try c.decodeIfPresent(String.self, forKey: .imageName)
        size = try c.effectsValue(.size, default: d.size)
        opacity = try c.effectsValue(.opacity, default: d.opacity)
        position = try c.effectsValue(.position, default: d.position)
        margin = try c.effectsValue(.margin, default: d.margin)
        tiled = try c.effectsValue(.tiled, default: d.tiled)
        spacing = try c.effectsValue(.spacing, default: d.spacing)
    }

    /// The text as it is drawn: one line, trimmed.
    var line: String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Nothing to draw: no text or no picture, or invisible.
    public var isIdentity: Bool {
        guard opacity > 0, size > 0 else { return true }
        switch kind {
        case .text: return line.isEmpty || !(color.alpha > 0)
        case .image: return imageBookmark == nil
        }
    }

    /// A read-only security-scoped bookmark to `url`, or a plain one where
    /// security scope isn't available (outside the sandbox, in tests).
    public static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                               includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}

// MARK: - Graph

/// Renders `.watermark` (see `EditGraph`).
///
/// The stamp, text or picture, is drawn with Core Graphics into a small
/// 8-bit bitmap at exactly the size it has on the working image, and
/// composited over the photo: wherever it is transparent the photo's own
/// values pass through untouched, HDR highlights included, and under a
/// translucent stamp they are only scaled. Every size and position is a
/// fraction of the working image's short side, rounded to whole working
/// pixels, so the proxy and the saved file show the same watermark in the
/// same place. The bitmap holds the stamp alone, never the gap between
/// tiles: tiling pads it with transparent Core Image pixels to the cell
/// (stamp plus gap) and repeats that with `CIAffineTile`, so the widest
/// spacing costs no more memory than the narrowest, and a tiled 50 MP photo
/// costs one stamp-sized bitmap.
///
/// A stamp larger than the photo (a long text at a large size) is shrunk to
/// fit inside the margins rather than dropped, by the same fraction at
/// every scale, so the saved file keeps the watermark the preview shows,
/// and the bitmap is never larger than the photo.
enum WatermarkGraph {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func apply(_ watermark: Watermark, to image: CIImage, scale: Double) -> CIImage {
        guard !watermark.isIdentity else { return image }
        let extent = image.extent
        guard let layout = Layout(watermark, imageSize: extent.size, scale: scale),
              let bitmap = layout.stamp.draw(opacity: EffectsMath.clamp(watermark.opacity, 0...1))
        else { return image }
        let height = Double(extent.height)
        let stamp = layout.stamp
        // Core Image's y points up: the stamp's bottom edge.
        let bottom = height - layout.top - stamp.height
        var layer = CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(translationX: layout.x, y: bottom))
        if watermark.tiled {
            // The cell: the stamp at its top left, the gap to its right and
            // below it transparent.
            let cell = CGRect(x: layout.x, y: bottom - layout.gap, width: stamp.width + layout.gap,
                              height: stamp.height + layout.gap)
            layer = layer.composited(over: CIImage(color: .clear).cropped(to: cell))
                .applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: CGAffineTransform.identity])
        }
        return layer.composited(over: image).cropped(to: extent)
    }

    /// Where the stamp goes on a working image, and how big it is.
    struct Layout {
        let stamp: Stamp
        /// The stamp's top-left corner in working pixels, top-left origin.
        let x: Double
        let top: Double
        /// The gap between tiles, 0 without tiling.
        let gap: Double

        init?(_ watermark: Watermark, imageSize: CGSize, scale: Double) {
            let width = Double(imageSize.width), height = Double(imageSize.height)
            let short = min(width, height)
            guard short >= 1 else { return nil }
            var size = EffectsMath.clamp(watermark.size, Watermark.sizeRange) * short
            let margin = (EffectsMath.clamp(watermark.margin, Watermark.marginRange) * short).rounded()
            guard var stamp = Stamp(watermark, size: size, scale: scale) else { return nil }
            // Too big for the photo: shrunk to fit inside the margins. The
            // fit is a fraction of the stamp's own size, so the proxy and
            // the saved file shrink theirs alike. Text isn't exactly
            // proportional to its size (fonts track small sizes wider), so
            // it is measured again, a few times at most.
            let room = (width: max(1, width - 2 * margin), height: max(1, height - 2 * margin))
            for _ in 0..<4 {
                let fit = min(room.width / stamp.width, room.height / stamp.height)
                guard fit < 1 else { break }
                size *= fit
                guard let smaller = Stamp(watermark, size: size, scale: scale) else { return nil }
                stamp = smaller
            }
            self.stamp = stamp
            gap = watermark.tiled
                ? (EffectsMath.clamp(watermark.spacing, Watermark.spacingRange) * size).rounded() : 0
            // At the anchor inside the margins.
            x = (margin + (width - 2 * margin - stamp.width) * watermark.position.x).rounded()
            top = (margin + (height - 2 * margin - stamp.height) * watermark.position.y).rounded()
        }
    }

    /// The text or picture, measured at its working size.
    struct Stamp {
        enum Content {
            case text(CTLine, ascent: CGFloat)
            case image(CGImage)
        }

        let content: Content
        /// Whole working pixels.
        let width: Double
        let height: Double

        init?(_ watermark: Watermark, size: Double, scale: Double) {
            switch watermark.kind {
            case .text:
                let font = WatermarkGraph.font(family: watermark.fontFamily, weight: watermark.fontWeight,
                                               pixelSize: CGFloat(size))
                let color = watermark.color
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(colorSpace: WatermarkGraph.sRGB, components: [
                            CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue),
                            CGFloat(EffectsMath.clamp(color.alpha, 0...1)),
                        ]) ?? CGColor(gray: 1, alpha: 1),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: watermark.line,
                                                                               attributes: attributes))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                guard advance > 0 else { return nil }
                content = .text(line, ascent: ascent)
                width = Double(advance).rounded(.up)
                height = Double(ascent + descent).rounded(.up)
            case .image:
                // Decoded at the height it is drawn at, at most twice that,
                // so a 40 MP logo file never costs more than the stamp.
                let wanted = max(1, Int(size.rounded(.up)))
                guard let bookmark = watermark.imageBookmark,
                      let picture = WatermarkImages.shared.image(bookmark: bookmark, height: wanted) else { return nil }
                let aspect = Double(picture.width) / Double(max(picture.height, 1))
                content = .image(picture)
                width = max(1, (size * aspect).rounded())
                height = max(1, size.rounded())
            }
            // Measured only: the size can be over any bitmap's limit here,
            // before `Layout` fits it to the photo.
            guard width >= 1, height >= 1, width.isFinite, height.isFinite else { return nil }
        }

        /// The stamp drawn into a bitmap of its own size.
        func draw(opacity: Double) -> CGImage? {
            guard width <= 32768, height <= 32768 else { return nil }
            let w = Int(width), h = Int(height)
            guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                                        bytesPerRow: 0, space: WatermarkGraph.sRGB,
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.setAlpha(CGFloat(opacity))
            context.interpolationQuality = .high
            // The context's y points up.
            switch content {
            case .text(let line, let ascent):
                context.setShouldAntialias(true)
                context.textPosition = CGPoint(x: 0, y: CGFloat(height) - ascent)
                CTLineDraw(line, context)
            case .image(let picture):
                context.draw(picture, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
            return context.makeImage()
        }
    }

    /// The watermark's font, as the drawing tool resolves its fonts.
    static func font(family: String, weight: Annotation.FontWeight, pixelSize: CGFloat) -> CTFont {
        var object = Annotation(kind: .text)
        object.fontFamily = family
        object.fontWeight = weight
        return AnnotationRenderer.font(for: object, pixelSize: pixelSize)
    }
}

/// The watermark pictures decoded recently, so moving a slider doesn't read
/// the file again for every frame.
///
/// Keyed by the bookmark and the height asked for, rounded up to a power of
/// two: a slider dragging the size reuses one decode for each doubling, and
/// the decode is never more than twice the size drawn. A few entries are
/// kept, the newest first; a watermark is a small picture.
final class WatermarkImages: @unchecked Sendable {
    static let shared = WatermarkImages()
    static let capacity = 6

    private let lock = NSLock()
    private var entries: [(key: Key, image: CGImage)] = []

    struct Key: Hashable {
        let bookmark: Data
        let height: Int
    }

    /// The bucket for a wanted height: the next power of two, at least 64.
    static func bucket(_ height: Int) -> Int {
        var b = 64
        while b < height && b < 1 << 15 { b <<= 1 }
        return b
    }

    func image(bookmark: Data, height: Int) -> CGImage? {
        let key = Key(bookmark: bookmark, height: Self.bucket(height))
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.image
        }
        lock.unlock()
        guard let image = Self.decode(bookmark: bookmark, height: key.height) else { return nil }
        lock.lock()
        entries.insert((key, image), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        lock.unlock()
        return image
    }

    /// Empties the cache (tests, and a picture the user chose again).
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The picture at about `height` pixels high, oriented. The thumbnail
    /// request is bounded by its long edge, so a tall picture is asked for
    /// at `height` and a wide one at its proportional width.
    static func decode(bookmark: Data, height: Int) -> CGImage? {
        guard let url = resolve(bookmark) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard VolumePolicy.isAllowed(url) else { return nil }
        var longEdge = height
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let (ow, oh) = orientation >= 5 ? (h, w) : (w, h)
            longEdge = max(height, Int((Double(height) * Double(ow) / Double(oh)).rounded(.up)))
        }
        return ImageDecoder.thumbnail(for: url, maxPixelSize: min(longEdge, 1 << 15))
    }

    /// The file a bookmark points at, without asking the user anything or
    /// mounting a volume.
    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        return (try? URL(resolvingBookmarkData: bookmark, options: quiet.union(.withSecurityScope), relativeTo: nil,
                         bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: quiet, relativeTo: nil, bookmarkDataIsStale: &stale))
    }
}
