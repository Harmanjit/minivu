import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
@testable import Minivu

/// Edit Metadata's sheet model: mixed values, keywords for several files,
/// the date and the location (G1).
@MainActor @Suite struct MetadataEditorModelTests {
    func model(_ fields: [MetadataFields]) -> MetadataEditorModel {
        MetadataEditorModel(urls: fields.indices.map { URL(fileURLWithPath: "/tmp/meta/\($0).jpg") }, fields: fields)
    }

    @Test func fieldsThatDifferAreMixedAndOnlyChangesAreWritten() {
        let m = model([MetadataFields(title: "Paris", caption: "same", copyright: "c", keywords: ["a"]),
                       MetadataFields(title: "Rome", caption: "same", copyright: "c", keywords: ["a"])])
        #expect(m.title.isMixed && !m.caption.isMixed)
        #expect(m.caption.text == "same" && m.title.text.isEmpty)
        #expect(m.edit.isEmpty && !m.hasChanges)

        // A mixed field left empty keeps each file's own value.
        m.caption.text = "new for both"
        #expect(m.edit == MetadataEdit(caption: "new for both"))
        m.title.text = "  Europe "
        #expect(m.edit.title == "Europe")
        m.title.text = ""
        #expect(m.edit.title == nil)
        // Clearing every file's is a choice of its own.
        m.title.isCleared = true
        #expect(m.edit.title == "")
        // An unmixed field put back as it was is no change.
        m.caption.text = "same"
        #expect(m.edit.caption == nil)
        m.copyright.text = ""
        #expect(m.edit.copyright == "")
    }

    @Test func keywordsAreAddedToAndRemovedFromEveryFile() {
        let m = model([MetadataFields(keywords: ["paris", "night"]), MetadataFields(keywords: ["paris"]),
                       MetadataFields(keywords: ["rome"])])
        #expect(m.keywords.map(\.name) == ["night", "paris", "rome"])
        #expect(m.keywords.map(\.count) == [1, 2, 1])

        m.toggleRemoved(m.keywords[2])                     // rome goes from every file
        m.toggleAddedToAll(m.keywords[1])                  // paris reaches the third
        m.keywordEntry = "Seine,  river , PARIS, seine"
        m.commitKeywordEntry()
        #expect(m.keywordEntry.isEmpty)
        #expect(m.newKeywords == ["Seine", "river"])
        #expect(m.edit.addedKeywords == ["Seine", "river", "paris"])
        #expect(m.edit.removedKeywords == ["rome"])
        // Each file keeps its others.
        #expect(m.edit.keywords(applyingTo: ["paris", "night"]) == ["paris", "night", "Seine", "river"])
        #expect(m.edit.keywords(applyingTo: ["rome"]) == ["Seine", "river", "paris"])

        m.removeNewKeyword("river")
        m.toggleRemoved(m.keywords[2])
        #expect(m.edit.removedKeywords.isEmpty && m.edit.addedKeywords == ["Seine", "paris"])
    }

    @Test func dateShiftAndSet() {
        let taken = WallClock(year: 2024, month: 5, day: 1, hour: 14, minute: 30)
        let m = model([MetadataFields(dateTaken: taken)])
        #expect(m.dateDescription == WallClock.formatted(taken))
        #expect(m.dateChange == nil && m.newDateDescription == nil)
        m.dateMode = .shift
        #expect(m.dateChange == nil)   // a shift of nothing
        m.shiftLater = false
        m.shiftDays = 1
        m.shiftHours = 2
        m.shiftMinutes = 3
        m.shiftSeconds = 4
        #expect(m.dateChange == .shift(seconds: -(86_400 + 2 * 3600 + 3 * 60 + 4)))
        #expect(m.newDateDescription == WallClock.formatted(WallClock(year: 2024, month: 4, day: 30, hour: 12, minute: 26, second: 56)))
        m.dateMode = .set
        #expect(m.setDate == taken.date)
        m.setDate = WallClock(year: 2000, month: 1, day: 1).date
        #expect(m.edit.date == .set(WallClock(year: 2000, month: 1, day: 1)))

        let mixed = model([MetadataFields(dateTaken: taken), MetadataFields()])
        #expect(mixed.dateDescription == "Mixed (some files have none)")
        mixed.dateMode = .shift
        mixed.shiftHours = 1
        #expect(mixed.newDateDescription == nil && mixed.dateChange == .shift(seconds: 3600))
    }

    @Test func removeLocationOnlyWhenThereIsOne() {
        let none = model([MetadataFields(), MetadataFields()])
        none.removeLocation = true
        #expect(none.locatedCount == 0 && !none.edit.removeLocation)
        let some = model([MetadataFields(hasLocation: true), MetadataFields()])
        some.removeLocation = true
        #expect(some.locatedCount == 1 && some.edit == MetadataEdit(removeLocation: true))
    }
}

