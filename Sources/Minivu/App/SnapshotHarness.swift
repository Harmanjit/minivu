import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinivuCore

/// Saves a picture of a window and quits, so developers and agents can see
/// the UI without granting screen-recording permission.
///
///     MINIVU_SNAPSHOT=/tmp/minivu.png          turns the harness on; the PNG to write
///     MINIVU_OPEN=~/Pictures/Trip             opened as if from Finder
///     MINIVU_WINDOW_SIZE=1400x900             content size in points
///     MINIVU_ACTIONS="openInViewer:;zoomIn:"  sent down the responder chain, 0.4 s apart
///                                             (then to an open sheet and its delegate);
///                                             a sheet is captured over its window
///     MINIVU_SNAPSHOT_DELAY=2                 seconds to wait before capturing (default 1.5)
///     MINIVU_SNAPSHOT_WINDOW=settings         capture the Settings window instead
///     MINIVU_VIEWER=~/Pictures/Trip/a.jpg     open the viewer on this file, without the browser
///
/// The picture is made inside the app by asking views to render into a
/// bitmap, not by reading the screen, which is why no permission is
/// needed. Metal content never reaches such a bitmap (it goes straight to
/// the display), so views that show it conform to `SnapshotProviding` and
/// are composited on top.
enum SnapshotHarness {
    /// Plain values parsed from the environment. `nonisolated` because
    /// nothing here touches the UI, so it can be used (and tested) anywhere.
    nonisolated struct Configuration: Equatable, Sendable {
        var output: URL
        var open: URL?
        var windowSize: CGSize?
        var actions: [String] = []
        var delay: Double = 1.5
        var capturesSettings = false
        var viewer: URL?

        /// nil unless MINIVU_SNAPSHOT is set.
        init?(environment: [String: String]) {
            guard let output = environment["MINIVU_SNAPSHOT"], !output.isEmpty else { return nil }
            self.output = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            if let path = environment["MINIVU_OPEN"], !path.isEmpty {
                open = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            windowSize = environment["MINIVU_WINDOW_SIZE"].flatMap(Self.parseSize)
            actions = environment["MINIVU_ACTIONS"].map(Self.parseActions) ?? []
            if let text = environment["MINIVU_SNAPSHOT_DELAY"], let seconds = Double(text), seconds >= 0 {
                delay = seconds
            }
            capturesSettings = environment["MINIVU_SNAPSHOT_WINDOW"]?.lowercased() == "settings"
            if let path = environment["MINIVU_VIEWER"], !path.isEmpty {
                viewer = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }

        /// "1400x900" (either case of x) to a size; nil if malformed.
        static func parseSize(_ text: String) -> CGSize? {
            let parts = text.lowercased().split(separator: "x")
            guard parts.count == 2,
                  let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }

        /// "a:; b:" to ["a:", "b:"].
        static func parseActions(_ text: String) -> [String] {
            text.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    /// A stuck run must not leave a windowed app behind in an agent's
    /// session, so a background timer kills the process whatever the main
    /// thread is doing.
    nonisolated static let timeout: Double = 30

    static func startIfRequested(app: AppDelegate,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let config = Configuration(environment: environment) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            FileHandle.standardError.write(Data("MINIVU_SNAPSHOT: gave up after \(Int(timeout)) s\n".utf8))
            exit(2)
        }
        Task { await run(config, app: app) }
    }

    private static func run(_ config: Configuration, app: AppDelegate) async {
        if let url = config.open { app.open([url]) }
        if config.capturesSettings { app.showSettings(nil) }
        if let file = config.viewer { await openViewer(on: file) }
        await pause(0.2)   // let the windows order in and lay out

        if let size = config.windowSize {
            targetWindow(config, app: app)?.setContentSize(size)
        }
        for action in config.actions {
            let selector = NSSelectorFromString(action)
            // With another app holding focus minivu can't activate, so there
            // is no key window for AppKit to start from; walk the captured
            // window's own responder chain instead.
            let target = targetWindow(config, app: app)
            let sent = NSApp.sendAction(selector, to: nil, from: nil)
                || target?.firstResponder?.tryToPerform(selector, with: nil) == true
                || target?.attachedSheet.map { send(selector, toSheet: $0) } == true
            if !sent { report("no responder handled \(action)") }
            await pause(0.4)
        }
        await pause(config.delay)

        guard let window = targetWindow(config, app: app) else {
            report("no visible window to capture")
            exit(1)
        }
        guard let image = capture(window), write(image, to: config.output) else {
            report("could not capture or write \(config.output.path)")
            exit(1)
        }
        report("wrote \(config.output.path) (\(image.width)x\(image.height) px)")
        // A sheet still up (the picture was of it) would hold up terminating.
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { exit(0) }
        NSApp.terminate(nil)
    }

    /// Lists the file's folder the way the browser would and opens the viewer
    /// on it, so the viewer can be pictured on its own.
    private static func openViewer(on file: URL) async {
        let folder = file.deletingLastPathComponent()
        let order = Preferences.shared.sortOrder
        let images = await Task.detached {
            FolderListing.sorted((try? FolderListing.contents(of: folder).images) ?? [], by: order)
        }.value
        guard let index = images.firstIndex(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) else {
            report("\(file.path) is not an image in its folder")
            return
        }
        ViewerWindowController.show(images: images, index: index, fullScreen: Preferences.shared.openViewerFullScreen,
                                    onClose: { _ in })
    }

    private static func targetWindow(_ config: Configuration, app: AppDelegate) -> NSWindow? {
        if config.capturesSettings { return app.settingsWindow }
        // Launched from a terminal the app may not become active, so there
        // may be no key window; the frontmost visible one is next best. A
        // key sheet is pictured on its window (see `capture`).
        let window = NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible }
        return window?.sheetParent ?? window
    }

    /// A sheet (Save As, the comment editor) isn't in its window's responder
    /// chain, and a save panel's controller is only its delegate: try the
    /// sheet's own chain, then the delegate.
    private static func send(_ selector: Selector, toSheet sheet: NSWindow) -> Bool {
        if sheet.firstResponder?.tryToPerform(selector, with: nil) == true { return true }
        guard let delegate = sheet.delegate as? NSObject, delegate.responds(to: selector) else { return false }
        delegate.perform(selector, with: nil)
        return true
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("MINIVU_SNAPSHOT: \(message)\n".utf8))
    }

    // MARK: - Capture

    /// Renders the whole window (titlebar and toolbar included) at its
    /// backing scale into an sRGB bitmap.
    ///
    /// The base picture comes from rendering the frame view's layer tree,
    /// which draws the layer contents already made for the screen. Asking
    /// the views to draw again with `cacheDisplay` gave identical pictures
    /// of AppKit controls, text, SwiftUI and layer images; neither captures
    /// translucent materials or Metal, which the steps below stand in for.
    static func capture(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        // The content view's superview is the window's frame view, which
        // also holds the titlebar and toolbar.
        let root = content.superview ?? content
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()

        let scale = window.backingScaleFactor
        let bounds = root.bounds
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            fillBackdrops(of: window, root: root, in: context)
            root.layer?.render(in: context)
            compositeProviders(in: root, context: context)
        }
        if let sheet = window.attachedSheet, sheet.isVisible {
            drawSheet(sheet, over: window, in: context)
        }
        return context.makeImage()
    }

