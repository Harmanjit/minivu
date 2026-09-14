import Testing
import CoreGraphics
@testable import MinivuRender

@Suite struct CanvasInteractionTests {
    typealias CI = CanvasInteraction

    // MARK: - Zoom ladder

    /// Ladder stops are percent / 100, which isn't exact in binary.
    func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    @Test func ladderStepsUpAndDown() {
        #expect(approx(CI.nextZoom(above: 1), 1.5))
        #expect(approx(CI.nextZoom(below: 1), 0.667))
        #expect(approx(CI.nextZoom(above: 0.4), 0.5))     // between stops: the next one up
        #expect(approx(CI.nextZoom(below: 0.4), 0.333))
        #expect(approx(CI.nextZoom(above: 0.998), 1.5))   // "on" 100% already
        #expect(approx(CI.nextZoom(below: 1.003), 0.667))
    }

    @Test func ladderStopsAtItsEnds() {
        #expect(approx(CI.nextZoom(above: 32), 32))
        #expect(approx(CI.nextZoom(above: 40), 40))       // never zooms out
        #expect(approx(CI.nextZoom(below: 0.05), 0.05))
        #expect(approx(CI.nextZoom(below: 0.03), 0.03))   // never zooms in
        #expect(approx(CI.nextZoom(below: 0.2), 0.1))
    }

    @Test func ladderIsAscending() {
        #expect(CI.zoomLadder == CI.zoomLadder.sorted())
        #expect(approx(CI.zoomLadder.first!, 0.05) && approx(CI.zoomLadder.last!, 32))
    }

    // MARK: - Press classification

    @Test func quickStillPressIsAClick() {
        var p = CI.PressClassifier(location: CGPoint(x: 10, y: 10), time: 100)
        #expect(p.moved(to: CGPoint(x: 12, y: 12), time: 100.1) == .pending)   // under 4 points
        #expect(p.released(at: CGPoint(x: 12, y: 12), time: 100.2) == .click)
    }

    @Test func stillPressHeldBecomesAHold() {
        var p = CI.PressClassifier(location: .zero, time: 0)
        #expect(p.update(time: 0.2) == .pending)
        #expect(p.update(time: 0.25) == .hold)
        // Moving after the magnifier appears keeps it a hold.
        #expect(p.moved(to: CGPoint(x: 100, y: 0), time: 0.5) == .hold)
        #expect(p.released(at: CGPoint(x: 100, y: 0), time: 1) == .hold)
    }

    @Test func lateReleaseWithoutTimerIsStillAHold() {
        var p = CI.PressClassifier(location: .zero, time: 0)
        #expect(p.released(at: .zero, time: 0.3) == .hold)
    }

    @Test func movingIsADrag() {
        var p = CI.PressClassifier(location: .zero, time: 0)
        #expect(p.moved(to: CGPoint(x: 3, y: 3), time: 0.05) == .drag)   // 4.24 points
        #expect(p.update(time: 1) == .drag)                            // stays a drag
        #expect(p.released(at: .zero, time: 1) == .drag)
    }

    @Test func withoutAHoldALongPressStillDrags() {
        // Magnifier off: holding still first must not block the pan after it.
        var p = CI.PressClassifier(location: .zero, time: 0, allowsHold: false)
        #expect(p.update(time: 1) == .pending)
        #expect(p.moved(to: CGPoint(x: 10, y: 0), time: 1.1) == .drag)

        // Released late without moving: not a click, which would toggle zoom.
        var late = CI.PressClassifier(location: .zero, time: 0, allowsHold: false)
        #expect(late.released(at: .zero, time: 0.5) == .hold)
        var quick = CI.PressClassifier(location: .zero, time: 0, allowsHold: false)
        #expect(quick.released(at: .zero, time: 0.1) == .click)
    }

    // MARK: - Wheel

    func wheel(_ mode: CI.WheelMode = .navigate, command: Bool = false, dy: CGFloat, dx: CGFloat = 0,
               precise: Bool = false, inverted: Bool = false, phase: CI.ScrollPhase = .none,
               momentum: CI.ScrollPhase = .none, exceeds: Bool = false) -> CI.WheelEvent {
        CI.WheelEvent(mode: mode, commandKey: command, precise: precise, delta: CGSize(width: dx, height: dy),
                      invertedFromDevice: inverted, phase: phase, momentumPhase: momentum, imageExceedsView: exceeds)
    }

