import Testing
import AppKit
import SwiftUI
import MinivuCore
@testable import Minivu

extension AppWindowTests {
    /// Batch Rename through the browser window (never shown), with a catalog
    /// and a settings store of its own.
    @MainActor @Suite(.serialized) struct BatchRenameWindowTests {
        let catalog = Catalog.inMemory()
        /// Removed when the test's suite instance goes.
        let scratchDefaults = ScratchDefaults("minivu-batch-rename-tests")
        var defaults: UserDefaults { scratchDefaults.defaults }

        init() {
            BatchTools.store = BatchStore(defaults: defaults)
            BatchTools.sheets = sheets.presenter
        }

        let sheets = BatchSheetRecorder()

        func makeController() -> BrowserWindowController {
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            return controller
        }

        func settle(_ controller: BrowserWindowController) async {
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }

        func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func names(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        func text(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        func write(_ t: ScratchFolder, _ name: String) throws -> URL {
            let url = t.url.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }

        /// The live plan marks a clash and blocks Rename until it is fixed;
        /// the pattern is remembered once used.
        @Test func previewFlagsClashesAndRemembersThePattern() async throws {
            let t = try ScratchFolder()
            let entries = try ["a.jpg", "b.jpg", "c.jpg", "outside.jpg"].map { try #require(FolderEntry(url: write(t, $0))) }
            let model = BatchRenameModel(entries: Array(entries.prefix(3)), store: BatchTools.store)
            await model.planWork?.value
            #expect(model.plan?.changeCount == 0 && !model.canRename)
            #expect(model.statusText == "The names wouldn’t change.")

            model.pattern = RenamePattern(text: "Trip")
            await model.planWork?.value
            #expect(model.plan?.problemCount == 3 && !model.canRename && model.hasProblems)
            #expect(model.statusText == "3 files would share a name with another file. Every file needs a name of its own.")

            model.pattern = RenamePattern(text: "{name}", find: "a", replacement: "outside")
            await model.planWork?.value
            #expect(model.plan?.items.first?.problem == .taken)
            #expect(model.statusText == "1 file would take the name of an item that isn’t being renamed.")

            model.pattern = RenamePattern(text: "{nmae}")
            await model.planWork?.value
            #expect(model.statusText == "The pattern has an unknown token: {nmae}." && !model.canRename)

            model.pattern = RenamePattern(text: "Trip {##}")
            await model.planWork?.value
            #expect(model.plan?.items.map(\.newName) == ["Trip 01.jpg", "Trip 02.jpg", "Trip 03.jpg"])
            #expect(model.canRename && model.statusText == "3 files will be renamed.")
            #expect(model.beginRenaming()?.count == 3)
            #expect(BatchStore(defaults: defaults).renamePattern == RenamePattern(text: "Trip {##}"))
            #expect(BatchRenameModel(entries: [], store: BatchTools.store).pattern.text == "Trip {##}")
        }

        /// While a batch sheet is up, or a batch runs, the Tools commands that
        /// would open a second sheet are off; a slideshow is still on.
        @Test func toolsThatOpenSheetsWaitForTheSheetAndTheBatch() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try write(t, "a.jpg"), b = try write(t, "b.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            func enabled(_ action: Selector) -> Bool {
                controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
            }
            let sheetTools: [Selector] = [.batchRename, .batchConvert, .printImages, .makeContactSheet, .makeMontage]
            #expect(sheetTools.allSatisfy(enabled))

            controller.batchRename(nil)
            let sheet = try #require(sheets.shown.last)
            #expect(!sheetTools.contains(where: enabled), "no second sheet while the rename sheet is up")
            #expect(enabled(.startSlideshow))
            let host = try #require(sheet.contentView as? NSHostingView<BatchRenameView>)
            host.rootView.onCancel()
            #expect(sheets.shown.isEmpty)
            #expect(sheetTools.allSatisfy(enabled))

            controller.performBatchRename([BatchRenamer.Request(url: a, newName: "c.jpg"),
                                           BatchRenamer.Request(url: b, newName: "d.jpg")], actionName: "Rename 2 Items")
            #expect(!enabled(.batchRename) && !enabled(.batchConvert), "not while the batch runs")
            await controller.batchWork?.value
            #expect(enabled(.batchRename) && enabled(.batchConvert))
        }

        /// The sheet renames the selection off the main thread (a swap and a
        /// case-only rename among them), selects the files under their new
        /// names, keeps Custom Order places, and one Undo restores every name.
        @Test func renamesThroughTheSheetWithOneUndo() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try write(t, "a.jpg"), b = try write(t, "b.jpg"), c = try write(t, "IMG.JPG")
            _ = try write(t, "other.jpg")
            catalog.setCustomOrder(["other.jpg", "b.jpg", "IMG.JPG", "a.jpg"], in: t.url)
            catalog.setRating(5, for: [a])
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)
            controller.model.setSelection([a, b, c], lead: a)
            #expect(controller.validateMenuItem(NSMenuItem(title: "", action: .batchRename, keyEquivalent: "")))

            controller.batchRename(nil)
            let sheet = try #require(sheets.shown.last)
            let host = try #require(sheet.contentView as? NSHostingView<BatchRenameView>)
            let model = host.rootView.model
            // Grid order: by name, as Finder sorts (letter case aside).
            #expect(model.entries.map(\.name) == ["a.jpg", "b.jpg", "IMG.JPG"])
            model.pattern = RenamePattern(text: "{name}", find: "a", replacement: "b")
            await model.planWork?.value
            #expect(!model.canRename, "b.jpg would get the name twice")

            // Swap a and b by name; lower the case of IMG.JPG.
            model.pattern = RenamePattern(text: "{name}", nameCase: .lower, extensionCase: .lower)
            await model.planWork?.value
            #expect(model.plan?.changeCount == 1)
            host.rootView.onRename()
            await controller.batchWork?.value
            await settle(controller)
            #expect(names(t.url) == ["a.jpg", "b.jpg", "img.jpg", "other.jpg"])
            #expect(sheets.shown.isEmpty, "the sheet closes when done")

            let swap = [BatchRenamer.Request(url: a, newName: "b.jpg"), BatchRenamer.Request(url: b, newName: "a.jpg")]
            controller.performBatchRename(swap, actionName: BatchRenameModel.actionName(count: 2))
            await controller.batchWork?.value
            await settle(controller)
            #expect(text(t.url.appendingPathComponent("a.jpg")) == "b.jpg" && text(t.url.appendingPathComponent("b.jpg")) == "a.jpg")
            #expect(catalog.marks(for: t.url.appendingPathComponent("b.jpg")).rating == 5, "stars follow the file")
            #expect(catalog.customOrder(in: t.url) == ["other.jpg", "a.jpg", "img.jpg", "b.jpg"])
            await waitUntil { Set(controller.model.selection.map(\.lastPathComponent)) == ["a.jpg", "b.jpg"] }
            #expect(Set(controller.model.selection.map(\.lastPathComponent)) == ["a.jpg", "b.jpg"])

            let undo = try #require(controller.window?.undoManager)
            #expect(undo.undoActionName == "Rename 2 Items")
            undo.undo()
            await controller.batchWork?.value
            #expect(text(a) == "a.jpg" && text(b) == "b.jpg")
            #expect(catalog.customOrder(in: t.url) == ["other.jpg", "b.jpg", "img.jpg", "a.jpg"])
            #expect(undo.canRedo && undo.redoActionName == "Rename 2 Items")
            undo.redo()
            await controller.batchWork?.value
            #expect(text(a) == "b.jpg" && text(b) == "a.jpg")
            // And the first batch: undoing both steps gives IMG.JPG back.
            undo.undo()
            await controller.batchWork?.value
            undo.undo()
            await controller.batchWork?.value
            #expect(names(t.url) == ["IMG.JPG", "a.jpg", "b.jpg", "other.jpg"])
        }

