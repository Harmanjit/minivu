import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// Regression tests from the editing engine's review, through documents and
/// files: colour and alpha fidelity of the stored original, saving originals
/// larger than a texture, HDR saved as SDR, and 16-bit saves after a resize.
///
/// Not on the main actor: only the document calls hop there, so the pixel
/// work in between doesn't hold up other suites' main-actor timing tests.
@Suite(.serialized) struct EditReviewTests {
    typealias F = EditFixtures
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func document(_ url: URL) async -> EditDocument {
        await MainActor.run { EditDocument(entry: FolderEntry(url: url)!) }
    }

    /// Every pixel of `image` drawn into an 8-bit premultiplied RGBA bitmap
    /// in `space`, top row first.
    func bytes(_ image: CGImage, space: CGColorSpace? = nil) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space ?? srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// A `width` x `height` 8-bit image in `space` with pseudo-random opaque
    /// colours, so every level of every channel is exercised.
    func noise(width: Int, height: Int, space: CGColorSpace) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt64 = 99
        for i in 0..<(width * height) {
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                data[i * 4 + c] = UInt8(seed >> 56)
            }
            data[i * 4 + 3] = 255
        }
        return ctx.makeImage()!
    }

    func worstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - The stored original

    /// A flip applied twice changes no pixel, so the saved file must match
    /// the original. Converting sRGB to 8-bit Display P3 on the way in was
    /// up to 9 levels off on the way back out.
    @Test(arguments: [CGColorSpace.sRGB as String, CGColorSpace.displayP3 as String])
    func losslessEditSavesTheOriginalValues(spaceName: String) async throws {
        let space = CGColorSpace(name: spaceName as CFString)!
        let renderer = await EditRenderer.shared
        let original = noise(width: 256, height: 256, space: space)
        let doc = await document(Fixtures.write(original, name: "noise-\(UUID()).png", type: .png))
        try await renderer.prepare(doc)
        // Kept 8-bit, in its own space: no more memory than the viewer uses.
        #expect(await doc.source?.texture?.pixelFormat == .bgra8Unorm_srgb)
        await doc.apply(.flip(horizontal: true))
        await doc.apply(.flip(horizontal: true))
        let saved = try await renderer.renderForExport(doc.snapshot(), colorSpace: space, bitsPerComponent: 8)
        let worst = worstDifference(bytes(original, space: space), bytes(saved, space: space))
        #expect(worst <= 1, "\(spaceName): worst difference \(worst) levels")
    }

    /// Core Graphics premultiplies 8-bit pixels in encoded values, which an
    /// sRGB texture can't undo: a half-transparent orange came back as
    /// (88, 46, 21) instead of (128, 64, 26).
    @Test func semiTransparentPixelsKeepTheirColour() async throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let renderer = await EditRenderer.shared
        let doc = await document(Fixtures.write(ctx.makeImage()!, name: "alpha-\(UUID()).png", type: .png))
        try await renderer.prepare(doc)
        #expect(await doc.source?.texture?.pixelFormat == .rgba16Float)
        await doc.apply(.rotate90(turns: 2))
        let saved = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        let pixel = Array(bytes(saved)[0..<4])
        #expect(worstDifference(pixel, [128, 64, 26, 128]) <= 1, "\(pixel)")
    }

    // MARK: - Originals larger than a texture

    /// A 17000 px wide panorama was edited at 16384 px and saved at that
    /// size. It is still shown at the limit, but saved at its own.
    @Test func originalLargerThanATextureIsSavedAtItsOwnSize() async throws {
        let width = 17000, height = 40
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let url = Fixtures.write(ctx.makeImage()!, name: "panorama-\(UUID()).png", type: .png)

        // Not prepared: the export decodes the file.
        let renderer = await EditRenderer.shared
        let unprepared = await document(url)
        await unprepared.apply(.flip(horizontal: true))
        let direct = try await renderer.renderForExport(unprepared.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        #expect(direct.width == width && direct.height == height)

        let doc = await document(url)
        try await renderer.prepare(doc, proxyPixelSize: 2000)
        #expect(await doc.sourceSize == CGSize(width: width, height: height))
        let source = try #require(await doc.source)
        #expect(source.texture?.width == 16384 && abs(source.scale - 16384.0 / 17000) < 1e-12)
        await doc.apply(.flip(horizontal: true))
        await doc.apply(.crop(CGRect(x: 0.25, y: 0, width: 0.75, height: 1)))
        #expect(await doc.outputSize == CGSize(width: 12750, height: 40))

        let full: ImageTexture = await withCheckedContinuation { continuation in
            Task { @MainActor in renderer.renderFullResolution(doc) { continuation.resume(returning: $0) } }
        }
        #expect(full.imageSize == CGSize(width: 12750, height: 40))
        #expect(full.texture.width == EditGraph.workingLength(12750, scale: 16384.0 / 17000))

        let saved = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        #expect(saved.width == 12750 && saved.height == 40)
        // Flipped, then the left quarter cut: blue for 4250 px, then red.
        let pixels = bytes(saved)
        func rgb(_ x: Int) -> [UInt8] { Array(pixels[(20 * saved.width + x) * 4..<(20 * saved.width + x) * 4 + 3]) }
        #expect(worstDifference(rgb(0), [0, 0, 255]) <= 1 && worstDifference(rgb(4249), [0, 0, 255]) <= 1)
        #expect(worstDifference(rgb(4250), [255, 0, 0]) <= 1 && worstDifference(rgb(12749), [255, 0, 0]) <= 1)
    }

    // MARK: - HDR saved as SDR

    /// An HDR original (here a ramp to 4x SDR white, stored as a gain-map
    /// HEIC) saved into sRGB used to clip everything above white: 12 of the
    /// ramp's 16 sample points came out 255. Tone mapped, it matches the
    /// file's own SDR rendition.
    @Test func hdrSavedAsSDRIsToneMappedNotClipped() async throws {
        let renderer = await EditRenderer.shared
        let url = try Fixtures.gainMapHEIC()
        let doc = await document(url)
        try await renderer.prepare(doc)
        #expect(await doc.source?.isHDR == true)
        await doc.apply(.flip(horizontal: false))
        let saved = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        let sdr = try ImageDecoder.decode(url, allowHDR: false).image
        let savedBytes = bytes(saved), sdrBytes = bytes(sdr)
        let row = 32
        let columns = Array(stride(from: 0, to: saved.width, by: 16))
        let savedRamp = columns.map { Int(savedBytes[(row * saved.width + $0) * 4]) }
        let sdrRamp = columns.map { Int(sdrBytes[(row * sdr.width + $0) * 4]) }
        #expect(zip(savedRamp, sdrRamp).allSatisfy { abs($0 - $1) <= 3 }, "\(savedRamp) vs \(sdrRamp)")
        #expect(savedRamp.filter { $0 == 255 }.count <= 2, "\(savedRamp)")

        // An HDR target keeps the highlights: PQ holds them below 1.
        let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let hdr = try await renderer.renderForExport(doc.snapshot(), colorSpace: pq, bitsPerComponent: 16)
        #expect(hdr.width == saved.width)
    }

    // MARK: - Resampling

    /// Metal truncates a float written to a half-float texture, so round-off
    /// just below 1 lost a whole half-float step: Lanczos 3 at 4x left every
    /// fourth pixel of an opaque image at alpha 0.99951, which a 16-bit save
    /// stores as 65503.
    @Test func resizedOpaqueImageSavesFullyOpaqueIn16Bits() async throws {
        let url = Fixtures.write(Fixtures.quadrants(width: 16, height: 8), name: "opaque-\(UUID()).tiff")
        let renderer = await EditRenderer.shared
        let doc = await document(url)
        await doc.apply(.resize(width: 64, height: 32, filter: .lanczos3))
        let saved = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 16)
        var pixels = [UInt16](repeating: 0, count: saved.width * saved.height * 4)
        let ctx = CGContext(data: &pixels, width: saved.width, height: saved.height, bitsPerComponent: 16,
                            bytesPerRow: saved.width * 8, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.draw(saved, in: CGRect(x: 0, y: 0, width: saved.width, height: saved.height))
        let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        #expect(alphas.allSatisfy { $0 == 65535 }, "lowest alpha \(alphas.min()!)")
        // The flat white quadrant within a half-float step of white. (Core
        // Image's own conversion into the kernel's half-float input can still
        // land a step low, 0.03%, which no 8-bit save shows.)
        let white = pixels[(28 * saved.width + 60) * 4]
        #expect(white >= 65500, "white \(white)")
    }
}

