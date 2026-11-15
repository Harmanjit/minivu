import Foundation
import CoreGraphics
import CoreImage
import MinivuCore

// The RAW tool (G10): settings for Apple's RAW engine, which act when the
// sensor data is developed rather than on the rendered picture. How the
// renderer brings a document's original into line with them is described
// on `EditRenderer` ("RAW settings").

/// Settings for Apple's RAW engine (`CIRAWFilter`), as the RAW tool sets
/// them. Each is nil when it is left to the camera and the engine: the
/// white balance as shot, the noise reduction the engine picks for the ISO.
///
/// The tool always stores every setting it shows, so a step reads the same
/// whatever came before it; the optionals are for settings this Mac's
/// engine can't make (noise reduction for some cameras, highlight recovery
/// before macOS 26) and for documents written by a later version.
public struct RawDevelop: Codable, Hashable, Sendable {
    /// In stops, added to the camera's own baseline.
    public var exposure: Double?
    /// The white balance: the colour temperature in kelvin that renders
    /// neutral, and the tint, green (negative) to magenta.
    public var temperature: Double?
    public var tint: Double?
    /// How much of the engine's tone curve is applied: 1 its full contrast,
    /// 0 a linear rendering, flat and dark.
    public var boost: Double?
    /// 0...1 each.
    public var luminanceNoiseReduction: Double?
    public var colorNoiseReduction: Double?
    /// The engine rebuilds clipped highlights from the channels that are
    /// not clipped (macOS 26 and later; on by default).
    public var recoversHighlights: Bool?

    public static let exposureRange: ClosedRange<Double> = -4...4
    /// The engine accepts 2000 K to 50000 K; past 20000 K nothing changes
    /// that a photo needs.
    public static let temperatureRange: ClosedRange<Double> = 2000...20000
    public static let tintRange: ClosedRange<Double> = -150...150

    public init(exposure: Double? = nil, temperature: Double? = nil, tint: Double? = nil, boost: Double? = nil,
                luminanceNoiseReduction: Double? = nil, colorNoiseReduction: Double? = nil,
                recoversHighlights: Bool? = nil) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.boost = boost
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.recoversHighlights = recoversHighlights
    }

    /// The settings in effect after `operations`: the last RAW step's, which
    /// replaces everything an earlier one set. Nil when there is none, and
    /// the original is decoded by the viewer's own rules.
    public static func inEffect(_ operations: [EditOperation]) -> RawDevelop? {
        for op in operations.reversed() {
            if case .rawDevelop(let develop) = op { return develop }
        }
        return nil
    }

    /// Every setting given, from `defaults` where this one leaves it to the
    /// camera; highlight recovery stays nil where the engine can't do it.
    public func filled(from defaults: RawDefaults) -> RawDevelop {
        RawDevelop(exposure: exposure ?? defaults.exposure,
                   temperature: temperature ?? defaults.temperature,
                   tint: tint ?? defaults.tint,
                   boost: boost ?? defaults.boost,
                   luminanceNoiseReduction: luminanceNoiseReduction ?? defaults.luminanceNoiseReduction,
                   colorNoiseReduction: colorNoiseReduction ?? defaults.colorNoiseReduction,
                   recoversHighlights: defaults.supportsHighlightRecovery
                       ? (recoversHighlights ?? defaults.recoversHighlights) : nil)
    }
}

/// What the engine would do with a file by itself, and which settings it
/// can change for that camera: the RAW tool's starting point and what a
/// slider's double-click returns to.
public struct RawDefaults: Hashable, Sendable {
    public var exposure: Double
    public var temperature: Double
    public var tint: Double
    public var boost: Double
    public var luminanceNoiseReduction: Double
    public var colorNoiseReduction: Double
    public var recoversHighlights: Bool
    public var supportsLuminanceNoiseReduction: Bool
    public var supportsColorNoiseReduction: Bool
    public var supportsHighlightRecovery: Bool

