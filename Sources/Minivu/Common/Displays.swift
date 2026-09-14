import AppKit

/// One connected display, as the viewer, slideshow and thumbnails need to
/// know it (DESIGN.md 5, dual display).
///
/// A plain value rather than `NSScreen`, which can't be made in a test: the
/// window code reads displays only through `Displays.provider`, so tests can
/// connect, disconnect and notch displays that don't exist.
nonisolated struct DisplayInfo: Equatable {
    /// `CGDirectDisplayID`: stays the same while the display is connected,
    /// through resolution and arrangement changes, which the frame doesn't.
    var id: UInt32
    /// In global screen coordinates, origin bottom left.
    var frame: CGRect
    /// The frame less the menu bar and Dock.
    var visibleFrame: CGRect
    /// Height of the camera housing strip on a notched display; zero
    /// elsewhere. Macs only ever have a top inset.
    var safeAreaTop: CGFloat = 0
    var backingScale: CGFloat = 2
    /// How far above SDR white the display can show right now (EDR).
    var headroom: CGFloat = 1
    /// How far it could reach once content asks for EDR.
    var potentialHeadroom: CGFloat = 1
    var colorSpace: CGColorSpace?

    init(id: UInt32, frame: CGRect, visibleFrame: CGRect? = nil, safeAreaTop: CGFloat = 0, backingScale: CGFloat = 2,
         headroom: CGFloat = 1, potentialHeadroom: CGFloat = 1, colorSpace: CGColorSpace? = nil) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.safeAreaTop = safeAreaTop
        self.backingScale = backingScale
        self.headroom = headroom
        self.potentialHeadroom = potentialHeadroom
        self.colorSpace = colorSpace
    }

    /// Long edge in pixels: the size a full-screen image decodes for.
    var pixelLongEdge: Int {
        Int((max(frame.width, frame.height) * backingScale).rounded())
    }
}

extension DisplayInfo {
    @MainActor init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        // The strip left of the notch is the fallback should a display
        // report the housing's area but no inset.
        var top = screen.safeAreaInsets.top
        if top == 0, let left = screen.auxiliaryTopLeftArea { top = left.height }
        #if DEBUG
        if top == 0, let debugTop = Displays.debugSafeAreaTop { top = debugTop }
        #endif
        self.init(id: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeAreaTop: top, backingScale: screen.backingScaleFactor,
                  headroom: screen.maximumExtendedDynamicRangeColorComponentValue,
                  potentialHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                  colorSpace: screen.colorSpace?.cgColorSpace)
    }
}

/// Where displays come from. The app uses `SystemScreens`; tests put in a
/// fake and post `NSApplication.didChangeScreenParametersNotification` (or a
/// window's `didChangeScreenNotification`) as the system would.
protocol ScreenProviding: AnyObject {
    /// Every connected display, the menu bar's first.
    var displays: [DisplayInfo] { get }
    /// The display with the key window (`NSScreen.main`).
    var mainDisplay: DisplayInfo? { get }
    /// The display `window` is on, or nil if it is on none.
    func display(of window: NSWindow) -> DisplayInfo?
    /// The EDR headroom of the display `window` is on, now and at most. Read
    /// for every frame drawn, so it mustn't build a whole `DisplayInfo`:
    /// reading a screen's frames and safe area takes some 50 µs,
    /// its headroom almost nothing.
    func headroom(of window: NSWindow) -> (current: CGFloat, potential: CGFloat)?
}

extension ScreenProviding {
    func headroom(of window: NSWindow) -> (current: CGFloat, potential: CGFloat)? {
        display(of: window).map { ($0.headroom, $0.potentialHeadroom) }
    }
}

final class SystemScreens: ScreenProviding {
    var displays: [DisplayInfo] { NSScreen.screens.map(DisplayInfo.init(screen:)) }
    var mainDisplay: DisplayInfo? { (NSScreen.main ?? NSScreen.screens.first).map(DisplayInfo.init(screen:)) }
    func display(of window: NSWindow) -> DisplayInfo? { window.screen.map(DisplayInfo.init(screen:)) }

    func headroom(of window: NSWindow) -> (current: CGFloat, potential: CGFloat)? {
        guard let screen = window.screen else { return nil }
        return (screen.maximumExtendedDynamicRangeColorComponentValue,
                screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }
}

/// Which display the full-screen viewer and slideshows open on: FastStone's
/// dual-monitor mode browses on one display and views on another.
nonisolated enum FullScreenDisplayChoice: String, CaseIterable, Identifiable {
    /// The display the browser (or the viewer's window) is on.
    case browserDisplay
    /// Another display than the browser's, when there is one.
    case anotherDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browserDisplay: "The display with the browser"
        case .anotherDisplay: "Another display"
        }
    }
}

/// The app's displays, and the decisions about which one a window goes to.
enum Displays {
    /// Tests replace it with a fake and put it back.
    static var provider: ScreenProviding = SystemScreens()
    /// Settings > Viewer, "Full-screen viewer opens on"; tests replace it.
    static var choice: () -> FullScreenDisplayChoice = { Preferences.shared.fullScreenDisplay }
    /// The browser window, whose display "another display" avoids and whose
    /// colour space thumbnails are drawn in; tests replace it.
    static var browserWindow: () -> NSWindow? = {
        NSApp.windows.first { $0.isVisible && $0.windowController is BrowserWindowController }
    }

