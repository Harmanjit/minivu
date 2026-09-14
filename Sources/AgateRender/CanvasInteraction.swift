import Foundation
import CoreGraphics

/// The decisions behind mouse, trackpad and zoom handling on the canvas,
/// kept free of AppKit so they can be unit tested.
///
/// The canvas view turns NSEvents into these plain values, asks what they
/// mean, and applies the answer. Everything that could be wrong about
/// "what should this gesture do" lives here.
public enum CanvasInteraction {
    // MARK: - Zoom ladder

    /// Stops for zoom in / zoom out, in percent. Roughly 1.5x apart, with the
    /// round numbers people expect (100, 200, 400...) always on the ladder.
    public static let zoomLadderPercents: [Double] = [
        5, 10, 25, 33.3, 50, 66.7, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200,
    ]

    /// The ladder as zoom factors (1 = 100%).
    public static let zoomLadder: [CGFloat] = zoomLadderPercents.map { CGFloat($0 / 100) }

    /// The next stop above `zoom`, or `zoom` itself at the top. A zoom within
    /// 0.5% of a stop counts as on it, so 99.8% steps to 150%, not to 100%.
    public static func nextZoom(above zoom: CGFloat) -> CGFloat {
        zoomLadder.first { $0 > zoom * 1.005 } ?? max(zoom, zoomLadder.last!)
    }

    /// The next stop below `zoom`, or `zoom` itself at the bottom.
    public static func nextZoom(below zoom: CGFloat) -> CGFloat {
        zoomLadder.last { $0 < zoom / 1.005 } ?? min(zoom, zoomLadder.first!)
    }

    // MARK: - Click, hold or drag

    /// What a mouse press has turned out to be so far.
    public enum Press: Equatable, Sendable {
        /// Too early to tell.
        case pending
        /// Released quickly without moving.
        case click
        /// Held still: show the magnifier.
        case hold
        /// Moved: pan.
        case drag
    }

    /// Classifies one mouse press from its events.
    ///
    /// A press is a click until proven otherwise; holding still for
    /// `holdDelay` makes it a hold, moving further than `dragDistance` makes
    /// it a drag. Once a press is a hold or a drag it stays one, so the
    /// magnifier doesn't turn into a pan when the hand trembles.
    public struct PressClassifier: Sendable {
        public static let holdDelay: TimeInterval = 0.25
        /// In points: small enough to feel immediate, large enough that a
        /// click on a trackpad doesn't register as a drag.
        public static let dragDistance: CGFloat = 4

        public let start: CGPoint
        public let startTime: TimeInterval
        public private(set) var state: Press = .pending

        public init(location: CGPoint, time: TimeInterval) {
            start = location
            startTime = time
        }

        /// The hold timer fired, or any other chance to check the clock.
        @discardableResult
        public mutating func update(time: TimeInterval) -> Press {
            if state == .pending, time - startTime >= Self.holdDelay { state = .hold }
            return state
        }

        /// The pointer moved while the button is down.
        @discardableResult
        public mutating func moved(to location: CGPoint, time: TimeInterval) -> Press {
            guard state == .pending else { return state }
            if hypot(location.x - start.x, location.y - start.y) > Self.dragDistance {
                state = .drag
            } else {
                update(time: time)
            }
            return state
        }

        /// The button went up: the final answer (never `.pending`).
        public mutating func released(at location: CGPoint, time: TimeInterval) -> Press {
            moved(to: location, time: time)
            if state == .pending { state = .click }
            return state
        }
    }

    // MARK: - Scroll wheel and trackpad scrolling

    /// Mirror of the app's wheel preference.
    public enum WheelMode: Sendable {
        case navigate, zoom
    }

    /// Mirror of NSEvent.Phase, reduced to what matters here.
    public enum ScrollPhase: Sendable {
        /// Not part of a gesture (a mouse wheel), or no momentum.
        case none
        case began
        case changed
        case ended
    }

    /// One scroll event, as plain values.
    public struct WheelEvent: Sendable {
        public var mode: WheelMode
        public var commandKey: Bool
        /// Trackpads and Magic Mouse report precise, pixel-level deltas; mouse
        /// wheels report lines per notch.
        public var precise: Bool
        /// Scrolling deltas as AppKit reports them (points when precise).
        public var delta: CGSize
        /// True when the system's natural scrolling flipped `delta`.
        public var invertedFromDevice: Bool
        public var phase: ScrollPhase
        public var momentumPhase: ScrollPhase
        /// The image is larger than the view on at least one axis.
        public var imageExceedsView: Bool

        public init(mode: WheelMode, commandKey: Bool = false, precise: Bool, delta: CGSize,
                    invertedFromDevice: Bool = false, phase: ScrollPhase = .none,
                    momentumPhase: ScrollPhase = .none, imageExceedsView: Bool = false) {
            self.mode = mode
            self.commandKey = commandKey
            self.precise = precise
            self.delta = delta
            self.invertedFromDevice = invertedFromDevice
            self.phase = phase
            self.momentumPhase = momentumPhase
            self.imageExceedsView = imageExceedsView
        }
    }

