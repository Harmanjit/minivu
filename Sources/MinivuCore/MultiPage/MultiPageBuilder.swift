import Foundation
import CoreGraphics
import ImageIO

/// Create Multi-Page File's engine: pictures, in the order chosen, into one
/// multi-page TIFF, PDF, animated GIF or animated HEIC.
///
/// Pages are decoded one at a time, in order, and handed to
/// `MultiPageWriter` as they come, so a TIFF or PDF of any length holds one
/// decoded page. GIF and HEIC frames are made at the frame size and checked
/// as a whole against the export budget first, since ImageIO keeps them all
/// until the file is finished (`MultiPageFormat.holdsEveryFrame`).
///
/// No metadata is carried: the pages come from different files, and one
/// file's EXIF and location on the whole document would be wrong for the
/// rest. Each TIFF page keeps its own colour profile.
public enum MultiPageBuilder {
    /// One page of the new file: page `index` (from 0) of `url`.
    public struct Page: Hashable, Sendable {
        public var url: URL
        public var index: Int
        /// The source's page count, for the sheet's "page 2 of 5".
        public var of: Int

        public init(url: URL, index: Int = 0, of count: Int = 1) {
            self.url = url
            self.index = index
            self.of = count
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The frames an animation keeps in memory pass the export budget.
        case tooManyFrames(frames: Int, width: Int, height: Int)
        case nothingToWrite

        public var errorDescription: String? {
            switch self {
            case .tooManyFrames(let frames, let width, let height):
                "\(frames.formatted()) frames of \(width.formatted()) × \(height.formatted()) pixels are more than "
                    + "this Mac can hold while the file is made. Choose a smaller frame size or fewer images."
            case .nothingToWrite:
                "None of the images could be read."
            }
        }
    }

    /// The pages of `urls`, in order: each file's first page, or all of them
    /// with `everyPage`. Reads headers only; a file that can't be read
    /// still gets its one page, which then fails when it is decoded.
    public static func pages(of urls: [URL], everyPage: Bool) -> [Page] {
        urls.flatMap { url -> [Page] in
            let count = everyPage ? PageSequence.pageCount(of: url) : 1
            return (0..<count).map { Page(url: url, index: $0, of: count) }
        }
    }

    /// The bytes an animation of `frames` frames made at `canvas` takes
    /// while ImageIO holds it: the frames at four bytes a pixel, three times
    /// over for the encoder's own copies and palettes (measured for GIF:
    /// 133 MB for 48 MB of frames).
    public static func animationBytes(frames: Int, canvas: (width: Int, height: Int)) -> Double {
        Double(frames) * Double(canvas.width) * Double(canvas.height) * 4 * 3
    }

    /// Refuses, before anything is decoded, an animation whose frames
    /// wouldn't fit the export budget. `first` is the first picture's size.
    public static func checkBudget(pageCount: Int, first: CGSize, settings: MultiPageSettings, byteLimit: Int) throws {
        guard settings.format.holdsEveryFrame else { return }
        let canvas = settings.frameCanvas(first: first)
        if animationBytes(frames: pageCount, canvas: canvas) > Double(byteLimit) {
            throw Failure.tooManyFrames(frames: pageCount, width: canvas.width, height: canvas.height)
        }
    }

    /// Writes `pages` into a new file at `url` (which must not exist; the
    /// caller puts it in place when this returns). Pages that can't be
    /// decoded are left out and returned with their error; if none can be,
    /// nothing is written and this throws. Cancel (`cancel`) is checked
    /// before every page: a cancelled build throws `CancellationError`
    /// and deletes what it wrote. `progress` gets the pages done so far.
    /// Blocking: run it on a thread that may block.
    @discardableResult
    public static func write(_ pages: [Page], settings: MultiPageSettings, to url: URL, byteLimit: Int,
                             cancel: CancellationFlag, progress: (Int) -> Void = { _ in }) throws -> [(Page, Error)] {
        guard !pages.isEmpty else { throw Failure.nothingToWrite }
        var sequences: [URL: PageSequence] = [:]
        func sequence(_ url: URL) -> PageSequence? {
            if let known = sequences[url] { return known }
            let made = PageSequence(url: url)
            sequences[url] = made
            return made
        }
        let firstSize = sequence(pages[0].url)?.pixelSize(ofPage: pages[0].index) ?? .zero
        try checkBudget(pageCount: pages.count, first: firstSize, settings: settings, byteLimit: byteLimit)
        // Animation frames are drawn into the canvas, so they are decoded no
        // larger than it needs (with headroom for the fit); documents keep
        // every pixel.
        let edge: Int? = settings.format.isAnimation
            ? { let c = settings.frameCanvas(first: firstSize); return max(c.width, c.height) * 2 }() : nil

        let writer = try MultiPageWriter(url: url, settings: settings, expectedPages: pages.count)
        var failures: [(Page, Error)] = []
        do {
            for (done, page) in pages.enumerated() {
                if cancel.isCancelled { throw CancellationError() }
                do {
                    guard let source = sequence(page.url) else { throw DecodeError.unreadable(page.url) }
                    try autoreleasepool {
                        let image = try source.page(page.index, maxPixelSize: edge, byteLimit: byteLimit)
                        try writer.add(image, delay: source.delay(ofPage: page.index), dpi: resolution(of: page.url))
                    }
                } catch let error as TIFFPageWriter.Failure {
                    // The file itself can't go on.
                    throw error
                } catch {
                    failures.append((page, error))
                }
                progress(done + 1)
            }
            if cancel.isCancelled { throw CancellationError() }
            guard writer.pageCount > 0 else { throw Failure.nothingToWrite }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return failures
    }

    /// The horizontal resolution a file records, if it records one.
    static func resolution(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [CFString: Any] else { return nil }
        return (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }
}
