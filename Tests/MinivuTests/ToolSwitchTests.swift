import AppKit
import Testing
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// Moving on to another command with a tool open keeps the tool's work:
    /// only Cancel, Esc, Back and Undo drop it.
    @MainActor @Suite(.serialized) struct ToolSwitchTests {
        init() { _ = NSApplication.shared }

        @Test func anotherCommandAppliesTheOpenToolFirst() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            let session = try #require(viewer.editSessionForCurrent())

            // Strokes, then Rotate Right: the strokes are committed before the turn.
            viewer.cloneStamp(nil)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            guard case .custom(let open)? = viewer.activeTool, let brush = open as? RetouchToolState else {
                Issue.record("The clone stamp didn't open")
                return
            }
            brush.setSource(CGPoint(x: 0.2, y: 0.5))
            brush.beginStroke(at: CGPoint(x: 0.6, y: 0.5))
            brush.endStroke()
            viewer.rotateRight(nil)
            #expect(viewer.activeTool == nil)
            #expect(session.document.operations.map(\.title) == ["Clone Stamp", "Rotate Right"])

            // A drawing, then another tool: the drawing is committed.
            viewer.drawAnnotations(nil)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            guard case .custom(let drawingOpen)? = viewer.activeTool,
                  let drawing = drawingOpen as? AnnotationToolState else {
                Issue.record("The drawing tool didn't open")
                return
            }
            for x in [0.2, 0.5] {
                var arrow = Annotation(kind: .arrow)
                arrow.start = CGPoint(x: x, y: 0.2)
                arrow.end = CGPoint(x: x + 0.3, y: 0.6)
                drawing.add(arrow)
            }
            #expect(drawing.objects.count == 2)

            // Undo from the menu takes back one object and leaves the tool open.
            viewer.undoEdit()
            #expect(viewer.activeTool != nil && drawing.objects.count == 1)

            viewer.removeRedEye(nil)
            await TestTiming.waitUntil { if case .custom(let s)? = viewer.activeTool { s is RedEyeToolState } else { false } }
            #expect(session.document.operations.count == 3)
            #expect(session.document.undoTitle == "Drawing")

            // A tool with nothing in it closes without adding a step.
            viewer.adjustLighting(nil)
            await TestTiming.waitUntil { if case .adjustment? = viewer.activeTool { true } else { false } }
            #expect(session.document.operations.count == 3)

            // Esc (cancel) still drops the open tool's work.
            viewer.closeTool()
            #expect(session.document.operations.count == 3)
        }
    }
}
