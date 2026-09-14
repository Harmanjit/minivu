import Testing
import Foundation
import CoreGraphics
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// The slideshow's transition shader and the geometry behind it.
///
/// Reference pictures come from the canvas renderer, a different shader, so
/// "the slideshow shows the old image" means "looks exactly as the viewer
/// shows it at best fit", not "agrees with itself".
@Suite struct SlideshowRendererTests {
    /// 4:3 like the view, so the old slide fills it (corners included).
    static let viewWidth = 128, viewHeight = 96

    /// Four solid quadrants of the given sRGB colours, as an SDR texture.
    static func texture(width: Int, height: Int, colors: [(CGFloat, CGFloat, CGFloat)]) throws -> ImageTexture {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // CG's origin is bottom left: top-left, top-right, bottom-left, bottom-right.
        let rects = [CGRect(x: 0, y: h, width: w, height: h), CGRect(x: w, y: h, width: w, height: h),
                     CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w, y: 0, width: w, height: h)]
        for (rect, color) in zip(rects, colors) {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(rect)
        }
        let image = try #require(context.makeImage())
        let decoded = DecodedImage(image: image, orientation: .up, imageSize: CGSize(width: width, height: height),
                                   isFullResolution: true, isHDR: false, contentHeadroom: 1, needsDeepStorage: false)
        return try TextureUploader.upload(decoded)
    }

    /// Landscape: red, green, blue, white.
    static func oldSlide() throws -> ImageTexture {
        try texture(width: 64, height: 48, colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1)])
    }

    /// Portrait, in other colours: cyan, magenta, yellow, grey. At best fit
    /// it is 48 × 96 pixels from x = 40, black either side.
    static func newSlide() throws -> ImageTexture {
        try texture(width: 32, height: 64, colors: [(0, 1, 1), (1, 0, 1), (1, 1, 0), (0.5, 0.5, 0.5)])
    }

    static func target() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SlideshowRenderer.pixelFormat,
                                                         width: viewWidth, height: viewHeight, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return GPU.shared.device.makeTexture(descriptor: d)!
    }

    static func render(_ frame: SlideshowFrame) throws -> MTLTexture {
        let target = target()
        try SlideshowRenderer().draw(frame, into: target)
        return target
    }

    /// The image as the viewer's canvas shows it at best fit on black.
    static func reference(_ image: ImageTexture) throws -> MTLTexture {
        let size = CGSize(width: viewWidth, height: viewHeight)
        let frame = CanvasFrame(image: image,
                                transform: .bestFit(imageSize: image.imageSize, viewSize: size, enlargeSmall: true),
                                background: SIMD3(0, 0, 0), checkerboard: false)
        return try Fixtures.render(frame, width: viewWidth, height: viewHeight)
    }

    static func rgb(_ texture: MTLTexture, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let p = Fixtures.pixel(texture, x, y)
        return SIMD3(p.x, p.y, p.z)
    }

    /// Largest channel difference over the whole picture.
    static func maxDifference(_ a: MTLTexture, _ b: MTLTexture) -> Float {
        var worst: Float = 0
        for y in 0..<viewHeight {
            for x in 0..<viewWidth {
                worst = max(worst, difference(rgb(a, x, y), rgb(b, x, y)))
            }
        }
        return worst
    }

    /// Largest channel difference between two colours.
    static func difference(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        max(Swift.abs(a.x - b.x), Swift.abs(a.y - b.y), Swift.abs(a.z - b.z))
    }

    static func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 0.02) -> Bool {
        difference(a, b) < tolerance
    }

    func frame(_ transition: SlideshowTransition, _ progress: Float, _ old: ImageTexture?, _ new: ImageTexture?,
               direction: SlideshowDirection = .forward) -> SlideshowFrame {
        SlideshowFrame(from: old, to: new, transition: transition, progress: progress, direction: direction,
                       enlargeSmallImages: true)
    }

    // MARK: - Shader

    @Test(arguments: SlideshowTransition.allCases)
    func startsOnTheOldSlideAndEndsOnTheNew(_ transition: SlideshowTransition) throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let oldReference = try Self.reference(old), newReference = try Self.reference(new)
        for direction in [SlideshowDirection.forward, .backward] {
            let start = try Self.render(frame(transition, 0, old, new, direction: direction))
            let end = try Self.render(frame(transition, 1, old, new, direction: direction))
            #expect(Self.maxDifference(start, oldReference) < 0.005, "\(transition) \(direction) at 0")
            #expect(Self.maxDifference(end, newReference) < 0.005, "\(transition) \(direction) at 1")
        }
    }

    @Test func crossFadeMidpointIsTheAverage() throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let a = try Self.reference(old), b = try Self.reference(new)
        let mid = try Self.render(frame(.crossFade, 0.5, old, new))
        for (x, y) in [(10, 10), (50, 30), (70, 70), (120, 90), (64, 48)] {
            #expect(Self.close(Self.rgb(mid, x, y), (Self.rgb(a, x, y) + Self.rgb(b, x, y)) / 2), "at \(x), \(y)")
        }
    }

    @Test func fadeThroughBlackIsDarkHalfWay() throws {
        let mid = try Self.render(frame(.fadeThroughBlack, 0.5, try Self.oldSlide(), try Self.newSlide()))
        var brightest: Float = 0
        for y in stride(from: 0, to: Self.viewHeight, by: 4) {
            for x in stride(from: 0, to: Self.viewWidth, by: 4) { brightest = max(brightest, Self.rgb(mid, x, y).max()) }
        }
        #expect(brightest < 0.01)
    }

    @Test func wipeSplitsTheScreenHalfWay() throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let a = try Self.reference(old), b = try Self.reference(new)
        // Going forward the new slide comes in from the right.
        let forward = try Self.render(frame(.wipe, 0.5, old, new))
        #expect(Self.close(Self.rgb(forward, 44, 30), Self.rgb(a, 44, 30)))
        #expect(Self.close(Self.rgb(forward, 84, 30), Self.rgb(b, 84, 30)))
        // Backward, from the left.
        let backward = try Self.render(frame(.wipe, 0.5, old, new, direction: .backward))
        #expect(Self.close(Self.rgb(backward, 44, 30), Self.rgb(b, 44, 30)))
        #expect(Self.close(Self.rgb(backward, 84, 30), Self.rgb(a, 84, 30)))
    }

    @Test func slideMovesOnlyTheNewSlide() throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let a = try Self.reference(old), b = try Self.reference(new)
        let mid = try Self.render(frame(.slide, 0.5, old, new))
        // The old slide stays put on the left; the new one is half a screen
        // (64 px) short of home on the right.
        #expect(Self.close(Self.rgb(mid, 20, 30), Self.rgb(a, 20, 30)))
        #expect(Self.close(Self.rgb(mid, 44, 70), Self.rgb(a, 44, 70)))
        #expect(Self.close(Self.rgb(mid, 110, 30), Self.rgb(b, 46, 30)))
        #expect(Self.close(Self.rgb(mid, 110, 70), Self.rgb(b, 46, 70)))
        #expect(Self.rgb(mid, 70, 30).max() < 0.01)   // the new slide's black margin
    }

    @Test func pushMovesBothSlides() throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let a = try Self.reference(old), b = try Self.reference(new)
        let mid = try Self.render(frame(.push, 0.5, old, new))
        // The old slide's right half now sits on the left.
        #expect(Self.close(Self.rgb(mid, 20, 30), Self.rgb(a, 84, 30)))
        #expect(Self.close(Self.rgb(mid, 44, 70), Self.rgb(a, 108, 70)))
        #expect(Self.close(Self.rgb(mid, 110, 30), Self.rgb(b, 46, 30)))
        // Backward it all mirrors: the new slide enters from the left.
        let back = try Self.render(frame(.push, 0.5, old, new, direction: .backward))
        #expect(Self.close(Self.rgb(back, 108, 30), Self.rgb(a, 44, 30)))
        #expect(Self.close(Self.rgb(back, 20, 30), Self.rgb(b, 84, 30)))
    }

    @Test func irisOpensFromTheCentre() throws {
        let old = try Self.oldSlide(), new = try Self.newSlide()
        let a = try Self.reference(old), b = try Self.reference(new)
        let mid = try Self.render(frame(.iris, 0.5, old, new))
        #expect(Self.close(Self.rgb(mid, 64, 48), Self.rgb(b, 64, 48)))
        #expect(Self.close(Self.rgb(mid, 60, 40), Self.rgb(b, 60, 40)))
        for (x, y) in [(1, 1), (126, 1), (1, 94), (126, 94)] {
            #expect(Self.close(Self.rgb(mid, x, y), Self.rgb(a, x, y)), "corner \(x), \(y)")
        }
        // Round on a wide screen, not stretched to its shape: half way, the
        // radius is 40 px (soft edge ±3), up, down, left and right alike.
        #expect(Self.close(Self.rgb(mid, 64, 84), Self.rgb(b, 64, 84)))
        #expect(Self.close(Self.rgb(mid, 64, 12), Self.rgb(b, 64, 12)))
        #expect(Self.close(Self.rgb(mid, 109, 48), Self.rgb(a, 109, 48)))
        #expect(Self.close(Self.rgb(mid, 19, 48), Self.rgb(a, 19, 48)))
    }

    @Test func dissolveMixesBlotchesHalfWay() throws {
        let gray = try Self.texture(width: 64, height: 48, colors: Array(repeating: (0, 0, 0), count: 4))
        let white = try Self.texture(width: 64, height: 48, colors: Array(repeating: (1, 1, 1), count: 4))
        let mid = try Self.render(frame(.dissolve, 0.5, gray, white))
        var newCount = 0, oldCount = 0, total = 0
        for y in 0..<Self.viewHeight {
            for x in 0..<Self.viewWidth {
                let value = Self.rgb(mid, x, y).x
                if value > 0.95 { newCount += 1 }
                if value < 0.05 { oldCount += 1 }
                total += 1
            }
        }
        #expect(newCount > total / 5, "new \(newCount) of \(total)")
        #expect(oldCount > total / 5, "old \(oldCount) of \(total)")
        // Blotches, not grain: neighbouring pixels mostly agree.
        #expect(abs(Self.rgb(mid, 30, 30).x - Self.rgb(mid, 31, 30).x) < 0.2)
    }

    @Test func missingSlidesAreBlack() throws {
        let fadeIn = try Self.render(frame(.crossFade, 0.5, nil, try Self.oldSlide()))
        let reference = try Self.reference(try Self.oldSlide())
        #expect(Self.close(Self.rgb(fadeIn, 10, 10), Self.rgb(reference, 10, 10) / 2))
        let nothing = try Self.render(.still(nil))
        #expect(Self.rgb(nothing, 64, 48).max() == 0)
    }

    /// A solid extended-range slide (linear P3 above SDR white), mipmapped
    /// like an uploaded HDR photo.
    static func hdrSlide(_ value: SIMD3<Float>, headroom: Float) throws -> ImageTexture {
        let width = 64, height = 48
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = Float16(value.x); pixels[i * 4 + 1] = Float16(value.y); pixels[i * 4 + 2] = Float16(value.z)
        }
        let gpu = GPU.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                         mipmapped: true)
        d.storageMode = .shared
        let texture = try #require(gpu.device.makeTexture(descriptor: d))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: width * 8)
        let commands = try #require(gpu.queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return ImageTexture(texture: texture, imageSize: CGSize(width: width, height: height), isFullResolution: true,
                            isHDR: true, contentHeadroom: headroom)
    }

    /// HDR slides roll off to the display exactly as the viewer's canvas
    /// does, each on its own terms: at t = 1 the slide matches the canvas at
    /// the same display headroom, and halfway through a cross-fade with an
    /// SDR slide the mix is of the two slides as each would show alone.
    @Test func hdrSlidesToneMapLikeTheCanvas() throws {
        let hdr = try Self.hdrSlide(SIMD3(3, 1.5, 0.25), headroom: 4)
        let sdr = try Self.oldSlide()
        let size = CGSize(width: Self.viewWidth, height: Self.viewHeight)
        for headroom: Float in [1, 2, 4] {
            let canvas = try Fixtures.render(
                CanvasFrame(image: hdr, transform: .bestFit(imageSize: hdr.imageSize, viewSize: size, enlargeSmall: true),
                            background: SIMD3(0, 0, 0), displayHeadroom: headroom, checkerboard: false),
                width: Self.viewWidth, height: Self.viewHeight)
            var still = frame(.crossFade, 1, sdr, hdr)
            still.displayHeadroom = headroom
            let shown = try Self.render(still)
            #expect(Self.close(Self.rgb(shown, 64, 48), Self.rgb(canvas, 64, 48), 0.005), "headroom \(headroom)")
            #expect(Self.rgb(shown, 64, 48).max() <= headroom + 0.001, "fits headroom \(headroom)")
            if headroom == 4 {
                #expect(Self.close(Self.rgb(shown, 64, 48), SIMD3(3, 1.5, 0.25), 0.01))   // passes through
            }

            var mid = frame(.crossFade, 0.5, sdr, hdr)
            mid.displayHeadroom = headroom
            let mixed = try Self.render(mid)
            let sdrAlone = try Self.reference(sdr)
            for (x, y) in [(10, 10), (120, 90)] {
                let expected = (Self.rgb(sdrAlone, x, y) + Self.rgb(canvas, x, y)) / 2
                #expect(Self.close(Self.rgb(mixed, x, y), expected, 0.01), "mix at \(x), \(y), headroom \(headroom)")
            }
        }
    }

    @Test func snapshotIsTheViewSize() throws {
        let image = try SlideshowRenderer().snapshot(.still(try Self.oldSlide(), enlargeSmallImages: true),
                                                     width: 200, height: 100)
        #expect(image?.width == 200 && image?.height == 100)
    }

    // MARK: - Geometry and choices

    @Test func aspectFitCentresOnBlack() {
        let view = CGSize(width: 1920, height: 1080)
        // Portrait photo in a landscape screen: full height, centred.
        #expect(SlideshowGeometry.fitRect(imageSize: CGSize(width: 4000, height: 6000), viewSize: view,
                                          enlargeSmall: false) == CGRect(x: 600, y: 0, width: 720, height: 1080))
        // Wider than the screen: full width.
        #expect(SlideshowGeometry.fitRect(imageSize: CGSize(width: 6000, height: 2000), viewSize: view,
                                          enlargeSmall: false) == CGRect(x: 0, y: 220, width: 1920, height: 640))
        // Small images stay at actual size unless enlarged.
        let small = CGSize(width: 640, height: 480)
        #expect(SlideshowGeometry.fitRect(imageSize: small, viewSize: view, enlargeSmall: false)
            == CGRect(x: 640, y: 300, width: 640, height: 480))
        #expect(SlideshowGeometry.fitRect(imageSize: small, viewSize: view, enlargeSmall: true)
            == CGRect(x: 240, y: 0, width: 1440, height: 1080))
        #expect(SlideshowGeometry.fitRect(imageSize: .zero, viewSize: view, enlargeSmall: true) == .zero)
    }

    @Test func transitionGeometry() {
        let view = CGSize(width: 1000, height: 500)
        let image = CGSize(width: 1000, height: 500)
        func rects(_ t: SlideshowTransition, _ p: CGFloat, _ d: SlideshowDirection = .forward) -> (CGRect?, CGRect?) {
            SlideshowGeometry.rects(transition: t, progress: p, direction: d, fromImage: image, toImage: image,
                                    viewSize: view, enlargeSmall: false)
        }
        let home = CGRect(origin: .zero, size: view)
        #expect(rects(.slide, 0.25).0 == home)
        #expect(rects(.slide, 0.25).1?.minX == 750)
        #expect(rects(.slide, 0.25, .backward).1?.minX == -750)
        #expect(rects(.push, 0.25).0?.minX == -250)
        #expect(rects(.push, 0.25, .backward).0?.minX == 250)
        for transition in SlideshowTransition.allCases {
            #expect(rects(transition, 0).0 == home, "\(transition) starts with the old slide at home")
            #expect(rects(transition, 1).1 == home, "\(transition) ends with the new slide at home")
        }
        let zoom = rects(.zoom, 0.5)
        #expect(zoom.0?.width == 1150 && zoom.0?.midX == 500 && zoom.0?.midY == 250)
        #expect(zoom.1?.width == 950 && zoom.1?.midX == 500)
    }

    @Test func easingKeepsTheEndsAndTheMiddle() {
        #expect(SlideshowEasing.easeInOut(0) == 0)
        #expect(SlideshowEasing.easeInOut(0.5) == 0.5)
        #expect(SlideshowEasing.easeInOut(1) == 1)
        #expect(SlideshowEasing.easeInOut(-1) == 0 && SlideshowEasing.easeInOut(2) == 1)
        #expect(SlideshowEasing.easeInOut(0.1) < 0.1 && SlideshowEasing.easeInOut(0.9) > 0.9)
    }

    @Test func randomNeverRepeatsThePreviousTransition() {
        var generator = SeededGenerator(state: 7)
        var previous: SlideshowTransition?
        var seen: Set<SlideshowTransition> = []
        for _ in 0..<400 {
            let next = SlideshowTransition.random(after: previous, using: &generator)
            #expect(next != previous)
            seen.insert(next)
            previous = next
        }
        #expect(seen.count == SlideshowTransition.allCases.count)
    }

    @Test func transitionsKeepTheirStoredNamesAndShaderOrder() throws {
        #expect(SlideshowTransition.allCases.map(\.rawValue)
            == ["crossFade", "fadeThroughBlack", "slide", "push", "wipe", "zoom", "iris", "dissolve"])
        #expect(SlideshowTransition.allCases.map(\.shaderIndex) == Array(0..<8))
        let data = try JSONEncoder().encode([SlideshowTransition.iris])
        #expect(try JSONDecoder().decode([SlideshowTransition].self, from: data) == [.iris])
    }

    @Test func uniformsCarryHeadroomAndDirection() throws {
        let old = try Self.oldSlide()
        var f = frame(.wipe, 0.25, old, nil, direction: .backward)
        f.displayHeadroom = 0.5
        let u = SlideshowRenderer.uniforms(for: f, viewSize: CGSize(width: 1000, height: 600))
        #expect(u.params.z == 1)   // never below SDR white
        #expect(u.params.w == 1)
        #expect(u.params.y == Float(SlideshowTransition.wipe.shaderIndex))
        #expect(u.params.x == SlideshowEasing.easeInOut(0.25))
        #expect(u.fromInfo.x == 1 && u.toInfo.x == 0)
        #expect(u.view.z == 18)   // 3% of the short side
    }
}
