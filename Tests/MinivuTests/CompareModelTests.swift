import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// a.jpg, b.jpg, ... (no files needed).
private func images(_ count: Int) -> [FolderEntry] {
    (0..<count).map { i in
        let name = "\(Character(UnicodeScalar(UInt8(97 + i)))).jpg"
        return FolderEntry(url: URL(fileURLWithPath: "/tmp/minivu-compare-tests/\(name)"), name: name,
                           isDirectory: false, kind: .raster, fileSize: 1, modified: .distantPast, created: .distantPast)
    }
}

private func names(_ list: [FolderEntry]) -> [String] { list.map(\.name) }

@Suite struct CompareModelTests {
    @Test func needsTwoImagesAndKeepsAtMostFour() throws {
        let all = images(6)
        #expect(CompareModel(entries: [all[0]], allImages: all) == nil)
        // Duplicates and folders don't count.
        #expect(CompareModel(entries: [all[0], all[0]], allImages: all) == nil)
        var folder = all[1]
        folder.isDirectory = true
        #expect(CompareModel(entries: [all[0], folder], allImages: all) == nil)
        let model = try #require(CompareModel(entries: all, allImages: all))
        #expect(names(model.panes) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(model.focus == 0)
    }

    @Test func focusAndTabCycling() throws {
        var model = try #require(CompareModel(entries: Array(images(3)), allImages: images(3)))
        let r1 = model.setFocus(2)
        #expect(r1)
        let r2 = model.setFocus(3)
        #expect(!r2)
        #expect(model.focus == 2)
        model.cycleFocus()
        #expect(model.focus == 0)
        model.cycleFocus(backward: true)
        #expect(model.focus == 2)
        #expect(model.focusedEntry?.name == "c.jpg")
    }

    @Test func replacingSkipsImagesAlreadyShown() throws {
        let all = images(6)   // a b c d e f
        var model = try #require(CompareModel(entries: [all[0], all[1], all[3]], allImages: all))
        // a → next not shown: b and d are in panes, so c.
        #expect(model.replacement(forPane: 0, step: 1)?.name == "c.jpg")
        let r3 = model.replace(pane: 0, step: 1)
        #expect(r3)
        #expect(names(model.panes) == ["c.jpg", "b.jpg", "d.jpg"])
        // c → next skips d: e.
        let r4 = model.replace(pane: 0, step: 1)
        #expect(r4)
        #expect(model.panes[0].name == "e.jpg")
        // Back from e: d and c shown... c is free again now.
        #expect(model.replacement(forPane: 0, step: -1)?.name == "c.jpg")
        // b ← a is free.
        #expect(model.replacement(forPane: 1, step: -1)?.name == "a.jpg")
        // d → f (e shown), then nothing past the end without wrap.
        let r5 = model.replace(pane: 2, step: 1)
        #expect(r5)
        #expect(model.panes[2].name == "f.jpg")
        #expect(model.replacement(forPane: 2, step: 1) == nil)
        let r6 = model.replace(pane: 2, step: 1)
        #expect(!r6)
        model.wrapAround = true
        #expect(model.replacement(forPane: 2, step: 1)?.name == "a.jpg")
    }

    @Test func replacingWhenEverythingIsShownFindsNothing() throws {
        let all = images(2)
        let model = try #require(CompareModel(entries: all, allImages: all))
        #expect(model.replacement(forPane: 0, step: 1) == nil)
        #expect(model.replacement(forPane: 1, step: -1) == nil)
    }

    @Test func anImageMissingFromTheFolderListStartsAtAnEnd() throws {
        let all = images(4)
        let stray = FolderEntry(url: URL(fileURLWithPath: "/elsewhere/z.jpg"), name: "z.jpg", isDirectory: false,
                                kind: .raster, fileSize: 1, modified: .distantPast, created: .distantPast)
        let model = try #require(CompareModel(entries: [stray, all[0]], allImages: all))
        #expect(model.replacement(forPane: 0, step: 1)?.name == "b.jpg")
        #expect(model.replacement(forPane: 0, step: -1)?.name == "d.jpg")
    }

    @Test func removingATrashedImageFillsItsPaneWithTheNextOne() throws {
        let all = images(5)   // a b c d e
        var model = try #require(CompareModel(entries: [all[1], all[2]], allImages: all))
        // b goes: the next image not shown is d (c is in a pane).
        let r7 = model.remove(all[1].url)
        #expect(r7 == .replaced(pane: 0))
        #expect(names(model.panes) == ["d.jpg", "c.jpg"])
        #expect(names(model.allImages) == ["a.jpg", "c.jpg", "d.jpg", "e.jpg"])
        // A file that isn't in a pane only leaves the folder list.
        let r8 = model.remove(all[4].url)
        #expect(r8 == .notShown)
        #expect(names(model.allImages) == ["a.jpg", "c.jpg", "d.jpg"])
        // d goes, last in the list: the previous free image is a.
        let r9 = model.remove(all[3].url)
        #expect(r9 == .replaced(pane: 0))
        #expect(names(model.panes) == ["a.jpg", "c.jpg"])
    }

