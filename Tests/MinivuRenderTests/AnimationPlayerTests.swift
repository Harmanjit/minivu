import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// An animated GIF of solid-colour frames, written by ImageIO.
func writeAnimatedGIF(colors: [(CGFloat, CGFloat, CGFloat)], delay: Double, loopCount: Int = 0,
                      width: Int = 40, height: Int = 30) -> URL {
    let url = Fixtures.directory.appendingPathComponent("anim-\(UUID()).gif")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
        as CFDictionary)
    for color in colors {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(dest))
    return url
}

@MainActor @Suite(.serialized) struct AnimationPlayerTests {
    static let rgb: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]

    /// Which of red, green or blue a frame texture shows, read from its
    /// centre pixel (BGRA, in P3, so pure sRGB primaries are only near 255).
    func colour(_ texture: ImageTexture) -> String {
        let t = texture.texture
        var p = [UInt8](repeating: 0, count: 4)
        t.getBytes(&p, bytesPerRow: t.width * 4, from: MTLRegionMake2D(t.width / 2, t.height / 2, 1, 1),
                   mipmapLevel: 0)
        let (b, g, r) = (Int(p[0]), Int(p[1]), Int(p[2]))
        if r > 200 && g < 120 && b < 120 { return "red" }
        if g > 200 && r < 160 && b < 160 { return "green" }
        if b > 200 && r < 120 && g < 120 { return "blue" }
        return "?(\(r),\(g),\(b))"
    }

    func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func sizesAndSlots() {
        #expect(AnimationPlayer.frameSize(imageSize: CGSize(width: 400, height: 300), maxPixelSize: 2880) == (400, 300))
        #expect(AnimationPlayer.frameSize(imageSize: CGSize(width: 400, height: 300), maxPixelSize: 200) == (200, 150))
        // Every frame when they fit, else a handful to decode ahead into.
        #expect(AnimationPlayer.slotCount(frameCount: 30, bytesPerFrame: 1 << 20) == 30)
        #expect(AnimationPlayer.slotCount(frameCount: 100, bytesPerFrame: 1 << 20) == 8)
        #expect(AnimationPlayer.slotCount(frameCount: 100, bytesPerFrame: 40 << 20) == AnimationPlayer.minimumSlots)
        #expect(AnimationPlayer.slotCount(frameCount: 2, bytesPerFrame: 40 << 20) == 2)
    }

    @Test func playsFramesInOrderAndReusesTexturesEachLoop() async throws {
        let url = writeAnimatedGIF(colors: Self.rgb, delay: 0.03)
        let player = AnimationPlayer(url: url, pixelSize: 1000)
        var shown: [ImageTexture] = []
        player.onFrame = { shown.append($0) }
        await waitUntil { shown.count >= 7 }
        player.stop()
        try #require(shown.count >= 7)
        #expect(shown.prefix(7).map(colour) == ["red", "green", "blue", "red", "green", "blue", "red"])
        #expect(shown[0].imageSize == CGSize(width: 40, height: 30))
        #expect(shown[0].textureSize == CGSize(width: 40, height: 30))
        #expect(shown[0].isFullResolution)
        // The second loop shows the very textures of the first: no allocations
        // and no decoding once every frame is in memory.
        #expect(shown[3] === shown[0] && shown[4] === shown[1] && shown[6] === shown[0])
        #expect(Set(shown.map { ObjectIdentifier($0) }).count == 3)
    }

    @Test func keepsToTheFileTiming() async throws {
        let url = writeAnimatedGIF(colors: Self.rgb, delay: 0.05)
        let player = AnimationPlayer(url: url, pixelSize: 100)
        var times: [TimeInterval] = []
        player.onFrame = { _ in times.append(ProcessInfo.processInfo.systemUptime) }
        await waitUntil { times.count >= 13 }
        player.stop()
        try #require(times.count >= 13)
        // Frames are 50 ms apart. The median interval is used rather than
        // the total, because other test suites share the main actor and can
        // make any single frame late; the player then catches up against its
        // deadlines (intended), which shortens the following interval. The
        // median ignores both, while a player that drifted or ran at the
        // wrong rate would still move it.
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        #expect(median > 0.04 && median < 0.065, "\(intervals)")
    }

    @Test func pauseAndSuspendStopTheClock() async throws {
        let url = writeAnimatedGIF(colors: Self.rgb, delay: 0.02)
        let player = AnimationPlayer(url: url, pixelSize: 100)
        var count = 0
        var states = 0
        player.onFrame = { _ in count += 1 }
        player.onStateChange = { states += 1 }
        await waitUntil { count >= 3 }

        player.pause()
        #expect(!player.isPlaying && states == 1)
        let paused = count
        let frame = player.currentFrame
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == paused)
        #expect(player.currentFrame == frame)

        player.play()
        await waitUntil { count >= paused + 3 }
        #expect(count >= paused + 3)

        player.isSuspended = true
        #expect(player.isPlaying)   // still wants to play when visible again
        let suspended = count
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == suspended)
        player.isSuspended = false
        await waitUntil { count >= suspended + 2 }
        #expect(count >= suspended + 2)
        player.stop()
        let stopped = count
        try await Task.sleep(for: .milliseconds(100))
        #expect(count == stopped)
    }

    @Test func finiteLoopsEndOnTheLastFrame() async throws {
        let url = writeAnimatedGIF(colors: Self.rgb, delay: 0.02, loopCount: 1)
        let player = AnimationPlayer(url: url, pixelSize: 100)
        var shown: [String] = []
        var ended = false
        player.onFrame = { shown.append(self.colour($0)) }
        player.onStateChange = { ended = true }
        await waitUntil { ended }
        #expect(ended && !player.isPlaying)
        #expect(shown == ["red", "green", "blue"])
        #expect(player.currentFrame == 2)
        // Play starts it over.
        player.play()
        await waitUntil { shown.count >= 4 }
        #expect(shown.dropFirst(3).first == "red")
        player.stop()
    }

    /// Too big to keep every frame: a few slots, decoded just ahead, still in
    /// order, and the slots are reused rather than reallocated.
    @Test func largeAnimationsDecodeAhead() async throws {
        let colours: [(CGFloat, CGFloat, CGFloat)] = Array(repeating: Self.rgb, count: 4).flatMap { $0 }
        let url = writeAnimatedGIF(colors: colours, delay: 0.02, width: 64, height: 64)
        let player = AnimationPlayer(url: url, pixelSize: 64, playing: true, budgetBytes: 1, gpu: .shared)
        let names = ["red", "green", "blue"]
        var shown: [ImageTexture] = []
        var seen: [String] = []   // read as each frame goes up: slots are reused
        var torn: [String] = []
        player.onFrame = { texture in
            // The frame going off screen and the one before it may still be
            // drawing on the GPU: nothing may have been decoded into them.
            let n = shown.count
            for back in 1...2 where n >= back && self.colour(shown[n - back]) != names[(n - back) % 3] {
                torn.append("frame \(n - back) overwritten when frame \(n) went up")
            }
            shown.append(texture)
            seen.append(self.colour(texture))
        }
        await waitUntil { shown.count >= 15 }
        player.stop()
        try #require(shown.count >= 15)
        let expected = (0..<15).map { names[$0 % 3] }
        #expect(Array(seen.prefix(15)) == expected)
        #expect(Set(shown.map { ObjectIdentifier($0) }).count == AnimationPlayer.minimumSlots)
        #expect(torn.isEmpty, "\(torn)")
    }

    /// Frames land in their textures upright and unmirrored, at full size
    /// (drawn straight from the source) and scaled (the thumbnail route).
    @Test func framesAreUpright() async throws {
        let url = Fixtures.directory.appendingPathComponent("quadrants-\(UUID()).gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for _ in 0..<2 {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]]
            CGImageDestinationAddImage(dest, Fixtures.quadrants(width: 64, height: 32), props as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))

        for pixelSize in [64, 32] {
            let player = AnimationPlayer(url: url, pixelSize: pixelSize, playing: false)
            var first: ImageTexture?
            player.onFrame = { first = first ?? $0 }
            await waitUntil { first != nil }
            player.stop()
            let t = try #require(first).texture
            #expect(t.width == pixelSize)
            func rgb(_ x: Int, _ y: Int) -> [Int] {
                var p = [UInt8](repeating: 0, count: 4)
                t.getBytes(&p, bytesPerRow: t.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                return [Int(p[2]), Int(p[1]), Int(p[0])]   // stored BGRA
            }
            let (w, h) = (t.width, t.height)
            let red = rgb(w / 4, h / 4), green = rgb(w * 3 / 4, h / 4), blue = rgb(w / 4, h * 3 / 4)
            #expect(red[0] > 200 && red[1] < 120 && red[2] < 120, "top left \(red) at \(pixelSize)")
            #expect(green[1] > 200 && green[0] < 160 && green[2] < 160, "top right \(green) at \(pixelSize)")
            #expect(blue[2] > 200 && blue[0] < 120 && blue[1] < 120, "bottom left \(blue) at \(pixelSize)")
        }
    }

    @Test func resizingKeepsThePlaceAndChangesTheFrameSize() async throws {
        let url = writeAnimatedGIF(colors: Self.rgb, delay: 0.03, width: 400, height: 300)
        let player = AnimationPlayer(url: url, pixelSize: 100)
        var shown: [ImageTexture] = []
        player.onFrame = { shown.append($0) }
        await waitUntil { !shown.isEmpty }
        #expect(shown[0].textureSize == CGSize(width: 100, height: 75))
        #expect(!shown[0].isFullResolution && !player.isFullResolution)
        #expect(shown[0].imageSize == CGSize(width: 400, height: 300))

        player.setPixelSize(4000)
        let before = shown.count
        await waitUntil { shown.count >= before + 2 }
        #expect(player.isFullResolution)
        player.stop()
        let later = try #require(shown.last)
        #expect(later.textureSize == CGSize(width: 400, height: 300))
        #expect(later.isFullResolution)
    }
}
