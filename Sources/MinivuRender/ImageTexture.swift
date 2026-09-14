import Foundation
import Metal
import CoreGraphics
import ImageIO
import MinivuCore

/// A decoded image on the GPU, ready for the canvas.
///
/// The texture may be smaller than the image (a screen-sized preview of a
/// 50 MP photo), so everything that positions the image uses `imageSize`,
/// the full oriented pixel size, and the shader works in normalised
/// coordinates. A preview and the full-resolution texture of the same image
/// are therefore interchangeable under the same zoom and pan.
public final class ImageTexture: @unchecked Sendable {
    public let texture: MTLTexture
    /// Full pixel size of the oriented image this texture shows.
    public let imageSize: CGSize
    /// True when the texture holds every pixel of the image.
    public let isFullResolution: Bool
    /// True for extended-range content (values above 1.0 are highlights).
    public let isHDR: Bool
    /// How far above SDR white the content reaches (1 for SDR).
    public let contentHeadroom: Float

    public var textureSize: CGSize { CGSize(width: texture.width, height: texture.height) }

    /// Approximate GPU memory in bytes, including the mip chain.
    public var byteCost: Int {
        let bpp = texture.pixelFormat == .rgba16Float ? 8 : 4
        return texture.width * texture.height * bpp * 4 / 3
    }

    init(texture: MTLTexture, imageSize: CGSize, isFullResolution: Bool, isHDR: Bool, contentHeadroom: Float) {
        self.texture = texture
        self.imageSize = imageSize
        self.isFullResolution = isFullResolution
        self.isHDR = isHDR
        self.contentHeadroom = contentHeadroom
    }
}

/// Turns a decoded CGImage into a mipmapped texture with a single colour
/// conversion and no CPU-to-GPU copy (DESIGN.md 4.2 steps 3 to 5).
public enum TextureUploader {
    /// Metal's texture size limit on every Apple Silicon GPU.
    public static let maximumDimension = 16384

    /// Uploads `decoded`. Runs on the calling thread and waits for the GPU,
    /// so call it from a background task.
    public static func upload(_ decoded: DecodedImage, gpu: GPU = .shared) throws -> ImageTexture {
        let image = decoded.image
        let oriented = decoded.orientation.swapsAxes
            ? CGSize(width: image.height, height: image.width)
            : CGSize(width: image.width, height: image.height)

        // Stay inside the texture limit, preserving aspect ratio.
        let longest = max(oriented.width, oriented.height)
        let scale = longest > CGFloat(maximumDimension) ? CGFloat(maximumDimension) / longest : 1
        let width = max(1, Int((oriented.width * scale).rounded()))
        let height = max(1, Int((oriented.height * scale).rounded()))

        let deep = decoded.isHDR || decoded.needsDeepStorage
        let format: MTLPixelFormat = deep ? .rgba16Float : .bgra8Unorm_srgb
        let bytesPerPixel = deep ? 8 : 4
        let alignment = gpu.device.minimumLinearTextureAlignment(for: format)
        let bytesPerRow = roundUp(width * bytesPerPixel, to: alignment)
        let pageSize = Int(getpagesize())
        let length = roundUp(bytesPerRow * height, to: pageSize)

        // Page-aligned memory the GPU can adopt without copying.
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: pageSize)
        guard let buffer = gpu.device.makeBuffer(bytesNoCopy: memory, length: length,
                                                 options: .storageModeShared,
                                                 deallocator: { pointer, _ in pointer.deallocate() }) else {
            memory.deallocate()
            throw GPUError.allocationFailed("an image buffer")
        }

        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        if deep {
            colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        }
        guard let context = CGContext(data: memory, width: width, height: height,
                                      bitsPerComponent: deep ? 16 : 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw GPUError.allocationFailed("a bitmap context")
        }
        if decoded.isHDR {
            // Keep highlights instead of tone mapping them to SDR on draw.
            context.setEDRTargetHeadroom(max(decoded.contentHeadroom, 1))
        }
        context.interpolationQuality = .high
        // The page-aligned memory isn't zeroed, and drawing normally blends
        // the image over what is already there: a transparent pixel would
        // keep old bytes. Copy mode writes every pixel, alpha included, and
        // costs less than clearing first. The image covers the whole bitmap.
        context.setBlendMode(.copy)
        // CGContext's origin is bottom-left; our textures are top-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(decoded.orientation.transform(width: CGFloat(width), height: CGFloat(height)))
        let drawSize = decoded.orientation.swapsAxes
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        // The flip above would draw the image upside down; undo it for the
        // image itself, since CGImage rows are stored top first.
        context.saveGState()
        context.translateBy(x: 0, y: drawSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: drawSize))
        context.restoreGState()

        let linearDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                        height: height, mipmapped: false)
        linearDescriptor.storageMode = .shared
        linearDescriptor.usage = .shaderRead
        guard let linear = buffer.makeTexture(descriptor: linearDescriptor, offset: 0, bytesPerRow: bytesPerRow) else {
            throw GPUError.allocationFailed("a linear texture")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw GPUError.allocationFailed("a mipmapped texture")
        }
        blit.copy(from: linear, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0,
                  destinationLevel: 0, sliceCount: 1, levelCount: 1)
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }

        return ImageTexture(texture: texture, imageSize: decoded.imageSize,
                            isFullResolution: decoded.isFullResolution && scale == 1,
                            isHDR: decoded.isHDR, contentHeadroom: decoded.contentHeadroom)
    }

    static func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }
}
