import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

@MainActor private func document() -> EditDocument {
    let url = URL(fileURLWithPath: "/tmp/minivu-annotation-tests/photo.jpg")
    return EditDocument(entry: FolderEntry(url: url, name: "photo.jpg", isDirectory: false, kind: .raster, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1e-4) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
        && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

/// Hit testing, handles and drags of the drawing tool, as pure geometry.
@Suite struct AnnotationGeometryTests {
    let size = CGSize(width: 400, height: 200)

    func rectangle(_ frame: CGRect, rotation: Double = 0, filled: Bool = false) -> Annotation {
        var a = Annotation(kind: .rectangle)
        a.frame = frame
        a.rotation = rotation
        a.strokeWidth = 0.01   // 2 px
        a.fillColor.alpha = filled ? 1 : 0
        return a
    }

    @Test func boxHandlesSitOnCornersEdgesAndAboveTheTop() {
        let a = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let handles = Dictionary(uniqueKeysWithValues: AnnotationGeometry.handles(for: a, in: size, rotateDistance: 20))
        #expect(handles.count == 9)
        #expect(near(handles[.topLeft]!, CGPoint(x: 100, y: 50)))
        #expect(near(handles[.top]!, CGPoint(x: 200, y: 50)))
        #expect(near(handles[.right]!, CGPoint(x: 300, y: 100)))
        #expect(near(handles[.bottomRight]!, CGPoint(x: 300, y: 150)))
        #expect(near(handles[.bottomLeft]!, CGPoint(x: 100, y: 150)))
        #expect(near(handles[.rotate]!, CGPoint(x: 200, y: 30)))
    }

    /// Turned 90° clockwise (y down), the top-left corner goes to the top right.
    @Test func handlesTurnWithTheBox() {
        let a = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), rotation: 90)
        let handles = Dictionary(uniqueKeysWithValues: AnnotationGeometry.handles(for: a, in: size, rotateDistance: 20))
        #expect(near(handles[.topLeft]!, CGPoint(x: 250, y: 0)))
        #expect(near(handles[.bottomRight]!, CGPoint(x: 150, y: 200)))
        #expect(near(handles[.rotate]!, CGPoint(x: 270, y: 100)))
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 252, y: 3), of: a, in: size, rotateDistance: 20, tolerance: 5)
                == .topLeft)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 200, y: 100), of: a, in: size, rotateDistance: 20,
                                          tolerance: 5) == nil)
    }

    @Test func linesHaveEndpointHandlesAndCalloutsATail() {
        var line = Annotation(kind: .arrow)
        line.start = CGPoint(x: 0.1, y: 0.2)
        line.end = CGPoint(x: 0.9, y: 0.8)
        let handles = AnnotationGeometry.handles(for: line, in: size, rotateDistance: 20)
        #expect(handles.map(\.0) == [.start, .end])
        #expect(near(handles[1].1, CGPoint(x: 360, y: 160)))

        var callout = Annotation(kind: .callout)
        callout.tailPoint = CGPoint(x: 0.5, y: 0.9)
        let calloutHandles = AnnotationGeometry.handles(for: callout, in: size, rotateDistance: 20)
        #expect(calloutHandles.contains { $0.0 == .tail && near($0.1, CGPoint(x: 200, y: 180)) })
        #expect(!calloutHandles.contains { $0.0 == .rotate })
    }

    @Test func clicksPickTheTopmostObjectAndOutlinesOnlyNearTheirStroke() {
        let bottom = rectangle(CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6), filled: true)
        let top = rectangle(CGRect(x: 0.3, y: 0.3, width: 0.6, height: 0.6), filled: true)
        #expect(AnnotationGeometry.hitTest([bottom, top], at: CGPoint(x: 200, y: 100), in: size, tolerance: 3) == top.id)
        #expect(AnnotationGeometry.hitTest([bottom, top], at: CGPoint(x: 60, y: 40), in: size, tolerance: 3) == bottom.id)
        #expect(AnnotationGeometry.hitTest([bottom, top], at: CGPoint(x: 395, y: 10), in: size, tolerance: 3) == nil)

        let frame = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))   // outline only
        #expect(!AnnotationGeometry.contains(frame, point: CGPoint(x: 200, y: 100), in: size, tolerance: 3))
        #expect(AnnotationGeometry.contains(frame, point: CGPoint(x: 102, y: 100), in: size, tolerance: 3))
        #expect(!AnnotationGeometry.contains(frame, point: CGPoint(x: 94, y: 100), in: size, tolerance: 3))

        var line = Annotation(kind: .line)
        line.start = CGPoint(x: 0, y: 0.5)
        line.end = CGPoint(x: 1, y: 0.5)
        line.strokeWidth = 0.02   // 4 px
        #expect(AnnotationGeometry.contains(line, point: CGPoint(x: 200, y: 104), in: size, tolerance: 3))
        #expect(!AnnotationGeometry.contains(line, point: CGPoint(x: 200, y: 108), in: size, tolerance: 3))

        var oval = Annotation(kind: .oval)
        oval.frame = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        oval.strokeWidth = 0.01
        #expect(AnnotationGeometry.contains(oval, point: CGPoint(x: 100, y: 100), in: size, tolerance: 3))
        #expect(!AnnotationGeometry.contains(oval, point: CGPoint(x: 200, y: 100), in: size, tolerance: 3))
        #expect(!AnnotationGeometry.contains(oval, point: CGPoint(x: 105, y: 10), in: size, tolerance: 3))
    }

    @Test func cornerAndEdgeDragsResizeAboutTheOppositeSide() {
        let a = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))   // 100...300 x 50...150
        let corner = AnnotationGeometry.dragged(a, handle: .bottomRight, to: CGPoint(x: 350, y: 190), in: size,
                                                constrain: false)
        #expect(near(corner.pixelRect(in: size), CGRect(x: 100, y: 50, width: 250, height: 140)))
        let edge = AnnotationGeometry.dragged(a, handle: .left, to: CGPoint(x: 20, y: 999), in: size, constrain: false)
        #expect(near(edge.pixelRect(in: size), CGRect(x: 20, y: 50, width: 280, height: 100)))
        // Past the anchor it stops at the minimum size instead of flipping.
        let crossed = AnnotationGeometry.dragged(a, handle: .topLeft, to: CGPoint(x: 390, y: 190), in: size,
                                                 constrain: false)
        #expect(near(crossed.pixelRect(in: size), CGRect(x: 296, y: 146, width: 4, height: 4)))
        // Shift keeps the proportions from a corner.
        let kept = AnnotationGeometry.dragged(a, handle: .bottomRight, to: CGPoint(x: 500, y: 160), in: size,
                                              constrain: true)
        #expect(near(kept.pixelRect(in: size), CGRect(x: 100, y: 50, width: 400, height: 200)))
    }

    /// A box turned 90°: dragging its right-hand handle (which points down on
    /// screen) makes it longer along its own width, about the opposite edge.
    @Test func dragsFollowATurnedBoxsOwnAxes() {
        let a = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), rotation: 90)   // centre (200, 100), 200 x 100
        let handles = Dictionary(uniqueKeysWithValues: AnnotationGeometry.handles(for: a, in: size, rotateDistance: 20))
        let leftBefore = handles[.left]!
        let dragged = AnnotationGeometry.dragged(a, handle: .right, to: CGPoint(x: 200, y: 260), in: size, constrain: false)
        let after = Dictionary(uniqueKeysWithValues: AnnotationGeometry.handles(for: dragged, in: size, rotateDistance: 20))
        #expect(near(after[.left]!, leftBefore))
        #expect(near(after[.right]!, CGPoint(x: 200, y: 260)))
        #expect(abs(dragged.pixelRect(in: size).width - 260) < 0.01 && abs(dragged.pixelRect(in: size).height - 100) < 0.01)
        #expect(dragged.rotation == 90)
    }

    @Test func rotationHandleTurnsAboutTheCentreInFifteenDegreeStepsWithShift() {
        let a = rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(AnnotationGeometry.dragged(a, handle: .rotate, to: CGPoint(x: 300, y: 100), in: size, constrain: false)
            .rotation == 90)
        #expect(AnnotationGeometry.dragged(a, handle: .rotate, to: CGPoint(x: 100, y: 100), in: size, constrain: false)
            .rotation == -90)
        let snapped = AnnotationGeometry.dragged(a, handle: .rotate, to: CGPoint(x: 230, y: 0), in: size, constrain: true)
        #expect(snapped.rotation == 15)
    }

    @Test func shiftConstrainsLinesTo45DegreesAndBoxesToSquares() {
        let template = Annotation(kind: .line)
        let line = AnnotationGeometry.created(from: template, anchor: CGPoint(x: 100, y: 100),
                                              to: CGPoint(x: 200, y: 110), in: size, constrain: true)
        #expect(near(line.pixelPoint(line.end, in: size), CGPoint(x: 200, y: 100), 1e-6))
        let diagonal = AnnotationGeometry.constrained45(CGPoint(x: 150, y: 140), from: CGPoint(x: 100, y: 100))
        #expect(abs(diagonal.x - 100 - (diagonal.y - 100)) < 1e-9)

        let oval = AnnotationGeometry.created(from: Annotation(kind: .oval), anchor: CGPoint(x: 200, y: 100),
                                              to: CGPoint(x: 150, y: 180), in: size, constrain: true)
        #expect(near(oval.pixelRect(in: size), CGRect(x: 120, y: 100, width: 80, height: 80)))

        let callout = AnnotationGeometry.created(from: Annotation(kind: .callout), anchor: CGPoint(x: 100, y: 20),
                                                 to: CGPoint(x: 200, y: 70), in: size, constrain: false)
        #expect(callout.pixelPoint(callout.tailPoint, in: size).y > 70)
    }

    @Test func movingShiftsEveryPoint() {
        var a = Annotation(kind: .callout)
        a.frame = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        a.tailPoint = CGPoint(x: 0.5, y: 0.5)
        let moved = AnnotationGeometry.moved(a, by: CGSize(width: 40, height: -20), in: size)
        #expect(near(moved.frame, CGRect(x: 0.2, y: 0, width: 0.2, height: 0.2)))
        #expect(near(moved.tailPoint, CGPoint(x: 0.6, y: 0.4), 1e-9))
    }
}

