import AppKit
import MinivuCore

/// Draws montages with Core Graphics: the small live preview in the sheet
/// and the wallpaper at the display's size, in 8-bit Display P3 (a
/// wallpaper is SDR, and P3 keeps a wide-gamut photo's colour on every
/// current Mac screen).
nonisolated enum MontageRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    struct Look: Sendable, Equatable {
        var style: MontageStyle
        var background: ExportColor
    }

    /// A bitmap of `size` pixels filled with the background.
    static func makeContext(size: CGSize, background: ExportColor) -> CGContext? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        return context
    }

    /// Makes the layout's top-left, y-down canvas pixels land on `context`
    /// (bottom-left, y-up), scaled from `canvas` to the context's size.
    static func applyCanvasTransform(_ context: CGContext, canvas: CGSize) {
        let sx = Double(context.width) / canvas.width, sy = Double(context.height) / canvas.height
        context.translateBy(x: 0, y: Double(context.height))
        context.scaleBy(x: sx, y: -sy)
    }

    /// Draws one photo. `scale` is output pixels per canvas pixel, for the
    /// shadow, which Core Graphics measures in output pixels whatever the
    /// transform.
    static func draw(_ tile: MontageTile, image: CGImage, style: MontageStyle, scale: Double, in context: CGContext) {
        let aspect = Double(image.width) / Double(max(image.height, 1))
        context.saveGState()
        defer { context.restoreGState() }
        switch style {
        case .grid, .mosaic:
            context.clip(to: tile.frame)
            drawUpright(image, in: MontageLayout.aspectFill(aspect, in: tile.frame), context: context)
        case .scattered:
            context.translateBy(x: tile.frame.midX, y: tile.frame.midY)
            context.rotate(by: tile.rotation)
            let frame = CGRect(x: -tile.frame.width / 2, y: -tile.frame.height / 2,
                               width: tile.frame.width, height: tile.frame.height)
            let short = min(frame.width, frame.height) * scale
            // A soft shadow falling down and a little right, as from a lamp
            // above: offsets are in output space, where y grows upwards.
            context.setShadow(offset: CGSize(width: short * 0.01, height: -short * 0.025), blur: short * 0.06,
                              color: CGColor(gray: 0, alpha: 0.45))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(frame)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            let picture = frame.insetBy(dx: tile.border, dy: tile.border)
            context.saveGState()
            context.clip(to: picture)
            drawUpright(image, in: MontageLayout.aspectFill(aspect, in: picture), context: context)
            context.restoreGState()
            // A hairline edge, so a print still reads on a white background.
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            context.setLineWidth(1 / scale)
            context.stroke(frame)
        }
    }

    /// `CGContext.draw` puts an image's first row at the bottom of `rect`;
    /// under the y-down canvas transform that is the top, so flip it back.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// The sheet's preview: every tile drawn from images already in memory.
    static func renderPreview(tiles: [MontageTile], canvas: CGSize, size: CGSize, look: Look,
                              images: [Int: ImageBox]) -> CGImage? {
        guard let context = makeContext(size: size, background: look.background) else { return nil }
        applyCanvasTransform(context, canvas: canvas)
        let scale = size.width / canvas.width
        for tile in tiles {
            if let box = images[tile.image] {
                draw(tile, image: box.image, style: look.style, scale: scale, in: context)
            } else {
                // Not decoded yet: a quiet placeholder where the photo goes.
                context.saveGState()
                context.setFillColor(CGColor(gray: 0.5, alpha: 0.25))
                context.translateBy(x: tile.frame.midX, y: tile.frame.midY)
                context.rotate(by: tile.rotation)
                context.fill(CGRect(x: -tile.frame.width / 2, y: -tile.frame.height / 2,
                                    width: tile.frame.width, height: tile.frame.height))
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    /// The wallpaper at full size. Photos are decoded as ImageIO thumbnails
    /// at just the size their tile needs, `concurrency` at a time, and drawn
    /// in order as each group arrives; a photo is let go after the last tile
    /// that shows it, so memory holds a few photos, not all of them.
    /// Throws `CancellationError` when the task is cancelled between groups.
    static func render(tiles: [MontageTile], canvas: CGSize, look: Look, files: [URL], aspectRatios: [Double],
                       concurrency: Int = 4,
                       decode: @escaping @Sendable (URL, Int) -> CGImage? = { ImageDecoder.thumbnail(for: $0, maxPixelSize: $1) })
        async throws -> ImageBox {
        guard let context = makeContext(size: canvas, background: look.background) else {
            throw ExportError.cannotConvertPixels
        }
        applyCanvasTransform(context, canvas: canvas)
        let needed = MontageLayout.neededLongEdges(tiles, aspectRatios: aspectRatios)
        var lastUse: [Int: Int] = [:]
        for (position, tile) in tiles.enumerated() { lastUse[tile.image] = position }

        var decoded: [Int: ImageBox] = [:]
        // Photos already asked for, so one that can't be read isn't tried
        // again for each tile that shows it.
        var tried = Set<Int>()
        var start = 0
        while start < tiles.count {
            try Task.checkCancellation()
            let end = min(start + max(concurrency, 1), tiles.count)
            let wanted = Set(tiles[start..<end].map(\.image)).filter { !tried.contains($0) && files.indices.contains($0) }
            tried.formUnion(wanted)
            let arrived = await withTaskGroup(of: (Int, ImageBox?).self) { group in
                for index in wanted {
                    let url = files[index], size = max(needed[index] ?? 256, 16)
                    group.addTask {
                        await BlockingWork.run { (index, decode(url, size).map(ImageBox.init)) }
                    }
                }
                var results: [Int: ImageBox] = [:]
                for await (index, box) in group { if let box { results[index] = box } }
                return results
            }
            decoded.merge(arrived) { $1 }
            for position in start..<end {
                let tile = tiles[position]
                if let box = decoded[tile.image] {
                    draw(tile, image: box.image, style: look.style, scale: 1, in: context)
                }
                if lastUse[tile.image] == position { decoded[tile.image] = nil }
            }
            start = end
        }
        guard let image = context.makeImage() else { throw ExportError.cannotConvertPixels }
        return ImageBox(image: image)
    }
}
