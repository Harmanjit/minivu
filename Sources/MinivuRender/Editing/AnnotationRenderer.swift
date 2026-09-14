import Foundation
import CoreGraphics
import CoreText

/// Draws annotations with Core Graphics and Core Text, in image pixels.
///
/// One drawing routine serves both places objects appear: the edit graph's
/// tiles (`AnnotationGraph`, into 8-bit sRGB bitmaps) and the drawing tool's
/// overlay, which draws the objects being dragged straight into its view
/// through the canvas's zoom and pan. The caller hands over the transform
/// from image pixels (top-left origin) to the context's base space, so the
/// same strokes, text layout and shadows come out in both.
///
/// **Shadows** are the one thing Core Graphics doesn't scale with the current
/// transform: their offset and blur are given in the context's base space,
/// so they are converted through `baseTransform` to keep their size in image
/// pixels whatever the zoom. (The graph blurs shadows on the GPU instead; a
/// Core Graphics shadow is a CPU blur that measured 2 ms an object at 3024
/// px, fine for the few objects the overlay draws.)
public enum AnnotationRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public struct Options: Sendable {
        /// Leaves this object's text out (the editor shows a text view there
        /// while typing).
        public var omitsTextOf: UUID?
        /// Draws highlights as a translucent source-over wash rather than a
        /// multiply. A view drawn over another layer can't multiply with the
        /// pixels beneath it, and a multiply over its own transparent
        /// backing would paint solid colour; this is the overlay's stand-in
        /// while a highlight is dragged.
        public var approximatesHighlights: Bool

        /// Draws drop shadows (with Core Graphics). The graph turns this off
        /// and blurs its shadows on the GPU instead (see `AnnotationGraph`).
        public var castsShadows: Bool

