import Testing
import AppKit
import ImageIO
import MinivuCore
@testable import Minivu

/// A capturer that records requests and returns a small image, or refuses.
/// It never touches ScreenCaptureKit, so no permission prompt can appear.
final class FakeCapturer: ScreenCapturing {
    var allowed = true
    var failure: Error?
    var permissionRequests = 0
    var displayRequests: [DisplayCaptureRequest] = []
    var pickerRequests = 0
    var pickerCancels = false
    var systemPromptedForPermission = false

    func requestPermission() -> Bool {
        permissionRequests += 1
        return allowed
    }

    func captureDisplay(_ request: DisplayCaptureRequest) async throws -> ImageBox {
        displayRequests.append(request)
        if let failure { throw failure }
        return Self.image(width: Int(request.pixelSize.width), height: Int(request.pixelSize.height))
    }

    func captureWindowFromPicker() async throws -> ImageBox? {
        pickerRequests += 1
        if let failure { throw failure }
        return pickerCancels ? nil : Self.image(width: 30, height: 20)
    }

    static func image(width: Int, height: Int) -> ImageBox {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageBox(image: context.makeImage()!)
    }
}

@Suite struct CaptureGeometryTests {
    /// The main screen, a 2x laptop, with a 1x display to its left and a
    /// little lower, and another above.
    let main = CaptureScreen(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    let left = CaptureScreen(displayID: 2, frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080), scale: 1)
    let above = CaptureScreen(displayID: 3, frame: CGRect(x: 200, y: 982, width: 2560, height: 1440), scale: 2)

    @Test func sourceRectIsFromTheDisplaysTopLeft() {
        // 100 pt from the main screen's left and 50 pt below its top.
        let rect = CGRect(x: 100, y: 982 - 50 - 200, width: 300, height: 200)
        #expect(CaptureGeometry.sourceRect(for: rect, on: main) == CGRect(x: 100, y: 50, width: 300, height: 200))
        // On the left display (negative x, lower origin).
        let onLeft = CGRect(x: -1820, y: 580, width: 400, height: 100)
        #expect(CaptureGeometry.sourceRect(for: onLeft, on: left) == CGRect(x: 100, y: 100, width: 400, height: 100))
        // On the display above.
        let onAbove = CGRect(x: 300, y: 2322, width: 50, height: 50)
        #expect(CaptureGeometry.sourceRect(for: onAbove, on: above) == CGRect(x: 100, y: 50, width: 50, height: 50))
        // The whole screen.
        #expect(CaptureGeometry.sourceRect(for: left.frame, on: left) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func pointsBecomePixels() {
        #expect(CaptureGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 300, height: 200.5), scale: 2)
            == CGSize(width: 600, height: 401))
        #expect(main.pixelSize == CGSize(width: 3024, height: 1964))
        #expect(left.pixelSize == CGSize(width: 1920, height: 1080))
        #expect(CaptureGeometry.sizeLabel(for: CGRect(x: 0, y: 0, width: 640, height: 400), scale: 2) == "1280 × 800")
    }

    @Test func theScreenUnderThePointer() {
        let screens = [main, left, above]
        #expect(CaptureGeometry.screen(containing: CGPoint(x: 10, y: 10), in: screens) == main)
        #expect(CaptureGeometry.screen(containing: CGPoint(x: -10, y: 0), in: screens) == left)
        #expect(CaptureGeometry.screen(containing: CGPoint(x: 1000, y: 2000), in: screens) == above)
        // The top edge of the main screen belongs to no frame; the nearest wins.
        #expect(CaptureGeometry.screen(containing: CGPoint(x: 100, y: 982), in: [main, left]) == main)
        #expect(CaptureGeometry.screen(containing: .zero, in: []) == nil)
    }

    @Test func selectionIsNormalisedClampedAndSnappedToPixels() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Dragged up and to the left.
        #expect(CaptureGeometry.selection(from: CGPoint(x: 300, y: 400), to: CGPoint(x: 100, y: 250), bounds: bounds,
                                          scale: 2) == CGRect(x: 100, y: 250, width: 200, height: 150))
        // Past the screen's edge.
        #expect(CaptureGeometry.selection(from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1200),
                                          bounds: bounds, scale: 2) == CGRect(x: 1400, y: 900, width: 112, height: 82))
        // Half points widen to whole pixels on a 1x display, stay on 2x.
        #expect(CaptureGeometry.selection(from: CGPoint(x: 10.25, y: 10.75), to: CGPoint(x: 20.5, y: 30.2),
                                          bounds: bounds, scale: 1) == CGRect(x: 10, y: 10, width: 11, height: 21))
        #expect(CaptureGeometry.selection(from: CGPoint(x: 10.25, y: 10.75), to: CGPoint(x: 20.5, y: 30.2),
                                          bounds: bounds, scale: 2) == CGRect(x: 10, y: 10.5, width: 10.5, height: 20))
        #expect(!CaptureGeometry.isUsable(CGRect(x: 0, y: 0, width: 3, height: 100)))
        #expect(CaptureGeometry.isUsable(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    @Test func sizeLabelStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let label = CGSize(width: 90, height: 22)
        // Below the bottom right corner.
        #expect(CaptureGeometry.labelFrame(for: CGRect(x: 100, y: 300, width: 400, height: 200), labelSize: label,
                                           bounds: bounds) == CGRect(x: 410, y: 270, width: 90, height: 22))
        // No room below: inside the selection's bottom edge.
        #expect(CaptureGeometry.labelFrame(for: CGRect(x: 100, y: 5, width: 400, height: 200), labelSize: label,
                                           bounds: bounds) == CGRect(x: 410, y: 13, width: 90, height: 22))
        // A narrow selection at the left edge keeps the label on screen.
        #expect(CaptureGeometry.labelFrame(for: CGRect(x: 0, y: 300, width: 20, height: 20), labelSize: label,
                                           bounds: bounds).minX == 8)
    }

    @Test func captureFileNames() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(CaptureFiles.fileName(date: Date(timeIntervalSince1970: 1_789_381_805), timeZone: utc)
            == "Capture 2026-09-14 at 10.30.05.png")
    }
}

