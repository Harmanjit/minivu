import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// A document for a file that needn't exist: tool state only previews and
/// commits operations, which never touches pixels.
@MainActor private func document() -> EditDocument {
    let url = URL(fileURLWithPath: "/tmp/minivu-retouch-tests/photo.jpg")
    return EditDocument(entry: FolderEntry(url: url, name: "photo.jpg", isDirectory: false, kind: .raster, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

@MainActor @Suite struct RetouchToolStateTests {
    let size = CGSize(width: 4000, height: 2000)

    @Test func pointsAlongADragAreEvenlySpacedAndEndOnThePointer() {
        let from = CGPoint(x: 0.1, y: 0.5), to = CGPoint(x: 0.2, y: 0.5)   // 400 px
        let points = RetouchToolState.interpolated(from: from, to: to, spacing: 30, imageSize: size)
        #expect(points.count == 14)
        #expect(points.last == to)
        var previous = from
        for p in points {
            #expect((p.x - previous.x) * size.width <= 30 + 1e-9)
            previous = p
        }
        // Too short to record, unless it is the last point of the stroke.
        let near = CGPoint(x: 0.1 + 10 / size.width, y: 0.5)
        #expect(RetouchToolState.interpolated(from: from, to: near, spacing: 30, imageSize: size).isEmpty)
        #expect(RetouchToolState.interpolated(from: from, to: near, spacing: 30, imageSize: size,
                                              includingShortLast: true) == [near])
    }

    @Test func optionClickThenAlignedStrokesUndoAndApply() {
        let doc = document()
        let state = RetouchToolState(mode: .clone, document: doc, imageSize: size)
        #expect(state.brushSize == 60)   // 3% of the short side
        #expect(state.title == "Clone Stamp" && !state.hasPendingChanges)

        // Nothing to copy from yet.
        #expect(!state.beginStroke(at: CGPoint(x: 0.5, y: 0.5)))
        #expect(state.needsSourceHint)

        state.setSource(CGPoint(x: 0.2, y: 0.3))
        #expect(state.beginStroke(at: CGPoint(x: 0.5, y: 0.5)))
        state.continueStroke(to: CGPoint(x: 0.6, y: 0.5))
        state.endStroke()
        #expect(state.strokes.count == 1)
        let first = state.strokes[0]
        #expect(abs(first.sourceOffset.dx - -0.3) < 1e-12 && abs(first.sourceOffset.dy - -0.2) < 1e-12)
        #expect(first.radius == 30.0 / 2000)
        // Recorded every 20% of the radius (6 px) at most.
        #expect(first.points.count >= 400 / 6)
        #expect(doc.preview == .retouch(state.strokes))

        // A later stroke keeps the same offset wherever it starts.
        state.setBrushSize(100)
        state.beginStroke(at: CGPoint(x: 0.8, y: 0.8))
        state.endStroke()
        #expect(state.strokes.count == 2 && state.strokes[1].sourceOffset == first.sourceOffset)
        #expect(state.strokes[1].radius == 50.0 / 2000)
        #expect(state.source.sourcePoint(forBrushAt: CGPoint(x: 0.5, y: 0.5))!.x - 0.2 < 1e-12)

        // Undo takes strokes back one at a time, and the source with them.
        #expect(state.undoStepTitle == "Stroke")
        #expect(state.undoStep())
        #expect(state.strokes.count == 1 && doc.preview == .retouch([first]))
        #expect(state.redoStepTitle == "Stroke")
        #expect(state.undoStep())
        #expect(state.strokes.isEmpty && doc.preview == nil)
        #expect(state.source == .pending(CGPoint(x: 0.2, y: 0.3)))
        #expect(!state.undoStep())
        #expect(state.redoStep() && state.redoStep() && !state.redoStep())
        #expect(state.strokes.count == 2)

        // Apply commits one operation for every stroke.
        state.apply()
        #expect(doc.operations.count == 1 && doc.preview == nil)
        #expect(doc.undoTitle == "Clone Stamp")
    }

    @Test func cancelResetAndBrushSizeKeys() {
        let doc = document()
        let state = RetouchToolState(mode: .heal, document: doc, imageSize: size)
        state.setSource(CGPoint(x: 0.1, y: 0.1))
        state.beginStroke(at: CGPoint(x: 0.4, y: 0.4))
        state.endStroke()
        #expect(doc.preview != nil && state.title == "Healing Brush")
        state.reset()
        #expect(state.strokes.isEmpty && doc.preview == nil)
        #expect(state.source == .pending(CGPoint(x: 0.1, y: 0.1)))
        state.beginStroke(at: CGPoint(x: 0.4, y: 0.4))
        state.endStroke()
        state.cancel()
        #expect(doc.preview == nil && doc.operations.isEmpty)

        let start = state.brushSize
        state.stepBrushSize(larger: true)
        #expect(state.brushSize == (start * 1.25).rounded())
        for _ in 0..<100 { state.stepBrushSize(larger: false) }
        #expect(state.brushSize == state.brushSizeRange.lowerBound)
        for _ in 0..<100 { state.stepBrushSize(larger: true) }
        #expect(state.brushSize == state.brushSizeRange.upperBound)
    }

    @Test func redEyeSpots() {
        let doc = document()
        let state = RedEyeToolState(document: doc, imageSize: size)
        state.addSpot(center: CGPoint(x: 0.3, y: 0.4), radius: 0.02)
        state.addSpot(center: CGPoint(x: 0.6, y: 0.4), radius: 0.0001)
        #expect(state.spots.count == 2 && state.selection == 1)
        #expect(state.spots[1].radius == 3.0 / 2000, "at least 3 px")
        #expect(doc.preview == .redEye(state.spots))
        #expect(state.spot(at: CGPoint(x: 0.3 + 30 / size.width, y: 0.4)) == 0)
        #expect(state.spot(at: CGPoint(x: 0.3 + 50 / size.width, y: 0.4)) == nil)

        state.setStrength(0, 0.4)
        #expect(state.spots[0].strength == 0.4)
        // Detected spots already covered by the user's are skipped.
        let added = state.addDetected([RedEyeSpot(center: CGPoint(x: 0.301, y: 0.4), radius: 0.02),
                                       RedEyeSpot(center: CGPoint(x: 0.8, y: 0.4), radius: 0.02)])
        #expect(added == 1 && state.detection == .found(1) && state.spots.count == 3)
        #expect(state.addDetected([]) == 0 && state.detection == .none)

        state.removeSpot(0)
        #expect(state.spots.count == 2 && state.selection == 0)
        #expect(state.undoStepTitle == "Red-Eye Circle" && state.undoStep())
        #expect(state.spots.count == 1)
        state.apply()
        #expect(doc.undoTitle == "Red-Eye Removal" && doc.preview == nil)
    }
}

extension AppWindowTests {
    /// The retouch tools in a real viewer: they open on their actions, paint
    /// through the overlay, undo strokes inside the tool, and commit one step.
    @MainActor @Suite(.serialized) struct RetouchViewerTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func key(_ characters: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }

        @Test func healingBrushPaintsUndoesStrokesAndApplies() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateEditAction(.healingBrush) == true)
            #expect(viewer.validateEditAction(.cloneStamp) == true)
            #expect(viewer.validateEditAction(.removeRedEye) == true)

            viewer.healingBrush(nil)
            await waitUntil { viewer.activeTool != nil }
            guard case .custom(let open)? = viewer.activeTool, let state = open as? RetouchToolState else {
                Issue.record("The healing brush didn't open")
                return
            }
            let window = try #require(viewer.window as? ViewerWindow)
            let overlay = try #require(viewer.container.canvasOverlay as? RetouchBrushOverlayView)
            #expect(window.firstResponder === overlay)
            #expect(state.imageSize == CGSize(width: 600, height: 400) && state.mode == .heal)

            // [ and ] reach the overlay; other keys go on to the viewer.
            let size = state.brushSize
            overlay.keyDown(with: try key("]", window: window))
            #expect(state.brushSize > size)

            state.setSource(CGPoint(x: 0.2, y: 0.5))
            state.beginStroke(at: CGPoint(x: 0.6, y: 0.5))
            state.continueStroke(to: CGPoint(x: 0.7, y: 0.5))
            state.endStroke()
            state.beginStroke(at: CGPoint(x: 0.6, y: 0.7))
            state.endStroke()
            let session = try #require(viewer.editSession)
            #expect(session.document.preview == .retouch(state.strokes))

            // Edit > Undo takes back a stroke and leaves the tool open.
            let undo = NSMenuItem(title: "Undo", action: ViewerWindow.undoAction, keyEquivalent: "z")
            #expect(window.validateMenuItem(undo) && undo.title == "Undo Stroke")
            window.perform(ViewerWindow.undoAction, with: nil)
            #expect(state.strokes.count == 1)
            #expect(viewer.activeTool != nil)
            let redo = NSMenuItem(title: "Redo", action: ViewerWindow.redoAction, keyEquivalent: "Z")
            #expect(window.validateMenuItem(redo) && redo.title == "Redo Stroke")
            window.perform(ViewerWindow.redoAction, with: nil)
            #expect(state.strokes.count == 2)

            // Return applies both strokes as one step.
            window.contentView?.keyDown(with: try key("\r", window: window))
            #expect(viewer.activeTool == nil && viewer.container.canvasOverlay == nil)
            #expect(session.document.operations.count == 1 && session.document.undoTitle == "Healing Brush")
            await waitUntil { session.hasDisplayedEdit }
            #expect(session.hasDisplayedEdit)
        }

        @Test func redEyeOpensAddsCirclesAndCancels() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await waitUntil { viewer.canEditCurrent }

            viewer.removeRedEye(nil)
            await waitUntil { viewer.activeTool != nil }
            guard case .custom(let open)? = viewer.activeTool, let state = open as? RedEyeToolState else {
                Issue.record("Red-eye removal didn't open")
                return
            }
            #expect(viewer.container.canvasOverlay is RedEyeOverlayView)
            state.addSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.05)
            let session = try #require(viewer.editSession)
            #expect(session.document.preview == .redEye(state.spots))
            let window = try #require(viewer.window)
            // Delete removes the selected circle.
            window.firstResponder?.keyDown(with: try key(String(Character(UnicodeScalar(NSDeleteCharacter)!)),
                                                         window: window))
            #expect(state.spots.isEmpty)
            state.addSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.05)
            window.contentView?.keyDown(with: try key("\u{1B}", window: window))
            #expect(viewer.activeTool == nil && session.document.preview == nil)
            #expect(session.document.operations.isEmpty)
        }
    }
}