/// The drawing tool's state: previews, commits, undo within the tool and
/// editing a drawing again.
@MainActor @Suite struct AnnotationToolStateTests {
    let size = CGSize(width: 600, height: 400)

    func arrow(_ x: CGFloat = 0.2) -> Annotation {
        var a = Annotation(kind: .arrow)
        a.start = CGPoint(x: x, y: 0.2)
        a.end = CGPoint(x: x + 0.3, y: 0.6)
        return a
    }

    @Test func applyCommitsOneDrawingStepAndCancelNothing() {
        let doc = document()
        let state = AnnotationToolState(document: doc, imageSize: size, tool: .arrow)
        #expect(!state.hasPendingChanges && !state.isReEditing)
        state.add(arrow())
        state.add(arrow(0.5))
        #expect(state.hasPendingChanges)
        state.flushPreview()
        #expect(doc.preview == .annotations(state.objects))
        state.apply()
        #expect(doc.operations == [.annotations(state.objects)])
        #expect(doc.preview == nil && doc.undoTitle == "Drawing")

        let other = document()
        let cancelled = AnnotationToolState(document: other, imageSize: size)
        cancelled.add(arrow())
        cancelled.flushPreview()
        cancelled.cancel()
        #expect(other.operations.isEmpty && other.preview == nil)
    }

