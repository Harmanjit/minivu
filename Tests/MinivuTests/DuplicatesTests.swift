import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// The duplicate finder's model without a window (G5): scopes, runs,
/// cancelling, the threshold, the keep rule and the marks.
@MainActor @Suite(.serialized) struct DuplicatesModelTests {
    let defaults = ScratchDefaults()

    func entry(_ url: URL) throws -> FolderEntry { try #require(FolderEntry(url: url)) }

    func makeModel(_ source: DuplicateSource, engine: DuplicatesModel.Engine? = nil) throws -> DuplicatesModel {
        let store = try ThumbnailStore.inMemory()
        if let engine { return DuplicatesModel(source: source, store: store, defaults: defaults.defaults, engine: engine) }
        return DuplicatesModel(source: source, store: store, defaults: defaults.defaults)
    }

    func finish(_ model: DuplicatesModel) async {
        await TestTiming.waitUntil(seconds: 30) { model.state == .finished }
    }

    @discardableResult
    func write(_ bytes: [UInt8], _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func scopesFollowWhatTheBrowserShows() throws {
        let folder = URL(fileURLWithPath: "/tmp/Holiday")
        let image = FolderEntry(url: folder.appendingPathComponent("a.jpg"), name: "a.jpg", isDirectory: false,
                                kind: .raster, fileSize: 1, modified: .now, created: .now)
        let plain = DuplicateSource(selection: [], folder: folder)
        #expect(plain.scopes == [.folder, .folderAndSubfolders])
        #expect(plain.title(of: .folderAndSubfolders) == "“Holiday” and Subfolders")
        let selected = DuplicateSource(selection: [image], folder: folder)
        #expect(selected.scopes == [.selection, .folder, .folderAndSubfolders])
        #expect(selected.title(of: .selection) == "Selected Images (1)")
        // A list shown instead of a folder: its images, no tree.
        let list = DuplicateSource(selection: [], folder: nil, listImages: [image])
        #expect(list.scopes == [.folder])
        #expect(list.title(of: .folder) == "Images Shown")

        // The window starts on the selection when there is one, and keeps
        // a scope only while the browser still offers it.
        let model = try makeModel(selected)
        #expect(model.scope == .selection)
        model.scope = .folderAndSubfolders
        model.retarget(list)
        #expect(model.scope == .folder)
    }

    /// This folder looks at its own files; with subfolders, at the tree.
    @Test func exactRunCoversTheChosenScope() async throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        try write([1, 2, 3], "a.jpg", in: t.url)
        try write([1, 2, 3], "b.jpg", in: t.url)
        try write([1, 2, 3], "c.jpg", in: sub)
        try write([4, 5, 6], "d.jpg", in: sub)
        let model = try makeModel(DuplicateSource(selection: [], folder: t.url))
        model.mode = .exact
        model.scope = .folder
        model.start()
        #expect(model.isRunning)
        await finish(model)
        #expect(model.groups.map { $0.files.map(\.name) } == [["a.jpg", "b.jpg"]])
        #expect(model.scanned == 2)

        model.scope = .folderAndSubfolders
        model.start()
        await finish(model)
        #expect(model.groups.map { $0.files.map(\.name) } == [["a.jpg", "b.jpg", "c.jpg"]])
        #expect(model.scanned == 4)
        #expect(model.note == nil)
    }

    @Test func selectionScopeLooksOnlyAtTheSelection() async throws {
        let t = try ScratchFolder()
        let a = try write([7, 7], "a.jpg", in: t.url)
        try write([7, 7], "b.jpg", in: t.url)
        let c = try write([7, 7], "c.jpg", in: t.url)
        let model = try makeModel(DuplicateSource(selection: [try entry(a), try entry(c)], folder: t.url))
        model.mode = .exact
        model.start()
        await finish(model)
        #expect(model.groups.map { $0.files.map(\.name) } == [["a.jpg", "c.jpg"]])
    }

    /// Prints along a line, so distances are known: 0, 0.1, 0.3 and 2 apart.
    nonisolated static func similarOutcome(_ images: [FolderEntry]) -> DuplicatesModel.Outcome {
        let prints = [0, 0.1, 0.4, 2.4].map { FeaturePrint(revision: 2, vector: [Float($0), 0]) }
        var outcome = DuplicatesModel.Outcome(mode: .similar)
        outcome.similarImages = images
        outcome.index = SimilarityIndex(prints: prints, maximumDistance: SimilarityIndex.thresholdRange.upperBound)
        outcome.scanned = images.count
        return outcome
    }

    nonisolated static func files(_ names: [String], sizes: [Int64]) -> [FolderEntry] {
        zip(names, sizes).enumerated().map { i, item in
            FolderEntry(url: URL(fileURLWithPath: "/p/\(item.0)"), name: item.0, isDirectory: false, kind: .raster,
                        fileSize: item.1, modified: Date(timeIntervalSince1970: Double(1000 - i)),
                        created: Date(timeIntervalSince1970: Double(1000 - i)))
        }
    }

    /// Moving the threshold regroups at once, without running again, and
    /// drops marks on files that leave the list.
    @Test func thresholdRegroupsWithoutRunningAgain() async throws {
        let images = Self.files(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], sizes: [10, 20, 30, 40])
        let runs = Tally()
        let model = try makeModel(DuplicateSource(selection: images, folder: nil)) { _, _, _ in
            runs.add()
            return Self.similarOutcome(images)
        }
        model.mode = .similar
        model.threshold = 0.2
        model.start()
        await finish(model)
        #expect(model.groups.map { $0.files.map(\.name) } == [["a.jpg", "b.jpg"]])
        model.marked = [images[1].url]

        model.threshold = 0.5
        #expect(model.groups.map { $0.files.map(\.name) } == [["a.jpg", "b.jpg", "c.jpg"]])
        model.threshold = 0.05
        #expect(model.groups.isEmpty)
        #expect(model.marked.isEmpty)
        #expect(runs.count == 1)
        // Remembered for next time.
        #expect(abs(defaults.defaults.double(forKey: DuplicatesModel.thresholdKey) - 0.05) < 0.0001)
    }

