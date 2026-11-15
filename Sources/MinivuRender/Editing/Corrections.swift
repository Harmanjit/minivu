import Foundation
import CoreGraphics
import CoreImage
import MinivuCore

// The G11 corrections (DESIGN.md 4.7): auto enhance, noise reduction and
// the vignette, plus the graph code of perspective correction and canvas
// size, whose payloads live in Perspective.swift and CanvasSize.swift.
// Like every operation they render the same on a proxy as in the saved
// file: lengths scale with the working image, positions are normalised.

// MARK: - Auto enhance

/// Core Image's automatic adjustments for one photo, as plain values.
///
/// `CIImage.autoAdjustmentFilters` looks at a picture and suggests a few
/// filters with settings (a tone curve, vibrance, highlight and shadow
/// recovery, a face-based colour balance). Asking again on every render
/// would cost an analysis per slider frame and could suggest something
/// different for the proxy than for the full image, or after the file is
/// reopened, so the suggestion is measured once, when the user chooses
/// Auto Enhance, and stored here: every render, preview or saved file,
/// applies exactly the same filters.
public struct AutoEnhance: Codable, Hashable, Sendable {
    /// One suggested filter: its Core Image name and its numeric inputs.
    public struct Filter: Codable, Hashable, Sendable {
        public var name: String
        /// Scalar inputs (booleans arrive as 0 or 1).
        public var numbers: [String: Double]
        /// Vector inputs, such as a tone curve's points.
        public var vectors: [String: [Double]]

        public init(name: String, numbers: [String: Double] = [:], vectors: [String: [Double]] = [:]) {
            self.name = name
            self.numbers = numbers
            self.vectors = vectors
        }

        private enum CodingKeys: String, CodingKey { case name, numbers, vectors }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            numbers = try c.effectsValue(.numbers, default: [:])
            vectors = try c.effectsValue(.vectors, default: [:])
        }
    }

    /// The filters Core Image may suggest that render here. A document is
    /// data, so only these names are ever instantiated; red-eye correction,
    /// which the analysis can also suggest, is the red-eye tool's job and is
    /// never asked for. A filter a later macOS adds is left out until it is
    /// checked to keep HDR.
    public static let knownFilters: Set<String> = [
        "CIFaceBalance", "CIVibrance", "CIToneCurve", "CIHighlightShadowAdjust", "CITemperatureAndTint",
    ]

    /// Inputs that are lengths in pixels of the analysed image, which the
    /// graph scales like any other length.
    static let lengthInputs: Set<String> = ["inputRadius"]

    public var filters: [Filter]

    public init(filters: [Filter] = []) {
        self.filters = filters
    }

    private enum CodingKeys: String, CodingKey { case filters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filters = try c.effectsValue(.filters, default: [])
    }

    /// The filters that will render, in order.
    var renderedFilters: [Filter] { filters.filter { Self.knownFilters.contains($0.name) } }

    /// Nothing suggested (the photo needed nothing), or nothing this Mac
    /// renders.
    public var isIdentity: Bool { renderedFilters.isEmpty }

    /// Measures `image` and returns what Core Image suggests for it. The
    /// image should be the edit as it stands (any earlier operations
    /// applied), small: the analysis downsamples anyway, and measured the
    /// same on 1024 px as on full resolution. `analysedScale` is that
    /// image's size over the full-resolution size, so a length the
    /// analysis suggests (a highlight radius) is stored in full-resolution
    /// pixels, as every operation's lengths are. Synchronous and some tens
    /// of milliseconds: call it off the main thread.
    public static func analyse(_ image: CIImage, analysedScale: Double = 1) -> AutoEnhance {
        let suggested = image.autoAdjustmentFilters(options: [.redEye: false, .enhance: true])
        return AutoEnhance(filters: suggested.compactMap { store($0, analysedScale: analysedScale) })
    }

    /// One suggested filter as values, or nil for one that doesn't render
    /// here. Lengths are divided by `analysedScale`.
    static func store(_ filter: CIFilter, analysedScale: Double) -> Filter? {
        guard knownFilters.contains(filter.name) else { return nil }
        let factor = analysedScale > 0 && analysedScale.isFinite ? 1 / analysedScale : 1
        var stored = Filter(name: filter.name)
        for key in filter.inputKeys where key != kCIInputImageKey {
            switch filter.value(forKey: key) {
            case let number as NSNumber:
                let value = number.doubleValue
                guard value.isFinite else { continue }
                stored.numbers[key] = lengthInputs.contains(key) ? value * factor : value
            case let vector as CIVector:
                let values = (0..<vector.count).map { Double(vector.value(at: $0)) }
                guard values.allSatisfy(\.isFinite) else { continue }
                stored.vectors[key] = values
            default:
                continue
            }
        }
        return stored
    }
}

