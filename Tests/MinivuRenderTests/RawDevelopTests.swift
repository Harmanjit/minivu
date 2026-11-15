import Testing
import Foundation
import CoreGraphics
import CoreImage
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// The RAW tool's settings (G10): the operation itself, and how
/// `EditRenderer` develops a RAW file's original with them. The renders need
/// a real camera file, so those tests run only where the test assets are.
@MainActor @Suite(.serialized) struct RawDevelopTests {
    typealias F = EditFixtures
    let renderer = EditRenderer.shared
    nonisolated static let nef = RawRendererTests.folder.appendingPathComponent("nikon_d750_sample.nef")

    func document(_ url: URL) -> EditDocument {
        EditDocument(entry: FolderEntry(url: url)!)
    }

    func preview(_ doc: EditDocument, _ pixelSize: Int) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderPreview(doc, pixelSize: pixelSize) { continuation.resume(returning: $0) }
        }
    }

    func fullResolution(_ doc: EditDocument) async -> ImageTexture {
        await withCheckedContinuation { continuation in
            renderer.renderFullResolution(doc) { continuation.resume(returning: $0) }
        }
    }

    /// The mean of the middle half of a texture's green channel, which a
    /// change of exposure moves and a change of size doesn't.
    nonisolated func middleMean(_ texture: MTLTexture) -> Float {
        let p = F.pixels(texture)
        var sum: Float = 0, count = 0
        for y in stride(from: p.height / 4, to: 3 * p.height / 4, by: max(1, p.height / 64)) {
            for x in stride(from: p.width / 4, to: 3 * p.width / 4, by: max(1, p.width / 64)) {
                sum += p[x, y].y
                count += 1
            }
        }
        return sum / Float(max(count, 1))
    }

    // MARK: - The operation

    @Test func operationRoundTripsAndNeverCountsAsNothing() throws {
        let develop = RawDevelop(exposure: 0.7, temperature: 4800, tint: 12, boost: 0.8, luminanceNoiseReduction: 0.3,
                                 colorNoiseReduction: 0.6, recoversHighlights: false)
        let op = EditOperation.rawDevelop(develop)
        let decoded = try JSONDecoder().decode(EditOperation.self, from: JSONEncoder().encode(op))
        #expect(decoded == op)
        // A document written with fewer settings leaves the rest to the camera.
        let sparse = try JSONDecoder().decode(RawDevelop.self, from: Data(#"{"exposure":1}"#.utf8))
        #expect(sparse == RawDevelop(exposure: 1))
        #expect(op.title == "RAW Adjustments")
        #expect(!op.changesGeometry)
        // Even the camera's settings replace what an earlier step set.
        #expect(!EditOperation.rawDevelop(RawDevelop()).isIdentity)
    }

    @Test func theLastStepIsTheOneInEffect() {
        let first = RawDevelop(exposure: 1), second = RawDevelop(exposure: -0.5)
        #expect(RawDevelop.inEffect([.grayscale]) == nil)
        #expect(RawDevelop.inEffect([.rawDevelop(first), .crop(CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                                     .rawDevelop(second), .negative]) == second)
        // Only a RAW file has sensor data to develop.
        #expect(EditRenderer.rawDevelop(kind: .raw, operations: [.rawDevelop(first)]) == first)
        #expect(EditRenderer.rawDevelop(kind: .raster, operations: [.rawDevelop(first)]) == nil)
    }

    @Test func settingsAreFilledFromTheCamera() {
        let defaults = RawDefaults(exposure: 0, temperature: 5300, tint: 8, boost: 1, luminanceNoiseReduction: 0.1,
                                   colorNoiseReduction: 0.5, recoversHighlights: true, supportsHighlightRecovery: false)
        let filled = RawDevelop(exposure: 1, tint: -20).filled(from: defaults)
        #expect(filled == RawDevelop(exposure: 1, temperature: 5300, tint: -20, boost: 1, luminanceNoiseReduction: 0.1,
                                     colorNoiseReduction: 0.5, recoversHighlights: nil))
        var recovering = defaults
        recovering.supportsHighlightRecovery = true
        #expect(RawDevelop().filled(from: recovering).recoversHighlights == true)
        #expect(RawDevelop(recoversHighlights: false).filled(from: recovering).recoversHighlights == false)
    }

    @Test func oneRawRenderAtATimeOnSmallMacs() {
        #expect(RawRenderer.concurrentEditRenders(physicalMemory: 8 << 30) == 1)
        #expect(RawRenderer.concurrentEditRenders(physicalMemory: 16 << 30) == 2)
        #expect(RawRenderer.viewerSharesEditSlot(physicalMemory: 8 << 30))
        #expect(!RawRenderer.viewerSharesEditSlot(physicalMemory: 16 << 30))
    }

    /// On an 8 GB Mac the viewer's RAW render waits while the editor renders
    /// one, so the app never runs two at once; on a larger Mac it doesn't.
    @Test nonisolated func theViewerWaitsForTheEditorsRawRenderOnSmallMacs() {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ item: String) { lock.withLock { items.append(item) } }
            var all: [String] { lock.withLock { items } }
        }
        for (memory, shares) in [(UInt64(8) << 30, true), (UInt64(16) << 30, false)] {
            let slots = RawRenderer.RenderSlots(physicalMemory: memory)
            let log = Log()
            let editing = DispatchSemaphore(value: 0), finishEdit = DispatchSemaphore(value: 0)
            let viewerDone = DispatchSemaphore(value: 0), editDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                slots.withEditRender {
                    editing.signal()
                    finishEdit.wait()
                    log.add("editor")
                }
                editDone.signal()
            }
            editing.wait()
            DispatchQueue.global().async {
                slots.withViewerRender { log.add("viewer") }
                viewerDone.signal()
            }
            let waited = viewerDone.wait(timeout: .now() + 0.3) == .timedOut
            #expect(waited == shares, "\(memory >> 30) GB")
            finishEdit.signal()
            editDone.wait()
            if waited { viewerDone.wait() }
            #expect(log.all == (shares ? ["editor", "viewer"] : ["viewer", "editor"]), "\(memory >> 30) GB")
        }
    }

    /// The graph leaves the picture alone: the step acts where the original
    /// is developed.
    @Test func theGraphPassesThePictureThrough() {
        let source = F.quadrants()
        let image = EditGraph.image(source: source, sourceSize: source.extent.size,
                                    operations: [.rawDevelop(RawDevelop(exposure: 2))], scale: 1)
        let a = F.pixels(image), b = F.pixels(source)
        #expect(a.data == b.data)
    }

    /// On any other file the step changes nothing, at any size.
    @Test func aStepOnAPhotoThatIsNotRawIsIgnored() async throws {
        let url = Fixtures.write(Fixtures.quadrants(width: 64, height: 32), name: "raw-ignored-\(UUID()).tiff")
        let doc = document(url)
        try await renderer.prepare(doc)
        let before = F.pixels(await preview(doc, 64).texture)
        doc.apply(.rawDevelop(RawDevelop(exposure: 2)))
        #expect(doc.operations.count == 1)
        let after = F.pixels(await preview(doc, 64).texture)
        #expect(before.data == after.data)
        #expect(doc.source?.develop == nil)
        renderer.release(doc)
    }

    // MARK: - Real RAW files

    @Test(.enabled(if: RawRendererTests.hasAssets))
    func defaultsComeFromTheCamera() async throws {
        let doc = document(Self.nef)
        let defaults = try #require(await renderer.rawDefaults(for: doc))
        #expect(RawDevelop.temperatureRange.contains(defaults.temperature), "\(defaults.temperature) K")
        #expect(abs(defaults.exposure) < 1e-6 && defaults.boost == 1)
        #expect(doc.rawFilter != nil, "the file stays open for the tool's previews")
        // Not a RAW file: nothing to offer.
        let photo = document(Fixtures.write(Fixtures.quadrants(), name: "raw-defaults-\(UUID()).tiff"))
        #expect(await renderer.rawDefaults(for: photo) == nil)
        renderer.release(doc)
        #expect(doc.rawFilter == nil)
    }

    /// While the tool's sliders move the engine develops at the preview's
    /// size (a proxy with the new settings), leaving the original as it was;
    /// the full-resolution render then makes the original with them, and the
    /// two agree.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func previewsDevelopAtTheirOwnSizeAndFullResolutionAgrees() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 1200)
        let original = try #require(doc.source)
        // The engine's own rendering, the tool's starting point (the
        // original may be the camera's embedded preview, which looks a
        // little different).
        doc.preview = .rawDevelop(RawDevelop())
        let plain = await preview(doc, 1200)
        let plainMean = middleMean(plain.texture)

        let brighter = RawDevelop(exposure: 1)
        doc.preview = .rawDevelop(brighter)
        let live = await preview(doc, 1200)
        #expect(max(live.texture.width, live.texture.height) == 1200)
        #expect(live.imageSize == plain.imageSize)
        let liveMean = middleMean(live.texture)
        // One stop is twice the light, give or take the engine's tone curve.
        #expect(liveMean > plainMean * 1.5, "\(plainMean) -> \(liveMean)")
        #expect(doc.source === original, "a preview doesn't wait for a full-size development")
        #expect(doc.proxy?.develop == brighter)

        let full = await fullResolution(doc)
        #expect(full.isFullResolution)
        #expect(doc.source?.develop == brighter)
        #expect(doc.source !== original)
        let fullMean = middleMean(full.texture)
        #expect(abs(fullMean - liveMean) < liveMean * 0.08, "preview \(liveMean), full \(fullMean)")
        renderer.release(doc)
    }

    /// Undo is a change of operations like any other: the renders after it
    /// put an original without the settings back.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func undoAndRedoBringTheOriginalBackInLine() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 1000)
        let plainMean = middleMean(await preview(doc, 1000).texture)
        doc.apply(.rawDevelop(RawDevelop(exposure: -1)))
        let darkerMean = middleMean(await preview(doc, 1000).texture)
        #expect(darkerMean < plainMean * 0.75, "\(plainMean) -> \(darkerMean)")

        doc.undo()
        let undoneMean = middleMean(await preview(doc, 1000).texture)
        #expect(abs(undoneMean - plainMean) < plainMean * 0.05, "\(plainMean) after undo: \(undoneMean)")
        #expect(doc.source?.develop == nil)

        doc.redo()
        let redoneMean = middleMean(await fullResolution(doc).texture)
        #expect(redoneMean < plainMean * 0.75)
        #expect(doc.source?.develop == RawDevelop(exposure: -1))
        renderer.release(doc)
    }

    /// After the last RAW step is undone both lanes need the plain original:
    /// they share one decode, and neither keeps a stage or proxy made from
    /// the developed original it replaced.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func bothLanesShareOneDecodeOfThePlainOriginal() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 1000)
        // A resize to fewer pixels with an operation after it, so renders
        // keep stages.
        doc.apply(.rawDevelop(RawDevelop(exposure: -1)))
        doc.apply(.resize(width: 1200, height: 800, filter: .lanczos3))
        doc.apply(.vignette(amount: 0.5, radius: 0.8, feather: 0.5))
        _ = await fullResolution(doc)
        let developed = try #require(doc.source)
        #expect(developed.develop == RawDevelop(exposure: -1))

        let before = doc.sourceRemakes
        doc.undo()
        doc.undo()
        doc.undo()
        #expect(RawDevelop.inEffect(doc.operations) == nil)
        renderer.renderPreview(doc, pixelSize: 1000) { _ in }
        renderer.renderFullResolution(doc) { _ in }
        let end = Date().addingTimeInterval(30 * TestTiming.slack)
        while Date() < end, doc.source?.develop != nil || doc.previewLane.isRunning || doc.fullLane.isRunning
            || doc.previewLane.pending != nil || doc.fullLane.pending != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(doc.source?.develop == nil)
        #expect(doc.sourceRemakes == before + 1, "\(doc.sourceRemakes - before) decodes")
        for lane in [doc.previewLane, doc.fullLane] {
            #expect(lane.stage == nil || lane.stage?.source === doc.source)
        }
        #expect(doc.proxy == nil || doc.proxy?.develop == nil)
        renderer.release(doc)
    }

    /// An analysis (Remove Background, Auto Enhance, Perspective's Auto, red
    /// eyes) right after the RAW tool's Apply develops the file at the
    /// analysis size only: the document keeps its original, no full-size
    /// decode starts beside the one the full lane will make, and the
    /// picture shows the new settings all the same.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func analysisDevelopsSmallRatherThanDecodeTheOriginalAgain() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 800)
        let original = try #require(doc.source)
        let plain = try await renderer.renderForAnalysis(doc, maxPixelSize: 600)
        doc.apply(.rawDevelop(RawDevelop(exposure: 1.5)))
        let before = doc.sourceRemakes
        let brighter = try await renderer.renderForAnalysis(doc, maxPixelSize: 600)
        #expect(max(brighter.width, brighter.height) == 600)
        #expect(brighter.width == plain.width && brighter.height == plain.height)
        #expect(meanByte(brighter) > meanByte(plain) + 20, "\(meanByte(plain)) -> \(meanByte(brighter))")
        #expect(doc.source === original, "an analysis doesn't replace the original")
        #expect(doc.sourceRemakes == before, "no full-size decode for an analysis")
        #expect(doc.previewLane.stage == nil || doc.previewLane.stage?.source === doc.source)
        #expect(doc.fullLane.stage == nil || doc.fullLane.stage?.source === doc.source)

        // The same picture the full-resolution original gives, near enough.
        _ = await fullResolution(doc)
        #expect(doc.source?.develop == RawDevelop(exposure: 1.5))
        let fromFull = try await renderer.renderForAnalysis(doc, maxPixelSize: 600)
        #expect(abs(meanByte(fromFull) - meanByte(brighter)) < 6, "\(meanByte(fromFull)) vs \(meanByte(brighter))")
        renderer.release(doc)
    }

    /// Once the last RAW step is undone an analysis takes the plain original
    /// from the remake the lanes share: the renders that follow it don't
    /// decode the file again.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func analysisAfterUndoSharesTheLanesDecode() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 800)
        doc.apply(.rawDevelop(RawDevelop(exposure: -1)))
        _ = await fullResolution(doc)
        #expect(doc.source?.develop == RawDevelop(exposure: -1))
        doc.undo()
        let before = doc.sourceRemakes
        renderer.renderPreview(doc, pixelSize: 800) { _ in }
        renderer.renderFullResolution(doc) { _ in }
        _ = try await renderer.renderForAnalysis(doc, maxPixelSize: 600)
        // (Waited for rather than awaited: a render of a state already
        // delivered at full resolution never calls its completion.)
        let end = Date().addingTimeInterval(30 * TestTiming.slack)
        while Date() < end, doc.previewLane.isRunning || doc.fullLane.isRunning
            || doc.previewLane.pending != nil || doc.fullLane.pending != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(doc.source?.develop == nil)
        #expect(doc.sourceRemakes == before + 1, "\(doc.sourceRemakes - before) decodes")
        renderer.release(doc)
    }

    /// A remake finished after its settings were undone serves the render
    /// that asked for it but isn't put on the document, which keeps the
    /// original its operations want; one for the settings in effect is.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func aRemakeForSettingsNoLongerWantedIsNotInstalled() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 800)
        let original = try #require(doc.source)
        let stale = await renderer.remadeSource(doc, develop: RawDevelop(exposure: 1), qos: .userInitiated)
        #expect(stale?.develop == RawDevelop(exposure: 1))
        #expect(doc.source === original, "no step asks for those settings")

        doc.apply(.rawDevelop(RawDevelop(exposure: 1)))
        let wanted = await renderer.remadeSource(doc, develop: RawDevelop(exposure: 1), qos: .userInitiated)
        #expect(wanted != nil && doc.source === wanted)
        renderer.release(doc)
    }

    /// One engine filter, two settings rendered at once from two threads:
    /// each comes out as it does alone (the editor's two RAW slots on
    /// larger Macs let a preview and a full render overlap).
    @Test(.enabled(if: RawRendererTests.hasAssets))
    nonisolated func oneFilterRendersTwoSettingsAtOnceWithoutMixingThem() throws {
        let filter = try #require(RawDevelopFilter(url: Self.nef))
        let settings = DisplaySettings()
        let developments = [RawDevelop(exposure: -1.5), RawDevelop(exposure: 1.5)]
        func mean(_ develop: RawDevelop) -> Float? {
            guard let rendered = try? EditRenderer.renderDeveloped(filter, develop: develop,
                                                                   fullSize: filter.orientedSize, scale: 0.2,
                                                                   settings: settings, gpu: .shared) else { return nil }
            return middleMean(rendered.texture)
        }
        let alone = try developments.map { try #require(mean($0)) }
        #expect(alone[1] > alone[0] * 2)
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int: Float] = [:]
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let value = mean(developments[index % 2])
            results.lock.withLock { results.values[index] = value }
        }
        for index in 0..<8 {
            let expected = alone[index % 2]
            let value = try #require(results.values[index])
            #expect(abs(value - expected) < expected * 0.02, "render \(index): \(value), alone \(expected)")
        }
    }

    /// A save renders with the committed settings, even from a document
    /// whose original was never developed with them.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func exportsUseTheCommittedSettings() async throws {
        let doc = document(Self.nef)
        try await renderer.prepare(doc, proxyPixelSize: 800)
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        doc.apply(.resize(width: 600, height: 400, filter: .lanczos3))
        let plain = try await renderer.renderForExport(doc.snapshot(), colorSpace: srgb, bitsPerComponent: 8)
        doc.apply(.rawDevelop(RawDevelop(exposure: 1.5)))
        let snapshot = doc.snapshot()
        #expect(snapshot.source?.develop == nil, "nothing has developed the original yet")
        let brighter = try await renderer.renderForExport(snapshot, colorSpace: srgb, bitsPerComponent: 8)
        #expect(brighter.width == 600 && brighter.height == 400)
        #expect(meanByte(brighter) > meanByte(plain) + 20, "\(meanByte(plain)) -> \(meanByte(brighter))")
        renderer.release(doc)
    }

    /// With extended dynamic range on, a developed image keeps its
    /// highlights above white and measures its own headroom.
    @Test(.enabled(if: RawRendererTests.hasAssets))
    func developedImagesKeepHDR() throws {
        let filter = try #require(RawDevelopFilter(url: Self.nef))
        let hdr = DisplaySettings(showHDR: true, hdrRaw: true, hdrRawAmount: 1)
        let rendered = try EditRenderer.renderDeveloped(filter, develop: RawDevelop(exposure: 1),
                                                        fullSize: filter.orientedSize, scale: 0.25, settings: hdr,
                                                        gpu: .shared)
        #expect(rendered.texture.pixelFormat == .rgba16Float)
        #expect(rendered.texture.width == EditGraph.workingLength(Int(filter.orientedSize.width), scale: 0.25))
        #expect(rendered.headroom > 1.5, "headroom \(rendered.headroom)")
        let peak = F.pixels(rendered.texture).data.max() ?? 0
        #expect(peak > 1.5, "brightest \(peak)")

        // The same settings without extended range stay at white.
        let sdr = try EditRenderer.renderDeveloped(filter, develop: RawDevelop(exposure: 1),
                                                   fullSize: filter.orientedSize, scale: 0.25,
                                                   settings: DisplaySettings(), gpu: .shared)
        #expect(sdr.headroom == 1)
        #expect((F.pixels(sdr.texture).data.max() ?? 0) <= 1.01)
    }

    /// The mean of an 8-bit image's bytes, colour channels only.
    func meanByte(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0
        for i in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) }
        return Double(sum) / Double(width * height * 3)
    }
}