    public init(exposure: Double = 0, temperature: Double = 5500, tint: Double = 0, boost: Double = 1,
                luminanceNoiseReduction: Double = 0, colorNoiseReduction: Double = 0, recoversHighlights: Bool = true,
                supportsLuminanceNoiseReduction: Bool = true, supportsColorNoiseReduction: Bool = true,
                supportsHighlightRecovery: Bool = false) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.boost = boost
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.recoversHighlights = recoversHighlights
        self.supportsLuminanceNoiseReduction = supportsLuminanceNoiseReduction
        self.supportsColorNoiseReduction = supportsColorNoiseReduction
        self.supportsHighlightRecovery = supportsHighlightRecovery
    }

    /// The camera's settings in the engine as it opened the file.
    init(_ filter: CIRAWFilter) {
        exposure = Double(filter.exposure)
        temperature = Double(filter.neutralTemperature)
        tint = Double(filter.neutralTint)
        boost = Double(filter.boostAmount)
        luminanceNoiseReduction = Double(filter.luminanceNoiseReductionAmount)
        colorNoiseReduction = Double(filter.colorNoiseReductionAmount)
        supportsLuminanceNoiseReduction = filter.isLuminanceNoiseReductionSupported
        supportsColorNoiseReduction = filter.isColorNoiseReductionSupported
        if #available(macOS 26.0, *) {
            supportsHighlightRecovery = filter.isHighlightRecoverySupported
            recoversHighlights = filter.isHighlightRecoveryEnabled
        } else {
            supportsHighlightRecovery = false
            recoversHighlights = false
        }
    }
}

/// One RAW file opened in Apple's RAW engine, kept for as long as its
/// document is edited, so each RAW tool preview only develops the sensor
/// data again.
///
/// Opening the file is the slow part: `CIRAWFilter(imageURL:)` took 130 to
/// 300 ms for a 24 MP NEF on M4, and a half-size render after it about
/// 110 ms; the same filter given new settings rendered again at half size
/// in 65-78 ms. Draft mode measured no faster at those sizes, so it stays
/// off. The filter is not safe to change from two threads, so settings and
/// output are taken under a lock; the `CIImage` it returns is immutable and
/// renders outside it.
final class RawDevelopFilter: @unchecked Sendable {
    let url: URL
    let defaults: RawDefaults
    /// The sensor's size, upright.
    let orientedSize: CGSize
    private let filter: CIRAWFilter
    private let lock = NSLock()

    /// Nil when the engine doesn't know the camera.
    init?(url: URL) {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        guard native.width > 0, native.height > 0 else { return nil }
        self.url = url
        self.filter = filter
        defaults = RawDefaults(filter)
        orientedSize = filter.orientation.swapsAxes ? CGSize(width: native.height, height: native.width) : native
    }

