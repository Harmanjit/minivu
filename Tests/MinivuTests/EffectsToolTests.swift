import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// A document for a file that needn't exist: tool state only previews and
/// commits operations, which never touches pixels.
@MainActor private func effectDocument() -> EditDocument {
    let url = URL(fileURLWithPath: "/tmp/minivu-effects-tests/photo.jpg")
    return EditDocument(entry: FolderEntry(url: url, name: "photo.jpg", isDirectory: false, kind: .raster, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

@MainActor @Suite struct EffectToolStateTests {
    @Test func previewsAtOnceAndAppliesOneStep() {
        let document = effectDocument()
        let state = EffectToolState(kind: .dropShadow, document: document, initial: DropShadow()) { .dropShadow($0) }
        #expect(document.preview == .dropShadow(DropShadow()))
        #expect(state.hasPendingChanges && state.title == "Drop Shadow")

        var changes = 0
        state.onChange = { changes += 1 }
        state.update { $0.opacity = 0.9 }
        state.update { $0.opacity = 0.9 }   // no change, no preview or callback
        #expect(changes == 1)
        guard case .dropShadow(let previewed)? = document.preview else {
            Issue.record("no shadow preview")
            return
        }
        #expect(previewed.opacity == 0.9)

        state.apply()
        #expect(document.preview == nil && document.operations.count == 1 && document.undoTitle == "Drop Shadow")
    }

    @Test func cancelDropsAndResetReturnsToTheOpeningValues() {
        let document = effectDocument()
        var initial = OilPaint()
        initial.radius = 2
        let state = EffectToolState(kind: .oilPaint, document: document, initial: initial) { .oilPaint($0) }
        state.update { $0.radius = 9; $0.levelsValue = 12.4 }
        #expect(state.payload.levels == 12)
        state.reset()
        #expect(state.payload == initial)
        #expect(document.preview == .oilPaint(initial))
        state.cancel()
        #expect(document.preview == nil && document.operations.isEmpty)
    }

    /// The shared colour panel outlives the inspector: a colour picked after
    /// Apply or Cancel must not put a preview back on the document.
    @Test func aClosedToolIgnoresLateChanges() {
        let document = effectDocument()
        let shadow = EffectToolState(kind: .dropShadow, document: document, initial: DropShadow()) { .dropShadow($0) }
        let well = shadow.colorBinding(\.color)
        shadow.apply()
        well.wrappedValue = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        shadow.reset()
        #expect(document.preview == nil && document.operations.count == 1)
        #expect(shadow.payload == DropShadow())
        shadow.apply()
        #expect(document.operations.count == 1)

        let frame = EffectToolState(kind: .frame, document: document, initial: FrameStyle()) { .frame($0) }
        frame.cancel()
        frame.binding(\.kind).wrappedValue = .bevel
        #expect(document.preview == nil && frame.payload.kind == .solid)
    }

    @Test func anIdentitySettingShowsNothingAndCommitsNothing() {
        let document = effectDocument()
        let state = EffectToolState(kind: .lens, document: document, initial: LensEffect()) { .lens($0) }
        state.update { $0.magnification = 1 }
        #expect(document.preview == nil && !state.hasPendingChanges)
        state.apply()
        #expect(document.operations.isEmpty)
    }

    @Test func slidersClampAndDoubleClickRestoresTheOpeningValue() {
        let document = effectDocument()
        let state = EffectToolState(kind: .frame, document: document, initial: FrameStyle()) { .frame($0) }
        let row = state.slider(\.width, "Width", range: FrameStyle.widthRange, displayScale: 100)
        row.setValue(3)
        #expect(state.payload.width == FrameStyle.widthRange.upperBound)
        row.reset()
        #expect(state.payload.width == FrameStyle().width)
    }

    @Test func coloursRoundTripThroughColourWells() {
        let color = EditColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.4)
        let back = EditColor(color.cgColor)
        #expect(abs(back.red - 0.25) < 1e-4 && abs(back.green - 0.5) < 1e-4 && abs(back.blue - 0.75) < 1e-4)
        #expect(abs(back.alpha - 0.4) < 1e-4)
        // A grey well colour becomes an sRGB grey.
        let grey = EditColor(CGColor(gray: 0.5, alpha: 1))
        #expect(abs(grey.red - grey.green) < 1e-3 && abs(grey.green - grey.blue) < 1e-3)
    }
}

@Suite struct LensGeometryTests {
    /// A 400 x 200 pt image drawn at (100, 50).
    let rect = CGRect(x: 100, y: 50, width: 400, height: 200)

    @Test func theCircleFollowsTheImageRect() {
        var lens = LensEffect()
        lens.centerX = 0.25
        lens.centerY = 0.5
        lens.radius = 0.25
        #expect(LensGeometry.center(lens, in: rect) == CGPoint(x: 200, y: 150))
        #expect(LensGeometry.radius(lens, in: rect) == 50)   // a quarter of the 200 pt short side
        #expect(LensGeometry.hit(CGPoint(x: 200, y: 150), lens: lens, in: rect) == .inside)
        #expect(LensGeometry.hit(CGPoint(x: 254, y: 150), lens: lens, in: rect) == .edge)
        #expect(LensGeometry.hit(CGPoint(x: 200, y: 94), lens: lens, in: rect) == .edge)
        #expect(LensGeometry.hit(CGPoint(x: 300, y: 150), lens: lens, in: rect) == .outside)
    }

    @Test func movingStaysOnTheImageAndResizingInRange() {
        let lens = LensEffect()
        let moved = LensGeometry.moving(lens, to: CGPoint(x: 200, y: 100), in: rect)
        #expect(moved.centerX == 0.25 && moved.centerY == 0.25 && moved.radius == lens.radius)
        let outside = LensGeometry.moving(lens, to: CGPoint(x: -500, y: 900), in: rect)
        #expect(outside.centerX == 0 && outside.centerY == 1)

        let resized = LensGeometry.resizing(lens, to: CGPoint(x: 300, y: 210), in: rect)   // 60 pt below the centre
        #expect(abs(resized.radius - 0.3) < 1e-9)
        #expect(LensGeometry.resizing(lens, to: CGPoint(x: 300, y: 150), in: rect).radius == LensEffect.radiusRange.lowerBound)
        #expect(LensGeometry.resizing(lens, to: CGPoint(x: 5000, y: 150), in: rect).radius == LensEffect.radiusRange.upperBound)
    }
}

extension AppWindowTests {
    /// The effect tools in a real (windowed) viewer.
    @MainActor @Suite(.serialized) struct EffectsViewerTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        @Test func effectsOpenPreviewAndApply() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }
            for action in [Selector.addDropShadow, .addFrame, .applyBumpMap, .applySketch, .applyOilPaint, .applyLens] {
                #expect(viewer.validateEditAction(action) == true, "\(action)")
                #expect(viewer.toolsPanel.row(for: action)?.isEnabled == true, "\(action)")
            }

            // Frame: opens once decoded, previews, and grows the canvas when applied.
            viewer.addFrame(nil)
            await waitUntil { viewer.activeEffect != nil }
            let frame = try #require(viewer.activeEffect as? EffectToolState<FrameStyle>)
            #expect(viewer.flyouts.isPinned(.left) && viewer.toolsPanel.inspector != nil)
            let session = try #require(viewer.editSession)
            #expect(session.document.preview == .frame(FrameStyle()))
            frame.update { $0.kind = .polaroid }
            viewer.closeTool(applying: true)
            #expect(session.document.outputSize == CGSize(width: 632, height: 472))   // 16 px sides, 56 px bottom
            await waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 632, height: 472) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 632, height: 472))

            // Oil paint and sketch default their sizes to the photo: the smallest brush for 632 x 472.
            viewer.applyOilPaint(nil)
            let paint = try #require(viewer.activeEffect as? EffectToolState<OilPaint>)
            #expect(paint.payload.radius == OilPaint.radiusRange.lowerBound)
            viewer.applySketch(nil)   // replaces the oil paint tool, dropping its preview
            #expect(viewer.activeEffect?.kind == .sketch)
            #expect(session.document.operations.count == 1)

            // Lens: an overlay on the canvas that edits the same state.
            viewer.applyLens(nil)
            let lens = try #require(viewer.activeEffect as? EffectToolState<LensEffect>)
            let overlay = try #require(viewer.container.canvasOverlay as? LensOverlayView)
            #expect(overlay.state === lens)
            #expect(viewer.canvasView.onViewChange != nil)
            let rect = try #require(overlay.imageRect)
            lens.update { $0 = LensGeometry.moving($0, to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY), in: rect) }
            #expect(abs(lens.payload.centerX - 0.3) < 1e-6)
            viewer.closeTool(applying: true)
            #expect(viewer.container.canvasOverlay == nil && viewer.canvasView.onViewChange == nil)
            #expect(session.document.operations.count == 2 && session.document.undoTitle == "Lens")
        }
    }
}