    /// The last committed drawing comes back into the tool; Apply replaces it,
    /// Cancel puts it back untouched. A drawing under another edit doesn't.
    @Test func reopeningEditsTheLastDrawingAgain() {
        let doc = document()
        let first = arrow()
        doc.apply(.grayscale)
        doc.apply(.annotations([first]))

        let state = AnnotationToolState(document: doc, imageSize: size)
        #expect(state.isReEditing && state.objects == [first])
        #expect(doc.operations == [.grayscale])
        #expect(doc.preview == .annotations([first]))
        #expect(state.hasPendingChanges)
        state.select(first.id)
        state.nudge(dx: 6, dy: 0)
        state.apply()
        #expect(doc.operations.count == 2 && doc.operations[0] == .grayscale)
        guard case .annotations(let edited)? = doc.operations.last else {
            Issue.record("no drawing committed")
            return
        }
        #expect(edited.count == 1 && edited[0].id == first.id)
        #expect(abs(edited[0].start.x - (first.start.x + 0.01)) < 1e-9)
        #expect(!doc.canRedo && doc.undoTitle == "Drawing")

        let again = AnnotationToolState(document: doc, imageSize: size)
        again.deleteSelection()
        again.add(arrow(0.6))
        again.cancel()
        #expect(doc.operations == [.grayscale, .annotations(edited)] && doc.preview == nil)

        doc.apply(.negative)
        let under = AnnotationToolState(document: doc, imageSize: size)
        #expect(!under.isReEditing && under.objects.isEmpty)
        under.cancel()
        #expect(doc.operations.last == .negative)
    }

