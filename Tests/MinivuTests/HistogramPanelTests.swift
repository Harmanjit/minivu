import Testing
import AppKit
import CoreGraphics
import MinivuCore
import MinivuRender
@testable import Minivu

/// The viewer's histogram panel: what it plots, how often it recomputes,
/// and the colour count.
@Suite struct HistogramPlotTests {
    func data(_ bins: [Int: UInt32], pixels: Int) -> HistogramData {
        var channel = [UInt32](repeating: 0, count: 256)
        for (bin, count) in bins { channel[bin] = count }
        return HistogramData(red: channel, green: channel, blue: channel, luminance: channel, aboveSDRWhite: 0,
                             pixelCount: pixels)
    }

    @Test func scaleIgnoresTheEndBins() {
        let spiky = data([0: 5000, 100: 40, 200: 90, 255: 9000], pixels: 14130)
        #expect(HistogramPlot.scale(spiky, channels: [.red]) == 90)
        // Only end bins: they set the scale rather than dividing by zero.
        #expect(HistogramPlot.scale(data([255: 10], pixels: 10), channels: [.luminance]) == 10)
        #expect(HistogramPlot.scale(data([:], pixels: 0), channels: [.red]) == 1)
    }

    @Test func clippingWarningsLightAboveOneInAThousand() {
        let clipped = data([0: 2, 128: 997, 255: 1], pixels: 1000)
        #expect(HistogramPlot.clipped(clipped, channels: [.red, .green], highlights: false) == [.red, .green])
        #expect(HistogramPlot.clipped(clipped, channels: [.red], highlights: true).isEmpty)   // exactly 0.1%
    }

    @Test func hoverPositionToLevel() {
        #expect(HistogramPlot.level(at: 0, width: 256) == 0)
        #expect(HistogramPlot.level(at: 128.5, width: 256) == 128)
        #expect(HistogramPlot.level(at: 300, width: 256) == 255)
        #expect(HistogramPlot.level(at: -4, width: 256) == 0)
        #expect(HistogramPlot.level(at: 50, width: 100) == 128)
    }

    @Test func percentages() {
        #expect(HistogramPanelView.percent(0) == "0%")
        #expect(HistogramPanelView.percent(0.004) == "0.4%")
        #expect(HistogramPanelView.percent(0.123) == "12%")
    }
}

@MainActor @Suite(.serialized) struct HistogramPanelControllerTests {
    func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func texture(width: Int, height: Int) throws -> ImageTexture {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try TextureUploader.upload(DecodedImage(image: image, orientation: .up,
                                                       imageSize: CGSize(width: width, height: height),
                                                       isFullResolution: true, isHDR: false, contentHeadroom: 1,
                                                       needsDeepStorage: false))
    }

    @Test func computesOnlyWhileVisibleAndAtMostTenTimesASecond() async throws {
        let panel = HistogramPanelController()
        let textures = try (1...8).map { try texture(width: 10 * $0, height: 10) }

        // Hidden: nothing is computed.
        panel.show(textures[0])
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.computeCount == 0)
        #expect(panel.model.data == nil)

        // Shown: the texture on the canvas is measured.
        panel.setActive(true)
        await waitUntil { panel.model.data != nil }
        #expect(panel.computeCount == 1)
        #expect(panel.model.data?.pixelCount == 100)

        // A slider drag: a new texture every 10 ms or so. Computations start
        // at most every 100 ms however long the drag takes (a busy machine
        // stretches the sleeps), and the last texture wins.
        let clock = ContinuousClock()
        let start = clock.now
        let before = panel.computeCount
        for texture in textures.dropFirst() {
            panel.show(texture)
            try await Task.sleep(for: .milliseconds(10))
        }
        await waitUntil { panel.model.data?.pixelCount == 800 }
        let elapsed = clock.now - start
        #expect(panel.model.data?.pixelCount == 800)
        let allowed = Int(Double(elapsed.components.attoseconds) / 1e17) + Int(elapsed.components.seconds) * 10 + 1
        #expect(panel.computeCount - before <= allowed, "computed \(panel.computeCount - before) times in \(elapsed)")

        // The same texture again costs nothing.
        let count = panel.computeCount
        panel.show(textures.last)
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.computeCount == count)

        // Hidden again: new textures wait until it shows.
        panel.setActive(false)
        panel.show(textures[0])
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.computeCount == count)
        panel.setActive(true)
        await waitUntil { panel.model.data?.pixelCount == 100 }
        #expect(panel.computeCount == count + 1)

        panel.show(nil)
        #expect(panel.model.data == nil)
        panel.stop()
    }

    @Test func countsColoursOncePerFile() async throws {
        let scratch = try ScratchFolder()
        let first = try #require(FolderEntry(url: scratch.jpeg("a.jpg", width: 64, height: 48)))
        let second = try #require(FolderEntry(url: scratch.jpeg("b.jpg", width: 64, height: 48)))
        let panel = HistogramPanelController()
        panel.setEntry(first)
        #expect(panel.model.colorCount == .idle)
        #expect(panel.model.canCountColors)
        panel.model.onCountColors?()
        #expect(panel.model.colorCount == .counting)
        await waitUntil { panel.model.colorCount != .counting }
        guard case .counted(let count) = panel.model.colorCount else {
            Issue.record("not counted: \(panel.model.colorCount)")
            return
        }
        #expect(count >= 1 && count < 50)   // a flat colour, give or take JPEG rounding

        panel.setEntry(second)
        #expect(panel.model.colorCount == .idle)
        // Back to the first file: remembered, no decode.
        panel.setEntry(first)
        #expect(panel.model.colorCount == .counted(count))
        panel.setEntry(nil)
        #expect(!panel.model.canCountColors)
        panel.stop()
    }
}

extension AppWindowTests {
    /// The panel inside a real viewer: idle while the right panel is hidden,
    /// following the canvas once Toggle Histogram pins it, and counting on
    /// Count Colors.
    @MainActor @Suite(.serialized) struct ViewerHistogramTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        @Test func toggleHistogramAndCountColours() async throws {
            let scratch = try ScratchFolder()
            let list = try [scratch.jpeg("a.jpg", width: 800, height: 600), scratch.jpeg("b.jpg", width: 640, height: 480)]
                .map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canvasTexture != nil }
            let panel = viewer.histogramPanel
            #expect(panel.computeCount == 0)
            #expect(!panel.isActive)

            let toggle = NSMenuItem(title: "", action: .toggleHistogram, keyEquivalent: "")
            #expect(viewer.validateMenuItem(toggle))
            #expect(toggle.state == .off)
            viewer.toggleHistogram(nil)
            #expect(viewer.validateMenuItem(toggle))
            #expect(toggle.state == .on)
            await waitUntil { panel.model.data != nil }
            #expect(panel.model.data?.pixelCount ?? 0 > 0)

            #expect(viewer.validateMenuItem(NSMenuItem(title: "", action: .countColors, keyEquivalent: "")))
            viewer.countColors(nil)
            await waitUntil { if case .counted = panel.model.colorCount { true } else { false } }
            if case .counted = panel.model.colorCount {} else { Issue.record("\(panel.model.colorCount)") }

            // The next image: its histogram follows, and its count starts afresh.
            viewer.nextImage(nil)
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 640, height: 480) }
            #expect(panel.model.colorCount == .idle)
            await waitUntil { panel.model.data?.sampledWidth == 640 }
            #expect(panel.model.data?.sampledWidth == 640)

            viewer.toggleHistogram(nil)
            await waitUntil { !panel.isActive }
            #expect(!panel.isActive)
        }
    }
}
