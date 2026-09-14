import AppKit
import MinivuCore

/// Tools > Capture: Entire Screen, Window… and Selection…. Each checks
/// permission, captures through `ScreenCapturing`, saves a PNG to
/// Pictures/minivu Captures and opens it in the viewer.
///
/// Captures are SDR PNGs: ScreenCaptureKit's still capture hands back an
/// 8-bit image. Keeping an HDR screen's highlights (a 16-bit float capture
/// saved with a gain map) is future work.
@MainActor final class ScreenCaptureController {
    static let shared = ScreenCaptureController(capturer: defaultCapturer())

    var capturer: ScreenCapturing
    /// Pictures; tests use a scratch folder.
    var picturesFolder: URL = BookmarkStore.picturesFolder
    var now: () -> Date = Date.init
    var screens: () -> [CaptureScreen] = { NSScreen.screens.map { CaptureScreen($0) } }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Opens the saved capture in the viewer.
    var open: ([URL]) -> Void = { urls in (NSApp.delegate as? AppDelegate)?.open(urls) }
    /// Explains how to allow screen recording; an alert in the app.
    var explainDenied: () -> Void = { ScreenCaptureController.showPermissionAlert() }
    var explainFailure: (Error) -> Void = { ScreenCaptureController.showFailureAlert($0) }
    /// False in tests: the overlay is made but never put on screen.
    var showsOverlay = true
    /// The capture in flight, for tests to await.
    private(set) var work: Task<Void, Never>?
    private(set) var overlay: SelectionOverlayController?

    init(capturer: ScreenCapturing) {
        self.capturer = capturer
    }

    /// ScreenCaptureKit only in the real app. A snapshot run and a test
    /// process get a capturer that never records and never asks, so neither
    /// can bring up the system's screen recording prompt.
    static func defaultCapturer(environment: [String: String] = ProcessInfo.processInfo.environment,
                                processName: String = ProcessInfo.processInfo.processName) -> ScreenCapturing {
        environment["MINIVU_SNAPSHOT"] != nil || processName != "minivu"
            ? HarnessScreenCapturer() : SystemScreenCapturer()
    }

    var capturesFolder: URL {
        picturesFolder.appendingPathComponent(CaptureFiles.folderName, isDirectory: true)
    }

    // MARK: - Commands

    /// The whole screen the pointer is on.
    func captureEntireScreen() {
        guard work == nil, overlay == nil else { return }
        guard capturer.requestPermission() else { return explainDenied() }
        guard let screen = CaptureGeometry.screen(containing: pointerLocation(), in: screens()) else { return }
        capture(DisplayCaptureRequest(displayID: screen.displayID, sourceRect: nil, pixelSize: screen.pixelSize))
    }

    /// A window chosen in the system's picker.
    func captureWindow() {
        guard work == nil, overlay == nil else { return }
        guard capturer.requestPermission() else { return explainDenied() }
        let capturer = self.capturer
        run { try await capturer.captureWindowFromPicker() }
    }

    /// Shows the selection overlay on every screen; the dragged rectangle is
    /// captured when the mouse comes up (or on Return), Esc cancels.
    func captureSelection(preset: (rect: CGRect, screen: CaptureScreen)? = nil) {
        guard work == nil, overlay == nil else { return }
        guard capturer.requestPermission() else { return explainDenied() }
        let overlay = SelectionOverlayController(screens: screens()) { [weak self] selection in
            guard let self else { return }
            self.overlay = nil
            if let selection { self.capture(selection.rect, on: selection.screen) }
        }
        self.overlay = overlay
        overlay.show(preset: preset, ordersFront: showsOverlay)
    }

    /// Captures `rect` (global AppKit coordinates) of `screen`.
    func capture(_ rect: CGRect, on screen: CaptureScreen) {
        let clipped = rect.intersection(screen.frame)
        guard !clipped.isNull, CaptureGeometry.isUsable(clipped) else { return }
        capture(DisplayCaptureRequest(displayID: screen.displayID,
                                      sourceRect: CaptureGeometry.sourceRect(for: clipped, on: screen),
                                      pixelSize: CaptureGeometry.pixelSize(of: clipped, scale: screen.scale)))
    }

    private func capture(_ request: DisplayCaptureRequest) {
        let capturer = self.capturer
        run { try await capturer.captureDisplay(request) }
    }

    /// Captures, saves and opens; a denial explains how to allow capture.
    private func run(_ produce: @escaping () async throws -> ImageBox?) {
        work = Task {
            defer { work = nil }
            do {
                guard let image = try await produce() else { return }
                let url = try await save(image)
                open([url])
            } catch CaptureError.permissionDenied {
                explainDenied()
            } catch {
                explainFailure(error)
            }
        }
    }

    /// Writes the PNG through the file write queue, into a folder made when
    /// missing, under a name no file has yet.
    func save(_ image: ImageBox) async throws -> URL {
        let folder = capturesFolder
        let name = CaptureFiles.fileName(date: now())
        let options = ExportOptions(format: .png, colorProfile: .original, keepMetadata: false)
        let job = FileWriteQueue.shared.enqueue {
            try await BlockingWork.run {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(FileOperations.uniqueName(for: name, in: folder))
                try ImageEncoder.write(image.image, to: url, options: options, metadataSource: nil)
                return url
            }
        }
        return try await job.value.value
    }

    // MARK: - Alerts

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "minivu needs permission to capture the screen"
        alert.informativeText = "Turn on minivu in System Settings > Privacy & Security > Screen & System Audio "
            + "Recording, then quit and reopen minivu."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(privacySettingsURL)
        }
    }

    static func showFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The screen couldn’t be captured."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension CaptureScreen {
    init(_ screen: NSScreen) {
        self.init(displayID: screen.displayID, frame: screen.frame, scale: screen.backingScaleFactor)
    }
}