    @Test func liveObjectsStayOutOfThePreview() {
        let doc = document()
        let state = AnnotationToolState(document: doc, imageSize: size)
        let a = arrow(), b = arrow(0.5)
        state.add(a)
        state.add(b, live: true)
        state.flushPreview()
        #expect(doc.preview == .annotations([a]))
        var ended: Set<UUID> = []
        state.onLiveEnded = { ended = $0 }
        state.endLive()
        state.flushPreview()
        #expect(ended == [b.id])
        #expect(doc.preview == .annotations([a, b]))
        state.beginLive(a.id)
        state.beginLive(b.id)
        state.flushPreview()
        #expect(doc.preview == nil)
    }

    @Test func undoWithinTheToolStepsBackThroughChanges() {
        let state = AnnotationToolState(document: document(), imageSize: size)
        let a = arrow()
        state.add(a)
        state.select(a.id)
        state.updateStyle("Width") { $0.strokeWidth = 0.02 }
        state.updateStyle("Width") { $0.strokeWidth = 0.03 }   // coalesced with the change before
        #expect(state.undoName == "Width")
        state.undo()
        #expect(state.object(a.id)?.strokeWidth == a.strokeWidth)
        #expect(state.undoName == "Add Arrow" && state.redoName == "Width")
        state.undo()
        #expect(state.objects.isEmpty)
        state.redo()
        state.redo()
        #expect(state.object(a.id)?.strokeWidth == 0.03)
        // A style change with nothing selected changes the next object instead.
        state.select(nil)
        state.tool = .rectangle
        state.updateStyle("Stroke Color") { $0.strokeColor = .white }
        #expect(state.newObject(.rectangle).strokeColor == .white)
        #expect(state.inspected?.strokeColor == .white && !state.hasSelection)
    }

    @Test func deleteDuplicateCopyPasteNudgeAndArrange() {
        let state = AnnotationToolState(document: document(), imageSize: size)
        let a = arrow(), b = arrow(0.5)
        state.add(a)
        state.add(b)
        state.select(a.id)
        state.duplicateSelection()
        #expect(state.objects.count == 3 && state.selectedID != a.id)
        let copy = state.objects[2]
        #expect(abs(copy.start.x - (a.start.x + 8.0 / 600)) < 1e-9)   // 2% of the short side
        state.deleteSelection()
        #expect(state.objects.map(\.id) == [a.id, b.id] && state.selectedID == nil)

        state.select(a.id)
        state.arrangeSelection(toFront: true)
        #expect(state.objects.map(\.id) == [b.id, a.id])
        state.copySelection()
        state.paste()
        #expect(state.objects.count == 3 && state.objects[2].id != a.id)
        #expect(state.objects[2].start != a.start)   // offset: the original is still here

        state.select(b.id)
        state.nudge(dx: 1, dy: 0)
        state.nudge(dx: 10, dy: 0)   // one undo step
        #expect(abs(state.object(b.id)!.start.x - (b.start.x + 11.0 / 600)) < 1e-9)
        state.undo()
        #expect(state.object(b.id)!.start == b.start)
    }

