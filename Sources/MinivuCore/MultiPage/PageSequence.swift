import Foundation
import CoreGraphics
import ImageIO

/// The pages or frames of one file, for the multi-page tools (Create
/// Multi-Page File, Extract Pages, Batch Convert's every-page option):
/// a PDF's pages, a multi-page TIFF's, an animation's frames (GIF, APNG,
/// WebP, animated HEIC), or the one picture of anything else.
///
/// Only headers are read on creation. Pages are decoded one at a time when
/// asked for, SDR and upright, so a job that walks a hundred pages holds
/// one of them at a time.
public struct PageSequence: Sendable {
    public enum Kind: Sendable, Equatable {
        /// One picture (a photo, a RAW file, an SVG).
        case single
        /// A PDF or a multi-page TIFF.
        case document
        /// A GIF, APNG, WebP or HEIC animation.
        case animation
    }

    public let url: URL
    public let kind: Kind
    public let count: Int
    /// Seconds each frame shows, one per frame, for an animation (with the
    /// browsers' rule for very short delays, as the viewer plays them);
    /// empty otherwise.
    public let delays: [TimeInterval]
    /// Times an animation plays; 0 is forever.
    public let loopCount: Int
    let info: ImageInfo
    let frames: AnimationFrames?

    /// nil when the file can't be read.
    public init?(url: URL) {
        guard let info = ImageDecoder.info(for: url) else { return nil }
        self.url = url
        self.info = info
        if info.isAnimated, info.kind == .raster, let frames = AnimationFrames(url: url) {
            kind = .animation
            count = frames.frameCount
            delays = frames.delays
            loopCount = frames.loopCount
            self.frames = frames
        } else {
            kind = info.documentPageCount > 1 ? .document : .single
            count = info.documentPageCount
            delays = []
            loopCount = 1
            frames = nil
        }
    }

    /// The number of pages or frames in the file at `url`, 1 for a single
    /// picture or a file that can't be read (header only).
    public static func pageCount(of url: URL) -> Int {
        PageSequence(url: url)?.count ?? 1
    }

    /// The pixel size of page `index` as displayed, from its header. Pages
    /// of a TIFF can differ; an animation's frames and a PDF's first page
    /// stand for the rest (a PDF page's own size is known once rendered).
    public func pixelSize(ofPage index: Int) -> CGSize {
        if kind == .document, info.kind == .raster, index > 0,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let page = ImageDecoder.info(source: source, kind: .raster, index: min(index, count - 1)) {
            return page.pixelSize
        }
        return info.pixelSize
    }

    /// The header's description of page `index`, for the export budget
    /// check made before decoding.
    public func info(ofPage index: Int) -> ImageInfo {
        var page = info
        page.pixelSize = pixelSize(ofPage: index)
        return page
    }

    /// The seconds frame `index` shows, or nil for a page that isn't an
    /// animation frame.
    public func delay(ofPage index: Int) -> TimeInterval? {
        delays.indices.contains(index) ? delays[index] : nil
    }

    /// Page `index`, upright and SDR, with its long edge at most
    /// `maxPixelSize` (nil: full resolution). A full-resolution page past
    /// `byteLimit` is refused unread (`DecodeError.tooLarge`), as every
    /// export decode is. Blocking.
    ///
    /// An animation's frames come composited (a frame that repaints a
    /// corner comes back as the whole picture); asking for them in order is
    /// cheapest. A PDF page renders as the viewer renders it at full
    /// resolution: its actual size at 144 dpi, at least 4096 px on the long
    /// edge and at most 16384.
    public func page(_ index: Int, maxPixelSize: Int? = nil, byteLimit: Int? = nil) throws -> CGImage {
        guard (0..<count).contains(index) else { throw DecodeError.noImage(url) }
        if let frames {
            if maxPixelSize == nil, let byteLimit, ImageDecoder.exceedsExportBudget(info, byteLimit: byteLimit) {
                throw DecodeError.tooLarge(url)
            }
            let edge = maxPixelSize ?? Int(saturating: max(frames.pixelSize.width, frames.pixelSize.height))
            guard let image = frames.frame(at: index, maxPixelSize: edge) else { throw DecodeError.noImage(url) }
            return image
        }
        return try ImageDecoder.decode(url, maxPixelSize: maxPixelSize, page: index, allowHDR: false,
                                       byteLimit: byteLimit).image
    }
}

/// Which pages of each file a job takes: all of them, or a range counted
/// from 1 (pages past a file's end are left out).
public struct PageRange: Codable, Hashable, Sendable {
    /// The first page, from 1.
    public var first: Int
    /// The last page, or nil for the file's last.
    public var last: Int?

    public init(first: Int = 1, last: Int? = nil) {
        self.first = first
        self.last = last
    }

    public static let all = PageRange()

    public var isAll: Bool { first <= 1 && last == nil }

    /// The page indices (from 0) this range takes from a file of `count`
    /// pages; empty when the file is shorter than the range's start.
    public func indices(count: Int) -> Range<Int> {
        let start = max(first, 1) - 1
        let end = min(last ?? count, count)
        return start < end ? start..<end : 0..<0
    }

    /// Why the range can't be used, or nil.
    public var problem: String? {
        if first < 1 { return "The first page must be 1 or more." }
        if let last, last < first { return "The last page must not come before the first." }
        return nil
    }
}
