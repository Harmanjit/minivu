import Foundation
import CoreGraphics
import ImageIO
import MinivuCore

/// Makes contact sheet pages: bitmaps for JPEG, PNG and TIFF (one file per
/// page), or a PDF with every page. All blocking; run on a GCD worker
/// (`BlockingWork`), never the main thread.
///
/// Pictures are decoded at the size of their cell, four at a time, and
/// drawn as each batch arrives, so memory holds one page and a few
/// pictures however many images the sheet has.
nonisolated enum ContactSheetRenderer {
    enum Failure: Error, LocalizedError {
        case cannotCreatePage
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotCreatePage: "The page couldn’t be created. It may be too large for the memory available."
            case .cancelled: "The contact sheet was canceled."
            }
        }
    }

    /// No picture on a sheet is decoded larger than this: a 16384 px page
    /// with a single cell doesn't need more.
    static let maxPixelSize = 8192

    /// Page `page` as a bitmap, at `scale` times the page's pixel size (1 to
    /// save; a fraction for the dialog's preview, which then decodes each
    /// picture that much smaller too). Nil when cancelled.
    static func renderPage(_ page: Int, items: [LayoutItem], settings: ContactSheetSettings, header: String?,
                           scale: Double = 1, provider: LayoutImageProvider,
                           cancel: CancellationFlag? = nil) throws -> CGImage? {
        let layout = settings.layout(imageCount: items.count, header: header)
        let size = layout.pageSize
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: settings.colorSpace.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.cannotCreatePage }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        LayoutRenderer.drawPage(page, items: items, layout: layout, style: settings.style(header: header),
                                pixelsPerUnit: scale, maxPixelSize: maxPixelSize, provider: provider,
                                cancel: cancel, in: context)
        if cancel?.isCancelled == true { return nil }
        return context.makeImage()
    }

    /// Writes every page as its own file into `folder` (a scratch folder;
    /// the caller moves them into place), named by `names`. Calls
    /// `progress` after each page with the number done. Throws
    /// `Failure.cancelled` when cancelled; files already made are the
    /// caller's to remove with the scratch folder.
    static func writeRasterPages(items: [LayoutItem], settings: ContactSheetSettings, header: String?,
                                 names: [String], into folder: URL, provider: LayoutImageProvider,
                                 cancel: CancellationFlag, progress: (Int) -> Void) throws -> [URL] {
        guard let options = settings.format.exportOptions else { return [] }
        var written: [URL] = []
        for (page, name) in names.enumerated() {
            guard !cancel.isCancelled else { throw Failure.cancelled }
            guard let image = try renderPage(page, items: items, settings: settings, header: header,
                                             provider: provider, cancel: cancel) else { throw Failure.cancelled }
            let url = folder.appendingPathComponent(name)
            try ImageEncoder.write(image, to: url, options: options, metadataSource: nil)
            written.append(url)
            progress(page + 1)
        }
        return written
    }

    /// `image` re-encoded as a high-quality JPEG and read back without
    /// decoding. A PDF context stores such an image's JPEG data as it is,
    /// where a decoded bitmap would be stored losslessly: measured on six
    /// photos on a 4K sheet, 15.8 MB became 3 MB. Transparency is
    /// flattened onto the sheet's background, which is what it is drawn on.
    static func jpegBacked(_ image: CGImage, background: ExportColor) -> CGImage {
        let options = ExportOptions(format: .jpeg, quality: 0.9, colorProfile: .original, keepMetadata: false,
                                    backgroundForOpaqueFormats: background)
        guard let data = try? ImageEncoder.encode(image, options: options, metadataSource: nil),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return image }
        return jpeg
    }

    /// Writes all pages into one PDF at `url`. Each page's media box is the
    /// page in points at the size preset's resolution (A4 at 300 dpi is
    /// A4 paper); pictures are embedded at their cell's pixel size.
    static func writePDF(items: [LayoutItem], settings: ContactSheetSettings, header: String?, to url: URL,
                         provider: LayoutImageProvider, cancel: CancellationFlag, progress: (Int) -> Void) throws {
        let layout = settings.layout(imageCount: items.count, header: header)
        let pointsPerPixel = settings.pdfPointsPerPixel
        var mediaBox = CGRect(x: 0, y: 0, width: layout.pageSize.width * pointsPerPixel,
                              height: layout.pageSize.height * pointsPerPixel)
        let info: [CFString: Any] = [kCGPDFContextCreator: "minivu", kCGPDFContextTitle: header ?? "Contact Sheet"]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw Failure.cannotCreatePage
        }
        let style = settings.style(header: header)
        let pages = layout.pageCount(forImageCount: items.count)
        for page in 0..<pages {
            guard !cancel.isCancelled else { break }
            context.beginPDFPage(nil)
            context.saveGState()
            context.scaleBy(x: pointsPerPixel, y: pointsPerPixel)
            LayoutRenderer.drawPage(page, items: items, layout: layout, style: style, pixelsPerUnit: 1,
                                    maxPixelSize: maxPixelSize, provider: provider, cancel: cancel,
                                    embed: { jpegBacked($0, background: settings.background) }, in: context)
            context.restoreGState()
            context.endPDFPage()
            progress(page + 1)
        }
        context.closePDF()
        if cancel.isCancelled { throw Failure.cancelled }
    }
}