/// Regression tests from the review that need no document, so they stay off
/// the main actor (other suites' main-actor timing tests run beside them):
/// how originals are stored, resampling at transparent edges, auto-crop on a
/// proxy, and crops that don't fit in whole pixels.
@Suite struct EditReviewGraphTests {
    typealias F = EditFixtures
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func decoded(_ image: CGImage) -> DecodedImage {
        DecodedImage(image: image, orientation: .up, imageSize: CGSize(width: image.width, height: image.height),
                     isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
    }

    @Test func storageFollowsSpaceAndTransparency() throws {
        func image(space: CGColorSpace, alpha: UInt8) -> CGImage {
            let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<16 { data[i * 4] = 128; data[i * 4 + 1] = 64; data[i * 4 + 2] = 0; data[i * 4 + 3] = 255 }
            if alpha < 255 {
                // Pixel (1, 1): the same colour at half coverage, premultiplied
                // in encoded values as Core Graphics stores it.
                data[4 * 5] = 64; data[4 * 5 + 1] = 32; data[4 * 5 + 3] = alpha
            }
            return ctx.makeImage()!
        }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // An alpha channel that is opaque everywhere (as HEIC photos decode) stays 8-bit.
        let opaque = try EditRenderer.upload(decoded(image(space: srgb, alpha: 255)), gpu: .shared)
        #expect(opaque.texture?.pixelFormat == .bgra8Unorm_srgb)
        #expect(try EditRenderer.upload(decoded(image(space: p3, alpha: 255)), gpu: .shared).texture?.pixelFormat
                == .bgra8Unorm_srgb)
        // One pixel that isn't: half float.
        let clear = try EditRenderer.upload(decoded(image(space: srgb, alpha: 128)), gpu: .shared)
        #expect(clear.texture?.pixelFormat == .rgba16Float)
        // Neither sRGB nor Display P3: half float, converted once, exactly.
        let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        #expect(EditRenderer.storage(for: decoded(image(space: adobe, alpha: 255))) == .halfFloat)

        // The half-transparent pixel's colour, unpremultiplied, is its opaque
        // neighbour's (both are encoded (128, 64, 0) before premultiplying).
        let pixels = F.pixels(clear.image)
        let neighbour = pixels[0, 0]
        let seeThrough = pixels[1, 1]
        #expect(nearly(seeThrough.w, 128.0 / 255, 1e-3))
        #expect(nearly(seeThrough.x / seeThrough.w, neighbour.x, 5e-3) && nearly(seeThrough.y / seeThrough.w, neighbour.y, 5e-3),
                "\(seeThrough) vs \(neighbour)")
    }

    /// The upload's memory is allocated, not cleared, and drawing a
    /// transparent image over it with source-over blending mixed in whatever
    /// was there. Freed blocks full of bright bytes stand in for a previous
    /// image's pixels.
    @Test func transparentPixelsDontPickUpOldMemory() throws {
        let page = Int(getpagesize())
        for _ in 0..<8 {
            let dirty = UnsafeMutableRawPointer.allocate(byteCount: page * 4, alignment: page)
            dirty.initializeMemory(as: UInt8.self, repeating: 200, count: page * 4)
            dirty.deallocate()
        }
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.25))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let source = try EditRenderer.upload(decoded(ctx.makeImage()!), gpu: .shared)
        let pixels = F.pixels(source.image)
        // The clear half is clear, the quarter-covered blue has no red or green.
        #expect(pixels.all.allSatisfy { $0.w < 0.3 && $0.x < 1e-3 }, "\(pixels.all.max { $0.x < $1.x }!)")
        #expect(pixels.at(0.75, 0.5) == SIMD4<Float>(0, 0, 0, 0))
    }

    /// Lanczos next to a transparent edge rang in alpha too (-0.12 to 1.12).
    @Test(arguments: [ResampleFilter.lanczos3, .lanczos8, .catmullRom, .quadratic])
    func ringingKeepsAlphaInRange(filter: ResampleFilter) {
        let edge = F.image(width: 16, height: 2) { x, _ in x < 8 ? SIMD4(0, 0, 0, 0) : SIMD4(1, 1, 1, 1) }
        let p = F.pixels(ResampleKernel.resize(edge, width: 64, height: 2, filter: filter))
        let row = (0..<64).map { p[$0, 0] }
        #expect(row.allSatisfy { $0.w >= 0 && $0.w <= 1 }, "\(filter) alpha \(row.map(\.w).min()!)...\(row.map(\.w).max()!)")
        // No light without coverage.
        #expect(row.allSatisfy { $0.w > 0 || ($0.x == 0 && $0.y == 0 && $0.z == 0) })
        // Opaque images are untouched by the clamp: colour still rings.
        let opaque = F.image(width: 16, height: 1) { x, _ in x < 8 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        let q = F.pixels(ResampleKernel.resize(opaque, width: 64, height: 1, filter: filter))
        #expect((0..<64).allSatisfy { abs(q[$0, 0].w - 1) < 1e-4 } && (0..<64).map { q[$0, 0].x }.max()! > 1.001)
    }

    /// At a working scale the auto-crop size is rounded to the nearest pixel
    /// and could reach past the proxy's inscribed rectangle, leaving
    /// see-through corners in the preview (alpha down to 0.74) that the saved
    /// file doesn't have.
    @Test func autoCropHasNoTransparentCornersOnAProxy() {
        let full = CGSize(width: 640, height: 320)
        for scale in [0.21, 0.37, 0.5, 1] {
            for degrees in [3.0, -12.0, 45.0, 100.0, 7.3] {
                let source = F.flat(0.5, width: EditGraph.workingLength(640, scale: scale),
                                    height: EditGraph.workingLength(320, scale: scale))
                let image = EditGraph.image(source: source, sourceSize: full,
                                            operations: [.rotate(degrees: degrees, autoCrop: true)], scale: scale)
                let size = EditGraph.outputSize(source: full, operations: [.rotate(degrees: degrees, autoCrop: true)])
                #expect(image.extent.size == CGSize(width: EditGraph.workingLength(Int(size.width), scale: scale),
                                                    height: EditGraph.workingLength(Int(size.height), scale: scale)))
                let minAlpha = F.pixels(image).all.map(\.w).min()!
                #expect(minAlpha > 0.98, "scale \(scale), \(degrees)°: min alpha \(minAlpha)")
            }
        }
    }

    @Test func nonFiniteOrFarOutCropsDontTrap() {
        let nan = EditOperation.crop(CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5))
        #expect(nan.isIdentity)
        #expect(EditOperation.crop(CGRect(x: 0, y: CGFloat.nan, width: 0.5, height: 0.5)).isIdentity)
        // Far outside on one side, a real crop on the other: whole pixels
        // come from the part inside the image.
        let far = EditOperation.crop(CGRect(x: -1e15, y: 0, width: 1e15 + 0.5, height: 1))
        #expect(!far.isIdentity)
        let size = EditGraph.outputSize(source: CGSize(width: 16384, height: 100), operations: [nan, far])
        #expect(size == CGSize(width: 8192, height: 100))
        let image = EditGraph.image(source: F.quadrants(width: 64, height: 32), sourceSize: CGSize(width: 64, height: 32),
                                    operations: [far], scale: 1)
        #expect(image.extent == CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(F.pixels(image).at(0.5, 0.25) == F.red)
    }
}