/// Writing one edit to a selection: mixed values kept, sidecars, Cancel,
/// failures and the summary.
@Suite struct MetadataBatchTests {
    func tagged(_ name: String, title: String, keywords: [String], in folder: ScratchFolder) throws -> URL {
        let url = try folder.jpeg(name, width: 40, height: 20)
        try MetadataWriter.apply(MetadataEdit(title: title, addedKeywords: keywords), to: url)
        return url
    }

    @Test func aBatchWithMixedValuesKeepsEachFilesOwn() async throws {
        let t = try ScratchFolder()
        let a = try tagged("a.jpg", title: "Paris", keywords: ["night", "old"], in: t)
        let b = try tagged("b.jpg", title: "Rome", keywords: ["old"], in: t)
        let gif = t.url.appendingPathComponent("c.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 1, nil))
        let source = try #require(CGImageSourceCreateWithURL(a as CFURL, nil))
        CGImageDestinationAddImage(destination, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), nil)
        #expect(CGImageDestinationFinalize(destination))
        let pdf = try t.file("d.pdf")
        let gifBytes = try Data(contentsOf: gif)

        let (writable, skipped) = MetadataBatch.partition([a, b, gif, pdf])
        #expect(writable == [a, b, gif] && skipped == [pdf])
        #expect(MetadataBatch.touchedFiles(writable) == [a, b, gif, t.url.appendingPathComponent("c.xmp")])
        let edit = MetadataEdit(copyright: "© Us", addedKeywords: ["trip"], removedKeywords: ["old"])
        let outcome = await MetadataBatch.run(edit, on: writable, skipped: skipped)
        #expect(outcome.rewritten == [a, b] && outcome.sidecars == [gif] && outcome.skipped == [pdf])
        #expect(outcome.failed.isEmpty && !outcome.wasCancelled)

        let fa = MetadataFields.read(from: a), fb = MetadataFields.read(from: b), fc = MetadataFields.read(from: gif)
        #expect(fa.title == "Paris" && fb.title == "Rome")
        #expect(fa.keywords == ["night", "trip"] && fb.keywords == ["trip"] && fc.keywords == ["trip"])
        #expect([fa, fb, fc].allSatisfy { $0.copyright == "© Us" })
        #expect(try Data(contentsOf: gif) == gifBytes)

        let summary = try #require(MetadataBatch.summary(for: outcome))
        #expect(summary.title == "1 file was skipped.")
        #expect(summary.detail == "3 files updated.\n\nMetadata can’t be written for these files:\nd.pdf")
    }

    @Test func cancelLeavesOnlyWholeFiles() async throws {
        let t = try ScratchFolder()
        let urls = try (0..<4).map { try t.jpeg("\($0).jpg", width: 40, height: 20) }
        let before = try urls.map { try Data(contentsOf: $0) }
        let started = Counter()
        let outcome = await MetadataBatch.run(MetadataEdit(title: "Cancelled"), on: urls,
                                              isCancelled: { await started.value >= 2 },
                                              starting: { _ in await started.increment() })
        #expect(outcome.wasCancelled && outcome.rewritten == Array(urls.prefix(2)))
        for (index, url) in urls.enumerated() {
            if index < 2 {
                #expect(MetadataFields.read(from: url).title == "Cancelled")
            } else {
                #expect(try Data(contentsOf: url) == before[index])
            }
        }
    }