    #if DEBUG
    /// Snapshots only: MINIVU_DEBUG_SAFE_AREA_TOP=38 gives displays without a
    /// camera housing one of that height, to picture the notch layout.
    static let debugSafeAreaTop: CGFloat? = ProcessInfo.processInfo.environment["MINIVU_DEBUG_SAFE_AREA_TOP"]
        .flatMap(Double.init).flatMap { $0 > 0 ? CGFloat($0) : nil }
    #endif

    /// The display a command starts from: the key window's, else the one
    /// under the pointer, else the main display.
    static func originDisplay() -> DisplayInfo? {
        let provider = provider
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, let display = provider.display(of: window) {
            return display
        }
        let mouse = NSEvent.mouseLocation
        return provider.displays.first { NSMouseInRect(mouse, $0.frame, false) } ?? provider.mainDisplay
    }

    /// Where a full-screen viewer or slideshow started from `current` (the
    /// display of the window it came from; nil for none) goes, by Settings.
    static func fullScreenDisplay(current: DisplayInfo?) -> DisplayInfo? {
        let provider = provider
        let displays = provider.displays
        let browser = browserWindow().flatMap(provider.display(of:))
        return DisplayPlacement.fullScreenDisplay(choice: choice(), browser: browser, current: current,
                                                  displays: displays) ?? provider.mainDisplay
    }
}

/// Display arithmetic on plain values, so it is tested without displays.
nonisolated enum DisplayPlacement {
    /// Left to right, and top to bottom where displays are stacked: the
    /// order Move to Next Display walks, which matches how they sit on the
    /// desk rather than the order the system lists them in.
    static func ordered(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.frame.maxY > $1.frame.maxY
        }
    }

    /// The display after `display` in `ordered` order, wrapping round; the
    /// first when `display` is nil or no longer connected. With one display
    /// that is the same display.
    static func next(after display: DisplayInfo?, in displays: [DisplayInfo]) -> DisplayInfo? {
        let ordered = ordered(displays)
        guard let display, let index = ordered.firstIndex(where: { $0.id == display.id }) else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }

    /// The connected display with this one's id, with its current values.
    static func connected(_ display: DisplayInfo?, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let display else { return nil }
        return displays.first { $0.id == display.id }
    }

    /// The display a window with `frame` is on: the one it overlaps most, as
    /// AppKit decides `NSWindow.screen`; nil when it overlaps none.
    static func display(for frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        return best?.display
    }

    /// Settings > Viewer's choice applied.
    ///
    /// - `browserDisplay`: where the command came from (`current`), which is
    ///   the browser's display when opened from it and the viewer's own when
    ///   a windowed viewer goes full screen.
    /// - `anotherDisplay`: a display other than the browser's. A viewer
    ///   already away from the browser stays where it is (so a slideshow
    ///   from a full-screen viewer plays over it); otherwise the next display
    ///   after the browser's. With one display, that display.
    ///
    /// Displays no longer connected count as unknown; nil when nothing is known.
    static func fullScreenDisplay(choice: FullScreenDisplayChoice, browser: DisplayInfo?, current: DisplayInfo?,
                                  displays: [DisplayInfo]) -> DisplayInfo? {
        let browser = connected(browser, in: displays)
        let current = connected(current, in: displays)
        switch choice {
        case .browserDisplay:
            return current ?? browser ?? ordered(displays).first
        case .anotherDisplay:
            guard let browser else { return current ?? ordered(displays).first }
            if let current, current.id != browser.id { return current }
            return next(after: browser, in: displays)
        }
    }

    /// A titled window moved to another display keeps its place relative to
    /// the usable area (a window at the top right stays at the top right),
    /// shrinking only if it wouldn't fit.
    static func movedFrame(_ frame: CGRect, from source: DisplayInfo?, to target: DisplayInfo) -> CGRect {
        let destination = target.visibleFrame
        let size = CGSize(width: min(frame.width, destination.width), height: min(frame.height, destination.height))
        let origin = source?.visibleFrame ?? destination
        func fraction(_ position: CGFloat, _ start: CGFloat, _ room: CGFloat) -> CGFloat {
            room > 0 ? min(max((position - start) / room, 0), 1) : 0.5
        }
        let fx = fraction(frame.minX, origin.minX, origin.width - frame.width)
        let fy = fraction(frame.minY, origin.minY, origin.height - frame.height)
        return CGRect(x: (destination.minX + fx * (destination.width - size.width)).rounded(),
                      y: (destination.minY + fy * (destination.height - size.height)).rounded(),
                      width: size.width, height: size.height)
    }

    /// The part of a full-screen window's `bounds` an image may use: all of
    /// it but the camera housing strip at the top of a notched display. The
    /// strip stays black, so the image never hides under the camera.
    static func pictureArea(in bounds: CGRect, safeAreaTop: CGFloat, flipped: Bool) -> CGRect {
        let inset = min(max(safeAreaTop, 0), bounds.height)
        var area = bounds
        area.size.height -= inset
        if flipped { area.origin.y += inset }
        return area
    }
}

extension AppDelegate {
    /// Debug only, for the snapshot harness: Settings opened at the Viewer
    /// pane, where the full-screen display is chosen
    /// (`MINIVU_SNAPSHOT_WINDOW=settings MINIVU_ACTIONS=debugShowViewerSettings:`).
    @objc func debugShowViewerSettings(_ sender: Any?) {
        showSettings(pane: .viewer)
    }
}