    @Test func mouseWheelNavigatesOnePerNotch() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(dy: -1)) == .navigate(1))    // towards you: next
        #expect(w.interpret(wheel(dy: -7)) == .navigate(1))    // a fast spin is still one notch
        #expect(w.interpret(wheel(dy: 1)) == .navigate(-1))
        #expect(w.interpret(wheel(dy: 0, dx: 3)) == .none)
        // Natural scrolling flips the reported delta; the physical wheel decides.
        #expect(w.interpret(wheel(dy: 1, inverted: true)) == .navigate(1))
    }

    @Test func mouseWheelZoomsInZoomModeAndCommandSwaps() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(.zoom, dy: 1)) == .zoom(1.25))
        #expect(w.interpret(wheel(.zoom, dy: -1)) == .zoom(0.8))
        #expect(w.interpret(wheel(.zoom, command: true, dy: -1)) == .navigate(1))
        #expect(w.interpret(wheel(.navigate, command: true, dy: 1)) == .zoom(1.25))
        // Zoom mode zooms even when zoomed in; the mouse wheel never pans.
        #expect(w.interpret(wheel(.zoom, dy: 1, exceeds: true)) == .zoom(1.25))
    }

    @Test func trackpadPansWhenZoomedIn() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(dy: -12, dx: 5, precise: true, phase: .changed, exceeds: true))
                == .pan(CGSize(width: 5, height: -12)))
        // Momentum keeps panning, like any scroll view.
        #expect(w.interpret(wheel(dy: -3, precise: true, momentum: .changed, exceeds: true))
                == .pan(CGSize(width: 0, height: -3)))
    }

    @Test func trackpadSwipeAtFitNavigatesOncePerGesture() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(dy: -20, precise: true, phase: .began)) == .none)
        #expect(w.interpret(wheel(dy: -20, precise: true, phase: .changed)) == .none)
        #expect(w.interpret(wheel(dy: -20, precise: true, phase: .changed)) == .navigate(1))   // past 50
        #expect(w.interpret(wheel(dy: -80, precise: true, phase: .changed)) == .none)          // rest ignored
        #expect(w.interpret(wheel(dy: 0, precise: true, phase: .ended)) == .none)
        #expect(w.interpret(wheel(dy: -90, precise: true, momentum: .changed)) == .none)
        // The next swipe works again, the other way.
        #expect(w.interpret(wheel(dy: 30, precise: true, phase: .began)) == .none)
        #expect(w.interpret(wheel(dy: 30, precise: true, phase: .changed)) == .navigate(-1))
    }

    @Test func trackpadInZoomModeZoomsAtAnyZoomAndCommandPansOrNavigates() {
        var w = CI.WheelInterpreter()
        // Zoomed in, zoom preference: scrolling still zooms (and can zoom out).
        #expect(w.interpret(wheel(.zoom, dy: -100, precise: true, phase: .changed, exceeds: true)) == .zoom(0.5))
        // Command swaps in the navigate behaviour: pan when zoomed in...
        #expect(w.interpret(wheel(.zoom, command: true, dy: -60, precise: true, phase: .changed, exceeds: true))
                == .pan(CGSize(width: 0, height: -60)))
        // ...and one step per swipe at fit.
        #expect(w.interpret(wheel(.zoom, command: true, dy: -60, precise: true, phase: .began)) == .navigate(1))
    }

    @Test func momentumAloneNeverNavigates() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(dy: -10, precise: true, phase: .began)) == .none)
        #expect(w.interpret(wheel(dy: 0, precise: true, phase: .ended)) == .none)
        #expect(w.interpret(wheel(dy: -200, precise: true, momentum: .began)) == .none)
    }

    @Test func phaselessPreciseDevicesStepEveryFiftyPoints() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(dy: -30, precise: true)) == .none)
        #expect(w.interpret(wheel(dy: -30, precise: true)) == .navigate(1))
        #expect(w.interpret(wheel(dy: -30, precise: true)) == .none)
        #expect(w.interpret(wheel(dy: -30, precise: true)) == .navigate(1))
    }

    @Test func trackpadWithCommandZoomsSmoothly() {
        var w = CI.WheelInterpreter()
        #expect(w.interpret(wheel(command: true, dy: 100, precise: true, phase: .changed)) == .zoom(2))
        #expect(w.interpret(wheel(command: true, dy: -50, precise: true, phase: .changed))
                == .zoom(pow(2, -0.5)))
        // Even when zoomed in, Command zooms rather than pans.
        #expect(w.interpret(wheel(command: true, dy: 100, precise: true, phase: .changed, exceeds: true)) == .zoom(2))
        // Per-event factor is limited, and momentum doesn't zoom.
        #expect(w.interpret(wheel(command: true, dy: 1000, precise: true, phase: .changed)) == .zoom(2))
        #expect(w.interpret(wheel(command: true, dy: 40, precise: true, momentum: .changed)) == .none)
    }

    // MARK: - Magnifier and resolution

    @Test func magnifierZoomIsAtLeastTwiceCurrent() {
        #expect(CI.magnifierZoom(preference: 2, currentZoom: 0.25) == 2)
        #expect(CI.magnifierZoom(preference: 2, currentZoom: 3) == 6)
        #expect(CI.magnifierZoom(preference: 4, currentZoom: 20) == 32)   // clamped
    }

    @Test func magnifierPreferenceStepsWithinRange() {
        #expect(CI.steppedMagnifierZoom(2, in: true) == 2.5)
        #expect(CI.steppedMagnifierZoom(2, in: false) == 1.6)
        #expect(CI.steppedMagnifierZoom(1.6, in: false) == 1.5)
        #expect(CI.steppedMagnifierZoom(15, in: true) == 16)
    }

    @Test func needsHigherResolutionWhenTexelsAreMagnified() {
        // A 6000 px photo with a 3000 px screen texture.
        func needs(_ zoom: CGFloat, full: Bool = false, texture: CGFloat = 3000) -> Bool {
            CI.needsHigherResolution(isFullResolution: full, currentZoom: zoom, imageLongEdge: 6000,
                                     textureLongEdge: texture)
        }
        #expect(!needs(0.5))          // fit: one texel per pixel
        #expect(!needs(0.525))        // within 5%
        #expect(needs(0.53))
        #expect(!needs(4, full: true))
        #expect(!needs(4, texture: 16384))   // Metal's limit: nothing better exists
    }

    @Test func imageExceedsViewOnEitherAxis() {
        let image = CGSize(width: 6000, height: 4000)
        let view = CGSize(width: 3000, height: 2400)
        let fit = ViewportTransform.bestFit(imageSize: image, viewSize: view)
        #expect(!CI.imageExceedsView(fit, imageSize: image, viewSize: view))
        #expect(CI.imageExceedsView(ViewportTransform(zoom: 0.55, center: .zero), imageSize: image, viewSize: view))
        #expect(CI.imageExceedsView(ViewportTransform(zoom: 1, center: .zero), imageSize: image, viewSize: view))
    }
}