    /// A sheet is a window of its own; it is drawn where it sits over its
    /// parent, clipped to the rounded shape sheets have.
    ///
    /// The system save panel is drawn by another process (its content is an
    /// `NSRemoteView`), which no bitmap render reaches. Only its accessory
    /// view lives in minivu, so that is drawn instead, in the panel's frame
    /// above where the button row would be.
    private static func drawSheet(_ sheet: NSWindow, over window: NSWindow, in context: CGContext) {
        guard let content = sheet.contentView else { return }
        let root = content.superview ?? content
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        context.saveGState()
        context.translateBy(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        context.addPath(CGPath(roundedRect: root.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.clip()
        sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
            fillBackdrops(of: sheet, root: root, in: context)
            root.layer?.render(in: context)
            if let accessory = (sheet as? NSSavePanel)?.accessoryView,
               let rep = accessory.bitmapImageRepForCachingDisplay(in: accessory.bounds) {
                report("the save panel is drawn out of process; picturing only its accessory view")
                accessory.cacheDisplay(in: accessory.bounds, to: rep)
                if let image = rep.cgImage {
                    let size = accessory.bounds.size
                    context.draw(image, in: CGRect(x: (root.bounds.width - size.width) / 2, y: 52,
                                                   width: size.width, height: size.height))
                }
            }
        }
        context.restoreGState()
    }

    /// Paints what a bitmap render leaves empty: the window background, and
    /// a solid stand-in for each translucent material (sidebar, titlebar),
    /// whose blur of the desktop behind only exists on screen.
    private static func fillBackdrops(of window: NSWindow, root: NSView, in context: CGContext) {
        context.setFillColor(window.backgroundColor.cgColor)
        context.fill(root.bounds)
        forEachVisibleView(in: root) { view in
            guard let effect = view as? NSVisualEffectView else { return }
            let color: NSColor = effect.material == .sidebar ? .underPageBackgroundColor : .windowBackgroundColor
            context.setFillColor(color.cgColor)
            context.fill(effect.convert(effect.bounds, to: nil))
        }
    }

    /// Draws each `SnapshotProviding` view's own image over its frame, then
    /// draws again whatever lies in front of it (its subviews and later
    /// overlapping siblings, such as overlays on the canvas), so the result
    /// stacks the way the screen does.
    private static func compositeProviders(in root: NSView, context: CGContext) {
        // Visible rectangles of the provider images drawn so far, in window
        // coordinates.
        var covered: [CGRect] = []

        /// `since` indexes the first entry of `covered` drawn after this
        /// view's pixels were last rendered; only those can hide it.
        func visit(_ view: NSView, since: Int) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            let frame = view.convert(view.bounds, to: nil)
            var childrenSince = since
            if let provider = view as? SnapshotProviding, let image = provider.snapshotImage() {
                let visible = view.convert(view.visibleRect, to: nil)
                context.saveGState()
                context.clip(to: visible)
                context.draw(image, in: frame)
                context.restoreGState()
                covered.append(visible)
            } else if covered[since...].contains(where: { $0.intersects(frame) }),
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                // One view on its own goes through `cacheDisplay`, which
                // returns it upright. Rendering its layer alone would lose
                // the flip AppKit puts on an ancestor layer and draw it
                // upside down. Subviews come along, so children need
                // drawing again only for providers drawn after this.
                view.cacheDisplay(in: view.bounds, to: rep)
                if let image = rep.cgImage {
                    context.saveGState()
                    context.clip(to: view.convert(view.visibleRect, to: nil))
                    context.draw(image, in: frame)
                    context.restoreGState()
                }
                childrenSince = covered.count
            }
            for subview in view.subviews { visit(subview, since: childrenSince) }
        }
        visit(root, since: 0)
    }

    /// Visits `root` and its descendants in drawing order, skipping hidden
    /// subtrees. Rectangles converted `to: nil` are in window coordinates,
    /// which match the bitmap: origin bottom left, in points.
    private static func forEachVisibleView(in root: NSView, _ body: (NSView) -> Void) {
        guard !root.isHidden, root.alphaValue > 0 else { return }
        body(root)
        for subview in root.subviews { forEachVisibleView(in: subview, body) }
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
