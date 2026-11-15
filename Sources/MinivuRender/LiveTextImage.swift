import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// The picture on the canvas as a still image for text recognition (the
/// viewer's Live Text).
///
/// Live Text reads what is shown, not the file: an edit's render, a page of
/// a document, a frame of a paused animation are all just the texture the
/// canvas draws. Reading that texture back costs one GPU pass and no
/// decode, and it is already at the size the screen needed (sharper only
/// if the user zoomed in), so recognition never sees more pixels than were
/// decoded for display.
///
/// Text recognition wants an ordinary picture: upright, 8 bits, SDR. An HDR
/// texture is tone mapped from its own headroom rather than clipped, so
/// text drawn in highlights brighter than paper white keeps its edges
/// instead of turning into white on white. This is a picture for a reader,
/// never written anywhere, so going down to SDR here costs the app none of
/// its HDR.
public enum LiveTextImage {
    /// The longest edge handed to text recognition. A screen-sized texture
    /// is well inside it; a full-resolution one (the user zoomed in) is
    /// scaled down, since recognition gains nothing from 50 MP and the
    /// readback would cost a buffer of that size.
    public static let maximumLongEdge = 4096

    /// One context, made on first use, sharing the app's device and queue so
    /// it can read the canvas's private textures. Nothing is cached between
    /// renders: each image is read once.
    private static let context = CIContext(mtlCommandQueue: GPU.shared.queue, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .name: "minivu Live Text",
    ])

    /// `texture` as an upright 8-bit sRGB image no longer than
    /// `maximumLongEdge` on its long side, or nil if Core Image can't read
    /// it. Blocks while the GPU works, so call it off the main thread.
    public static func render(_ texture: ImageTexture, maximumLongEdge: Int = maximumLongEdge) -> CGImage? {
        let metal = texture.texture
        guard metal.width > 0, metal.height > 0, maximumLongEdge > 0 else { return nil }
        // The canvas's two storages (DESIGN.md 4.3): half float in extended
        // linear Display P3, or 8-bit Display P3 in an `_srgb` texture,
        // which reads as the linear form of that space.
        let space = metal.pixelFormat == .rgba16Float
            ? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            : CGColorSpace(name: CGColorSpace.linearDisplayP3)!
        guard var image = CIImage(mtlTexture: metal, options: [.colorSpace: space]) else { return nil }
        // Core Image reads row 0 as the bottom; the canvas's textures keep
        // the top row first. An exact flip puts the picture upright.
        let height = CGFloat(metal.height)
        image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
        if texture.isHDR, texture.contentHeadroom > 1 {
            let toneMap = CIFilter.toneMapHeadroom()
            toneMap.inputImage = image
            toneMap.sourceHeadroom = texture.contentHeadroom
            toneMap.targetHeadroom = 1
            image = toneMap.outputImage ?? image
        }
        let longEdge = CGFloat(max(metal.width, metal.height))
        if longEdge > CGFloat(maximumLongEdge) {
            // After the tone map, so nothing here is above 1 for the
            // resampler to clip (see "Core Image on macOS 27" in DESIGN.md).
            let scale = CGFloat(maximumLongEdge) / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        }
        let extent = CGRect(x: 0, y: 0, width: max(1, (image.extent.width).rounded()),
                            height: max(1, (image.extent.height).rounded()))
        return context.createCGImage(image, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
