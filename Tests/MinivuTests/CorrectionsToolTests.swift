import Testing
import AppKit
import ImageIO
import MinivuCore
import MinivuRender
@testable import Minivu

/// A document for a file that needn't exist: tool state only previews and
/// commits operations, which never touches pixels.
@MainActor private func correctionsDocument() -> EditDocument {
    let url = URL(fileURLWithPath: "/tmp/minivu-corrections-tests/photo.jpg")
    return EditDocument(entry: FolderEntry(url: url, name: "photo.jpg", isDirectory: false, kind: .raster, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

@MainActor @Suite struct CorrectionsToolStateTests {
    /// Noise reduction and the vignette start at a visible setting, as sharpen
    /// and blur do, and apply as one step with their own titles.
    @Test func noiseReductionAndVignetteOpenWithAVisibleSetting() {
        let document = correctionsDocument()
        let noise = AdjustmentToolState(kind: .noiseReduction, document: document)
        #expect(document.preview == .noiseReduction(level: 0.5, sharpness: 0.4))
        noise.setValue(0.8, section: 0, slider: 0)
        noise.apply()
        #expect(document.operations == [.noiseReduction(level: 0.8, sharpness: 0.4)])
        #expect(document.undoTitle == "Noise Reduction")

        let vignette = AdjustmentToolState(kind: .vignette, document: document)
        #expect(document.preview == .vignette(amount: 0.5, radius: 0.5, feather: 0.5))
        vignette.setValue(-2, section: 0, slider: 0)   // clamped to -1
        #expect(document.preview == .vignette(amount: -1, radius: 0.5, feather: 0.5))
        vignette.setValue(0, section: 0, slider: 0)
        #expect(document.preview == nil && !vignette.hasPendingChanges)
        vignette.cancel()
        #expect(document.operations.count == 1)
    }

    /// Corners are placed over the uncorrected image: nothing previews until
    /// Show Result, and Apply commits one "Perspective" step.
    @Test func perspectivePreviewsOnlyWhenAskedAndAppliesOneStep() {
        let document = correctionsDocument()
        let state = PerspectiveToolState(document: document)
        #expect(!state.hasPendingChanges && document.preview == nil)
        var changes = 0
        state.onChange = { changes += 1 }
        state.setCorner(0, to: CGPoint(x: 0.1, y: 0.05))
        state.setCorner(3, to: CGPoint(x: -0.5, y: 2))   // held to the image
        #expect(state.quad.bottomLeft == CGPoint(x: 0, y: 1))
        #expect(state.hasPendingChanges && document.preview == nil && changes == 1)

        state.setShowsResult(true)
        #expect(document.preview == .perspective(state.quad))
        state.setShowsResult(false)
        #expect(document.preview == nil)

        state.apply()
        #expect(document.operations == [.perspective(state.quad)] && document.undoTitle == "Perspective")
        // Closed: a late detection or drag changes nothing.
        state.useDetected(PerspectiveQuad())
        state.setCorner(1, to: .zero)
        #expect(document.operations.count == 1 && document.preview == nil)
    }

    @Test func perspectiveDetectionResetAndAnUnchangedQuad() {
        let document = correctionsDocument()
        let state = PerspectiveToolState(document: document)
        state.detection = .running
        let found = PerspectiveQuad(topLeft: CGPoint(x: 0.2, y: 0.1), topRight: CGPoint(x: 0.8, y: 0.15),
                                    bottomRight: CGPoint(x: 0.85, y: 0.9), bottomLeft: CGPoint(x: 0.15, y: 0.85))
        state.useDetected(found)
        #expect(state.quad == found && state.detection == .found)
        state.useDetected(nil)
        #expect(state.quad == found && state.detection == .none)
        state.setShowsResult(true)
        state.reset()
        #expect(state.quad == PerspectiveQuad() && !state.showsResult && document.preview == nil)
        state.apply()
        #expect(document.operations.isEmpty, "the image's own corners correct nothing")
    }

    @Test func perspectiveGeometryGrabsTheNearestCorner() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 200)
        let quad = PerspectiveQuad()
        #expect(PerspectiveGeometry.corner(at: CGPoint(x: 104, y: 53), quad: quad, in: rect) == 0)
        #expect(PerspectiveGeometry.corner(at: CGPoint(x: 495, y: 248), quad: quad, in: rect) == 2)
        #expect(PerspectiveGeometry.corner(at: CGPoint(x: 300, y: 150), quad: quad, in: rect) == nil)
        #expect(PerspectiveGeometry.normalised(CGPoint(x: 300, y: 100), in: rect) == CGPoint(x: 0.5, y: 0.25))
        #expect(PerspectiveGeometry.normalised(CGPoint(x: -50, y: 900), in: rect) == CGPoint(x: 0, y: 1))
        #expect(PerspectiveGeometry.blend(quad, u: 0.5, v: 0.5) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func canvasSizeModelMakesTheOperation() {
        var model = CanvasSizeModel(width: 600, height: 400)
        #expect(model.isUnchanged && !model.crops)
        model.setWidthPercent(150)
        model.setHeight(99_999)   // held to the largest side
        #expect(model.width == 900 && model.height == CanvasSize.maximumSide)
        model.setHeight(300)
        #expect(model.crops)
        model.anchor = .topRight
        model.fill = EditColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        #expect(model.operation == .canvasSize(CanvasSize(width: 900, height: 300, anchor: .topRight,
                                                          fill: EditColor(red: 0.2, green: 0.4, blue: 0.6))))
        model.transparent = true
        guard case .canvasSize(let canvas) = model.operation else {
            Issue.record("not a canvas size")
            return
        }
        #expect(canvas.fill.alpha == 0)
    }

    @Test func watermarkStatePreviewsAndAppliesOneStep() {
        let document = correctionsDocument()
        var initial = Watermark()
        initial.text = "© 2026"
        let state = EffectToolState(kind: .watermark, document: document, initial: initial) { .watermark($0) }
        #expect(state.title == "Watermark" && document.preview == .watermark(initial))
        state.update { $0.kind = .image }   // no picture yet: nothing to show
        #expect(document.preview == nil)
        state.update { $0.kind = .text; $0.tiled = true }
        state.apply()
        #expect(document.undoTitle == "Watermark" && document.operations.count == 1)
    }
}