// MARK: - Graph

/// Renders auto enhance, noise reduction, the vignette, perspective
/// correction and canvas size (see `EditGraph`).
enum CorrectionsGraph {
    /// The stored filters in order. Each was checked to pass HDR highlights
    /// through: the tone curve the analysis suggests asks to extrapolate
    /// beyond its last point, so values above 1 keep rising rather than
    /// flattening, and vibrance, the highlight and shadow recovery and the
    /// colour balances leave them above 1 too.
    static func autoEnhance(_ image: CIImage, _ enhance: AutoEnhance, scale: Double) -> CIImage {
        var result = image
        for stored in enhance.renderedFilters {
            guard let filter = CIFilter(name: stored.name) else { continue }
            filter.setValue(result, forKey: kCIInputImageKey)
            let keys = Set(filter.inputKeys)
            for (key, value) in stored.numbers where keys.contains(key) && value.isFinite {
                let v = AutoEnhance.lengthInputs.contains(key) ? value * scale : value
                filter.setValue(NSNumber(value: v), forKey: key)
            }
            for (key, values) in stored.vectors where keys.contains(key) && !values.isEmpty
                && values.allSatisfy(\.isFinite) {
                let components = values.map { CGFloat($0) }
                filter.setValue(CIVector(values: components, count: components.count), forKey: key)
            }
            if let output = filter.outputImage { result = output }
        }
        // None of them moves pixels, but a highlight radius reads past the
        // edge: keep the extent what it was.
        return result.cropped(to: image.extent)
    }

    /// The range sigma at `level` 1, in encoded units: differences between
    /// neighbours up to about this size count as noise. A tenth of the way
    /// from black to white already flattens fine texture, as
    /// `CINoiseReduction`'s own scale does at its top.
    static let maximumRangeSigma = 0.1
    /// The spatial sigma in full-resolution pixels at `level` 0 and 1: from
    /// one pixel's neighbours to about three pixels, the grain of a noisy
    /// high-ISO photo.
    static let spatialSigmaRange = 1.0...3.0
    /// The most taps either side: a 13 x 13 window, two sigmas, reached at
    /// full resolution and level 1. Each tap is a texture read, so this
    /// bounds the cost of a full-resolution render.
    static let maximumTaps = 6

