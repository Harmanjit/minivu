// TEMPORARY. HDR diagnostics for one test session on a macOS 26+ Mac with an
// HDR screen, where an HDR photo turns SDR once an edit is rendered and comes
// back after a click to 100%. Delete this file, its tests
// (HDRDiagnosticsTests.swift) and every line marked "HDRDiagnostics" once the
// cause is known.
//
// Everything is off, and costs one Bool test at each hook, unless its
// environment variable is set. Run the app from Terminal:
//
//     MINIVU_HDR_DIAGNOSTICS=1 /Applications/minivu.app/Contents/MacOS/minivu
//
// and capture the log in another window:
//
//     log stream --predicate 'subsystem == "com.minivu.app" AND category == "hdr"'
//
// Variables:
//   MINIVU_HDR_DIAGNOSTICS=1  log textures, edit renders, headroom changes and
//                             HDR suppression, with measured peak values
//   MINIVU_HDR_PREVIEW=full   experiment: edit previews render at full scale,
//                             never from the proxy or through Lanczos
//   MINIVU_HDR_LAYER=high     experiment (macOS 26+): the canvas layer also gets
//                             preferredDynamicRange .high and contentsHeadroom
//   MINIVU_HDR_CIHEADROOM=1   experiment (macOS 26+): CIImages made from edit
//                             textures are tagged with the source's headroom

import AppKit
import CoreImage
import Metal
import QuartzCore
import os

public enum HDRDiagnostics {
    public struct Settings: Equatable, Sendable {
        /// MINIVU_HDR_DIAGNOSTICS=1
        public var logging = false
        /// MINIVU_HDR_PREVIEW=full
        public var fullScalePreviews = false
        /// MINIVU_HDR_LAYER=high
        public var highDynamicRangeLayer = false
        /// MINIVU_HDR_CIHEADROOM=1
        public var tagsContentHeadroom = false

        public static let off = Settings()

        public init() {}

        public init(environment: [String: String]) {
            func value(_ key: String) -> String {
                (environment[key] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            }
            func flag(_ key: String) -> Bool { ["1", "true", "yes"].contains(value(key)) }
            logging = flag("MINIVU_HDR_DIAGNOSTICS")
            fullScalePreviews = value("MINIVU_HDR_PREVIEW") == "full"
            highDynamicRangeLayer = value("MINIVU_HDR_LAYER") == "high"
            tagsContentHeadroom = flag("MINIVU_HDR_CIHEADROOM")
        }

        public var isAnyOn: Bool { logging || fullScalePreviews || highDynamicRangeLayer || tagsContentHeadroom }
    }

    /// Read once, from the process environment.
    public static let current = Settings(environment: ProcessInfo.processInfo.environment)

    /// Notice level, so `log stream` shows it without `--level debug`.
    static let log = Logger(subsystem: "com.minivu.app", category: "hdr")

    // MARK: - Launch and HDR suppression

    @MainActor private static var suppressionObservers: [NSObjectProtocol] = []