extension AppWindowTests {
    /// The G11 tools and the watermark in a real (windowed) viewer.
    @MainActor @Suite(.serialized) struct CorrectionsViewerTests {
        init() { _ = NSApplication.shared }

        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// A dull, low-contrast gradient JPEG, which Auto Enhance has
        /// something to do for.
        func dullJPEG(in folder: ScratchFolder) throws -> URL {
            let url = folder.url.appendingPathComponent("dull.jpg")
            let width = 600, height = 400
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let gradient = try #require(CGGradient(colorsSpace: space, colors: [
                CGColor(srgbRed: 0.45, green: 0.4, blue: 0.33, alpha: 1),
                CGColor(srgbRed: 0.7, green: 0.64, blue: 0.55, alpha: 1),
            ] as CFArray, locations: [0, 1]))
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(destination))
            return url
        }

        @Test func everyNewToolIsInTheMenuAndPanelAndEnabled() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            for action in [Selector.autoEnhance, .reduceNoise, .addVignette, .correctPerspective, .changeCanvasSize,
                           .addWatermark] {
                #expect(viewer.validateEditAction(action) == true, "\(action)")
                #expect(viewer.toolsPanel.row(for: action)?.isEnabled == true, "\(action)")
                #expect(viewer.toolsPanel.row(for: action)?.title.isEmpty == false, "\(action)")
            }
        }

        @Test func autoEnhanceMeasuresOnceAndAppliesOneStep() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try dullJPEG(in: folder)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.autoEnhance(nil)
            #expect(viewer.autoEnhanceTask != nil)
            #expect(viewer.validateEditAction(.autoEnhance) == false, "not again while it measures")
            await viewer.autoEnhanceTask?.value
            let document = try #require(viewer.editSession?.document)
            guard case .autoEnhance(let enhance)? = document.operations.last else {
                Issue.record("no Auto Enhance step: \(document.operations)")
                return
            }
            #expect(!enhance.isIdentity && document.undoTitle == "Auto Enhance" && document.operations.count == 1)
            #expect(viewer.validateEditAction(.autoEnhance) == true)
            // The stored values render the edit; the canvas gets it.
            await TestTiming.waitUntil { viewer.editSession?.hasDisplayedEdit == true }
            #expect(viewer.editSession?.hasDisplayedEdit == true)
            viewer.undoEdit()
            #expect(document.operations.isEmpty)
        }

        @Test func perspectiveOverlayEditsTheCornersAndApplyChangesTheSize() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.correctPerspective(nil)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            guard case .custom(let open as PerspectiveToolState)? = viewer.activeTool else {
                Issue.record("perspective did not open")
                return
            }
            let overlay = try #require(viewer.container.canvasOverlay as? PerspectiveOverlayView)
            #expect(overlay.state === open && overlay.accessibilityLabel() == "Perspective corners")
            #expect(viewer.flyouts.isPinned(.left) && viewer.toolsPanel.inspector != nil)
            let session = try #require(viewer.editSession)
            open.update {
                $0.topLeft = CGPoint(x: 0.1, y: 0)
                $0.topRight = CGPoint(x: 0.9, y: 0)
            }
            open.setShowsResult(true)
            #expect(overlay.isHidden, "corners hide while the result shows")
            viewer.closeTool(applying: true)
            #expect(viewer.container.canvasOverlay == nil)
            // The bottom edge is the longer: 600 wide; the sides hypot(60, 400).
            #expect(session.document.outputSize == CGSize(width: 600, height: 404))
            #expect(session.document.undoTitle == "Perspective")
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 404) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 404))
        }

        @Test func canvasSizeOpensASheetAndWatermarkTakesAChosenPicture() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            let picture = try folder.jpeg("logo.jpg", width: 80, height: 40)
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            let window = try #require(viewer.window)
            await TestTiming.waitUntil { viewer.canEditCurrent }

            viewer.changeCanvasSize(nil)
            await TestTiming.waitUntil { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            #expect(sheet.title == "Canvas Size")
            window.endSheet(sheet)
            await TestTiming.waitUntil { window.attachedSheet == nil }

            let saved = ViewerWindowController.askForWatermarkImage
            defer { ViewerWindowController.askForWatermarkImage = saved }
            ViewerWindowController.askForWatermarkImage = { _, completion in completion(picture) }
            viewer.addWatermark(nil)
            await TestTiming.waitUntil { viewer.activeEffect != nil }
            let state = try #require(viewer.activeEffect as? EffectToolState<Watermark>)
            #expect(state.payload.text.hasPrefix("© "))
            viewer.chooseWatermarkImage(for: state)
            #expect(state.payload.kind == .image && state.payload.imageName == "logo.jpg")
            #expect(state.payload.imageBookmark != nil)
            let session = try #require(viewer.editSession)
            #expect(session.document.preview == .watermark(state.payload))
            viewer.closeTool(applying: true)
            #expect(session.document.undoTitle == "Watermark")
        }
    }
}