        public init(omitsTextOf: UUID? = nil, approximatesHighlights: Bool = false, castsShadows: Bool = true) {
            self.omitsTextOf = omitsTextOf
            self.approximatesHighlights = approximatesHighlights
            self.castsShadows = castsShadows
        }
    }

    /// Draws `objects` in order. `baseTransform` maps image pixels of an image
    /// `imageSize` to `context`'s base space (its user space as handed over);
    /// the context's state is restored afterwards.
    public static func draw(_ objects: [Annotation], in context: CGContext, imageSize: CGSize,
                            baseTransform: CGAffineTransform, options: Options = Options()) {
        for object in objects {
            draw(object, in: context, imageSize: imageSize, baseTransform: baseTransform, options: options)
        }
    }

    public static func draw(_ a: Annotation, in context: CGContext, imageSize size: CGSize,
                            baseTransform: CGAffineTransform, options: Options = Options()) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(baseTransform)

        let highlight = a.kind == .highlight
        var alpha = a.clampedOpacity
        if highlight && options.approximatesHighlights { alpha *= 0.45 }
        guard alpha > 0 else { return }
        let shadow = a.shadow && options.castsShadows
        if highlight && !options.approximatesHighlights { context.setBlendMode(.multiply) }
        // Opacity and shadow apply to the object as a whole: fill, outline and
        // text are drawn into one transparency layer, which then fades and
        // casts one shadow. Only when needed, since a layer costs a buffer.
        let usesLayer = alpha < 1 || shadow
        if usesLayer {
            context.setAlpha(alpha)
            if shadow {
                // Shadow offset and blur are in the context's base space, which
                // `baseTransform` maps image pixels to.
                let geometry = a.shadowGeometry(in: size)
                let scale = sqrt(abs(baseTransform.a * baseTransform.d - baseTransform.b * baseTransform.c))
                context.setShadow(offset: geometry.offset.applying(baseTransform), blur: geometry.blur * scale,
                                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: Annotation.shadowAlpha))
            }
            context.beginTransparencyLayer(in: a.paintedBounds(in: size), auxiliaryInfo: nil)
            context.setBlendMode(.normal)
        }
        drawBody(a, in: context, size: size, options: options)
        if usesLayer { context.endTransparencyLayer() }
    }

    private static func drawBody(_ a: Annotation, in context: CGContext, size: CGSize, options: Options) {
        switch a.kind {
        case .rectangle, .oval, .highlight:
            context.saveGState()
            context.concatenate(a.boxTransform(in: size))
            let box = a.localBox(in: size)
            let path = a.kind == .oval ? CGPath(ellipseIn: box, transform: nil) : CGPath(rect: box, transform: nil)
            fillAndStroke(path, a, in: context, size: size, joinsRound: a.kind == .oval)
            context.restoreGState()
        case .line, .arrow:
            drawLine(a, in: context, size: size)
        case .text:
            context.saveGState()
            context.concatenate(a.boxTransform(in: size))
            let box = a.localBox(in: size)
            fillAndStroke(CGPath(rect: box, transform: nil), a, in: context, size: size, joinsRound: false)
            if options.omitsTextOf != a.id { drawText(a, in: context, size: size) }
            context.restoreGState()
        case .callout:
            fillAndStroke(calloutPath(a, in: size), a, in: context, size: size, joinsRound: true)
            if options.omitsTextOf != a.id {
                context.saveGState()
                context.concatenate(a.boxTransform(in: size))
                drawText(a, in: context, size: size)
                context.restoreGState()
            }
        }
    }

    // MARK: - Shapes

    private static func cgColor(_ c: EditColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue),
                alpha: CGFloat(min(max(c.alpha, 0), 1)))
    }

    private static func fillAndStroke(_ path: CGPath, _ a: Annotation, in context: CGContext, size: CGSize,
                                      joinsRound: Bool) {
        if a.fillColor.alpha > 0 {
            context.addPath(path)
            context.setFillColor(cgColor(a.fillColor))
            context.fillPath()
        }
        let w = a.strokePixelWidth(in: size)
        guard w > 0, a.strokeColor.alpha > 0 else { return }
        context.addPath(path)
        setStroke(a, width: w, in: context, round: joinsRound)
        context.strokePath()
    }

    private static func setStroke(_ a: Annotation, width w: CGFloat, in context: CGContext, round: Bool) {
        context.setStrokeColor(cgColor(a.strokeColor))
        context.setLineWidth(w)
        context.setLineJoin(round ? .round : .miter)
        switch a.dash {
        case .solid:
            context.setLineCap(round ? .round : .butt)
        case .dashed:
            context.setLineCap(.butt)
            context.setLineDash(phase: 0, lengths: [3 * w, 2 * w])
        case .dotted:
            // Zero-length dashes with round caps are round dots.
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0, 2 * w])
        }
    }

    /// Arrowhead length in pixels: `arrowheadSize` stroke widths, and never so
    /// long that the heads of a short arrow overlap.
    public static func arrowheadLength(_ a: Annotation, in size: CGSize) -> CGFloat {
        let w = a.strokePixelWidth(in: size)
        let factor = CGFloat(a.arrowheadSize.isFinite ? min(max(a.arrowheadSize, 2), 20) : 4)
        let p = a.pixelPoint(a.start, in: size), q = a.pixelPoint(a.end, in: size)
        let length = hypot(q.x - p.x, q.y - p.y)
        return min(factor * w, length * (a.arrowheads == .both ? 0.45 : 0.9))
    }

    private static func drawLine(_ a: Annotation, in context: CGContext, size: CGSize) {
        let w = a.strokePixelWidth(in: size)
        guard w > 0, a.strokeColor.alpha > 0 else { return }
        let p = a.pixelPoint(a.start, in: size), q = a.pixelPoint(a.end, in: size)
        let length = hypot(q.x - p.x, q.y - p.y)
        guard length > 0.01 else { return }
        let u = CGPoint(x: (q.x - p.x) / length, y: (q.y - p.y) / length)
        let head = a.arrowheads == .none ? 0 : arrowheadLength(a, in: size)
        let halfWidth = max(head * 0.5, w)
        // The shaft stops inside each head, so its end never pokes past the tip.
        let inset = head * 0.8
        var from = p, to = q
        if a.arrowheads == .both { from = CGPoint(x: p.x + u.x * inset, y: p.y + u.y * inset) }
        if a.arrowheads != .none { to = CGPoint(x: q.x - u.x * inset, y: q.y - u.y * inset) }

        context.saveGState()
        setStroke(a, width: w, in: context, round: a.arrowheads == .none)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
        context.restoreGState()

        func arrowhead(tip: CGPoint, direction d: CGPoint) {
            let base = CGPoint(x: tip.x - d.x * head, y: tip.y - d.y * head)
            let side = CGPoint(x: -d.y, y: d.x)
            context.move(to: tip)
            context.addLine(to: CGPoint(x: base.x + side.x * halfWidth, y: base.y + side.y * halfWidth))
            context.addLine(to: CGPoint(x: base.x - side.x * halfWidth, y: base.y - side.y * halfWidth))
            context.closePath()
        }
        guard head > 0 else { return }
        arrowhead(tip: q, direction: u)
        if a.arrowheads == .both { arrowhead(tip: p, direction: CGPoint(x: -u.x, y: -u.y)) }
        context.setFillColor(cgColor(a.strokeColor))
        context.fillPath()
    }

    /// A rounded bubble with a tail reaching `tailPoint`, as one outline (in
    /// image pixels), so the stroke has no seam where the tail joins. The tail
    /// leaves from the side of the bubble facing the point; a point inside the
    /// bubble has no tail.
    public static func calloutPath(_ a: Annotation, in size: CGSize) -> CGPath {
        let r = a.pixelRect(in: size)
        let radius = min(r.width, r.height) * 0.2
        let bubble = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let tail = a.pixelPoint(a.tailPoint, in: size)
        guard r.width > 1, r.height > 1, !r.contains(tail) else { return bubble }
        let dx = tail.x - r.midX, dy = tail.y - r.midY
        // The side the ray from the centre leaves through.
        let horizontal = abs(dx) / r.width > abs(dy) / r.height
        // A tail about a fifth of the bubble's shorter side wide, and never
        // wider than the straight part of the side it leaves from.
        let side = horizontal ? r.height : r.width
        let halfBase = max(min(min(r.width, r.height) * 0.22, side / 2 - radius), 0.5)
        let inward = max(a.strokePixelWidth(in: size) * 2, 1)
        var b1: CGPoint, b2: CGPoint
        if horizontal {
            let t = (dx > 0 ? r.width / 2 : -r.width / 2) / dx
            let y = min(max(r.midY + dy * t, r.minY + radius + halfBase), r.maxY - radius - halfBase)
            let x = dx > 0 ? r.maxX - inward : r.minX + inward
            b1 = CGPoint(x: x, y: y - halfBase)
            b2 = CGPoint(x: x, y: y + halfBase)
        } else {
            let t = (dy > 0 ? r.height / 2 : -r.height / 2) / dy
            let x = min(max(r.midX + dx * t, r.minX + radius + halfBase), r.maxX - radius - halfBase)
            let y = dy > 0 ? r.maxY - inward : r.minY + inward
            b1 = CGPoint(x: x - halfBase, y: y)
            b2 = CGPoint(x: x + halfBase, y: y)
        }
        if b1.x.isNaN || b1.y.isNaN { return bubble }
        let wedge = CGMutablePath()
        wedge.move(to: b1)
        wedge.addLine(to: tail)
        wedge.addLine(to: b2)
        wedge.closeSubpath()
        return bubble.union(wedge)
    }

    // MARK: - Text

    /// The font an object's text is set in, at `pixelSize`. "System" is San
    /// Francisco; a family that isn't installed falls back to Core Text's
    /// default, so a document from another Mac still renders.
    public static func font(for a: Annotation, pixelSize: CGFloat) -> CTFont {
        let family = a.fontFamily == Annotation.systemFontFamily || a.fontFamily.isEmpty
            ? ".AppleSystemUIFont" : a.fontFamily
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: a.fontWeight.trait],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, max(pixelSize, 0.5), nil)
    }

    /// Space between an object's box and its text, in pixels.
    public static func textPadding(for a: Annotation, in size: CGSize) -> CGFloat {
        let font = a.fontPixelSize(in: size)
        return a.kind == .callout ? font * 0.5 + a.strokePixelWidth(in: size) : font * 0.2
    }

    private static func attributedText(_ a: Annotation, font: CTFont, color: EditColor, outlineWidth: CGFloat?) -> CFAttributedString {
        var alignment: CTTextAlignment = switch a.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let style = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        if let outlineWidth {
            // Positive: stroke only, in percent of the font size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = outlineWidth
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cgColor(color)
        }
        // A trailing newline would otherwise measure no line for itself.
        let string = a.text.hasSuffix("\n") ? a.text + " " : a.text
        return NSAttributedString(string: string, attributes: attributes) as CFAttributedString
    }

    /// The height the text needs inside the object's width, with padding, in
    /// pixels. An empty text measures one line.
    public static func fittingPixelHeight(for a: Annotation, in size: CGSize) -> CGFloat {
        let padding = textPadding(for: a, in: size)
        let width = max(a.pixelRect(in: size).width - 2 * padding, 1)
        return textHeight(a, width: width, in: size) + 2 * padding
    }

    /// `frame.height` that fits the text (normalised).
    public static func fittingHeight(for a: Annotation, in size: CGSize) -> Double {
        guard size.height > 0 else { return Double(a.frame.height) }
        return Double(fittingPixelHeight(for: a, in: size) / size.height)
    }

    private static func textHeight(_ a: Annotation, width: CGFloat, in size: CGSize) -> CGFloat {
        let font = font(for: a, pixelSize: a.fontPixelSize(in: size))
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        guard !a.text.isEmpty else { return ceil(lineHeight) }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText(a, font: font, color: a.textColor,
                                                                                 outlineWidth: nil))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(max(fit.height, lineHeight))
    }

    /// Where the text block sits in the box's own coordinates (centred on the
    /// origin, unrotated): inside the padding, at the top for text and
    /// centred vertically in a callout. The editor puts its text view here.
    public static func textRect(for a: Annotation, in size: CGSize) -> CGRect {
        let box = a.localBox(in: size)
        let padding = textPadding(for: a, in: size)
        let inner = box.insetBy(dx: min(padding, box.width / 2), dy: min(padding, box.height / 2))
        let height = textHeight(a, width: max(inner.width, 1), in: size)
        var top = inner.minY
        if a.kind == .callout, height < inner.height { top = inner.midY - height / 2 }
        return CGRect(x: inner.minX, y: top, width: inner.width, height: height)
    }

    /// Draws the text in the box's own coordinates (the context is already
    /// centred on the box), clipped to the box.
    private static func drawText(_ a: Annotation, in context: CGContext, size: CGSize) {
        guard !a.text.isEmpty, a.textColor.alpha > 0 || a.textOutlineColor.alpha > 0 else { return }
        let fontSize = a.fontPixelSize(in: size)
        let font = font(for: a, pixelSize: fontSize)
        let rect = textRect(for: a, in: size)
        let box = a.localBox(in: size)
        context.saveGState()
        context.clip(to: box.insetBy(dx: -fontSize * 0.1, dy: -fontSize * 0.1))
        // Core Text lays out with y up: flip about the text block, with a path
        // taller than the text so no line is dropped for want of room.
        let pathHeight = rect.height + fontSize * 2
        context.translateBy(x: rect.minX, y: rect.minY + pathHeight)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(rect.width, 1), height: pathHeight), transform: nil)
        if a.textOutlineColor.alpha > 0 {
            // Stroked first and 16% of the font size wide, so the fill on top
            // leaves an outline of 8% outside each letter.
            let outline = attributedText(a, font: font, color: a.textOutlineColor, outlineWidth: 16)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(outline),
                                                 CFRange(location: 0, length: 0), path, nil), context)
        }
        if a.textColor.alpha > 0 {
            let fill = attributedText(a, font: font, color: a.textColor, outlineWidth: nil)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(fill),
                                                 CFRange(location: 0, length: 0), path, nil), context)
        }
        context.restoreGState()
    }
}