    /// Mark Suggested marks all but each group's keeper by the chosen rule,
    /// so it never marks a whole group; trashed files leave the groups.
    @Test func keepRuleChoosesWhatMarkSuggestedLeaves() async throws {
        let images = Self.files(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], sizes: [10, 30, 20, 40])
        let model = try makeModel(DuplicateSource(selection: images, folder: nil)) { _, _, _ in
            var outcome = Self.similarOutcome(images)
            outcome.pixelSizes = [images[0].url: CGSize(width: 4000, height: 3000),
                                  images[1].url: CGSize(width: 800, height: 600),
                                  images[2].url: CGSize(width: 800, height: 600)]
            return outcome
        }
        model.mode = .similar
        model.threshold = 0.5
        model.start()
        await finish(model)
        let group = try #require(model.groups.first)

        model.keepRule = .highestResolution
        #expect(model.keeper(of: group) == images[0].url)
        model.markSuggested()
        #expect(model.marked == [images[1].url, images[2].url])
        #expect(model.wholeGroupsMarked == 0)

        model.keepRule = .largestFile
        #expect(model.keeper(of: group) == images[1].url)
        model.markSuggested()
        #expect(model.marked == [images[0].url, images[2].url])

        model.keepRule = .oldest
        // c.jpg has the earliest date of the three.
        #expect(model.keeper(of: group) == images[2].url)
        #expect(defaults.defaults.string(forKey: DuplicatesModel.keepRuleKey) == "oldest")

        model.setMarked(images[1].url, true)
        #expect(model.wholeGroupsMarked == 1)
        model.clearMarks()
        #expect(model.marked.isEmpty)