    /// The engine's rendering with `develop` (nil: the camera's settings),
    /// at `scale` of the sensor's size, upright with its extent at the
    /// origin. With `hdr` highlights reach up to `headroom` (see
    /// `RawRenderer.maximumHeadroom`).
    func image(develop: RawDevelop?, scale: Double, hdr: Bool, headroom: Float) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        let settings = (develop ?? RawDevelop()).filled(from: defaults)
        filter.isDraftModeEnabled = false
        filter.scaleFactor = Float(min(max(scale, 0.01), 1))
        filter.extendedDynamicRangeAmount = hdr ? RawRenderer.edrAmount(forHeadroom: headroom) : 0
        filter.exposure = Float(Self.clamp(settings.exposure, RawDevelop.exposureRange, default: defaults.exposure))
        // Temperature first: the two are one white point, and the tint is
        // read against the temperature already set.
        filter.neutralTemperature = Float(Self.clamp(settings.temperature, 2000...50000, default: defaults.temperature))
        filter.neutralTint = Float(Self.clamp(settings.tint, RawDevelop.tintRange, default: defaults.tint))
        filter.boostAmount = Float(Self.clamp(settings.boost, 0...1, default: defaults.boost))
        if defaults.supportsLuminanceNoiseReduction {
            filter.luminanceNoiseReductionAmount = Float(Self.clamp(settings.luminanceNoiseReduction, 0...1,
                                                                    default: defaults.luminanceNoiseReduction))
        }
        if defaults.supportsColorNoiseReduction {
            filter.colorNoiseReductionAmount = Float(Self.clamp(settings.colorNoiseReduction, 0...1,
                                                                default: defaults.colorNoiseReduction))
        }
        if #available(macOS 26.0, *), defaults.supportsHighlightRecovery {
            filter.isHighlightRecoveryEnabled = settings.recoversHighlights ?? defaults.recoversHighlights
        }
        guard let output = filter.outputImage, !output.extent.isInfinite, !output.extent.isEmpty else { return nil }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
    }

    private static func clamp(_ value: Double?, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension EditRenderer {
    /// The camera's own RAW settings for the document's file, and which of
    /// them the engine can change, for the RAW tool. Opens the file in the
    /// engine (a few hundred milliseconds the first time; the document keeps
    /// it for the tool's previews). Nil for a file that isn't RAW or whose
    /// camera the engine doesn't know.
    public func rawDefaults(for document: EditDocument) async -> RawDefaults? {
        guard document.entry.kind == .raw else { return nil }
        if let filter = document.rawFilter { return filter.defaults }
        let url = document.entry.url
        let token = document.preparationToken
        let expected = document.sourceSignature
        let filter = await BlockingWork.run { () -> RawDevelopFilter? in
            // Only the file the document's operations were made on.
            if let expected, FileSignature.read(url) != expected { return nil }
            return RawDevelopFilter(url: url)
        }
        if let filter, document.rawFilter == nil, document.preparationToken == token {
            document.rawFilter = filter
        }
        return filter?.defaults
    }

    /// The RAW settings a render of `operations` asks of the original: the
    /// last RAW step's for a RAW file, nil otherwise (other files have no
    /// sensor data to develop, so the step is ignored).
    nonisolated static func rawDevelop(kind: ImageKind?, operations: [EditOperation]) -> RawDevelop? {
        kind == .raw ? RawDevelop.inEffect(operations) : nil
    }

    /// The document's RAW file developed with `develop` at `scale` of
    /// `fullSize` (the original's size, which every operation refers to),
    /// rendered into a half-float texture in Core Image's orientation, the
    /// way proxies and stages are. The engine renders at the scale itself,
    /// which skips work rather than resampling a full render; an output a
    /// pixel off the exact working size is resampled to it.
    ///
    /// In one of the editor's RAW slots, on the RAW context with its memory
    /// limit. Synchronous and slow (tens to hundreds of milliseconds): from
    /// `BlockingWork` only.
    nonisolated static func renderDeveloped(_ filter: RawDevelopFilter, develop: RawDevelop?, fullSize: CGSize,
                                            scale: Double, settings: DisplaySettings,
                                            gpu: GPU) throws -> (texture: MTLTexture, image: CIImage, headroom: Float) {
        let hdr = settings.rendersHDRRaw
        let long = max(fullSize.width, fullSize.height)
        let sensorLong = max(filter.orientedSize.width, filter.orientedSize.height)
        let engineScale = long > 0 && sensorLong > 0 ? scale * Double(long / sensorLong) : scale
        return try RawRenderer.withEditRenderSlot {
            guard let output = filter.image(develop: develop, scale: engineScale, hdr: hdr,
                                            headroom: settings.rawHeadroom) else {
                throw DecodeError.noImage(filter.url)
            }
            let width = EditGraph.workingLength(Int(fullSize.width.rounded()), scale: scale)
            let height = EditGraph.workingLength(Int(fullSize.height.rounded()), scale: scale)
            let exact = Int(output.extent.width.rounded()) == width && Int(output.extent.height.rounded()) == height
                ? output : lanczos(output, to: fullSize, scale: scale)
            let context = RawRenderer.context(for: gpu)
            let (texture, image) = try renderIntermediate(exact, context: context, gpu: gpu, label: "a RAW rendering")
            var headroom: Float = 1
            if hdr {
                // As `RawRenderer.render` measures it: the engine reports none.
                let fallback = pow(2, RawRenderer.edrAmount(forHeadroom: settings.rawHeadroom))
                headroom = max(1, RawRenderer.peakValue(of: texture, gpu: gpu) ?? fallback)
            }
            return (texture, image, headroom)
        }
    }

    /// The original of a RAW file developed with `develop`, at its full size
    /// (or Metal's texture limit), for editing and saving.
    nonisolated static func developedSource(_ filter: RawDevelopFilter, develop: RawDevelop,
                                            settings: DisplaySettings, gpu: GPU) throws -> EditSource {
        let size = filter.orientedSize
        let scale = RawRenderer.renderScale(longestEdge: Int(max(size.width, size.height)), maxPixelSize: nil)
        let rendered = try renderDeveloped(filter, develop: develop, fullSize: size, scale: scale, settings: settings,
                                           gpu: gpu)
        return EditSource(texture: rendered.texture, image: rendered.image, size: size, scale: scale,
                          isHDR: settings.rendersHDRRaw, contentHeadroom: rendered.headroom, develop: develop)
    }
}