    @Test func failuresAndNotesAreSummarised() async throws {
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/meta/\($0).jpg") }
        let raw = URL(fileURLWithPath: "/tmp/meta/r.nef")
        let outcome = await MetadataBatch.run(MetadataEdit(date: .shift(seconds: 60), removeLocation: true),
                                              on: urls + [raw], apply: { _, url in
            switch url.lastPathComponent {
            case "1.jpg": throw MetadataWriter.Error.copyFailed("disk full")
            case "2.jpg": return .init(written: url, usedSidecar: false, hadNoDateToShift: true)
            case "r.nef": return .init(written: url.deletingPathExtension().appendingPathExtension("xmp"), usedSidecar: true,
                                       locationLeftInFile: true)
            default: return .init(written: url, usedSidecar: false)
            }
        })
        #expect(outcome.rewritten == [urls[0], urls[2]] && outcome.sidecars == [raw])
        #expect(outcome.failed == [.init(url: urls[1], reason: "The metadata couldn’t be written (disk full).")])
        let summary = try #require(MetadataBatch.summary(for: outcome))
        #expect(summary.title == "1 file couldn’t be updated.")
        #expect(summary.detail.contains("1.jpg: The metadata couldn’t be written (disk full)."))
        #expect(summary.detail.contains("stays in this camera raw file, which minivu never modifies:\nr.nef"))
        #expect(summary.detail.contains("This file has no date taken to shift:\n2.jpg"))
        #expect(MetadataBatch.summary(for: .init(rewritten: urls)) == nil)
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

extension AppWindowTests {
    /// Edit Metadata from the browser and the viewer: validation, the
    /// unsaved-edits question, the write and what is shown afterwards.
    @MainActor @Suite(.serialized, .batchToolsReset) struct MetadataWindowTests {
        let sheets = BatchSheetRecorder()

        init() {
            _ = NSApplication.shared
            BatchTools.sheets = sheets.presenter
        }

        func settle(_ controller: BrowserWindowController) async {
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        func valid(_ controller: BrowserWindowController, _ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        @Test func theBrowserEditsItsSelection() async throws {
            let t = try ScratchFolder()
            let folder = try t.folder("Sub")
            let a = try t.jpeg("a.jpg", width: 40, height: 20)
            let b = try t.jpeg("b.jpg", width: 40, height: 20)
            try MetadataWriter.apply(MetadataEdit(title: "Only a"), to: a)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await settle(controller)

            controller.model.select(folder)
            #expect(!valid(controller, .editMetadata))
            controller.model.setSelection([a, b, folder], lead: a)
            #expect(valid(controller, .editMetadata))

            func modified(_ name: String) -> Date? { controller.model.entries.first { $0.name == name }?.modified }
            let modifiedBefore = try #require(modified("b.jpg"))
            let stub = MetadataSheetStub(answer: MetadataEdit(caption: "Both", addedKeywords: ["k"]))
            defer { stub.restore() }
            controller.editMetadata(nil)
            await TestTiming.waitUntil { !stub.models.isEmpty }
            await MetadataEditor.work?.value
            await settle(controller)
            let model = try #require(stub.models.first)
            #expect(model.urls.map(\.lastPathComponent) == ["a.jpg", "b.jpg"] && model.title.isMixed)
            // Two files: the progress sheet came and went.
            #expect(sheets.everShown.count == 1 && sheets.shown.isEmpty)
            #expect(MetadataFields.read(from: a).title == "Only a" && MetadataFields.read(from: b).title.isEmpty)
            #expect(MetadataFields.read(from: a).caption == "Both" && MetadataFields.read(from: b).keywords == ["k"])
            #expect(MetadataRevisions.shared.revision(of: b) > 0)
            await TestTiming.waitUntil { modified("b.jpg") != modifiedBefore }
            #expect(modified("b.jpg") != modifiedBefore)

            // Nothing is edited under a sheet.
            let window = try #require(controller.window)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
            window.beginSheet(sheet, completionHandler: nil)
            defer { window.endSheet(sheet) }
            #expect(!valid(controller, .editMetadata))
        }

        @Test func cancellingTheSheetWritesNothing() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 40, height: 20)
            let bytes = try Data(contentsOf: a)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.select(a)
            let stub = MetadataSheetStub(answer: nil)
            defer { stub.restore() }
            controller.editMetadata(nil)
            await TestTiming.waitUntil { !stub.models.isEmpty }
            await FileWriteQueue.shared.waitUntilIdle()
            #expect(stub.models.count == 1)
            #expect(try Data(contentsOf: a) == bytes)
        }

        @Test func theViewerAsksAboutUnsavedEditsFirstAndRestampsItsEntry() async throws {
            let folder = try ScratchFolder()
            let url = try folder.jpeg("a.jpg", width: 600, height: 400)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(viewer.validateMenuItem(NSMenuItem(title: "", action: .editMetadata, keyEquivalent: "")))

            viewer.rotateRight(nil)
            #expect(viewer.hasUnsavedEdits)
            let savedQuestion = ViewerWindowController.askAboutUnsavedEdits
            defer { ViewerWindowController.askAboutUnsavedEdits = savedQuestion }
            var answer = UnsavedEditsChoice.cancel
            var asked = 0
            ViewerWindowController.askAboutUnsavedEdits = { _, _, reply in
                asked += 1
                reply(answer)
            }
            let stub = MetadataSheetStub(answer: MetadataEdit(title: "From the viewer"))
            defer { stub.restore() }
            // Cancel: no sheet, nothing written, the edits stay.
            viewer.editMetadata(nil)
            #expect(asked == 1 && stub.models.isEmpty && viewer.hasUnsavedEdits)

            answer = .discard
            viewer.editMetadata(nil)
            #expect(asked == 2 && viewer.editSession == nil)
            await TestTiming.waitUntil { !stub.models.isEmpty }
            await MetadataEditor.work?.value
            #expect(MetadataFields.read(from: url).title == "From the viewer")
            let stamp = ExternalEditWatcher.stamp(of: url)
            await TestTiming.waitUntil { viewer.model.current?.modified == stamp.modified }
            #expect(viewer.model.current?.modified == stamp.modified)
            #expect(viewer.model.current?.fileSize == stamp.size.map(Int64.init))
        }
    }
}

/// Answers Edit Metadata's sheet with a set edit and records what it was
/// shown; the summary alert is swallowed.
@MainActor final class MetadataSheetStub {
    private(set) var models: [MetadataEditorModel] = []
    private let savedAsk = MetadataEditor.askForEdit
    private let savedSummary = MetadataEditor.showSummary

    init(answer: MetadataEdit?) {
        MetadataEditor.askForEdit = { [unowned self] model, _, reply in
            models.append(model)
            reply(answer)
        }
        MetadataEditor.showSummary = { _, _, _ in }
    }

    func restore() {
        MetadataEditor.askForEdit = savedAsk
        MetadataEditor.showSummary = savedSummary
    }
}
