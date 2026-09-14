import Testing
import CoreGraphics
@testable import AgateRender

@Suite struct ViewportTransformTests {
    let image = CGSize(width: 6000, height: 4000)
    let view = CGSize(width: 3000, height: 2000)

    @Test func bestFitShowsWholeImageCentred() {
        let t = ViewportTransform.bestFit(imageSize: image, viewSize: view)
        #expect(t.zoom == 0.5)
        #expect(t.screenRect(imageSize: image, viewSize: view) == CGRect(x: 0, y: 0, width: 3000, height: 2000))
    }

    @Test func smallImagesAreNotEnlargedByDefault() {
        let small = CGSize(width: 800, height: 600)
        #expect(ViewportTransform.bestFit(imageSize: small, viewSize: view).zoom == 1)
        #expect(ViewportTransform.bestFit(imageSize: small, viewSize: view, enlargeSmall: true).zoom == 2000.0 / 600.0)
    }

    @Test func zoomKeepsAnchorFixed() {
        let t = ViewportTransform.bestFit(imageSize: image, viewSize: view)
        let anchor = CGPoint(x: 700, y: 300)
        let before = t.imagePoint(forScreenPoint: anchor, viewSize: view)
        let z = t.zoomed(by: 3, about: anchor, viewSize: view)
        let after = z.imagePoint(forScreenPoint: anchor, viewSize: view)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func actualSizeIsOneToOne() {
        let t = ViewportTransform.bestFit(imageSize: image, viewSize: view).actualSize(about: CGPoint(x: 10, y: 10), viewSize: view)
        #expect(abs(t.zoom - 1) < 1e-12)
    }

    @Test func uvMapMatchesPointMapping() {
        let t = ViewportTransform(zoom: 1.7, center: CGPoint(x: 1234, y: 987))
        let m = t.screenToUV(imageSize: image, viewSize: view)
        let p = CGPoint(x: 400, y: 1500)
        let ip = t.imagePoint(forScreenPoint: p, viewSize: view)
        let u = m.columns.0.x * Float(p.x) + m.columns.1.x * Float(p.y) + m.columns.2.x
        let v = m.columns.0.y * Float(p.x) + m.columns.1.y * Float(p.y) + m.columns.2.y
        #expect(abs(Double(u) - ip.x / image.width) < 1e-5)
        #expect(abs(Double(v) - ip.y / image.height) < 1e-5)
    }

    @Test func clampKeepsImageOnScreen() {
        let t = ViewportTransform(zoom: 1, center: CGPoint(x: -5000, y: 99999)).clamped(imageSize: image, viewSize: view)
        #expect(t.center == CGPoint(x: 1500, y: 3000))
    }
}