@MainActor @Suite struct CaptureControllerTests {
    let main = CaptureScreen(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    let left = CaptureScreen(displayID: 2, frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080), scale: 1)

    func controller(_ capturer: FakeCapturer, pictures: URL) -> (ScreenCaptureController, Recorder) {
        let controller = ScreenCaptureController(capturer: capturer)
        let recorder = Recorder()
        controller.picturesFolder = pictures
        controller.screens = { [main, left] }
        controller.now = { Date(timeIntervalSince1970: 1_789_381_805) }
        controller.open = { recorder.opened += $0 }
        controller.explainDenied = { recorder.denied += 1 }
        controller.explainFailure = { recorder.failures.append($0.localizedDescription) }
        controller.showsOverlay = false
        return (controller, recorder)
    }

    final class Recorder {
        var opened: [URL] = []
        var denied = 0
        var failures: [String] = []
    }

    @Test func deniedPermissionExplainsAndCapturesNothing() async throws {
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        capturer.allowed = false
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        controller.captureEntireScreen()
        controller.captureSelection()
        #expect(recorder.denied == 2)
        #expect(controller.work == nil && controller.overlay == nil)
        #expect(capturer.displayRequests.isEmpty && capturer.pickerRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: controller.capturesFolder.path))

        // The first refusal comes with the system's own prompt: no second alert.
        capturer.systemPromptedForPermission = true
        controller.captureEntireScreen()
        #expect(recorder.denied == 2 && controller.work == nil)
        capturer.systemPromptedForPermission = false

        // Refused during the capture itself (the user turned it off meanwhile).
        capturer.allowed = true
        capturer.failure = CaptureError.permissionDenied
        controller.captureEntireScreen()
        await controller.work?.value
        #expect(recorder.denied == 3 && recorder.failures.isEmpty && recorder.opened.isEmpty)
    }

    /// Window… opens the system's picker without asking for screen
    /// recording: choosing a window there is consent enough on macOS 15.
    @Test func windowPickerNeedsNoScreenRecordingPermission() async throws {
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        capturer.allowed = false
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        controller.captureWindow()
        await controller.work?.value
        #expect(capturer.permissionRequests == 0, "never asked")
        #expect(capturer.pickerRequests == 1 && recorder.denied == 0)
        #expect(recorder.opened.count == 1, "the chosen window was captured and opened")

        // A refusal from the capture itself is still explained.
        capturer.failure = CaptureError.permissionDenied
        controller.captureWindow()
        await controller.work?.value
        #expect(capturer.permissionRequests == 0 && recorder.denied == 1 && recorder.opened.count == 1)
    }

