import Testing
import AppKit
import ImageIO
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// Editing in a real (windowed) viewer: sessions start on the first edit,
    /// renders reach the canvas, undo goes through the window, tools pin the
    /// panel, and unsaved edits are asked about before moving on.
    @MainActor @Suite(.serialized) struct EditViewerTests {
        init() { _ = NSApplication.shared }

        func enabled(_ viewer: ViewerWindowController, _ action: Selector) -> Bool {
            viewer.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        func press(_ character: Int, in viewer: ViewerWindowController) throws {
            let window = try #require(viewer.window)
            let characters = String(Character(UnicodeScalar(character)!))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: 0))
            window.contentView?.keyDown(with: event)
        }

        /// Closes whatever viewer is open without asking about edits.
        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        @Test func rotateUndoRedoAndTheUnsavedChangesQuestion() async throws {
            let folder = try ScratchFolder()
            let list = try [folder.jpeg("a.jpg", width: 600, height: 400), folder.jpeg("b.jpg", width: 600, height: 400)]
                .map { try #require(FolderEntry(url: $0)) }
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(enabled(viewer, .rotateRight) && enabled(viewer, .adjustLighting) && enabled(viewer, .saveImageAs))
            #expect(!enabled(viewer, .saveImage) && !enabled(viewer, .revertToSaved))
            #expect(viewer.editSession == nil)   // viewing alone makes no session
            #expect(viewer.toolsPanel.row(for: .cropImage)?.isEnabled == true)

            viewer.rotateRight(nil)
            let session = try #require(viewer.editSession)
            #expect(session.document.isDirty)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600))
            #expect(viewer.window?.isDocumentEdited == true)
            #expect(enabled(viewer, .saveImage) && enabled(viewer, .revertToSaved))

            // The Edit menu's Undo and Redo reach the image through the window.
            let window = try #require(viewer.window as? ViewerWindow)
            let undoItem = NSMenuItem(title: "Undo", action: ViewerWindow.undoAction, keyEquivalent: "z")
            #expect(window.validateMenuItem(undoItem))
            #expect(undoItem.title == "Undo Rotate Right")
            window.perform(ViewerWindow.undoAction, with: nil)
            #expect(!session.document.isDirty)
            #expect(viewer.window?.isDocumentEdited == false)
            let redoItem = NSMenuItem(title: "Redo", action: ViewerWindow.redoAction, keyEquivalent: "Z")
            #expect(window.validateMenuItem(redoItem))
            #expect(redoItem.title == "Redo Rotate Right")
            window.perform(ViewerWindow.redoAction, with: nil)
            #expect(session.document.isDirty)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600) }

            // Moving on with unsaved edits asks first. Cancel stays put.
            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            var asked: [String] = []
            var answer = UnsavedEditsChoice.cancel
            ViewerWindowController.askAboutUnsavedEdits = { name, _, reply in
                asked.append(name)
                reply(answer)
            }
            viewer.nextImage(nil)
            #expect(asked == ["a.jpg"])
            #expect(viewer.window?.title == "a.jpg")
            #expect(viewer.editSession === session)
            answer = .discard
            viewer.nextImage(nil)
            #expect(asked == ["a.jpg", "a.jpg"])
            #expect(viewer.window?.title == "b.jpg")
            #expect(viewer.editSession == nil)
            #expect(session.isEnded)
            #expect(viewer.window?.isDocumentEdited == false)
        }

        @Test func toolsPinThePanelReturnAppliesAndEscCancels() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }

            viewer.adjustLighting(nil)
            guard case .adjustment(let lighting)? = viewer.activeTool else {
                Issue.record("Lighting didn't open")
                return
            }
            #expect(viewer.flyouts.isPinned(.left))
            #expect(viewer.toolsPanel.inspector != nil)
            #expect(viewer.container.canvasLeadingInset == ViewerToolsPanel.inspectorWidth)
            lighting.setValue(0.5, section: 0, slider: 0)
            let session = try #require(viewer.editSession)
            await TestTiming.waitUntil { session.hasDisplayedEdit }
            #expect(session.hasDisplayedEdit)
            #expect(viewer.undoEditTitle == "Lighting")

            try press(0x1B, in: viewer)   // Esc cancels the tool, not the viewer
            #expect(ViewerWindowController.current === viewer)
            #expect(viewer.activeTool == nil)
            #expect(session.document.preview == nil && !session.document.isDirty)
            #expect(!viewer.flyouts.isPinned(.left))
            #expect(viewer.toolsPanel.inspector == nil)
            #expect(viewer.container.canvasLeadingInset == 0)

            viewer.cropImage(nil)
            await TestTiming.waitUntil { viewer.activeTool != nil }
            guard case .crop(let crop)? = viewer.activeTool else {
                Issue.record("Crop didn't open")
                return
            }
            #expect(viewer.container.canvasOverlay is CropOverlayView)
            #expect(viewer.canvasView.scrollingKeepsImage)
            crop.setPreset(.square)
            try press(NSCarriageReturnCharacter, in: viewer)
            #expect(viewer.activeTool == nil)
            #expect(viewer.container.canvasOverlay == nil)
            #expect(session.document.undoTitle == "Crop")
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 400) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 400))
            #expect(!viewer.canvasView.scrollingKeepsImage)
        }

        /// After a save writes the edits into the file, the session must not
        /// keep rendering from the pixels decoded before it: a decode of the
        /// saved file (new display settings) would apply the edits twice.
        @Test func savingOverTheOriginalStartsAgainFromTheSavedFile() async throws {
            let folder = try ScratchFolder()
            let url = try folder.jpeg("a.jpg", width: 600, height: 400)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            let session = try #require(viewer.editSession)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600) }

            // A save to another file leaves the document dirty: nothing changes.
            viewer.editsWereSaved(session)
            #expect(viewer.editSession === session)

            // What Save does: the rotated pixels over the original, caches
            // emptied, the document marked saved, then its completion.
            _ = try folder.jpeg("a.jpg", width: 400, height: 600)
            AppServices.images.invalidate(url)
            session.document.markSaved()
            viewer.editsWereSaved(session)
            #expect(viewer.editSession == nil && session.isEnded)
            #expect(viewer.window?.isDocumentEdited == false)
            #expect(!enabled(viewer, .saveImage) && !enabled(viewer, .revertToSaved))

            // New display settings decode the saved file once, not rotated again.
            NotificationCenter.default.post(name: .minivuDisplaySettingsChanged, object: nil)
            try? await Task.sleep(for: .milliseconds(600))
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 400, height: 600))

            // The next edit starts from the saved file.
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.rotateRight(nil)
            let next = try #require(viewer.editSession)
            #expect(next !== session && next.document.operations.count == 1)
            await TestTiming.waitUntil { viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 400) }
            #expect(viewer.canvasTexture?.imageSize == CGSize(width: 600, height: 400))
        }

        /// The app delegate asks the viewer before quitting.
        @Test func quittingAsksAboutUnsavedEdits() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            var replies: [Bool] = []
            viewer.reviewUnsavedEditsBeforeQuitting { replies.append($0) }
            #expect(replies == [true])

            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            var answer = UnsavedEditsChoice.cancel
            ViewerWindowController.askAboutUnsavedEdits = { _, _, reply in reply(answer) }
            viewer.adjustLighting(nil)
            guard case .adjustment(let lighting)? = viewer.activeTool else {
                Issue.record("Lighting didn't open")
                return
            }
            lighting.setValue(0.3, section: 0, slider: 0)
            #expect(viewer.hasUnsavedEdits)
            viewer.reviewUnsavedEditsBeforeQuitting { replies.append($0) }
            #expect(replies == [true, false])
            #expect(viewer.activeTool != nil)
            answer = .discard
            viewer.reviewUnsavedEditsBeforeQuitting { replies.append($0) }
            #expect(replies == [true, false, true])
            #expect(viewer.editSession == nil && !viewer.hasUnsavedEdits)
        }

        /// The crop overlay draws through the canvas's mapping: image pixels
        /// to view points and back, whatever the zoom and backing scale.
        @Test func imageAndViewPointsRoundTrip() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            let canvas = viewer.canvasView
            let rect = canvas.viewRect(forImageRect: CGRect(x: 0, y: 0, width: 600, height: 400))
            // Fitted and centred in the view (flipped, top-left origin).
            #expect(abs(rect.midX - canvas.bounds.midX) < 1 && abs(rect.midY - canvas.bounds.midY) < 1)
            #expect(rect.width <= canvas.bounds.width + 0.5 && rect.height <= canvas.bounds.height + 0.5)
            canvas.zoomIn()
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 320), CGPoint(x: 600, y: 400)] {
                let back = canvas.imagePoint(forViewPoint: canvas.viewPoint(forImagePoint: point))
                #expect(abs(back.x - point.x) < 0.01 && abs(back.y - point.y) < 0.01)
            }
            // A point lower in the view is lower in the image.
            let top = canvas.imagePoint(forViewPoint: CGPoint(x: canvas.bounds.midX, y: 10))
            let bottom = canvas.imagePoint(forViewPoint: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.height - 10))
            #expect(top.y < bottom.y)
        }

        /// Only one frame of an animation would survive an edit, so none is offered.
        @Test func animationsCantBeEdited() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("minivu-edit-gif-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("a.gif")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil))
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                as CFDictionary)
            for level in [0.0, 1.0] {
                let ctx = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(gray: level, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
                CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), props as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(destination))
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.animationPlayer != nil && viewer.canvasTexture != nil }
            #expect(!viewer.canEditCurrent)
            #expect(!enabled(viewer, .rotateLeft) && !enabled(viewer, .adjustCurves) && !enabled(viewer, .saveImageAs))
            viewer.rotateLeft(nil)
            #expect(viewer.editSession == nil)
            #expect(viewer.toolsPanel.row(for: .rotateLeft) == nil)
            #expect(viewer.toolsPanel.row(for: .adjustCurves)?.isEnabled == false)
        }
    }
}