        model.didTrash([images[1].url, images[2].url])
        #expect(model.groups.isEmpty)
        // However the threshold moves, trashed files stay out.
        model.threshold = 0.8
        #expect(model.groups.isEmpty)
    }

    /// Stop ends the run and shows what it found, saying it stopped early.
    @Test func stopShowsWhatWasFound() async throws {
        let images = Self.files(["a.jpg", "b.jpg"], sizes: [5, 5])
        let model = try makeModel(DuplicateSource(selection: images, folder: nil)) { _, cancel, progress in
            progress(DuplicateFinder.Progress(phase: .comparing, done: 1, total: 2))
            while !cancel.isCancelled { usleep(2000) }
            var outcome = DuplicatesModel.Outcome(mode: .exact)
            outcome.exactGroups = [images]
            outcome.isCancelled = true
            return outcome
        }
        model.start()
        await TestTiming.waitUntil { model.state == .running(DuplicateFinder.Progress(phase: .comparing, done: 1, total: 2)) }
        #expect(DuplicatesView.describe(DuplicateFinder.Progress(phase: .comparing, done: 1, total: 2))
                    == "Comparing files of the same size… 1 of 2")
        model.stop()
        await finish(model)
        #expect(model.groups.count == 1)
        #expect(model.note?.hasPrefix("Stopped") == true)
    }

    /// Closing the window mid-run shows nothing afterwards.
    @Test func abandonedRunIsDropped() async throws {
        let images = Self.files(["a.jpg", "b.jpg"], sizes: [5, 5])
        let model = try makeModel(DuplicateSource(selection: images, folder: nil)) { _, cancel, _ in
            while !cancel.isCancelled { usleep(2000) }
            var outcome = DuplicatesModel.Outcome(mode: .exact)
            outcome.exactGroups = [images]
            return outcome
        }
        model.start()
        model.abandon()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.groups.isEmpty)
        #expect(model.isRunning)
    }

    /// The folder alone compares every image in it: its subfolders were
    /// never asked for, so no limit is said to be reached.
    @Test func theFolderScopeSaysNothingOfItsSubfolders() throws {
        let t = try ScratchFolder()
        let sub = try t.folder("Sub")
        try write([1, 2, 3], "a.jpg", in: t.url)
        try write([1, 2, 3], "b.jpg", in: t.url)
        try write([1, 2, 3], "c.jpg", in: sub)
        var request = DuplicatesModel.Request(source: DuplicateSource(selection: [], folder: t.url), scope: .folder,
                                              mode: .exact, maximumSimilarImages: 10, workers: 1, store: nil)
        let alone = DuplicatesModel.find(request, cancel: CancellationFlag()) { _ in }
        #expect(alone.note == nil)
        #expect(alone.scanned == 2 && alone.exactGroups.map { $0.map(\.name) } == [["a.jpg", "b.jpg"]])
        request.scope = .folderAndSubfolders
        let tree = DuplicatesModel.find(request, cancel: CancellationFlag()) { _ in }
        #expect(tree.note == nil && tree.scanned == 3)
    }

    /// Stop after the comparing: the groups found come back at once, without
    /// reading every grouped image's header for its dimensions.
    @Test func stopSkipsReadingPixelSizes() throws {
        let t = try ScratchFolder()
        let a = try t.jpeg("a.jpg", width: 64, height: 48)
        try FileManager.default.copyItem(at: a, to: t.url.appendingPathComponent("b.jpg"))
        let request = DuplicatesModel.Request(source: DuplicateSource(selection: [], folder: t.url), scope: .folder,
                                              mode: .exact, maximumSimilarImages: 10, workers: 1, store: nil)
        let whole = DuplicatesModel.find(request, cancel: CancellationFlag()) { _ in }
        #expect(whole.pixelSizes.count == 2)
        let cancel = CancellationFlag()
        let stopped = DuplicatesModel.find(request, cancel: cancel) { progress in
            if progress.total > 0, progress.done == progress.total { cancel.cancel() }
        }
        #expect(stopped.isCancelled && stopped.exactGroups.count == 1)
        #expect(stopped.pixelSizes.isEmpty)
    }

    /// After Stop the model reads the shown files' dimensions itself, so
    /// Highest Resolution keeps the bigger picture, not the bigger file,
    /// and suggests nothing (Mark Suggested waits) until they are read.
    @Test func highestResolutionAfterStopReadsTheShownSizes() async throws {
        let t = try ScratchFolder()
        let urls = [try t.jpeg("a.jpg", width: 64, height: 48), try t.jpeg("b.jpg", width: 32, height: 24),
                    try t.jpeg("c.jpg", width: 16, height: 12), try t.jpeg("d.jpg", width: 16, height: 12)]
        // The smaller picture is the bigger file, as a PNG of a half-size copy can be.
        let images = zip(urls, [10, 40, 20, 30] as [Int64]).map { url, size in
            FolderEntry(url: url, name: url.lastPathComponent, isDirectory: false, kind: .raster, fileSize: size,
                        modified: Date(timeIntervalSince1970: 1000), created: Date(timeIntervalSince1970: 1000))
        }
        let model = try makeModel(DuplicateSource(selection: images, folder: nil)) { _, _, _ in
            var outcome = Self.similarOutcome(images)
            outcome.isCancelled = true
            return outcome
        }
        model.mode = .similar
        model.keepRule = .highestResolution
        model.threshold = 0.2
        model.start()
        await finish(model)
        let group = try #require(model.groups.first)
        #expect(group.files.map(\.name) == ["a.jpg", "b.jpg"])
        // Never a guess by file size while the headers are read.
        if !model.sizesBeingRead.isEmpty {
            #expect(model.isWaitingForSizes && model.keeper(of: group) == nil)
            model.markSuggested()
            #expect(model.marked.isEmpty)
        }
        await TestTiming.waitUntil(seconds: 10) { model.sizesBeingRead.isEmpty }
        #expect(!model.isWaitingForSizes)
        #expect(model.pixelSizes.count == 2)
        #expect(model.keeper(of: group) == images[0].url)
        model.markSuggested()
        #expect(model.marked == [images[1].url])

        // A wider threshold shows c.jpg, whose size is read in turn.
        model.threshold = 0.5
        await TestTiming.waitUntil(seconds: 10) { model.sizesBeingRead.isEmpty }
        #expect(model.pixelSizes[images[2].url] == CGSize(width: 16, height: 12))
    }

    /// The real search on synthetic pictures: a resized copy groups with its
    /// original, and a different picture doesn't; the note explains a
    /// memory cap.
    @Test func similarRunGroupsAResizedCopy() async throws {
        let t = try ScratchFolder()
        try t.jpeg("flat.jpg", width: 800, height: 600)
        try t.jpeg("flat small.jpg", width: 400, height: 300)
        let model = try makeModel(DuplicateSource(selection: [], folder: t.url))
        model.mode = .similar
        model.threshold = SimilarityIndex.defaultThreshold
        model.scope = .folder
        model.start()
        await finish(model)
        #expect(model.groups.map { Set($0.files.map(\.name)) } == [["flat.jpg", "flat small.jpg"]])
        #expect(model.pixelSizes.values.contains(CGSize(width: 800, height: 600)))

        var request = DuplicatesModel.Request(source: DuplicateSource(selection: [], folder: t.url), scope: .folder,
                                              mode: .similar, maximumSimilarImages: 1, workers: 1, store: nil)
        let capped = DuplicatesModel.find(request, cancel: CancellationFlag()) { _ in }
        #expect(capped.similarImages.count == 1)
        #expect(capped.note?.contains("first 1 images") == true)
        request.mode = .exact
        #expect(DuplicatesModel.find(request, cancel: CancellationFlag()) { _ in }.exactGroups.isEmpty)
    }
}

