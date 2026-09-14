import Testing
import AppKit
import QuartzCore
import MinivuCore
@testable import Minivu

/// Main-thread cost of putting a screenful of thumbnails on screen: layer
/// contents assigned and the Core Animation transaction committed, which is
/// where Core Animation prepares each new image for the display. Runs only
/// when MINIVU_BENCH_DIR points at a folder of images, e.g.
/// MINIVU_BENCH_DIR=~/latent/TestAssets swift test --filter ThumbnailCommitBenchmark
@MainActor @Suite(.serialized) struct ThumbnailCommitBenchmark {
    nonisolated static let folder = ProcessInfo.processInfo.environment["MINIVU_BENCH_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    static let cells = 48
    static let rounds = 7

    @Test(.enabled(if: folder != nil))
    func commitCost() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 8 * 150, height: 6 * 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let host = try #require(content.layer)
        let layers = (0..<Self.cells).map { index in
            let layer = CALayer()
            layer.frame = CGRect(x: index % 8 * 150, y: index / 8 * 150, width: 140, height: 140)
            layer.contentsGravity = .resizeAspect
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull()]
            host.addSublayer(layer)
            return layer
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        CATransaction.flush()

        let files = try FileManager.default.contentsOfDirectory(at: try #require(Self.folder),
                                                                includingPropertiesForKeys: nil)
            .filter(ImageFormats.isImage).sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { FolderEntry(url: $0) }
        try #require(!files.isEmpty)
        let displaySpace = window.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-bench-\(UUID()).sqlite")
        let store = try ThumbnailStore(url: storeURL)
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: storeURL.path + suffix) }
        }

        /// Fresh services, so every image is a new CGImage Core Animation
        /// has never prepared.
        func thumbnails(store: ThumbnailStore?) async -> [CGImage] {
            var images: [CGImage] = []
            for index in 0..<Self.cells {
                let service = ThumbnailService(store: store)
                configure(service, displaySpace)
                let entry = files[index % files.count]
                let image = await withCheckedContinuation { done in
                    service.request(entry, pixelSize: 256) { done.resume(returning: $0) }
                }
                if let image { images.append(image) }
            }
            return images
        }

        _ = await thumbnails(store: store)   // fills the store
        for (label, source) in [("decoded", nil as ThumbnailStore?), ("from store", store)] {
            var times: [Double] = []
            for _ in 0..<Self.rounds {
                let images = await thumbnails(store: source)
                let clock = ContinuousClock()
                let start = clock.now
                CATransaction.begin()
                // A copy per layer, as the grid's cells make (ThumbnailCellView.setImage).
                for (layer, image) in zip(layers, images) { layer.contents = image.copy() }
                CATransaction.commit()
                CATransaction.flush()
                let elapsed = clock.now - start
                times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                CATransaction.begin()
                for layer in layers { layer.contents = nil }
                CATransaction.commit()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(50))
            }
            let sorted = times.sorted()
            let info = (await thumbnails(store: source)).first
            print(String(format: "THUMB COMMIT %@: %d images, median %.2f ms, min %.2f ms, max %.2f ms  [%@, %@]",
                         label as NSString, Self.cells, sorted[sorted.count / 2], sorted[0], sorted[sorted.count - 1],
                         "\(info.map { $0.bitmapInfo.rawValue } ?? 0)" as NSString,
                         (info?.colorSpace?.name as String? ?? "?") as NSString))
        }
        print("THUMB COMMIT display space: \(displaySpace.name as String? ?? "unnamed")")
    }

    /// As the app does at launch (`AppServices.updateThumbnailColorSpace`).
    /// MINIVU_BENCH_UNCONVERTED=1 leaves the service at sRGB, for comparison.
    func configure(_ service: ThumbnailService, _ space: CGColorSpace) {
        guard ProcessInfo.processInfo.environment["MINIVU_BENCH_UNCONVERTED"] == nil else { return }
        service.displayColorSpace = space
    }
}