    @Test func textEndsTypingFitsItsHeightAndDisappearsWhenEmpty() {
        let state = AnnotationToolState(document: document(), imageSize: size)
        var text = state.newObject(.text)
        text.frame = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.01)
        state.add(text)
        state.beginTextEditing(text.id)
        #expect(state.capturesKeyboard && state.liveIDs.contains(text.id))
        state.setText("One line", of: text.id)
        let oneLine = state.object(text.id)!.frame.height
        #expect(oneLine > 0.05)
        state.setText("One line\nand another\nand a third", of: text.id)
        #expect(state.object(text.id)!.frame.height > oneLine * 2)
        state.endTextEditing()
        #expect(!state.capturesKeyboard && state.liveIDs.isEmpty)

        let empty = state.newObject(.text)
        state.add(empty)
        state.beginTextEditing(empty.id)
        state.endTextEditing()
        #expect(state.object(empty.id) == nil)
        // A callout keeps its bubble without text.
        let callout = state.newObject(.callout)
        state.add(callout)
        state.beginTextEditing(callout.id)
        state.endTextEditing()
        #expect(state.object(callout.id) != nil)
    }

    /// A text box that ends up empty leaves no undo steps: Undo goes straight
    /// to the step before it rather than bringing back an invisible box. Text
    /// that was there and was all deleted comes back with Undo.
    @Test func emptyTextLeavesNoUndoStepsButDeletedTextComesBack() {
        let state = AnnotationToolState(document: document(), imageSize: size)
        state.add(arrow())
        #expect(state.undoName == "Add Arrow")

        let clicked = state.newObject(.text)
        state.add(clicked, live: true)
        state.beginTextEditing(clicked.id)
        state.endTextEditing()
        #expect(state.object(clicked.id) == nil && state.objects.count == 1)
        #expect(state.undoName == "Add Arrow")
        state.undo()
        #expect(state.objects.isEmpty)

        let written = state.newObject(.text)
        state.add(written)
        state.beginTextEditing(written.id)
        state.setText("Keep me", of: written.id)
        state.endTextEditing()
        state.beginTextEditing(written.id)
        state.setText("", of: written.id)
        state.endTextEditing()
        #expect(state.object(written.id) == nil)
        state.undo()
        #expect(state.object(written.id)?.text == "Keep me")
    }

    @Test func toolKindsMatchTheirTags() {
        #expect(AnnotationToolKind(rawValue: 0) == .select)
        #expect(AnnotationToolKind.allCases.map(\.rawValue) == Array(0...7))
        #expect(AnnotationToolKind.allCases.compactMap(\.objectKind) == Annotation.Kind.allCases)
        for kind in AnnotationToolKind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind.symbol)")
        }
    }
}

extension AppWindowTests {
    /// The drawing tool in a real viewer: it opens from the action with the
    /// tag's tool, Return applies one step, reopening edits it again, and Esc
    /// puts it back.
    @MainActor @Suite(.serialized) struct AnnotationViewerTests {
        init() { _ = NSApplication.shared }