/// A count closures on other threads can add to.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

extension AppWindowTests {
    /// The Find Duplicates window and its commands: the browser's menu item,
    /// the Trash (always into a test folder, never the user's Trash), Show
    /// in Browser and Compare.
    @MainActor @Suite(.serialized) struct DuplicatesWindowTests {
        let catalog = Catalog.inMemory()
        let defaults = ScratchDefaults()

        func makeBrowser() -> BrowserWindowController {
            let controller = BrowserWindowController(catalog: catalog)
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            return controller
        }

        func settle(_ controller: BrowserWindowController) async {
            var awaited: Task<Void, Never>?
            repeat {
                awaited = controller.model.work
                await awaited?.value
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            } while controller.model.work != awaited
        }

        func menuItem(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        /// Three copies of one file and two of another in a scratch folder,
        /// found by the real search.
        func finder(in t: ScratchFolder, browser: BrowserWindowController?) async throws -> DuplicatesWindowController {
            for name in ["a.jpg", "b.jpg", "c.jpg"] { try Data([1, 2, 3, 4]).write(to: t.url.appendingPathComponent(name)) }
            for name in ["d.png", "e.png"] { try Data([9, 9]).write(to: t.url.appendingPathComponent(name)) }
            let model = DuplicatesModel(source: DuplicateSource(selection: [], folder: t.url),
                                        store: try ThumbnailStore.inMemory(), defaults: defaults.defaults)
            model.mode = .exact
            model.keepRule = .highestResolution
            let controller = DuplicatesWindowController(model: model, browser: browser)
            model.start()
            await TestTiming.waitUntil(seconds: 30) { model.state == .finished }
            return controller
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        /// A file of the results by name, spelt as the search found it.
        func found(_ name: String, in controller: DuplicatesWindowController) throws -> URL {
            try #require(controller.model.allFiles.first { $0.name == name }).url
        }

        @Test func browserOpensTheFinderOnWhatItShows() async throws {
            let t = try ScratchFolder()
            try t.file("a.jpg")
            let browser = makeBrowser()
            defer { browser.close() }
            #expect(!browser.validateMenuItem(menuItem(.findDuplicates)))
            browser.open(folder: t.url)
            await settle(browser)
            #expect(browser.validateMenuItem(menuItem(.findDuplicates)))
            browser.model.select(t.url.appendingPathComponent("a.jpg"))
            let source = browser.duplicateSource
            #expect(source.folder == t.url)
            #expect(source.selection.map(\.name) == ["a.jpg"])
            #expect(source.scopes == [.selection, .folder, .folderAndSubfolders])

            let window = DuplicatesWindowController.show(source: source, browser: browser, store: try ThumbnailStore.inMemory())
            defer { window.close() }
            #expect(DuplicatesWindowController.current === window)
            #expect(window.model.scope == .selection)
            #expect(window.window?.contentViewController != nil)
            // Asking again points the same window at the browser's state.
            browser.model.setSelection([], lead: nil)
            #expect(DuplicatesWindowController.show(source: browser.duplicateSource, browser: browser) === window)
            #expect(window.model.scope == .folder)
            window.close()
            #expect(DuplicatesWindowController.current == nil)
        }

        /// Nothing moves until the user confirms; confirmed, the marked
        /// files go through the write queue's Trash (a test folder here) and
        /// leave the groups.
        @Test func markedFilesGoToTheTrashOnlyWhenConfirmed() async throws {
            let t = try ScratchFolder()
            let bin = try AppWindowTests.TrashSafetyTests.Bin(in: t)
            defer { bin.restore() }
            let savedPrompt = DuplicatePrompts.confirmTrash
            defer { DuplicatePrompts.confirmTrash = savedPrompt }
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
            let controller = try await finder(in: t, browser: nil)
            defer { controller.close() }
            #expect(controller.model.groups.map { $0.files.map(\.name) } == [["a.jpg", "b.jpg", "c.jpg"], ["d.png", "e.png"]])

            // Nothing marked: nothing asked.
            var asked: [(Int, Int)] = []
            var answer = false
            DuplicatePrompts.confirmTrash = { _, count, whole, reply in
                asked.append((count, whole))
                reply(answer)
            }
            controller.moveMarkedToTrash()
            #expect(asked.isEmpty)

            // Exact copies tie: the oldest, then the first by path, stays.
            controller.model.markSuggested()
            #expect(Set(controller.model.marked.map(\.lastPathComponent)) == ["b.jpg", "c.jpg", "e.png"])
            controller.moveMarkedToTrash()
            #expect(asked.count == 1 && asked[0] == (3, 0))
            await FileWriteQueue.shared.waitUntilIdle()
            #expect(bin.names.isEmpty)
            #expect(exists(t.url.appendingPathComponent("b.jpg")))

            answer = true
            controller.model.setMarked(try found("d.png", in: controller), true)
            controller.moveMarkedToTrash()
            #expect(asked.last! == (4, 1))
            await TestTiming.waitUntil { !controller.isTrashing && controller.model.marked.isEmpty }
            #expect(bin.names.sorted() == ["b.jpg", "c.jpg", "d.png", "e.png"])
            #expect(exists(t.url.appendingPathComponent("a.jpg")))
            #expect(!exists(t.url.appendingPathComponent("b.jpg")))
            // Groups left with one file leave the list.
            #expect(controller.model.groups.isEmpty)
        }

        /// A copy trashed from a subfolder takes only itself out of the
        /// browser, never the shown folder's file of the same name, and the
        /// catalog hears of the move: the copy leaves its collection, and
        /// the collection's count, at once.
        @Test func trashingACopyInASubfolderKeepsItsNamesakeAndLeavesItsCollection() async throws {
            let t = try ScratchFolder()
            let bin = try AppWindowTests.TrashSafetyTests.Bin(in: t, name: ".Trash")
            defer { bin.restore() }
            let savedCatalog = FileWriteQueue.shared.catalog
            FileWriteQueue.shared.catalog = catalog
            defer { FileWriteQueue.shared.catalog = savedCatalog }
            let savedPrompt = DuplicatePrompts.confirmTrash
            defer { DuplicatePrompts.confirmTrash = savedPrompt }
            DuplicatePrompts.confirmTrash = { _, _, _, reply in reply(true) }
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }

            let sub = try t.folder("Sub")
            let original = t.url.appendingPathComponent("a.jpg"), copy = sub.appendingPathComponent("a.jpg")
            try Data([1, 2, 3, 4]).write(to: original)
            try Data([1, 2, 3, 4]).write(to: copy)
            let id = try #require(catalog.createCollection(named: "Keep"))
            catalog.addToCollection(id, urls: [original, copy])

            let browser = makeBrowser()
            defer { browser.close() }
            browser.open(folder: t.url)
            await settle(browser)
            #expect(browser.model.entries.filter { !$0.isDirectory }.map(\.name) == ["a.jpg"])

            let model = DuplicatesModel(source: DuplicateSource(selection: [], folder: t.url),
                                        store: try ThumbnailStore.inMemory(), defaults: defaults.defaults)
            model.mode = .exact
            model.scope = .folderAndSubfolders
            let controller = DuplicatesWindowController(model: model, browser: browser)
            defer { controller.close() }
            model.start()
            await TestTiming.waitUntil(seconds: 30) { model.state == .finished }
            #expect(model.groups.map { $0.files.count } == [2])
            let found = try #require(model.allFiles.first { $0.url.deletingLastPathComponent().lastPathComponent == "Sub" })
            model.setMarked(found.url, true)
            controller.moveMarkedToTrash()
            await TestTiming.waitUntil { !controller.isTrashing && model.marked.isEmpty }

            #expect(bin.names == ["a.jpg"])
            #expect(exists(original) && !exists(copy))
            #expect(browser.model.entries.filter { !$0.isDirectory }.map(\.name) == ["a.jpg"])
            #expect(catalog.collections().first?.count == 1)
            #expect(catalog.collectionMembers(id).map { $0.resolvingSymlinksInPath().path }
                    == [original.resolvingSymlinksInPath().path])
        }

