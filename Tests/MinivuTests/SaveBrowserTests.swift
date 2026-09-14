import Testing
import AppKit
import ImageIO
import MinivuCore
@testable import Minivu

/// Lossless rotate and flip for a browser selection.
@Suite struct LosslessBatchTests {
    func entry(_ name: String, directory: Bool = false) -> FolderEntry {
        let url = URL(fileURLWithPath: "/tmp/batch/\(name)")
        return FolderEntry(url: url, name: name, isDirectory: directory, kind: directory ? nil : ImageFormats.kind(of: url),
                           fileSize: 1, modified: .distantPast, created: .distantPast)
    }

    @Test func partitionsTheSelection() {
        let (applicable, skipped) = LosslessBatch.partition([
            entry("a.jpg"), entry("Folder", directory: true), entry("b.NEF"), entry("c.gif"), entry("d.heic"),
            entry("e.png"), entry("f.dng"),
        ])
        #expect(applicable.map(\.lastPathComponent) == ["a.jpg", "d.heic", "e.png"])
        #expect(skipped.map(\.lastPathComponent) == ["b.NEF", "c.gif", "f.dng"])
        #expect(!LosslessBatch.isApplicable(entry("Folder.jpg", directory: true)))
    }

    @Test func sortsOutcomesAndReportsFailures() async {
        let urls = (0..<9).map { URL(fileURLWithPath: "/tmp/batch/\($0).jpg") }
        let outcome = await LosslessBatch.run(.rotateClockwise, on: urls, skipped: [URL(fileURLWithPath: "/tmp/batch/x.gif")]) { _, url in
            switch url.lastPathComponent {
            case "3.jpg": throw LosslessTransform.Error.unsupportedFormat
            case "5.jpg": throw LosslessTransform.Error.copyFailed("disk full")
            default: usleep(UInt32.random(in: 0...2000))
            }
        }
        #expect(outcome.transformed.map(\.lastPathComponent) == ["0.jpg", "1.jpg", "2.jpg", "4.jpg", "6.jpg", "7.jpg", "8.jpg"])
        #expect(outcome.skipped.map(\.lastPathComponent) == ["x.gif", "3.jpg"])
        #expect(outcome.failed == [.init(url: urls[5], reason: "The file couldn’t be rewritten (disk full).")])
    }

    @Test func messages() throws {
        let file = { (name: String) in URL(fileURLWithPath: "/tmp/batch/\(name)") }
        #expect(LosslessBatch.message(for: .init(transformed: [file("a.jpg")]), kind: .rotateClockwise) == nil)

        let skipped = LosslessBatch.Outcome(transformed: [file("a.jpg")], skipped: [file("b.nef"), file("c.gif")])
        let message = try #require(LosslessBatch.message(for: skipped, kind: .rotateCounterclockwise))
        #expect(message.title == "1 file was rotated.")
        #expect(message.detail == "2 files can’t be rotated without re-encoding (RAW, GIF).")

        let one = LosslessBatch.Outcome(skipped: [file("c.bmp")])
        #expect(LosslessBatch.message(for: one, kind: .flipVertical)?.detail == "1 file can’t be flipped without re-encoding (BMP).")
        #expect(LosslessBatch.message(for: one, kind: .flipVertical)?.title == "No files were flipped.")

        let failed = LosslessBatch.Outcome(transformed: [file("a.jpg"), file("b.jpg")],
                                           failed: [.init(url: file("c.jpg"), reason: "The file couldn’t be read.")])
        #expect(LosslessBatch.message(for: failed, kind: .flipHorizontal)?.detail
            == "“c.jpg” couldn’t be flipped: The file couldn’t be read.")
    }

    @Test func typeListNamesTheCommonestFirst() {
        let urls = ["a.gif", "b.nef", "c.cr3", "d.bmp", "e.tga", "f.bmp", "g.bmp"].map { URL(fileURLWithPath: "/x/\($0)") }
        #expect(LosslessBatch.typeList(urls) == "BMP, RAW, GIF, …")
        #expect(LosslessBatch.typeList([URL(fileURLWithPath: "/x/readme")]) == "no extension")
    }

    @Test func rotatesARealJPEG() async throws {
        let t = try ScratchFolder()
        let url = try t.jpeg("a.jpg", width: 40, height: 20)
        let outcome = await LosslessBatch.run(.rotateClockwise, on: [url])
        #expect(outcome.transformed == [url])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
    }
}

/// The browser's editing commands and their menu validation. Part of the
/// serialized window suite.
extension AppWindowTests {
    @MainActor @Suite(.serialized) struct BrowserEditingTests {
        func settle(_ controller: BrowserWindowController) async {
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        func valid(_ controller: BrowserWindowController, _ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        @Test func validationFollowsTheSelection() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let folder = try t.folder("Sub")
            let jpeg = try t.file("a.jpg"), gif = try t.file("b.gif"), raw = try t.file("c.nef"), png = try t.file("d.png")
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await settle(controller)

            controller.model.select(jpeg)
            for action: Selector in [.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical, .editComment, .saveImageAs] {
                #expect(valid(controller, action), "\(action)")
            }

            controller.model.select(png)
            #expect(valid(controller, .rotateLeft) && valid(controller, .saveImageAs))
            #expect(!valid(controller, .editComment))

            for url in [gif, raw] {
                controller.model.select(url)
                #expect(!valid(controller, .rotateRight) && !valid(controller, .flipVertical))
                #expect(valid(controller, .saveImageAs))
            }

            controller.model.select(folder)
            #expect(!valid(controller, .rotateLeft) && !valid(controller, .editComment) && !valid(controller, .saveImageAs))

            // A mix rotates what it can; single-file commands need one file.
            controller.model.setSelection([gif, jpeg], lead: jpeg)
            #expect(valid(controller, .rotateLeft))
            #expect(!valid(controller, .editComment) && !valid(controller, .saveImageAs))
            controller.model.setSelection([gif, raw, folder], lead: gif)
            #expect(!valid(controller, .rotateLeft))
        }

        @Test func rotatingTheSelectionRewritesTheFiles() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let first = try t.jpeg("a.jpg", width: 40, height: 20)
            let second = try t.jpeg("b.jpg", width: 40, height: 20)
            try t.file("c.gif")
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await settle(controller)

            controller.model.setSelection([first, second], lead: first)
            controller.rotateRight(nil)
            controller.rotateRight(nil)   // queued behind the first: both turns count
            await LosslessQueue.shared.waitUntilIdle()
            for url in [first, second] {
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                #expect((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 3)
            }
        }
    }
}