    @Test func removingWithNothingLeftToShowRemovesThePane() throws {
        let all = images(3)
        var model = try #require(CompareModel(entries: all, allImages: all))
        let r10 = model.setFocus(2)
        #expect(r10)
        let r11 = model.remove(all[1].url)
        #expect(r11 == .removedPane(1))
        #expect(names(model.panes) == ["a.jpg", "c.jpg"])
        // The focused pane (c) keeps the focus at its new index.
        #expect(model.focus == 1)
        let r12 = model.remove(all[2].url)
        #expect(r12 == .removedPane(1))
        #expect(model.focus == 0)
        let r13 = model.remove(all[0].url)
        #expect(r13 == .removedPane(0))
        #expect(model.panes.isEmpty)
    }

    @Test func layoutIsARowExceptFourInAGrid() {
        #expect(CompareModel.grid(count: 2, arrangement: .grid) == (2, 1))
        #expect(CompareModel.grid(count: 3, arrangement: .grid) == (3, 1))
        #expect(CompareModel.grid(count: 4, arrangement: .grid) == (2, 2))
        #expect(CompareModel.grid(count: 4, arrangement: .row) == (4, 1))

        let bounds = CGRect(x: 0, y: 0, width: 1001, height: 600)
        let two = CompareModel.frames(count: 2, arrangement: .grid, in: bounds, spacing: 1)
        #expect(two == [CGRect(x: 0, y: 0, width: 500, height: 600), CGRect(x: 501, y: 0, width: 500, height: 600)])
        let four = CompareModel.frames(count: 4, arrangement: .grid, in: CGRect(x: 0, y: 0, width: 802, height: 602),
                                       spacing: 2)
        #expect(four == [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 402, y: 0, width: 400, height: 300),
                         CGRect(x: 0, y: 302, width: 400, height: 300), CGRect(x: 402, y: 302, width: 400, height: 300)])
        let row = CompareModel.frames(count: 4, arrangement: .row, in: CGRect(x: 0, y: 0, width: 406, height: 100),
                                      spacing: 2)
        #expect(row.map(\.minX) == [0, 102, 204, 306])
        #expect(row.allSatisfy { $0.width == 100 && $0.height == 100 })
    }

    @Test func relativeViewCarriesZoomAndCentreAcrossImageSizes() {
        let view = CGSize(width: 1000, height: 800)
        let big = CGSize(width: 6000, height: 4000)    // fits at 1/6
        let small = CGSize(width: 3000, height: 2000)  // fits at 1/3

        // 100% on the big image, looking at its upper-left quarter point.
        let transform = ViewportTransform(zoom: 1, center: CGPoint(x: 1500, y: 1000))
        let relative = RelativeView(transform: transform, isFit: false, imageSize: big, viewSize: view, enlargeSmall: false)
        #expect(!relative.isFit)
        #expect(abs(relative.zoomFactor - 6) < 1e-9)
        #expect(relative.center == CGPoint(x: 0.25, y: 0.25))

        // The same image in the same view comes back unchanged.
        let same = relative.transform(imageSize: big, viewSize: view, enlargeSmall: false)
        #expect(abs(same.zoom - 1) < 1e-9 && same.center == transform.center)
        // A half-size photo: six times its fit is 200%, at the same place.
        let other = relative.transform(imageSize: small, viewSize: view, enlargeSmall: false)
        #expect(abs(other.zoom - 2) < 1e-9)
        #expect(other.center == CGPoint(x: 750, y: 500))

        // Fitted stays fitted.
        let fitted = RelativeView(transform: .bestFit(imageSize: big, viewSize: view), isFit: true, imageSize: big,
                                  viewSize: view, enlargeSmall: false)
        #expect(fitted == .fit)
        #expect(fitted.transform(imageSize: small, viewSize: view, enlargeSmall: false)
                == .bestFit(imageSize: small, viewSize: view))
    }

    @Test func keyboardMap() {
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> CompareKeyCommand? {
            CompareKeyCommand.command(characters: characters, modifiers: modifiers)
        }
        func special(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) -> CompareKeyCommand? {
            key(String(Character(UnicodeScalar(code)!)), modifiers)
        }
        #expect(key("1", .command) == .focus(0))
        #expect(key("4", .command) == .focus(3))
        #expect(key("5", .command) == nil)
        #expect(key("0") == .rate(0))
        #expect(key("5") == .rate(5))
        #expect(key("6") == nil)
        #expect(key("t") == .toggleTag)
        #expect(key("T") == .toggleTag)
        #expect(key("f") == .toggleFullScreen)
        #expect(special(NSCarriageReturnCharacter) == .toggleFullScreen)
        #expect(special(0x1B) == .close)
        #expect(special(NSTabCharacter) == .cycleFocus(backward: false))
        #expect(special(NSBackTabCharacter, .shift) == .cycleFocus(backward: true))
        #expect(special(NSLeftArrowFunctionKey) == .replace(-1))
        #expect(special(NSRightArrowFunctionKey) == .replace(1))
        #expect(special(NSDeleteCharacter) == .trash)
        #expect(special(NSDeleteCharacter, .command) == .trash)
        // Other shortcuts belong to the menu.
        #expect(key("t", .control) == nil)
        #expect(key("3", .option) == nil)
        #expect(special(NSRightArrowFunctionKey).map(\.repeats) == true)
        #expect(key("3").map(\.repeats) == false)
    }
}
