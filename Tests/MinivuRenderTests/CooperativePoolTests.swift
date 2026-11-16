import Testing
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import MinivuCore
@testable import MinivuRender

/// Batch Convert (and the Shortcuts Convert and Resize actions, which run
/// it) encodes on GCD, never on the cooperative thread its async code runs
/// on: HEIF and AVIF encoders wait on their own queues, and enough such
/// waits on the pool at once deadlock it (docs/feature-notes/coop-starvation.md).
///
/// Not `.offCooperativePool`: these tests are about where the production
/// code runs when called from the pool, as the app calls it.
#if DEBUG
@Suite struct CooperativePoolTests {
    static var formats: [ExportFormat] { [.heic] + (ExportFormat.avif.isWritable ? [.avif] : []) }

    @MainActor func converter() -> BatchConverter {
        BatchConverter(renderer: EditRenderer.shared, displaySettings: DisplaySettings()) { _, _, _ in
            CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    /// An SDR original and an HDR one written with a gain map: neither
    /// encode runs on the calling task's cooperative thread.
    @Test(arguments: formats)
    func batchConvertEncodesOffThePool(_ format: ExportFormat) async throws {
        let converter = await converter()
        let sdr = Fixtures.write(Fixtures.quadrants(width: 96, height: 64), name: "pool-\(UUID()).png", type: .png)
        let hdr = try await BlockingWork.run { try Fixtures.gainMapHEIC(width: 96, height: 32) }
        #expect(BlockingWork.isOnCooperativeThread)

        let log = BlockingWork.CallLog()
        let settings = BatchConvertSettings(options: .defaults(for: format))
        let written = try await BlockingWork.$cooperativeCallLog.withValue(log) {
            [try await converter.encodedData(for: sdr, settings: settings),
             try await converter.encodedData(for: hdr, settings: settings)]
        }
        #expect(written.allSatisfy { !$0.isEmpty })
        #expect(log.names.isEmpty, "\(format): \(log.names)")
    }
}
#endif
