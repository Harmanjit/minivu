import Testing
import Foundation
import CoreGraphics
import CoreImage
import Metal
@testable import MinivuRender
@testable import MinivuCore

/// TEMPORARY, with HDRDiagnostics.swift: the switches parse as documented,
/// change nothing when unset, and the peak measurement sees HDR values.
@Suite struct HDRDiagnosticsTests {
    typealias Settings = HDRDiagnostics.Settings

    @Test func environmentParsing() {
        let all = Settings(environment: ["MINIVU_HDR_DIAGNOSTICS": "1", "MINIVU_HDR_PREVIEW": "full",
                                         "MINIVU_HDR_LAYER": "high", "MINIVU_HDR_CIHEADROOM": "1"])
        #expect(all.logging && all.fullScalePreviews && all.highDynamicRangeLayer && all.tagsContentHeadroom)
        #expect(all.isAnyOn)

        let forgiving = Settings(environment: ["MINIVU_HDR_DIAGNOSTICS": " TRUE ", "MINIVU_HDR_PREVIEW": "Full",
                                               "MINIVU_HDR_LAYER": "HIGH", "MINIVU_HDR_CIHEADROOM": "yes"])
        #expect(forgiving == all)

        var onlyPreview = Settings.off
        onlyPreview.fullScalePreviews = true
        #expect(Settings(environment: ["MINIVU_HDR_PREVIEW": "full"]) == onlyPreview)

        let wrong = Settings(environment: ["MINIVU_HDR_DIAGNOSTICS": "0", "MINIVU_HDR_PREVIEW": "proxy",
                                           "MINIVU_HDR_LAYER": "standard", "MINIVU_HDR_CIHEADROOM": ""])
        #expect(wrong == .off)
        #expect(!wrong.isAnyOn)
    }

    @Test func nothingChangesWithoutTheVariables() {
        #expect(Settings(environment: [:]) == .off)
        #expect(Settings(environment: ["PATH": "/usr/bin", "MINIVU_CATALOG": "memory"]) == .off)

        // Previews plan as they always have.
        let size = CGSize(width: 6000, height: 4000)
        for (pixelSize, proxy) in [(3000, 0.5), (1200, 0.5), (2400, 0.25)] as [(Int, Double?)] {
            #expect(EditRenderer.plan(full: false, outputSize: size, pixelSize: pixelSize, proxyScale: proxy,
                                      diagnostics: .off)
                    == EditRenderer.previewPlan(outputSize: size, pixelSize: pixelSize, proxyScale: proxy))
        }
        #expect(EditRenderer.plan(full: true, outputSize: size, pixelSize: 3000, proxyScale: 0.5, diagnostics: .off)
                == EditRenderer.fullResolutionPlan(outputSize: size))

        // Core Image images are passed through untouched.
        let image = CIImage(color: CIColor(red: 2, green: 2, blue: 2)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(HDRDiagnostics.taggingContentHeadroom(image, isHDR: true, headroom: 4, settings: .off) === image)
        var tagging = Settings.off
        tagging.tagsContentHeadroom = true
        #expect(HDRDiagnostics.taggingContentHeadroom(image, isHDR: false, headroom: 1, settings: tagging) === image)
        if #available(macOS 26, *) {
            #expect(HDRDiagnostics.taggingContentHeadroom(image, isHDR: true, headroom: 4, settings: tagging)
                .contentHeadroom == 4)
        } else {
            #expect(HDRDiagnostics.taggingContentHeadroom(image, isHDR: true, headroom: 4, settings: tagging) === image)
        }
    }

    @Test func fullScalePreviewsPlanLikeFullResolution() {
        var settings = Settings.off
        settings.fullScalePreviews = true
        let size = CGSize(width: 6000, height: 4000)
        let plan = EditRenderer.plan(full: false, outputSize: size, pixelSize: 1200, proxyScale: 0.5, diagnostics: settings)
        #expect(plan == .init(scale: 1, maximumScale: 1, useProxy: false, rebuildProxy: false))
    }

    @Test func peakOfAnHDRTextureIsAboveSDRWhite() async throws {
        let hdr = try TextureUploader.upload(ImageDecoder.decode(Fixtures.gainMapHEIC()))
        #expect(hdr.isHDR)
        let peak = try #require(HDRDiagnostics.peak(of: hdr.texture))
        #expect(peak.max() > 3, "HDR peak \(peak)")   // the ramp reaches about 3.9

        let sdrURL = Fixtures.write(Fixtures.quadrants(), name: "diagnostics-sdr-\(UUID()).png", type: .png)
        let sdr = try TextureUploader.upload(ImageDecoder.decode(sdrURL))
        let sdrPeak = try #require(HDRDiagnostics.peak(of: sdr.texture))
        #expect(sdrPeak.max() > 0.98 && sdrPeak.max() < 1.01, "SDR peak \(sdrPeak)")

        // The asynchronous form, as the logs use it.
        nonisolated(unsafe) let texture = hdr.texture
        let peaks = await withCheckedContinuation { continuation in
            HDRDiagnostics.measurePeaks([nil, texture]) { continuation.resume(returning: $0) }
        }
        let measured = try #require(peaks)
        #expect(measured.count == 2 && measured[0] == nil)
        #expect((measured[1]?.max() ?? 0) > 3)
    }
}
