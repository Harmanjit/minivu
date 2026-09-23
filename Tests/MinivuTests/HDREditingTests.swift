import Testing
import AppKit
import CoreImage
import Metal
import MinivuCore
@testable import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// An HDR photo in a full-screen viewer on an XDR display (headroom 8
    /// now, 16 at most) stays HDR while tools open, preview, apply, cancel
    /// and close: the texture on the canvas is HDR with highlights past 2.5,
    /// EDR is on, and frames are drawn for the screen's headroom. The display
    /// sits far from the real ones and presentation options are fake.
    @MainActor @Suite(.serialized) struct HDREditingTests {
        init() { _ = NSApplication.shared }

        /// A gain-map HEIC: a grey ramp from black to 4x SDR white over its
        /// left three quarters, 4x white beyond, so every resampled copy
        /// keeps highlights at 4.
        static func gainMapHEIC(in folder: ScratchFolder, width: Int = 3000, height: Int = 2000) throws -> URL {
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let hdr = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: CGFloat(width) * 0.75, y: 0),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, colorSpace: space)!,
                "inputColor1": CIColor(red: 4, green: 4, blue: 4, colorSpace: space)!,
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4, "inputTargetHeadroom": 1])
            let data = try #require(CIContext().heifRepresentation(of: sdr, format: .RGBA8,
                                                                   colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                                   options: [.hdrImage: hdr]))
            let url = folder.url.appendingPathComponent("hdr.heic")
            try data.write(to: url)
            return url
        }

        /// The brightest colour value in a half-float texture's top level.
        static func peak(_ texture: MTLTexture) -> Float {
            guard texture.pixelFormat == .rgba16Float else { return 0 }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: texture.width,
                                                             height: texture.height, mipmapped: false)
            d.storageMode = .shared
            guard let copy = GPU.shared.device.makeTexture(descriptor: d),
                  let commands = GPU.shared.queue.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else { return 0 }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, to: copy, destinationSlice: 0, destinationLevel: 0,
                      sliceCount: 1, levelCount: 1)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
            copy.getBytes(&pixels, bytesPerRow: texture.width * 8,
                          from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            var peak: Float = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                peak = max(peak, Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
            }
            return peak
        }

        /// Runs `body` with the HDR photo (or an SDR JPEG) open in a
        /// full-screen viewer on the XDR display.
        func withHDRViewer(sdr: Bool = false,
                           _ body: @MainActor (ViewerWindowController) async throws -> Void) async throws {
            let frame = CGRect(x: 40_000, y: 40_000, width: 800, height: 500)
            let xdr = DisplayInfo(id: 21, frame: frame, backingScale: 2, headroom: 8, potentialHeadroom: 16,
                                  colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
            let options = FakePresentationOptions()
            let saved = (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared)
            Displays.provider = FakeScreens([xdr])
            Displays.choice = { .browserDisplay }
            Displays.browserWindow = { nil }
            FullScreenPresentation.shared = options.makeCoordinator()
            // The settle time is short, so `expectHDR` can wait past it.
            let settleTime = ImageCanvasView.headroomSettleTime
            ImageCanvasView.headroomSettleTime = 0.05
            defer {
                ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
                (Displays.provider, Displays.choice, Displays.browserWindow, FullScreenPresentation.shared) = saved
                ImageCanvasView.headroomSettleTime = settleTime
            }
            let folder = try ScratchFolder()
            let url = sdr ? try folder.jpeg("sdr.jpg", width: 3000, height: 2000) : try Self.gainMapHEIC(in: folder)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: true) { _ in }
            let viewer = try #require(ViewerWindowController.current)
            #expect(viewer.window?.frame == frame)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            try await body(viewer)
        }

        /// What an XDR screen would show is HDR: `what` names the moment. The
        /// texture is HDR and EDR is on, and the frame follows the screen: it
        /// is drawn for the headroom the screen has, again after a dip the
        /// system announces, and again after a rise, well past the settle
        /// time, that nobody announces.
        func expectHDR(_ viewer: ViewerWindowController, _ what: String,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
            let canvas = viewer.canvasView
            guard let image = canvas.image else {
                Issue.record("\(what): nothing on the canvas", sourceLocation: sourceLocation)
                return
            }
            #expect(image.isHDR && image.contentHeadroom > 3, "\(what): texture flagged SDR", sourceLocation: sourceLocation)
            let peak = Self.peak(image.texture)
            #expect(peak > 2.5, "\(what): brightest value \(peak)", sourceLocation: sourceLocation)
            #expect(canvas.isExtendedDynamicRange, "\(what): EDR off", sourceLocation: sourceLocation)
            guard let screens = Displays.provider as? FakeScreens else {
                Issue.record("\(what): no fake display", sourceLocation: sourceLocation)
                return
            }
            @MainActor func refresh() { for _ in 0..<3 { canvas.displayRefreshed() } }
            refresh()
            #expect(canvas.lastFrameHeadroom == 8, "\(what): frame drawn for headroom \(canvas.lastFrameHeadroom as Any)",
                    sourceLocation: sourceLocation)
            screens.displays[0].headroom = 1.5
            screens.postChange()
            refresh()
            #expect(canvas.lastFrameHeadroom == 1.5, "\(what): a dip left the frame at \(canvas.lastFrameHeadroom as Any)",
                    sourceLocation: sourceLocation)
            try? await Task.sleep(for: .milliseconds(150))
            refresh()
            screens.displays[0].headroom = 8
            refresh()
            #expect(canvas.lastFrameHeadroom == 8,
                    "\(what): an unannounced rise left the frame at \(canvas.lastFrameHeadroom as Any)",
                    sourceLocation: sourceLocation)
        }

        /// Whether the canvas shows the viewer's own decode of the file
        /// rather than an edit render.
        func showsViewersTexture(_ viewer: ViewerWindowController) -> Bool {
            viewer.editSession?.hasDisplayedEdit != true
        }

        /// A tool opened and closed without a change leaves the viewer's own
        /// texture on the canvas: nothing is rendered in its place when the
        /// original has been decoded for editing, nor when the tool closes
        /// and the canvas grows back.
        @Test func toolsOpenedAndClosedWithoutAChangeKeepTheViewersHDRTexture() async throws {
            try await withHDRViewer { viewer in
                await expectHDR(viewer, "viewing")
                let tools: [(String, () -> Void)] = [
                    ("Rotate & Flip", { viewer.showRotateFlipTool(nil) }),
                    ("Crop", { viewer.cropImage(nil) }),
                    ("Lighting", { viewer.adjustLighting(nil) }),
                    ("Text and Shapes", { viewer.drawAnnotations(nil) }),
                    ("Clone Stamp", { viewer.cloneStamp(nil) }),
                ]
                for (name, open) in tools {
                    open()
                    await TestTiming.waitUntil { viewer.activeTool != nil && viewer.editSession?.document.outputSize != nil }
                    #expect(viewer.activeTool?.title == name)
                    // Long enough for a render started by the decode to arrive.
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(showsViewersTexture(viewer), "\(name) open: replaced by an edit render")
                    await expectHDR(viewer, "\(name) open")

                    viewer.closeTool()
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(showsViewersTexture(viewer), "\(name) closed: replaced by an edit render")
                    await expectHDR(viewer, "\(name) closed")
                }

                // Zoomed in with a tool open and nothing edited, full
                // resolution comes from the original already decoded for
                // editing, not from decoding the file again.
                viewer.healingBrush(nil)
                await TestTiming.waitUntil { viewer.activeTool != nil }
                viewer.canvasView.actualSize(at: nil)
                await TestTiming.waitUntil { viewer.canvasTexture?.isFullResolution == true }
                #expect(viewer.editSession?.hasDisplayedEdit == true && viewer.canvasTexture?.isFullResolution == true)
                await expectHDR(viewer, "zoomed in with Healing Brush open")
                viewer.closeTool()
            }
        }

        /// Edits show as HDR renders, live and applied, and a change taken
        /// back (Cancel, Undo) puts the viewer's own texture back.
        @Test func editsStayHDRAndTakingThemBackRestoresTheViewersTexture() async throws {
            try await withHDRViewer { viewer in
                // TEMPORARY PROBE: what the session is about to take as the
                // size of the viewer's texture, which it must later match to
                // put that texture back.
                print("PROBE before tool: displayed=\(viewer.editDisplayedImageSize.map(String.init(describing:)) ?? "nil") " +
                      "canvas=\(viewer.canvasView.bounds.size) backing=\(viewer.window?.backingScaleFactor ?? -1) " +
                      "full=\(viewer.canvasTexture?.isFullResolution.description ?? "nil")")
                // A temperature preview, then Cancel.
                viewer.adjustColors(nil)
                guard case .adjustment(let colors)? = viewer.activeTool else {
                    Issue.record("Colors didn't open")
                    return
                }
                let session = try #require(viewer.editSession)
                colors.setValue(0.3, section: 0, slider: 3)
                await TestTiming.waitUntil { session.hasDisplayedEdit }
                await expectHDR(viewer, "temperature preview")
                viewer.closeTool()
                await TestTiming.waitUntil { showsViewersTexture(viewer) }
                // TEMPORARY PROBE: if the restore never happened, these say why.
                print("PROBE after cancel: displayed=\(viewer.editDisplayedImageSize.map(String.init(describing:)) ?? "nil") " +
                      "source=\(session.document.sourceSize.map(String.init(describing:)) ?? "nil") " +
                      "ops=\(session.document.operations.count) preview=\(session.document.preview.debugDescription) " +
                      "hasDisplayedEdit=\(session.hasDisplayedEdit)")
                #expect(showsViewersTexture(viewer), "temperature cancelled: the edit render stayed")
                await expectHDR(viewer, "temperature cancelled")

                // Applied this time: the edit stays on screen after the tool closes.
                viewer.adjustColors(nil)
                guard case .adjustment(let warmer)? = viewer.activeTool else {
                    Issue.record("Colors didn't open again")
                    return
                }
                warmer.setValue(0.3, section: 0, slider: 3)
                viewer.closeTool(applying: true)
                await TestTiming.waitUntil { session.document.deliveredOperations == session.document.operations }
                try await Task.sleep(for: .milliseconds(200))
                #expect(!showsViewersTexture(viewer) && session.document.operations.count == 1)
                await expectHDR(viewer, "temperature applied")

                // A line drawn: only the line is SDR.
                var drawing: AnnotationToolState?
                viewer.openDrawing(tool: .line) { state, _ in drawing = state }
                await TestTiming.waitUntil { drawing != nil }
                let state = try #require(drawing)
                var line = state.newObject(.line)
                line.start = CGPoint(x: 0.1, y: 0.5)
                line.end = CGPoint(x: 0.5, y: 0.5)
                state.add(line)
                await TestTiming.waitUntil { session.document.deliveredOperations?.count == 2 }
                await expectHDR(viewer, "line drawn")
                viewer.closeTool(applying: true)
                await TestTiming.waitUntil { session.document.operations.count == 2 }
                try await Task.sleep(for: .milliseconds(300))
                await expectHDR(viewer, "drawing applied and closed")

                // Both undone: the unedited photo is the viewer's texture again.
                viewer.undoEdit()
                viewer.undoEdit()
                #expect(session.document.operations.isEmpty)
                await TestTiming.waitUntil { showsViewersTexture(viewer) }
                #expect(showsViewersTexture(viewer), "undone: the edit render stayed")
                try await Task.sleep(for: .milliseconds(300))
                #expect(showsViewersTexture(viewer), "undone: a render replaced the viewer's texture again")
                await expectHDR(viewer, "all undone")
            }
        }

        /// A change a tool makes in several steps in one event passes through
        /// a document with nothing to render: a second Colors section taking
        /// over from the first, one effect replacing another, a drawing's
        /// re-edit cancelled. The unedited photo never comes up in between;
        /// the edit on screen stays until the render of the new state
        /// replaces it.
        @Test func changesMadeInSeveralStepsNeverFlashTheUneditedPhoto() async throws {
            try await withHDRViewer { viewer in
                @MainActor func nextTurn() async {
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                }
                /// Runs `change` with an edit render on screen and checks what
                /// the canvas shows: that render, in the event and after it,
                /// until a render of the new state replaces it.
                @MainActor func expectEditStays(_ what: String, _ change: () -> Void) async throws {
                    let session = try #require(viewer.editSession)
                    #expect(session.hasDisplayedEdit, "\(what): no edit on screen to begin with")
                    let shown = viewer.canvasTexture
                    change()
                    #expect(session.hasDisplayedEdit && viewer.canvasTexture === shown,
                            "\(what): the unedited photo came up in the event")
                    await nextTurn()
                    #expect(session.hasDisplayedEdit, "\(what): the unedited photo came up after the event")
                    var unedited = false
                    let end = TestTiming.patience()
                    while viewer.canvasTexture === shown
                        || session.document.deliveredOperations != session.document.renderedOperations, Date() < end {
                        if !session.hasDisplayedEdit { unedited = true }
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    #expect(!unedited, "\(what): the unedited photo came up before the render")
                    #expect(session.hasDisplayedEdit && viewer.canvasTexture !== shown, "\(what): no render of the new state")
                }

                // Colors: Temperature, then a slider of the RGB section.
                viewer.adjustColors(nil)
                guard case .adjustment(let colors)? = viewer.activeTool else {
                    Issue.record("Colors didn't open")
                    return
                }
                let session = try #require(viewer.editSession)
                /// An edit render of the document as it is now on screen.
                @MainActor func renderShown() -> Bool {
                    session.hasDisplayedEdit && session.document.deliveredOperations == session.document.renderedOperations
                }
                colors.setValue(0.3, section: 0, slider: 3)
                await TestTiming.waitUntil { renderShown() }
                try await expectEditStays("Colors section switched") { colors.setValue(0.2, section: 1, slider: 0) }
                viewer.closeTool()
                await TestTiming.waitUntil { showsViewersTexture(viewer) }

                // Sketch, then Oil Painting in its place.
                viewer.applySketch(nil)
                await TestTiming.waitUntil { renderShown() }
                try await expectEditStays("Oil Painting after Sketch") { viewer.applyOilPaint(nil) }
                viewer.closeTool()
                await TestTiming.waitUntil { showsViewersTexture(viewer) }

                // A line drawn and applied, opened again, and cancelled.
                var drawing: AnnotationToolState?
                viewer.openDrawing(tool: .line) { state, _ in drawing = state }
                await TestTiming.waitUntil { drawing != nil }
                var line = try #require(drawing).newObject(.line)
                line.start = CGPoint(x: 0.1, y: 0.5)
                line.end = CGPoint(x: 0.5, y: 0.5)
                drawing?.add(line)
                viewer.closeTool(applying: true)
                await TestTiming.waitUntil {
                    session.document.operations.count == 1 && session.document.deliveredOperations == session.document.operations
                }
                drawing = nil
                viewer.openDrawing(tool: .select) { state, _ in drawing = state }
                await TestTiming.waitUntil { drawing != nil }
                #expect(drawing?.isReEditing == true)
                await TestTiming.waitUntil { renderShown() }
                try await expectEditStays("drawing re-edit cancelled") { viewer.closeTool() }
                #expect(session.document.operations.count == 1)
            }
        }

        /// An SDR photo on the same display never turns EDR on, through a
        /// tool's preview and apply, and its canvas goes idle afterwards.
        @Test func sdrPhotoStaysSDR() async throws {
            try await withHDRViewer(sdr: true) { viewer in
                let canvas = viewer.canvasView
                #expect(canvas.image?.isHDR == false && !canvas.isExtendedDynamicRange)
                viewer.adjustLighting(nil)
                guard case .adjustment(let lighting)? = viewer.activeTool else {
                    Issue.record("Lighting didn't open")
                    return
                }
                let session = try #require(viewer.editSession)
                lighting.setValue(0.4, section: 0, slider: 0)
                await TestTiming.waitUntil { session.hasDisplayedEdit }
                #expect(canvas.image?.isHDR == false && !canvas.isExtendedDynamicRange)
                viewer.closeTool(applying: true)
                await TestTiming.waitUntil { session.document.deliveredOperations == session.document.operations }
                for _ in 0..<3 { canvas.displayRefreshed() }
                #expect(canvas.image?.isHDR == false && !canvas.isExtendedDynamicRange && !canvas.isRefreshing)
                #expect(canvas.lastFrameHeadroom == 1)
            }
        }
    }
}