        /// Undo and redo pressed quickly, before the work of the step before
        /// has finished, wait for it: redo still knows the names to put back,
        /// and two renames of the same files never run at once.
        @Test func quickUndoAndRedoWaitForEachOther() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try write(t, "a.jpg"), b = try write(t, "b.jpg")
            let controller = makeController()
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await settle(controller)

            controller.performBatchRename([BatchRenamer.Request(url: a, newName: "one.jpg"),
                                           BatchRenamer.Request(url: b, newName: "two.jpg")],
                                          actionName: BatchRenameModel.actionName(count: 2))
            await controller.batchWork?.value
            #expect(names(t.url) == ["one.jpg", "two.jpg"])
            let undo = try #require(controller.window?.undoManager)

            // No waiting in between.
            undo.undo()
            #expect(controller.isRunningBatch)
            undo.redo()
            undo.undo()
            undo.redo()
            await controller.batchWork?.value
            #expect(!controller.isRunningBatch)
            #expect(names(t.url) == ["one.jpg", "two.jpg"])
            #expect(text(t.url.appendingPathComponent("one.jpg")) == "a.jpg")
            #expect(undo.canUndo && undo.undoActionName == "Rename 2 Items")
            undo.undo()
            await controller.batchWork?.value
            #expect(names(t.url) == ["a.jpg", "b.jpg"])
        }

        /// Big batches: the plan for 5000 files comes off the main thread.
        @Test func plansALargeBatchOffTheMainThread() async throws {
            let names = (0..<5000).map { String(format: "IMG_%04d.JPG", $0) }
            let existing = Set(names.map { "/tmp/big/" + $0.lowercased() })
            // The files need not exist: the plan asks this pretend disk.
            let probe = BatchFileProbe(identity: { url in
                let path = url.path.lowercased()
                return existing.contains(path) ? BatchItemIdentity(device: 1, inode: UInt64(abs(path.hashValue))) : nil
            }, isCaseSensitive: { _ in false })
            let entries = names.map { name in
                FolderEntry(url: URL(fileURLWithPath: "/tmp/big/" + name), name: name, isDirectory: false, kind: .raster,
                            fileSize: 0, modified: Date(), created: Date())
            }
            let model = BatchRenameModel(entries: entries, store: BatchTools.store, probe: probe)
            await model.planWork?.value
            let started = Date()
            model.pattern = RenamePattern(text: "Holiday {####}")
            // Generous: the margin is for a busy test machine.
            #expect(Date().timeIntervalSince(started) < 0.25, "setting the pattern doesn't plan on the main thread")
            await model.planWork?.value
            #expect(model.plan?.items.last?.newName == "Holiday 5000.JPG")
            #expect(model.canRename)
        }
    }
}

/// Records the batch sheets instead of animating them onto a window.
@MainActor final class BatchSheetRecorder {
    private(set) var shown: [NSWindow] = []
    private(set) var everShown: [NSWindow] = []

    var presenter: BatchSheetPresenter {
        BatchSheetPresenter(begin: { [unowned self] sheet, _ in
            shown.append(sheet)
            everShown.append(sheet)
        }, end: { [unowned self] sheet, _ in
            shown.removeAll { $0 === sheet }
        })
    }
}
