import Foundation
import CoreGraphics

/// Image Strip's choices: pictures joined side by side, one above another,
/// or in a grid, with spacing, a margin and a background. Remembered
/// between launches; decoding fills anything missing from the defaults.
public struct ImageStripSettings: Codable, Hashable, Sendable {
    public enum Arrangement: String, Codable, CaseIterable, Sendable {
        case horizontal, vertical, grid

        public var title: String {
            switch self {
            case .horizontal: localized(.init("Side by Side", comment: "Image strip arrangement"))
            case .vertical: localized(.init("One Above Another", comment: "Image strip arrangement"))
            case .grid: localized(.init("Grid", comment: "Arrangement of pictures in rows and columns"))
            }
        }

        /// What `size` measures, for the sheet's label.
        public var sizeTitle: String {
            switch self {
            case .horizontal: localized("Height")
            case .vertical: localized("Width")
            case .grid: localized(.init("Cell height", comment: "Height of each picture in an image strip's grid"))
            }
        }
    }

    public var arrangement: Arrangement
    /// Side by side: every picture's height. One above another: every
    /// picture's width. Grid: every cell's height (cells are as wide as the
    /// pictures' middle shape needs). In pixels.
    public var size: Int
    /// Grid only.
    public var columns: Int
    /// Between pictures, in pixels.
    public var spacing: Int
    /// Around the whole strip, in pixels.
    public var margin: Int
    /// nil is transparent (where the format keeps transparency).
    public var background: ExportColor?
    /// The output file's format and options.
    public var options: ExportOptions

    public init(arrangement: Arrangement = .horizontal, size: Int = 1080, columns: Int = 3, spacing: Int = 0,
                margin: Int = 0, background: ExportColor? = .white, options: ExportOptions = .defaults(for: .jpeg)) {
        self.arrangement = arrangement
        self.size = size
        self.columns = columns
        self.spacing = spacing
        self.margin = margin
        self.background = background
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case arrangement, size, columns, spacing, margin, background, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageStripSettings()
        arrangement = (try? c.decodeIfPresent(Arrangement.self, forKey: .arrangement)) ?? d.arrangement
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? d.size
        columns = (try? c.decodeIfPresent(Int.self, forKey: .columns)) ?? d.columns
        spacing = (try? c.decodeIfPresent(Int.self, forKey: .spacing)) ?? d.spacing
        margin = (try? c.decodeIfPresent(Int.self, forKey: .margin)) ?? d.margin
        background = c.contains(.background) ? (try? c.decodeIfPresent(ExportColor.self, forKey: .background)) ?? nil
                                             : d.background
        options = (try? c.decodeIfPresent(ExportOptions.self, forKey: .options)) ?? d.options
    }
}

/// Where each picture of an image strip goes, and how large the strip is.
/// Pure geometry, top-left origin, whole pixels.
public struct ImageStripLayout: Equatable, Sendable {
    /// The strip's size in pixels.
    public var width: Int
    public var height: Int
    /// Each picture's rectangle, in the order given.
    public var frames: [CGRect]

    /// The longest side minivu writes, as Resize and Batch Convert allow.
    public static let maximumSide = 32768

    /// Lays out pictures of `sizes` (as displayed). Zero-sized entries (a
    /// file that couldn't be read) get an empty frame and take no room.
    public static func make(sizes: [CGSize], settings: ImageStripSettings) -> ImageStripLayout {
        let size = max(settings.size, 1)
        let spacing = max(settings.spacing, 0), margin = max(settings.margin, 0)
        func aspect(_ s: CGSize) -> Double? {
            s.width > 0 && s.height > 0 ? Double(s.width / s.height) : nil
        }
        var frames: [CGRect] = []
        switch settings.arrangement {
        case .horizontal, .vertical:
            let horizontal = settings.arrangement == .horizontal
            var cursor = margin
            var placed = 0
            for item in sizes {
                guard let a = aspect(item) else {
                    frames.append(.zero)
                    continue
                }
                if placed > 0 { cursor += spacing }
                let length = max(1, Int((horizontal ? Double(size) * a : Double(size) / a).rounded()))
                frames.append(horizontal
                    ? CGRect(x: cursor, y: margin, width: length, height: size)
                    : CGRect(x: margin, y: cursor, width: size, height: length))
                cursor += length
                placed += 1
            }
            let along = cursor + margin, across = size + 2 * margin
            return ImageStripLayout(width: horizontal ? along : across, height: horizontal ? across : along,
                                    frames: frames)
        case .grid:
            let valid = sizes.compactMap(aspect).sorted()
            let middle = valid.isEmpty ? 1 : valid[valid.count / 2]
            let cellWidth = max(1, Int((Double(size) * middle).rounded())), cellHeight = size
            let count = valid.count
            let columns = min(max(settings.columns, 1), max(count, 1))
            let rows = max(1, (count + columns - 1) / columns)
            var slot = 0
            for item in sizes {
                guard let a = aspect(item) else {
                    frames.append(.zero)
                    continue
                }
                let column = slot % columns, row = slot / columns
                let cellX = margin + column * (cellWidth + spacing), cellY = margin + row * (cellHeight + spacing)
                // Fitted into its cell and centred.
                let scale = min(Double(cellWidth) / a, Double(cellHeight))
                let w = max(1, Int((scale * a).rounded())), h = max(1, Int(scale.rounded()))
                frames.append(CGRect(x: cellX + (cellWidth - w) / 2, y: cellY + (cellHeight - h) / 2, width: w, height: h))
                slot += 1
            }
            return ImageStripLayout(width: 2 * margin + columns * cellWidth + (columns - 1) * spacing,
                                    height: 2 * margin + rows * cellHeight + (rows - 1) * spacing, frames: frames)
        }
    }