        /// A key press delivered to `responder`, or to the window's content
        /// view as the canvas passes it on.
        func press(_ character: Int, in viewer: ViewerWindowController, to responder: NSResponder? = nil) throws {
            let window = try #require(viewer.window)
            let characters = String(Character(UnicodeScalar(character)!))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            (responder ?? window.contentView)?.keyDown(with: event)
        }

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, in overlay: AnnotationOverlayView, clicks: Int = 1,
                   shift: Bool = false) throws -> NSEvent {
            let window = try #require(overlay.window)
            return try #require(NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil),
                                                   modifierFlags: shift ? .shift : [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: clicks, pressure: 1))
        }

        /// Drags with the rectangle tool, then the new rectangle's corner and
        /// body, through the overlay's own mouse handling.
        @Test func draggingCreatesResizesAndMovesObjects() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("b.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.openDrawing(tool: .rectangle)
            await TestTiming.waitUntil { viewer.drawingToolState != nil }
            let state = try #require(viewer.drawingToolState)
            let overlay = try #require(viewer.container.canvasOverlay as? AnnotationOverlayView)
            let t = overlay.imageToView
            func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }

            overlay.mouseDown(with: try mouse(.leftMouseDown, at: view(100, 100), in: overlay))
            overlay.mouseDragged(with: try mouse(.leftMouseDragged, at: view(200, 150), in: overlay))
            overlay.mouseDragged(with: try mouse(.leftMouseDragged, at: view(300, 180), in: overlay, shift: true))
            #expect(state.objects.count == 1 && state.liveIDs.count == 1)
            overlay.display()   // draws the live rectangle and its handles
            overlay.mouseUp(with: try mouse(.leftMouseUp, at: view(300, 180), in: overlay))
            let created = try #require(state.objects.first)
            let rect = created.pixelRect(in: state.imageSize)
            // Shift made it a square, 200 image pixels a side (to within a view point's rounding).
            #expect(abs(rect.minX - 100) < 2 && abs(rect.minY - 100) < 2, "\(rect)")
            #expect(abs(rect.width - 200) < 3 && abs(rect.width - rect.height) < 0.01, "\(rect)")
            #expect(state.selectedID == created.id && state.liveIDs.isEmpty)
            state.flushPreview()
            #expect(viewer.editSession?.document.preview == .annotations([created]))

            // The bottom-right handle resizes; the body moves.
            overlay.mouseDown(with: try mouse(.leftMouseDown, at: view(rect.maxX, rect.maxY), in: overlay))
            overlay.mouseDragged(with: try mouse(.leftMouseDragged, at: view(rect.maxX + 50, rect.maxY + 20), in: overlay))
            overlay.mouseUp(with: try mouse(.leftMouseUp, at: view(rect.maxX + 50, rect.maxY + 20), in: overlay))
            let resized = try #require(state.object(created.id)).pixelRect(in: state.imageSize)
            #expect(abs(resized.width - (rect.width + 50)) < 3 && abs(resized.minX - rect.minX) < 0.01, "\(resized)")
            overlay.mouseDown(with: try mouse(.leftMouseDown, at: view(rect.midX, rect.minY + 1), in: overlay))
            overlay.mouseDragged(with: try mouse(.leftMouseDragged, at: view(rect.midX - 60, rect.minY + 41), in: overlay))
            overlay.mouseUp(with: try mouse(.leftMouseUp, at: view(rect.midX - 60, rect.minY + 41), in: overlay))
            let moved = try #require(state.object(created.id)).pixelRect(in: state.imageSize)
            #expect(abs(moved.minX - (resized.minX - 60)) < 3 && abs(moved.minY - (resized.minY + 40)) < 3, "\(moved)")
            #expect(state.undoName == "Move Rectangle")
            overlay.display()

            // A click with the text tool places a text box and starts typing in it.
            state.tool = .text
            overlay.mouseDown(with: try mouse(.leftMouseDown, at: view(40, 300), in: overlay))
            overlay.mouseUp(with: try mouse(.leftMouseUp, at: view(40, 300), in: overlay))
            let textID = try #require(state.editingID)
            let textView = try #require(overlay.textView)
            #expect(viewer.window?.firstResponder === textView && state.capturesKeyboard)
            textView.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(state.object(textID)?.text == "Hello")
            textView.cancelOperation(nil)   // Esc ends typing, not the tool
            #expect(state.editingID == nil && overlay.textView == nil && viewer.drawingToolState === state)
            viewer.closeTool()
        }

        /// Keys the drawing tool keeps from the viewer: Delete with nothing
        /// selected doesn't go to the previous image, Esc first lets go of
        /// the selection, and ⌘Z undoes within the tool even when the overlay
        /// has lost the keyboard (but not while text is being typed).
        @Test func keysStayWithTheTool() async throws {
            let folder = try ScratchFolder()
            let entries = try ["a.jpg", "b.jpg"].map { try #require(FolderEntry(url: try folder.jpeg($0, width: 600, height: 400))) }
            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            var asked = 0
            ViewerWindowController.askAboutUnsavedEdits = { _, _, reply in
                asked += 1
                reply(.cancel)
            }
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            ViewerWindowController.show(images: entries, index: 1, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.openDrawing(tool: .arrow)
            await TestTiming.waitUntil { viewer.drawingToolState != nil }
            let state = try #require(viewer.drawingToolState)
            let overlay = try #require(viewer.container.canvasOverlay as? AnnotationOverlayView)
            var a = state.newObject(.arrow)
            a.start = CGPoint(x: 0.1, y: 0.1)
            a.end = CGPoint(x: 0.5, y: 0.5)
            state.add(a)
            var b = state.newObject(.rectangle)
            b.frame = CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
            state.add(b)

            // Delete removes the selection; pressed again it stays in the tool.
            try press(NSDeleteCharacter, in: viewer, to: overlay)
            #expect(state.objects.map(\.id) == [a.id])
            try press(NSDeleteCharacter, in: viewer, to: overlay)
            #expect(asked == 0 && viewer.model.index == 1 && viewer.drawingToolState === state)

            // Esc: first the selection, then the tool.
            state.select(a.id)
            try press(0x1B, in: viewer, to: overlay)
            #expect(state.selectedID == nil && viewer.drawingToolState === state)

            // ⌘Z with the keyboard elsewhere still takes back the last step.
            let window = try #require(viewer.window)
            window.makeFirstResponder(viewer.canvas)
            func commandZ(shift: Bool = false) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                              modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "z", charactersIgnoringModifiers: "z", isARepeat: false,
                                              keyCode: 6))
            }
            #expect(overlay.performKeyEquivalent(with: try commandZ()))
            #expect(state.objects.map(\.id) == [a.id, b.id] && viewer.drawingToolState === state)
            #expect(overlay.performKeyEquivalent(with: try commandZ(shift: true)))
            #expect(state.objects.map(\.id) == [a.id])
            // While typing, ⌘Z belongs to the text.
            var text = state.newObject(.text)
            text.frame = CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)
            state.add(text)
            state.beginTextEditing(text.id)
            #expect(window.firstResponder === overlay.textView)
            #expect(!overlay.performKeyEquivalent(with: try commandZ()))
            overlay.textView?.cancelOperation(nil)

            try press(0x1B, in: viewer, to: overlay)
            #expect(viewer.activeTool == nil && asked == 0)
        }

        @Test func drawApplyReopenAndCancel() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateMenuItem(NSMenuItem(title: "", action: .drawAnnotations, keyEquivalent: "")))

            let item = NSMenuItem(title: "", action: .drawAnnotations, keyEquivalent: "")
            item.tag = AnnotationToolKind.arrow.rawValue
            viewer.drawAnnotations(item)
            await TestTiming.waitUntil { viewer.drawingToolState != nil }
            let state = try #require(viewer.drawingToolState)
            #expect(state.tool == .arrow && state.imageSize == CGSize(width: 600, height: 400))
            let overlay = try #require(viewer.container.canvasOverlay as? AnnotationOverlayView)
            #expect(viewer.window?.firstResponder === overlay)
            #expect(viewer.flyouts.isPinned(.left) && viewer.toolsPanel.inspector != nil)

            var drawn = state.newObject(.arrow)
            drawn.start = CGPoint(x: 0.1, y: 0.1)
            drawn.end = CGPoint(x: 0.6, y: 0.5)
            state.add(drawn)
            let session = try #require(viewer.editSession)
            await TestTiming.waitUntil { session.document.preview != nil }
            #expect(session.document.preview == .annotations([drawn]))
            // Delete with the object selected removes it; ⌘Z within the tool brings it back.
            try press(NSDeleteCharacter, in: viewer, to: overlay)
            #expect(state.objects.isEmpty)
            state.undo()
            #expect(state.objects.map(\.id) == [drawn.id])

            try press(NSCarriageReturnCharacter, in: viewer)
            #expect(viewer.activeTool == nil && viewer.container.canvasOverlay == nil)
            #expect(session.document.operations == [.annotations([drawn])])
            #expect(viewer.undoEditTitle == "Drawing")

            viewer.drawAnnotations(nil)
            let again = try #require(viewer.drawingToolState)
            #expect(again.tool == .select && again.isReEditing && again.objects == [drawn])
            #expect(session.document.operations.isEmpty)
            try press(0x1B, in: viewer)   // Esc cancels: the drawing goes back as it was
            #expect(viewer.activeTool == nil)
            #expect(session.document.operations == [.annotations([drawn])] && session.document.preview == nil)
        }
    }
}