    /// OS, Mac, experiments, screens and (macOS 26+) HDR suppression, then
    /// suppression changes as they are posted.
    @MainActor public static func appLaunched(settings: Settings = current) {
        guard settings.isAnyOn else { return }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let mac = "\(sysctl("hw.model")) \(sysctl("machdep.cpu.brand_string"))"
        log.notice("HDR: session: minivu \(version, privacy: .public), macOS \(os, privacy: .public), \(mac, privacy: .public)")
        log.notice("""
            HDR: logging \(settings.logging ? "on" : "off", privacy: .public); experiments: \
            MINIVU_HDR_PREVIEW=full \(settings.fullScalePreviews ? "ACTIVE (previews at full scale, no proxy, no Lanczos)" : "off", privacy: .public), \
            MINIVU_HDR_LAYER=high \(settings.highDynamicRangeLayer ? layerExperimentState : "off", privacy: .public), \
            MINIVU_HDR_CIHEADROOM=1 \(settings.tagsContentHeadroom ? ciHeadroomExperimentState : "off", privacy: .public)
            """)
        guard settings.logging else { return }
        for screen in NSScreen.screens {
            log.notice("HDR: screen \"\(screen.localizedName, privacy: .public)\" \(screenDescription(screen), privacy: .public)")
        }
        guard #available(macOS 26, *) else {
            log.notice("HDR: applicationShouldSuppressHighDynamicRangeContent unavailable (macOS before 26)")
            return
        }
        log.notice("HDR: at launch applicationShouldSuppressHighDynamicRangeContent=\(NSApplication.shared.applicationShouldSuppressHighDynamicRangeContent, privacy: .public)")
        let center = NotificationCenter.default
        for (name, label) in [(NSNotification.Name.NSApplicationShouldBeginSuppressingHighDynamicRangeContent, "begin"),
                              (NSNotification.Name.NSApplicationShouldEndSuppressingHighDynamicRangeContent, "end")] {
            suppressionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    log.notice("""
                        HDR: suppression \(label, privacy: .public) notification, \
                        applicationShouldSuppressHighDynamicRangeContent=\(NSApplication.shared.applicationShouldSuppressHighDynamicRangeContent, privacy: .public)
                        """)
                }
            })
        }
    }

    private static var layerExperimentState: String {
        if #available(macOS 26, *) { return "ACTIVE (preferredDynamicRange high, contentsHeadroom = image's, while EDR is on)" }
        return "requested but inactive (macOS before 26)"
    }

    private static var ciHeadroomExperimentState: String {
        if #available(macOS 26, *) { return "ACTIVE (edit CIImages from textures tagged with the source's content headroom)" }
        return "requested but inactive (macOS before 26)"
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Canvas

    /// Where edit renders came from, by texture (weak keys: nothing is kept alive).
    @MainActor private static let origins = NSMapTable<ImageTexture, NSString>.weakToStrongObjects()
    @MainActor private static let numbers = NSMapTable<ImageTexture, NSNumber>.weakToStrongObjects()
    @MainActor private static var textureCount = 0
    @MainActor private static var renderCount = 0
    /// Set when the viewer is asked to put its own texture back.
    @MainActor private static var restorePending = false

    /// The viewer was asked to show its unedited texture again: the next
    /// canvas texture that isn't an edit render is that one.
    @MainActor public static func viewerRestoreRequested() {
        guard current.logging else { return }
        restorePending = true
    }

    /// A texture was put on a canvas: what it is, where it came from and,
    /// asynchronously, its peak value.
    @MainActor public static func canvasTexture(_ texture: ImageTexture, canvas: AnyObject, layer: CAMetalLayer?) {
        guard current.logging else { return }
        textureCount += 1
        let number = textureCount
        numbers.setObject(NSNumber(value: number), forKey: texture)
        var origin = origins.object(forKey: texture).map { $0 as String }
        if origin == nil {
            origin = restorePending ? "viewer texture restored" : "viewer loader"
            restorePending = false
        }
        let t = texture.texture
        log.notice("""
            HDR: canvas \(canvasID(canvas), privacy: .public) texture #\(number, privacy: .public) from \(origin ?? "?", privacy: .public): \
            texture \(t.width, privacy: .public)x\(t.height, privacy: .public) \(formatName(t.pixelFormat), privacy: .public), \
            image \(Int(texture.imageSize.width), privacy: .public)x\(Int(texture.imageSize.height), privacy: .public), \
            full=\(texture.isFullResolution, privacy: .public) hdr=\(texture.isHDR, privacy: .public) \
            headroom=\(format(texture.contentHeadroom), privacy: .public) | \(layerDescription(layer), privacy: .public)
            """)
        measurePeaks([t]) { peaks in
            log.notice("HDR: texture #\(number, privacy: .public) peak \(peakDescription(peaks, 0), privacy: .public)")
        }
    }

    /// A frame drawn for another display headroom than the one before.
    @MainActor public static func canvasFrame(canvas: AnyObject, image: ImageTexture?, headroom: Float, previous: Float?,
                                              layer: CAMetalLayer, screen: NSScreen?) {
        guard current.logging else { return }
        let number = image.flatMap { numbers.object(forKey: $0) }.map { "#\($0.intValue)" } ?? (image == nil ? "none" : "?")
        log.notice("""
            HDR: canvas \(canvasID(canvas), privacy: .public) frame headroom \(previous.map(format) ?? "none", privacy: .public) \
            -> \(format(headroom), privacy: .public), texture \(number, privacy: .public) | \
            \(layerDescription(layer), privacy: .public) | screen \(screen.map(screenDescription) ?? "none", privacy: .public)
            """)
    }

    /// MINIVU_HDR_LAYER=high: on macOS 26+, the layer's preferred dynamic
    /// range and contents headroom follow its EDR state.
    @MainActor public static func applyLayerExperiment(to layer: CAMetalLayer, contentHeadroom: Float?,
                                                       settings: Settings = current) {
        guard settings.highDynamicRangeLayer, #available(macOS 26, *) else { return }
        let edr = layer.wantsExtendedDynamicRangeContent
        let range: CALayer.DynamicRange = edr ? .high : .standard
        let headroom = edr ? CGFloat(max(contentHeadroom ?? 1, 1)) : 0
        guard layer.preferredDynamicRange != range || layer.contentsHeadroom != headroom else { return }
        layer.preferredDynamicRange = range
        layer.contentsHeadroom = headroom
        if settings.logging {
            log.notice("HDR: layer experiment set preferredDynamicRange=\(range.rawValue, privacy: .public) contentsHeadroom=\(format(Float(headroom)), privacy: .public)")
        }
    }

    // MARK: - Edit renderer

    /// MINIVU_HDR_CIHEADROOM=1: on macOS 26+, an HDR image made from a texture
    /// says how much headroom it has, which Core Image can't tell from the texture.
    public static func taggingContentHeadroom(_ image: CIImage, isHDR: Bool, headroom: Float,
                                              settings: Settings = current) -> CIImage {
        guard settings.tagsContentHeadroom, isHDR, headroom > 1, #available(macOS 26, *) else { return image }
        return image.settingContentHeadroom(headroom)
    }

    static func taggingContentHeadroom(_ image: CIImage, of source: EditSource) -> CIImage {
        taggingContentHeadroom(image, isHDR: source.isHDR, headroom: source.contentHeadroom)
    }

    /// The original and proxy a document's edits render from, once decoded.
    @MainActor static func editPrepared(source: EditSource, proxy: EditProxy?) {
        guard current.logging else { return }
        let summary = """
            edit source \(Int(source.size.width))x\(Int(source.size.height)) scale \(format(source.scale)), \
            \(source.texture.map(textureDescription) ?? "no texture (tiled)"), hdr=\(source.isHDR) \
            headroom=\(format(source.contentHeadroom)) ciHeadroom=\(format(source.image.contentHeadroom)) | \
            \(proxy.map { "proxy scale \(format($0.scale)) \(textureDescription($0.texture)) ciHeadroom=\(format($0.image.contentHeadroom))" } ?? "no proxy")
            """
        measurePeaks([source.texture, proxy?.texture]) { peaks in
            log.notice("""
                HDR: \(summary, privacy: .public) | peaks: source \(peakDescription(peaks, 0), privacy: .public), \
                proxy \(proxy == nil ? "none" : peakDescription(peaks, 1), privacy: .public)
                """)
        }
    }

    /// A finished render (delivered or not): what it started from and the
    /// peaks of that start and of the output. Also remembers the lane, for
    /// `canvasTexture`.
    @MainActor static func editRendered(_ output: ImageTexture, full: Bool, plan: EditRenderer.Plan, proxy: EditProxy?,
                                        rebuiltProxy: Bool, stage: Bool) {
        guard current.logging else { return }
        renderCount += 1
        let number = renderCount
        origins.setObject("edit \(full ? "full" : "preview") lane (render #\(number))" as NSString, forKey: output)
        let start: String
        if stage {
            start = "stage"
        } else if plan.useProxy, let proxy {
            start = "proxy scale \(format(proxy.scale))\(rebuiltProxy ? " (rebuilt)" : "") \(textureDescription(proxy.texture)) ciHeadroom=\(format(proxy.image.contentHeadroom))"
        } else {
            start = "original"
        }
        let experiment = !full && current.fullScalePreviews ? " [MINIVU_HDR_PREVIEW=full]" : ""
        let summary = """
            edit render #\(number) \(full ? "full" : "preview") lane\(experiment): scale \(format(plan.scale)) of max \(format(plan.maximumScale)), \
            from \(start) -> output \(textureDescription(output.texture)) full=\(output.isFullResolution) \
            hdr=\(output.isHDR) headroom=\(format(output.contentHeadroom))
            """
        let usedProxy = plan.useProxy && !stage ? proxy?.texture : nil
        let measuresStart = usedProxy != nil
        measurePeaks([usedProxy, output.texture]) { peaks in
            log.notice("""
                HDR: \(summary, privacy: .public) | peaks: start \(measuresStart ? peakDescription(peaks, 0) : "not measured", privacy: .public), \
                output \(peakDescription(peaks, 1), privacy: .public)
                """)
        }
    }

    // MARK: - Peaks

    private static let measureQueue = DispatchQueue(label: "com.minivu.hdr-diagnostics", qos: .utility)
    private static let pendingMeasurements = OSAllocatedUnfairLock(initialState: 0)
    private static let measureContext = CIContext(mtlDevice: GPU.shared.device, options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false, .name: "minivu HDR diagnostics",
    ])

    /// The largest value of each colour channel in `texture`'s first level,
    /// as sampled (an `_srgb` texture reads as linear), without colour
    /// management. Synchronous: waits for the GPU.
    static func peak(of texture: MTLTexture) -> SIMD3<Float>? {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: NSNull()]) else { return nil }
        let reduced = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: -1, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            measureContext.render(reduced, toBitmap: raw.baseAddress!, rowBytes: 16,
                                  bounds: CGRect(x: reduced.extent.minX, y: reduced.extent.minY, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: nil)
        }
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }

    /// `peak(of:)` for each texture (nil stays nil), one after another on a
    /// utility queue, never on the caller's thread. Reports nil instead when
    /// a few measurements are already waiting (a slider being dragged), so
    /// the queue can't hold on to textures.
    static func measurePeaks(_ textures: [MTLTexture?], then report: @escaping @Sendable ([SIMD3<Float>?]?) -> Void) {
        let admitted = pendingMeasurements.withLock { count in
            guard count < 6 else { return false }
            count += 1
            return true
        }
        guard admitted else { return report(nil) }
        nonisolated(unsafe) let textures = textures
        measureQueue.async {
            let peaks = textures.map { $0.flatMap(peak(of:)) }
            pendingMeasurements.withLock { $0 -= 1 }
            report(peaks)
        }
    }

    // MARK: - Formatting

    private static func peakDescription(_ peaks: [SIMD3<Float>?]?, _ index: Int) -> String {
        guard let peaks else { return "skipped (busy)" }
        guard index < peaks.count, let peak = peaks[index] else { return "unreadable" }
        return "r=\(format(peak.x)) g=\(format(peak.y)) b=\(format(peak.z))"
    }

    private static func layerDescription(_ layer: CAMetalLayer?) -> String {
        guard let layer else { return "no layer" }
        var text = "layer wantsEDR=\(layer.wantsExtendedDynamicRangeContent) toneMapMode=\(layer.toneMapMode.rawValue) "
            + "edrMetadata=\(layer.edrMetadata == nil ? "nil" : "set")"
        if #available(macOS 26, *) {
            text += " preferredDynamicRange=\(layer.preferredDynamicRange.rawValue) contentsHeadroom=\(format(Float(layer.contentsHeadroom)))"
        }
        return text
    }

    @MainActor private static func screenDescription(_ screen: NSScreen) -> String {
        """
        current=\(format(Float(screen.maximumExtendedDynamicRangeColorComponentValue))) \
        potential=\(format(Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))) \
        reference=\(format(Float(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)))
        """
    }

    private static func textureDescription(_ texture: MTLTexture) -> String {
        "\(texture.width)x\(texture.height) \(formatName(texture.pixelFormat))"
    }

    private static func formatName(_ format: MTLPixelFormat) -> String {
        switch format {
        case .rgba16Float: "rgba16Float"
        case .bgra8Unorm_srgb: "bgra8Unorm_srgb"
        case .bgra8Unorm: "bgra8Unorm"
        case .rgba8Unorm: "rgba8Unorm"
        case .rgba8Unorm_srgb: "rgba8Unorm_srgb"
        case .rgba32Float: "rgba32Float"
        default: "format \(format.rawValue)"
        }
    }

    private static func canvasID(_ canvas: AnyObject) -> String {
        String(UInt(bitPattern: Unmanaged.passUnretained(canvas).toOpaque()) & 0xFFFFF, radix: 16)
    }

    private static func format(_ value: Float) -> String { String(format: "%.3f", value) }
    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
