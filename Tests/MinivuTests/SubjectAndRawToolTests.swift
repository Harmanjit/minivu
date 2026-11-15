import Testing
import AppKit
import ImageIO
import MinivuCore
import MinivuRender
@testable import Minivu

/// A document for a file that needn't exist: tool state only previews and
/// commits operations, which never touches pixels.
@MainActor private func toolDocument(kind: ImageKind) -> EditDocument {
    let name = kind == .raw ? "photo.nef" : "photo.jpg"
    let url = URL(fileURLWithPath: "/tmp/minivu-subject-tests/\(name)")
    return EditDocument(entry: FolderEntry(url: url, name: name, isDirectory: false, kind: kind, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

/// A mask whose subject is the left half of a 40 x 20 picture.
private func halfMask() -> SubjectMask {
    SubjectMask(coverage: (0..<(40 * 20)).map { $0 % 40 < 20 ? 255 : 0 }, width: 40, height: 20)!
}

/// The camera settings a RAW tool test pretends the engine reported.
private let camera = RawDefaults(exposure: 0, temperature: 5200, tint: 6, boost: 1, luminanceNoiseReduction: 0.2,
                                 colorNoiseReduction: 0.5, recoversHighlights: true, supportsHighlightRecovery: true)

@MainActor @Suite struct RawAndSubjectToolStateTests {
    /// The tool opens on the settings in effect (the camera's, before any
    /// RAW step), shows them at once, and commits only a change.
    @Test func rawToolStartsFromTheSettingsInEffectAndAppliesOnlyAChange() {
        let document = toolDocument(kind: .raw)
        let first = RawDevelopToolState(document: document, defaults: camera)
        let asShot = RawDevelop(exposure: 0, temperature: 5200, tint: 6, boost: 1, luminanceNoiseReduction: 0.2,
                                colorNoiseReduction: 0.5, recoversHighlights: true)
        #expect(first.initial == asShot && first.asShot == asShot)
        #expect(document.preview == .rawDevelop(asShot), "the engine's rendering shows as the tool opens")
        #expect(!first.hasPendingChanges)
        first.apply()
        #expect(document.operations.isEmpty && document.preview == nil, "nothing changed, nothing committed")

        let second = RawDevelopToolState(document: document, defaults: camera)
        second.update { $0.exposure = 1.2; $0.tint = 20 }
        #expect(second.hasPendingChanges)
        #expect(document.preview == .rawDevelop(second.settings))
        second.apply()
        #expect(document.operations.count == 1 && document.undoTitle == "RAW Adjustments")
        // A closed tool changes nothing more.
        second.update { $0.exposure = -3 }
        #expect(document.preview == nil)

        // Reopened, it starts where the last step left off; Reset goes back
        // to the camera's settings, and a slider's double-click to its own.
        let third = RawDevelopToolState(document: document, defaults: camera)
        #expect(third.initial.exposure == 1.2 && third.initial.tint == 20)
        let temperature = third.slider(\.temperature, "Temperature", range: RawDevelop.temperatureRange)
        #expect(temperature.slider.defaultValue == 5200)
        temperature.setValue(9000)
        #expect(third.settings.temperature == 9000)
        temperature.reset()
        #expect(third.settings.temperature == 5200)
        third.reset()
        #expect(third.settings == asShot)
        third.cancel()
        #expect(document.operations.count == 1 && document.preview == nil)
    }

    /// Nothing shows until Vision has answered; then the cut-out previews,
    /// transparent or on a colour, and Apply commits one step.
    @Test func removeBackgroundWaitsForTheSubject() {
        let document = toolDocument(kind: .raster)
        let lost = RemoveBackgroundToolState(document: document)
        #expect(lost.search == .running && document.preview == nil)
        lost.useMask(nil)
        #expect(lost.search == .none && document.preview == nil)
        lost.apply()
        #expect(document.operations.isEmpty)

        let state = RemoveBackgroundToolState(document: document)
        state.setColor(EditColor(red: 1, green: 0, blue: 0, alpha: 0.4))   // before the answer: kept, opaque
        #expect(document.preview == nil)
        state.useMask(halfMask())
        #expect(state.search == .found)
        #expect(document.preview == .removeBackground(RemoveBackground(mask: halfMask(), fill: EditColor(red: 1, green: 0, blue: 0))))
        state.setTransparent(true)
        #expect(document.preview == .removeBackground(RemoveBackground(mask: halfMask())))
        state.setTransparent(false)
        #expect(state.fill == EditColor(red: 1, green: 0, blue: 0), "the colour chosen comes back")
        state.reset()
        #expect(state.isTransparent)
        state.apply()
        #expect(document.operations == [.removeBackground(RemoveBackground(mask: halfMask()))])
        #expect(document.undoTitle == "Remove Background")
        // A late answer after Apply goes nowhere.
        state.useMask(halfMask())
        #expect(document.preview == nil)
    }
}

extension AppWindowTests {
    /// The RAW tool, Remove Background and Copy Subject in a real (windowed)
    /// viewer.
    @MainActor @Suite(.serialized) struct SubjectViewerTests {
        init() { _ = NSApplication.shared }

        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        /// A pasteboard of this test's own (never the person's clipboard).
        func scratchboard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("minivu-subject-tests-\(UUID().uuidString)"))
        }

        /// A red disc with a blue block below it on a plain light background,
        /// 800 x 600, as a PNG: a subject Vision lifts. The subject's box is
        /// x 250-550, y 150-540 from the top.
        func discPNG(in folder: ScratchFolder) throws -> URL {
            let url = folder.url.appendingPathComponent("disc.png")
            let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 360, y: 60, width: 80, height: 120))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(destination))
            return url
        }

        @Test func rawAdjustmentsAreOfferedOnlyForRawFiles() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("a.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateEditAction(.adjustRaw) == false)
            #expect(viewer.toolsPanel.row(for: .adjustRaw)?.isEnabled == false)
            #expect(viewer.validateEditAction(.removeBackground) == true)
            #expect(viewer.toolsPanel.row(for: .removeBackground)?.isEnabled == true)
            #expect(viewer.validateClipboardAction(.copySubject) == true)
        }

        @Test func removeBackgroundFindsTheSubjectAndAppliesOneStep() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try discPNG(in: folder)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            viewer.removeBackground(nil)
            guard case .custom(let open as RemoveBackgroundToolState)? = viewer.activeTool else {
                Issue.record("Remove Background did not open")
                return
            }
            #expect(viewer.toolsPanel.inspector != nil)
            await TestTiming.waitUntil { open.search != .running }
            #expect(open.search == .found)
            let session = try #require(viewer.editSession)
            guard case .removeBackground(let preview)? = session.document.preview else {
                Issue.record("no cut-out previewed")
                return
            }
            #expect(abs(preview.mask.bounds.midX - 0.5) < 0.05)
            viewer.closeTool(applying: true)
            #expect(session.document.undoTitle == "Remove Background" && session.document.operations.count == 1)
            await TestTiming.waitUntil { session.hasDisplayedEdit }
            #expect(session.hasDisplayedEdit)
            viewer.undoEdit()
            #expect(session.document.operations.isEmpty)
        }

        /// The subject alone, cut out and cropped to it, as PNG on the
        /// pasteboard; the document isn't changed.
        @Test func copySubjectPutsTheCutOutOnThePasteboard() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try discPNG(in: folder)))
            let board = scratchboard()
            defer { board.releaseGlobally() }
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }

            let task = try #require(viewer.copySubject(to: board))
            #expect(viewer.validateClipboardAction(.copySubject) == false, "not again while it works")
            #expect(viewer.copySubject(to: board) == nil)
            await task.value
            #expect(viewer.copySubjectTask == nil)
            #expect(viewer.validateClipboardAction(.copySubject) == true)

            #expect(board.data(forType: .png) != nil)
            let data = try #require(board.data(forType: .png))
            let rep = try #require(NSBitmapImageRep(data: data))
            // Cropped to the subject's box, give or take Vision's soft edge.
            #expect(abs(rep.pixelsWide - 300) < 30 && abs(rep.pixelsHigh - 390) < 40,
                    "\(rep.pixelsWide) x \(rep.pixelsHigh)")
            #expect(rep.hasAlpha)
            let corner = try #require(rep.colorAt(x: 1, y: 1))
            #expect(corner.alphaComponent < 0.1, "outside the disc: alpha \(corner.alphaComponent)")
            let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 3))
            #expect(middle.alphaComponent > 0.9 && middle.redComponent > 0.6, "the disc: \(middle)")
            // Nothing was edited to get it.
            #expect(viewer.editSession?.document.operations.isEmpty ?? true)
        }

        /// A real camera file: the tool opens on the camera's settings and
        /// applies a change as one step, which the canvas then shows. The
        /// file is copied, so nothing is ever written beside the test assets.
        @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Users/harman/latent/TestAssets/nikon_d750_sample.nef")))
        func rawToolDevelopsARealCameraFile() async throws {
            let folder = try ScratchFolder()
            let copy = folder.url.appendingPathComponent("sample.nef")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/Users/harman/latent/TestAssets/nikon_d750_sample.nef"),
                                             to: copy)
            let entry = try #require(FolderEntry(url: copy))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateEditAction(.adjustRaw) == true)
            #expect(viewer.toolsPanel.row(for: .adjustRaw)?.isEnabled == true)

            var opened: RawDevelopToolState?
            viewer.openRawDevelop { opened = $0 }
            await TestTiming.waitUntil { opened != nil }
            let state = try #require(opened)
            #expect(RawDevelop.temperatureRange.contains(state.initial.temperature ?? 0))
            let session = try #require(viewer.editSession)
            state.update { $0.exposure = 1 }
            await TestTiming.waitUntil { session.hasDisplayedEdit }
            viewer.closeTool(applying: true)
            #expect(session.document.undoTitle == "RAW Adjustments")
            #expect(session.document.operations.count == 1)
            await TestTiming.waitUntil { viewer.canvasTexture != nil && session.hasDisplayedEdit }
            #expect(session.hasDisplayedEdit)
        }
    }
}