    /// Why a strip of this size can't be made within `byteLimit` (the
    /// strip is one bitmap at four bytes a pixel, eight at 16 bits), or nil.
    public func problem(byteLimit: Int, bytesPerPixel: Int = 4) -> String? {
        if width > Self.maximumSide || height > Self.maximumSide {
            return localized("The strip would be \(width) × \(height) px; the most minivu makes is \(Self.maximumSide) px on a side.")
        }
        if Double(width) * Double(height) * Double(bytesPerPixel) > Double(byteLimit) {
            return localized("The strip would be \(width) × \(height) px, more than this Mac can hold at once. Choose a smaller size.")
        }
        return nil
    }
}

/// Draws an image strip: one bitmap the strip's size, each picture decoded
/// at about its frame's size (the codec's own downscale) and drawn in
/// turn, so memory is the strip and one picture. SDR, 8 bits (16 with the
/// format's 16-bit option), in Display P3 so wide-gamut photos keep their
/// colour; the encoder converts to the chosen profile.
public enum ImageStripRenderer {
    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge(String)
        case nothingToDraw

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let reason): reason
            case .nothingToDraw: localized("None of the images could be read.")
            }
        }
    }

    /// The pictures' sizes as displayed, from their headers (zero for a
    /// file that can't be read). Blocking.
    public static func sizes(of urls: [URL]) -> [CGSize] {
        urls.map { ImageDecoder.info(for: $0)?.pixelSize ?? .zero }
    }

    /// The strip of `urls`, laid out for `sizes` (from `sizes(of:)`).
    /// Checks `cancel` before each picture (throwing `CancellationError`).
    /// Pictures that can't be decoded leave their frame empty and are
    /// returned. Blocking.
    public static func render(_ urls: [URL], sizes: [CGSize], settings: ImageStripSettings, byteLimit: Int,
                              cancel: CancellationFlag) throws -> (image: CGImage, failed: [URL]) {
        let layout = ImageStripLayout.make(sizes: sizes, settings: settings)
        let deep = settings.options.format.supports16Bit && settings.options.sixteenBit
        if let problem = layout.problem(byteLimit: byteLimit, bytesPerPixel: deep ? 8 : 4) {
            throw Failure.tooLarge(problem)
        }
        guard layout.frames.contains(where: { !$0.isEmpty }) else { throw Failure.nothingToDraw }
        let bitmap: UInt32 = deep
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: layout.width, height: layout.height,
                                      bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: bitmap) else {
            throw Failure.tooLarge(localized("The strip couldn’t be made: not enough memory."))
        }
        let height = CGFloat(layout.height)
        if let background = settings.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        }
        context.interpolationQuality = .high
        var failed: [URL] = []
        for (url, frame) in zip(urls, layout.frames) where !frame.isEmpty {
            if cancel.isCancelled { throw CancellationError() }
            do {
                try autoreleasepool {
                    let edge = Int(max(frame.width, frame.height).rounded(.up))
                    let picture = try ImageDecoder.decode(url, maxPixelSize: edge, allowHDR: false,
                                                          byteLimit: byteLimit).image
                    // Layout is top-left; Core Graphics draws from the bottom.
                    let flipped = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
                    context.draw(picture, in: flipped)
                }
            } catch {
                failed.append(url)
            }
        }
        if cancel.isCancelled { throw CancellationError() }
        guard failed.count < layout.frames.filter({ !$0.isEmpty }).count else { throw Failure.nothingToDraw }
        guard let image = context.makeImage() else { throw Failure.tooLarge(localized("The strip couldn’t be made.")) }
        return (image, failed)
    }
}