    /// Edge-preserving noise reduction: a bilateral filter (see
    /// `effectsDenoise`) whose strength is the range of differences it
    /// treats as noise, and an edge-only sharpening on top.
    ///
    /// Not `CINoiseReduction`: on macOS 27 it clips every value to 1 in the
    /// edit renderer (measured: an HDR photo's 4.0 came out 1.0 in preview
    /// and full resolution alike, edges repeated or not), like the
    /// resampling filters "Core Image on macOS 27" in DESIGN.md describes.
    /// A weighted average of neighbours keeps HDR values as they are.
    ///
    /// **Scale.** The window is in full-resolution pixels and scales with
    /// the working image, as a blur radius does; the range of differences
    /// that count as noise is a property of the values, not of the pixel
    /// grid, and stays. A proxy has already averaged most of its noise away
    /// in the downsample, so at screen size the filter does little, which is
    /// what the full-resolution result looks like at that size too.
    static func reduceNoise(_ image: CIImage, level: Double, sharpness: Double, scale: Double) -> CIImage {
        let l = EffectsMath.clamp(level, 0...1)
        let s = EffectsMath.clamp(sharpness, 0...2)
        guard l > 0 || s > 0, let kernel = EffectsKernels.kernel("effectsDenoise") else { return image }
        let sigma = (spatialSigmaRange.lowerBound + (spatialSigmaRange.upperBound - spatialSigmaRange.lowerBound) * l)
            * scale
        let taps = min(maximumTaps, max(1, Int((2 * sigma).rounded(.up))))
        let params = CIVector(x: max(sigma, 0.3), y: max(l * maximumRangeSigma, 0.002), z: CGFloat(taps), w: s)
        // The kernel holds its samples to the image, which repeats the edges
        // outward so the border's windows don't take in Core Image's clear
        // surround. Not `clampedToExtent`: on macOS 27 that node, read by a
        // sampling kernel in this context, is materialised in 8 bits and
        // clips HDR to 1 (measured here as for the resampling filters). A
        // general kernel, applied over an infinite extent and cropped (see
        // `EffectsKernels`).
        let extent = image.extent
        return kernel.apply(extent: .infinite, roiCallback: { _, rect in
            rect.insetBy(dx: -CGFloat(taps) - 1, dy: -CGFloat(taps) - 1).intersection(extent)
        }, arguments: [image, params, CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY)])?
            .cropped(to: extent) ?? image
    }

    /// A gain that eases from none inside `radius` to `amount` × 2 stops at
    /// the corners (darker for a positive amount), on an ellipse that fits
    /// the image's own proportions. Everything is a fraction of the working
    /// image, so it scales by itself. Core Image's vignette filters clip to
    /// 1 in this context (measured: an HDR 3.0 came out 1.0), so this is a
    /// kernel of our own, a gain in linear light that keeps highlights.
    static func vignette(_ image: CIImage, amount: Double, radius: Double, feather: Double) -> CIImage {
        let a = EffectsMath.clamp(amount, -1...1)
        guard a != 0, let kernel = EffectsKernels.kernel("effectsVignette") else { return image }
        let extent = image.extent
        let frame = CIVector(x: extent.midX, y: extent.midY, z: extent.width / 2, w: extent.height / 2)
        let shape = CIVector(x: EffectsMath.clamp(radius, 0...1), y: EffectsMath.clamp(feather, 0...1),
                             z: -2 * a, w: 0)
        // A general kernel over an infinite extent, then cropped, for the
        // reasons `EffectsKernels.frame` gives.
        return kernel.apply(extent: .infinite, roiCallback: { _, rect in rect }, arguments: [image, frame, shape])?
            .cropped(to: extent) ?? image
    }

    /// The quadrilateral pulled out to fill an `outputWidth` x
    /// `outputHeight` rectangle by a projective warp. Samples are bilinear,
    /// which suits a correction of a few degrees; the edges are repeated
    /// outward so the border's half pixels don't fade.
    static func perspective(_ image: CIImage, _ quad: PerspectiveQuad, outputWidth: Int, outputHeight: Int) -> CIImage {
        guard let warp = EffectsKernels.kernel("effectsPerspective") as? CIWarpKernel else { return image }
        let extent = image.extent
        // The corners in Core Image's coordinates (y up), working pixels.
        let corners = quad.sanitized.corners.map {
            CGPoint(x: $0.x * extent.width, y: (1 - $0.y) * extent.height)
        }
        // The unit square's (0,0) (1,0) (1,1) (0,1) are the output's bottom
        // left, bottom right, top right and top left.
        let m = PerspectiveQuad.squareToQuad(corners[3], corners[2], corners[1], corners[0])
        let output = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let reach = CGRect(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!,
                           width: corners.map(\.x).max()! - corners.map(\.x).min()!,
                           height: corners.map(\.y).max()! - corners.map(\.y).min()!).insetBy(dx: -2, dy: -2)
        return warp.apply(extent: output, roiCallback: { _, _ in reach }, image: image.clampedToExtent(), arguments: [
            CIVector(x: m[0], y: m[1], z: m[2]), CIVector(x: m[3], y: m[4], z: m[5]),
            CIVector(x: m[6], y: m[7], z: 1), CIVector(x: CGFloat(outputWidth), y: CGFloat(outputHeight)),
        ])?.cropped(to: output) ?? image
    }

    /// The image placed on a canvas of the new size at the anchor, over the
    /// fill. The offset is worked out in full-resolution pixels and scaled,
    /// so the proxy puts the image where the saved file will; a canvas
    /// smaller than the image crops it about the anchor.
    static func canvasSize(_ image: CIImage, _ canvas: CanvasSize, input: EditGraph.Size, scale: Double,
                           outputWidth: Int, outputHeight: Int) -> CIImage {
        let h = image.extent.height.rounded()
        let offset = canvas.photoOrigin(photoWidth: input.width, photoHeight: input.height)
        let x = (Double(offset.x) * scale).rounded()
        let top = (Double(offset.y) * scale).rounded()
        let placed = image.transformed(by: CGAffineTransform(translationX: x, y: CGFloat(outputHeight) - top - h))
        let output = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        return placed.composited(over: canvas.fill.image).cropped(to: output)
    }
}

extension EditRenderer {
    /// The long edge Auto Enhance and Auto perspective analyse at: plenty for
    /// a histogram, a face or a rectangle, and a few milliseconds to render.
    public nonisolated static let analysisPixelSize = 1024

    /// What Auto Enhance would apply to the committed edit as it stands
    /// (the preview left out): measured once on a small rendering, with any
    /// length it suggests converted to full-resolution pixels.
    public func autoEnhancement(for document: EditDocument) async throws -> AutoEnhance {
        let image = try await renderForAnalysis(document, maxPixelSize: Self.analysisPixelSize)
        let output = document.sourceSize.map { EditGraph.outputSize(source: $0, operations: document.operations) }
        let scale = output.map { $0.width > 0 ? Double(image.width) / Double($0.width) : 1 } ?? 1
        return await BlockingWork.run { AutoEnhance.analyse(CIImage(cgImage: image), analysedScale: scale) }
    }
}
