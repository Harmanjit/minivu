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
        controller.captureWindow()
        controller.captureSelection()
        #expect(recorder.denied == 3)
        #expect(controller.work == nil && controller.overlay == nil)
        #expect(capturer.displayRequests.isEmpty && capturer.pickerRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: controller.capturesFolder.path))

        // Refused during the capture itself (the user turned it off meanwhile).
        capturer.allowed = true
        capturer.failure = CaptureError.permissionDenied
        controller.captureEntireScreen()
        await controller.work?.value
        #expect(recorder.denied == 4 && recorder.failures.isEmpty && recorder.opened.isEmpty)
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