        /// The selected files, or every file found, open as a list in the
        /// browser; Back returns to the folder.
        @Test func showInBrowserOpensAListAndCompareTakesTheSelection() async throws {
            let t = try ScratchFolder()
            let browser = makeBrowser()
            defer { browser.close() }
            browser.open(folder: t.url)
            await settle(browser)
            let controller = try await finder(in: t, browser: browser)
            defer { controller.close() }
            // The list lays out with its groups.
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            controller.showInBrowser()
            await settle(browser)
            guard case .files(let urls)? = browser.model.list?.kind else {
                Issue.record("not a list of files")
                return
            }
            #expect(urls.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "c.jpg", "d.png", "e.png"])
            #expect(browser.model.entries.count == 5)
            #expect(browser.window?.title == "Duplicates")

            controller.model.selection = [try found("e.png", in: controller), try found("a.jpg", in: controller)]
            controller.showInBrowser()
            await settle(browser)
            #expect(browser.model.entries.map(\.name) == ["a.jpg", "e.png"])
            browser.model.goBack()
            browser.model.goBack()
            await settle(browser)
            #expect(browser.model.folder == t.url)

            #expect(controller.canCompare)
            controller.compareSelected()
            let compare = try #require(CompareWindowController.current)
            #expect(compare.model.panes.map(\.name) == ["a.jpg", "e.png"])
            compare.close()
            controller.model.selection = [try found("a.jpg", in: controller)]
            #expect(!controller.canCompare)
        }
    }
}
