import AppKit
@preconcurrency import ScreenCaptureKit

/// What to capture from one display.
nonisolated struct DisplayCaptureRequest: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    /// Part of the display in points from its top left (ScreenCaptureKit's
    /// `sourceRect`); nil for all of it.
    var sourceRect: CGRect?
    /// Size of the picture in pixels.
    var pixelSize: CGSize
}

nonisolated enum CaptureError: LocalizedError, Equatable {
    /// Screen recording isn't allowed for minivu.
    case permissionDenied
    case displayNotFound
    /// A capture the snapshot harness asked for; it never records the screen.
    case notInHarness

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "minivu isn’t allowed to record the screen."
        case .displayNotFound: "The display is no longer connected."
        case .notInHarness: "Screen capture is off in snapshot runs."
        }
    }
}

/// Screen recording, behind a protocol: ScreenCaptureKit in the app, fakes
/// in tests, which must never trigger the system's permission prompt.
protocol ScreenCapturing: AnyObject {
    /// Whether minivu may record the screen. The system capturer asks the
    /// system, which shows its prompt the first time only.
    func requestPermission() -> Bool
    /// The display, without minivu's own windows.
    func captureDisplay(_ request: DisplayCaptureRequest) async throws -> ImageBox
    /// Shows the system's window picker and captures the window chosen; nil
    /// when the user cancels.
    func captureWindowFromPicker() async throws -> ImageBox?
}

/// ScreenCaptureKit.
final class SystemScreenCapturer: NSObject, ScreenCapturing, SCContentSharingPickerObserver {
    private var pickerContinuation: CheckedContinuation<FilterBox?, Error>?

    func requestPermission() -> Bool {
        // The preflight never prompts; the request prompts once in the app's
        // life, then answers at once.
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func captureDisplay(_ request: DisplayCaptureRequest) async throws -> ImageBox {
        try await Self.capture(request, processID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Off the main actor: listing windows and capturing take tens of
    /// milliseconds.
    nonisolated private static func capture(_ request: DisplayCaptureRequest, processID: Int32) async throws -> ImageBox {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
                throw CaptureError.displayNotFound
            }
            // minivu's own windows (the browser, a sheet) are left out, so a
            // capture shows what the user wanted to capture.
            let own = content.windows.filter { $0.owningApplication?.processID == processID }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let configuration = SCStreamConfiguration()
            if let rect = request.sourceRect { configuration.sourceRect = rect }
            configuration.width = Int(request.pixelSize.width)
            configuration.height = Int(request.pixelSize.height)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.displayP3
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return ImageBox(image: image)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        }
    }

    func captureWindowFromPicker() async throws -> ImageBox? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        if let identifier = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [identifier] }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
        }
        let picked: FilterBox? = try await withCheckedThrowingContinuation { continuation in
            pickerContinuation = continuation
            picker.present(using: .window)
        }
        guard let filter = picked?.filter else { return nil }
        let scale = CGFloat(filter.pointPixelScale)
        let size = CGSize(width: (filter.contentRect.width * scale).rounded(),
                          height: (filter.contentRect.height * scale).rounded())
        return try await Self.capture(filter: filter, pixelSize: size)
    }

    nonisolated private static func capture(filter: SCContentFilter, pixelSize: CGSize) async throws -> ImageBox {
        do {
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(pixelSize.width))
            configuration.height = max(1, Int(pixelSize.height))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.displayP3
            configuration.ignoreShadowsSingleWindow = false
            return ImageBox(image: try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                              configuration: configuration))
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        }
    }

    // MARK: SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finishPicking(.success(nil)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        let box = FilterBox(filter: filter)
        Task { @MainActor in self.finishPicking(.success(box)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let failure = CaptureError.permissionDenied as Error
        let isDenied = (error as? SCStreamError)?.code == .userDeclined
        let message = error.localizedDescription
        Task { @MainActor in
            self.finishPicking(.failure(isDenied ? failure : NSError(domain: "minivu.capture", code: 1,
                                                                     userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    private func finishPicking(_ result: Result<FilterBox?, Error>) {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        continuation.resume(with: result)
    }
}

/// The picked filter, handed from the picker's callback to the main actor.
/// A filter is a description the capture only reads.
nonisolated struct FilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}

/// Used by the snapshot harness: the selection overlay can be pictured, but
/// nothing is ever recorded and the system is never asked for permission.
final class HarnessScreenCapturer: ScreenCapturing {
    func requestPermission() -> Bool { true }

    func captureDisplay(_ request: DisplayCaptureRequest) async throws -> ImageBox {
        throw CaptureError.notInHarness
    }

    func captureWindowFromPicker() async throws -> ImageBox? {
        throw CaptureError.notInHarness
    }
}
