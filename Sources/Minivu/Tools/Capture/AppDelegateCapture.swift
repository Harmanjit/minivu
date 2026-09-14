import AppKit

/// Tools > Capture, handled by the app delegate: a capture doesn't belong to
/// any window, and works with none open.
extension AppDelegate {
    @objc func captureScreen(_ sender: Any?) {
        ScreenCaptureController.shared.captureEntireScreen()
    }

    @objc func captureWindow(_ sender: Any?) {
        ScreenCaptureController.shared.captureWindow()
    }

    @objc func captureSelection(_ sender: Any?) {
        ScreenCaptureController.shared.captureSelection()
    }

    #if DEBUG
    /// Debug only, for the snapshot harness: shows the selection overlay with
    /// a rectangle already dragged on the main screen. In a snapshot run the
    /// capturer never records, so letting go captures nothing.
    @objc func debugShowSelectionOverlay(_ sender: Any?) {
        guard let screen = NSScreen.main.map(CaptureScreen.init) else { return }
        let frame = screen.frame
        let rect = CGRect(x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.35,
                          width: frame.width * 0.36, height: frame.height * 0.3)
        let pixels = CaptureGeometry.selection(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY),
                                               bounds: frame, scale: screen.scale)
        ScreenCaptureController.shared.captureSelection(preset: (pixels, screen))
    }
    #endif
}