    public enum WheelOutcome: Equatable, Sendable {
        /// Show the image `offset` places away (+1 next, -1 previous).
        case navigate(Int)
        /// Multiply the zoom by this factor, about the pointer.
        case zoom(CGFloat)
        /// Move the content by this many points (content follows the fingers).
        case pan(CGSize)
        case none
    }

    /// Turns scroll events into navigation, zoom or pan.
    ///
    /// Stateful because a trackpad swipe is dozens of small events: they
    /// add up to one step to the next photo, and the rest of that swipe must
    /// not flip through the folder.
    public struct WheelInterpreter: Sendable {
        /// Vertical travel in points that turns a swipe into one image step.
        public static let navigationDistance: CGFloat = 50
        /// Zoom factor per mouse wheel notch.
        public static let wheelZoomStep: CGFloat = 1.25
        /// Zoom doubles for every this many points of trackpad travel.
        public static let pointsPerDoubling: CGFloat = 100

        private var accumulated: CGFloat = 0
        private var gestureUsed = false

        public init() {}

        public mutating func interpret(_ e: WheelEvent) -> WheelOutcome {
            // Command swaps what the wheel does.
            let wantsZoom = (e.mode == .zoom) != e.commandKey
            return e.precise ? precise(e, wantsZoom: wantsZoom) : notch(e, wantsZoom: wantsZoom)
        }

        /// A mouse wheel: one step per notch, whatever the notch's size (fast
        /// spins report bigger deltas, which would skip photos). Directions
        /// follow the physical wheel, so rolling towards you is always
        /// "next" and "zoom out", with or without natural scrolling.
        private func notch(_ e: WheelEvent, wantsZoom: Bool) -> WheelOutcome {
            let dy = e.invertedFromDevice ? -e.delta.height : e.delta.height
            guard dy != 0 else { return .none }
            if wantsZoom { return .zoom(dy > 0 ? Self.wheelZoomStep : 1 / Self.wheelZoomStep) }
            return .navigate(dy > 0 ? -1 : 1)
        }

        /// A trackpad. Deltas are used as reported, so the content follows
        /// the fingers the way the user has set scrolling up.
        private mutating func precise(_ e: WheelEvent, wantsZoom: Bool) -> WheelOutcome {
            if e.phase == .began {
                accumulated = 0
                gestureUsed = false
            }
            let momentum = e.momentumPhase != .none

            // Zoomed in: scrolling moves around the image, momentum included.
            if e.imageExceedsView && !e.commandKey {
                return e.delta == .zero ? .none : .pan(e.delta)
            }
            if wantsZoom {
                // Momentum would keep zooming after the fingers lift.
                guard !momentum, e.delta.height != 0 else { return .none }
                let factor = pow(2, e.delta.height / Self.pointsPerDoubling)
                return .zoom(min(max(factor, 0.5), 2))
            }

            // At fit: one photo per swipe.
            guard !momentum, !gestureUsed else { return .none }
            accumulated += e.delta.height
            guard abs(accumulated) >= Self.navigationDistance else { return .none }
            let step = accumulated > 0 ? -1 : 1
            accumulated = 0
            // Devices without phases never end a gesture, so they get one step
            // per 50 points instead of one per swipe.
            if e.phase != .none { gestureUsed = true }
            return .navigate(step)
        }
    }

    // MARK: - Magnifier

    /// The loupe's zoom: the preference, but always at least twice the
    /// current zoom so it magnifies even when already zoomed in, and never
    /// beyond the canvas's 32x limit.
    public static func magnifierZoom(preference: Double, currentZoom: CGFloat) -> CGFloat {
        min(max(CGFloat(preference), currentZoom * 2), ViewportTransform.maximumZoom)
    }

    public static let magnifierZoomRange: ClosedRange<Double> = 1.5...16
    public static let magnifierZoomStep = 1.25

    /// The magnifier preference after one scroll step up (in) or down (out).
    public static func steppedMagnifierZoom(_ zoom: Double, in zoomIn: Bool) -> Double {
        let next = zoomIn ? zoom * magnifierZoomStep : zoom / magnifierZoomStep
        return min(max(next, magnifierZoomRange.lowerBound), magnifierZoomRange.upperBound)
    }

    // MARK: - Geometry and resolution

    /// True when the image overflows the view on either axis, so dragging
    /// and scrolling can move it.
    public static func imageExceedsView(_ transform: ViewportTransform, imageSize: CGSize, viewSize: CGSize) -> Bool {
        let tolerance: CGFloat = 0.5   // rounding in fit zoom must not make fit pannable
        return imageSize.width * transform.zoom > viewSize.width + tolerance
            || imageSize.height * transform.zoom > viewSize.height + tolerance
    }

    /// True when texture texels are being magnified by more than 5%, so a
    /// sharper texture would show more detail.
    ///
    /// A texture already at Metal's size limit can't get any better, so it
    /// never asks.
    public static func needsHigherResolution(isFullResolution: Bool, currentZoom: CGFloat,
                                             imageLongEdge: CGFloat, textureLongEdge: CGFloat,
                                             maximumTextureDimension: Int = TextureUploader.maximumDimension) -> Bool {
        guard !isFullResolution, textureLongEdge > 0,
              textureLongEdge < CGFloat(maximumTextureDimension) else { return false }
        return currentZoom * (imageLongEdge / textureLongEdge) > 1.05
    }
}
