import Testing
import AppKit
@testable import Agate

@Suite struct SnapshotConfigurationTests {
    typealias Configuration = SnapshotHarness.Configuration

    @Test func offWithoutOutputPath() {
        #expect(Configuration(environment: [:]) == nil)
        #expect(Configuration(environment: ["AGATE_SNAPSHOT": ""]) == nil)
        #expect(Configuration(environment: ["AGATE_OPEN": "/tmp"]) == nil)
    }

    @Test func defaults() throws {
        let config = try #require(Configuration(environment: ["AGATE_SNAPSHOT": "/tmp/a.png"]))
        #expect(config.output.path == "/tmp/a.png")
        #expect(config.open == nil)
        #expect(config.windowSize == nil)
        #expect(config.actions.isEmpty)
        #expect(config.delay == 1.5)
        #expect(!config.capturesSettings)
    }

    @Test func readsEveryVariable() throws {
        let config = try #require(Configuration(environment: [
            "AGATE_SNAPSHOT": "~/shot.png",
            "AGATE_OPEN": "/Users/someone/Pictures",
            "AGATE_WINDOW_SIZE": "1400x900",
            "AGATE_ACTIONS": "openInViewer:; zoomIn: ;;",
            "AGATE_SNAPSHOT_DELAY": "0.25",
            "AGATE_SNAPSHOT_WINDOW": "Settings",
        ]))
        #expect(!config.output.path.hasPrefix("~"))
        #expect(config.open?.path == "/Users/someone/Pictures")
        #expect(config.windowSize == CGSize(width: 1400, height: 900))
        #expect(config.actions == ["openInViewer:", "zoomIn:"])
        #expect(config.delay == 0.25)
        #expect(config.capturesSettings)
    }

    @Test func rejectsMalformedValues() throws {
        #expect(Configuration.parseSize("1400X900") == CGSize(width: 1400, height: 900))
        #expect(Configuration.parseSize("1400") == nil)
        #expect(Configuration.parseSize("0x900") == nil)
        #expect(Configuration.parseSize("wide x tall") == nil)
        let config = try #require(Configuration(environment: ["AGATE_SNAPSHOT": "/tmp/a.png",
                                                              "AGATE_SNAPSHOT_DELAY": "soon"]))
        #expect(config.delay == 1.5)
    }
}

/// Captures a real (never shown) window and checks the composite step:
/// a provider's image lands in its frame and views in front of it stay in
/// front.
@MainActor @Suite struct SnapshotCaptureTests {
    /// Solid red top half, blue bottom half.
    final class FakeCanvas: NSView, SnapshotProviding {
        func snapshotImage() -> CGImage? {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            return context.makeImage()
        }
    }

    /// An opaque green square, drawn in front of the canvas.
    final class Badge: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()
            bounds.fill()
        }
    }

    @Test func compositesProvidersUnderViewsInFront() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        let canvas = FakeCanvas(frame: NSRect(x: 100, y: 50, width: 100, height: 100))
        content.addSubview(canvas)
        let badge = Badge(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        canvas.addSubview(badge)

        let image = try #require(SnapshotHarness.capture(window))
        let scale = Int(window.backingScaleFactor)
        #expect(image.width == 300 * scale)
        let pixels = try #require(RGBA(image))
        // Points measured from the bottom left, as window coordinates are.
        #expect(pixels.isNear(x: 150, y: 125, red: 1, green: 0, blue: 0, scale: scale))
        #expect(pixels.isNear(x: 180, y: 70, red: 0, green: 0, blue: 1, scale: scale))
        #expect(pixels.isNear(x: 120, y: 70, red: 0, green: 1, blue: 0, scale: scale))
    }
}

/// Reads pixels from a CGImage by drawing it into a known RGBA layout.
struct RGBA {
    let width: Int, height: Int
    var bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    /// `x`, `y` in points from the bottom left; rows in memory run top down.
    func isNear(x: Int, y: Int, red: Double, green: Double, blue: Double, scale: Int) -> Bool {
        let px = x * scale, row = height - 1 - y * scale
        let i = (row * width + px) * 4
        let actual = [bytes[i], bytes[i + 1], bytes[i + 2]].map { Double($0) / 255 }
        return zip(actual, [red, green, blue]).allSatisfy { abs($0 - $1) < 0.1 }
    }
}