    @Test func entireScreenCapturesTheScreenUnderThePointerAndOpensIt() async throws {
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        controller.pointerLocation = { CGPoint(x: -100, y: 200) }
        controller.captureEntireScreen()
        await controller.work?.value
        #expect(capturer.displayRequests == [DisplayCaptureRequest(displayID: 2, sourceRect: nil,
                                                                   pixelSize: CGSize(width: 1920, height: 1080))])
        let url = try #require(recorder.opened.first)
        let name = CaptureFiles.fileName(date: controller.now())
        #expect(url.lastPathComponent == name)
        #expect(url.deletingLastPathComponent().lastPathComponent == "minivu Captures")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1920)

        // A second capture in the same second gets a name of its own.
        controller.captureEntireScreen()
        await controller.work?.value
        #expect(recorder.opened.map(\.lastPathComponent)
            == [name, name.replacingOccurrences(of: ".png", with: " 2.png")])
    }

    @Test func selectionCapturesItsRectangleInDisplayPixels() async throws {
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        controller.capture(CGRect(x: -1820, y: 580, width: 400, height: 100), on: left)
        await controller.work?.value
        controller.capture(CGRect(x: 100, y: 732, width: 300, height: 200), on: main)
        await controller.work?.value
        #expect(capturer.displayRequests == [
            DisplayCaptureRequest(displayID: 2, sourceRect: CGRect(x: 100, y: 100, width: 400, height: 100),
                                  pixelSize: CGSize(width: 400, height: 100)),
            DisplayCaptureRequest(displayID: 1, sourceRect: CGRect(x: 100, y: 50, width: 300, height: 200),
                                  pixelSize: CGSize(width: 600, height: 400)),
        ])
        #expect(recorder.opened.count == 2)
        // A rectangle running off the screen is clipped to it; a sliver is ignored.
        controller.capture(CGRect(x: 1400, y: 900, width: 500, height: 500), on: main)
        await controller.work?.value
        #expect(capturer.displayRequests.last?.sourceRect == CGRect(x: 1400, y: 0, width: 112, height: 82))
        let count = capturer.displayRequests.count
        controller.capture(CGRect(x: 10, y: 10, width: 2, height: 50), on: main)
        #expect(controller.work == nil && capturer.displayRequests.count == count)
    }

    @Test func windowPickerCancelAndFailure() async throws {
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        capturer.pickerCancels = true
        controller.captureWindow()
        await controller.work?.value
        #expect(capturer.pickerRequests == 1 && recorder.opened.isEmpty && recorder.failures.isEmpty)

        capturer.pickerCancels = false
        controller.captureWindow()
        await controller.work?.value
        #expect(recorder.opened.count == 1)

        capturer.failure = CaptureError.displayNotFound
        controller.captureWindow()
        await controller.work?.value
        #expect(recorder.failures == ["The display is no longer connected."])
    }

    /// The overlay shows on each screen; letting go of a drag captures that
    /// rectangle, in global coordinates; Esc captures nothing.
    @Test func selectionOverlayReportsTheDraggedRectangle() async throws {
        _ = NSApplication.shared
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        controller.captureSelection(preset: (CGRect(x: -1820, y: 580, width: 400, height: 100), left))
        let overlay = try #require(controller.overlay)
        #expect(overlay.windows.count == 2)
        let leftView = try #require(overlay.windows.first { $0.frame == left.frame }?.overlayView)
        #expect(leftView.selection == CGRect(x: 100, y: 880, width: 400, height: 100))
        #expect(overlay.windows.allSatisfy { $0.level == .screenSaver && !$0.isOpaque })
        leftView.onFinish?(leftView.selection)
        #expect(controller.overlay == nil)
        await controller.work?.value
        #expect(capturer.displayRequests.first?.sourceRect == CGRect(x: 100, y: 100, width: 400, height: 100))
        #expect(recorder.opened.count == 1)

        controller.captureSelection()
        let second = try #require(controller.overlay)
        let window = try #require(second.windows.first)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        window.overlayView.keyDown(with: escape)
        #expect(controller.overlay == nil && controller.work == nil)
        #expect(capturer.displayRequests.count == 1)
    }

    /// The overlay is key but never main, so a menu shortcut would go on to
    /// the browser or viewer behind it: ⌘Delete would trash photos. The
    /// overlay takes every key equivalent before the menu bar can, and Esc
    /// and Return still cancel and capture. Nothing is put on screen.
    @Test func selectionOverlayKeepsMenuShortcutsFromOtherWindows() async throws {
        _ = NSApplication.shared
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        final class Target: NSObject {
            var trashed = 0
            @objc func moveToTrash(_ sender: Any?) { trashed += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Move to Trash", action: #selector(Target.moveToTrash(_:)),
                                keyEquivalent: MainMenu.Key.backspace)
        item.target = target
        let commandDelete = try key(51, MainMenu.Key.backspace, .command)
        #expect(menu.performKeyEquivalent(with: commandDelete) && target.trashed == 1, "the shortcut matches")

        controller.captureSelection(preset: (CGRect(x: 100, y: 732, width: 300, height: 200), main))
        let window = try #require(controller.overlay?.windows.first { $0.frame == main.frame })
        #expect(window.canBecomeKey && !window.canBecomeMain)
        // AppKit's order: the key window first, the menu bar only if it declines.
        #expect(window.performKeyEquivalent(with: commandDelete) || menu.performKeyEquivalent(with: commandDelete))
        #expect(target.trashed == 1 && controller.overlay != nil && capturer.displayRequests.isEmpty)

        #expect(window.performKeyEquivalent(with: try key(36, "\r")))
        #expect(controller.overlay == nil)
        await controller.work?.value
        #expect(capturer.displayRequests.first?.sourceRect == CGRect(x: 100, y: 50, width: 300, height: 200))
        #expect(recorder.opened.count == 1)

        controller.captureSelection()
        let second = try #require(controller.overlay?.windows.first)
        #expect(second.performKeyEquivalent(with: try key(53, "\u{1b}")))
        #expect(controller.overlay == nil && controller.work == nil && capturer.displayRequests.count == 1)
        #expect(target.trashed == 1)
    }

    /// ⌘Q is the one shortcut the overlay passes on: the capture is abandoned
    /// (overlay gone, nothing captured or written) and the menu bar gets it.
    /// A fake Quit item stands in for the app's, so nothing terminates.
    @Test func selectionOverlayLetsQuitThrough() async throws {
        _ = NSApplication.shared
        let scratch = try ScratchFolder()
        let capturer = FakeCapturer()
        let (controller, recorder) = controller(capturer, pictures: scratch.url)
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 12))
        }
        final class Target: NSObject {
            var quits = 0
            @objc func quit(_ sender: Any?) { quits += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit minivu", action: #selector(Target.quit(_:)), keyEquivalent: "q").target = target
        let commandQ = try key("q", .command)

        controller.captureSelection(preset: (CGRect(x: 100, y: 732, width: 300, height: 200), main))
        let window = try #require(controller.overlay?.windows.first { $0.frame == main.frame })
        // Other shortcuts with Q stay the overlay's.
        #expect(window.performKeyEquivalent(with: try key("q", [.command, .option])))
        #expect(controller.overlay != nil)

        #expect(!window.performKeyEquivalent(with: commandQ), "passed on, not swallowed")
        #expect(controller.overlay == nil && controller.work == nil)
        #expect(window.performKeyEquivalent(with: commandQ) || menu.performKeyEquivalent(with: commandQ))
        #expect(target.quits == 1)
        #expect(capturer.displayRequests.isEmpty && recorder.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: controller.capturesFolder.path))
        // A new capture can start.
        controller.captureSelection()
        #expect(controller.overlay != nil)
        controller.overlay?.cancel()
    }

    /// Only the real app records the screen: a snapshot run or a test
    /// process can never bring up the permission prompt.
    @Test func harnessAndTestsNeverUseScreenCaptureKit() async {
        #expect(ScreenCaptureController.defaultCapturer() is HarnessScreenCapturer)
        #expect(ScreenCaptureController.defaultCapturer(environment: ["MINIVU_SNAPSHOT": "/tmp/x.png"],
                                                        processName: "minivu") is HarnessScreenCapturer)
        #expect(ScreenCaptureController.defaultCapturer(environment: [:], processName: "minivu") is SystemScreenCapturer)
        let harness = HarnessScreenCapturer()
        #expect(harness.requestPermission())
        await #expect(throws: CaptureError.notInHarness) {
            _ = try await harness.captureDisplay(DisplayCaptureRequest(displayID: 1, pixelSize: CGSize(width: 1, height: 1)))
        }
    }

    @Test func commandsAreImplementedByTheAppDelegate() {
        for action: Selector in [.captureScreen, .captureWindow, .captureSelection, .manageExternalEditors] {
            #expect(AppDelegate.instancesRespond(to: action), "\(action)")
        }
        #expect(ScreenCaptureController.privacySettingsURL.scheme == "x-apple.systempreferences")
    }
}
