import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// Windows opened and closed over and over, as a long session does: each
    /// must let go of everything it made (controllers, windows, canvases,
    /// edit sessions, tool states), or display links, observers and textures
    /// would pile up behind windows that are gone.
    @MainActor @Suite(.serialized) struct WindowReleaseTests {
        init() { _ = NSApplication.shared }

        func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Lets queued main-thread work (work items, tasks delivering to
        /// closed windows) run, so what it captured is released.
        func drain() async {
            for _ in 0..<5 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func jpegs(_ names: [String], in folder: ScratchFolder) throws -> [FolderEntry] {
            try names.map { try #require(FolderEntry(url: try folder.jpeg($0, width: 600, height: 400))) }
        }

        /// Every tool in the viewer's tools panel, opened on a decoded image
        /// and closed again, then the viewer closed: nothing of it survives.
        @Test func viewerWithEveryToolIsFreed() async throws {
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg"], in: folder)
            let actions = ViewerToolsPanel.groups.flatMap(\.tools).compactMap(\.action)
            #expect(actions.count >= 20)

            weak var viewer: ViewerWindowController?
            weak var window: NSWindow?
            weak var canvas: ImageCanvasView?
            weak var session: EditSession?
            for round in 0..<3 {
                autoreleasepool {
                    ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
                    viewer = ViewerWindowController.current
                    window = viewer?.window
                    canvas = viewer?.canvas
                }
                await waitUntil { viewer?.canEditCurrent == true && viewer?.canvasTexture != nil }
                #expect(viewer?.canEditCurrent == true, "round \(round)")
                for action in actions {
                    autoreleasepool { _ = NSApp.sendAction(action, to: viewer, from: nil) }
                    if action == .resizeImage {
                        // A sheet rather than a panel tool: cancelled by ending it.
                        await waitUntil { window?.attachedSheet != nil }
                        #expect(window?.attachedSheet != nil, "\(action) did not open")
                        autoreleasepool { if let sheet = window?.attachedSheet { window?.endSheet(sheet) } }
                        await waitUntil { window?.attachedSheet == nil }
                        continue
                    }
                    await waitUntil { viewer?.activeTool != nil }
                    #expect(viewer?.activeTool != nil, "\(action) did not open")
                    if session == nil { session = viewer?.editSession }
                    autoreleasepool { viewer?.closeTool() }
                }
                autoreleasepool {
                    viewer?.toggleHistogram(nil)
                    viewer?.toggleInfoPanel(nil)
                    viewer?.nextImage(nil)
                }
                await waitUntil { viewer?.canvasTexture != nil }
                autoreleasepool {
                    viewer?.toggleHistogram(nil)
                    viewer?.toggleInfoPanel(nil)
                    viewer?.exitViewer(nil)
                }
                await waitUntil { viewer == nil && window == nil && canvas == nil && session == nil }
                await drain()
                #expect(ViewerWindowController.current == nil)
                #expect(viewer == nil, "round \(round)")
                #expect(window == nil, "round \(round)")
                #expect(canvas == nil, "round \(round)")
                #expect(session == nil, "round \(round)")
            }
        }

        /// The Resize sheet's own Cancel (Esc) reports no operation, ends the
        /// sheet, and leaves nothing of it or its parent behind.
        @Test func resizeSheetCancelledByItsButtonIsFreed() async throws {
            weak var parent: NSWindow?
            weak var sheet: NSWindow?
            var results: [EditOperation?] = []
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                parent = window
                ResizeSheet.present(size: CGSize(width: 600, height: 400), on: window) { results.append($0) }
                sheet = window.attachedSheet
            }
            try autoreleasepool {
                let attached = try #require(sheet)
                attached.contentView?.layoutSubtreeIfNeeded()
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                           timestamp: 0, windowNumber: attached.windowNumber,
                                                           context: nil, characters: "\u{1b}",
                                                           charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                           keyCode: 53))
                #expect(attached.performKeyEquivalent(with: escape))
            }
            await waitUntil { results.count == 1 }
            #expect(results.count == 1 && results.first == .some(nil))
            #expect(parent?.attachedSheet == nil)
            autoreleasepool { parent?.close() }
            await drain()
            await waitUntil { sheet == nil && parent == nil }
            #expect(sheet == nil)
            #expect(parent == nil)
        }

        /// Moving to another image with a tool open (nothing changed) lets go
        /// of the old image's edit session and its textures. (An effect that
        /// previews as it opens asks about unsaved changes first, so none is
        /// here.)
        @Test func navigatingAwayFreesTheEditSession() async throws {
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg", "c.jpg"], in: folder)
            ViewerWindowController.show(images: list, index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.current?.exitViewer(nil) }
            let viewer = try #require(ViewerWindowController.current)
            weak var session: EditSession?
            for action in [Selector.adjustLighting, .cropImage, .adjustCurves, .cloneStamp, .drawAnnotations] {
                await waitUntil { viewer.canEditCurrent }
                autoreleasepool { _ = NSApp.sendAction(action, to: viewer, from: nil) }
                await waitUntil { viewer.activeTool != nil }
                #expect(viewer.activeTool != nil, "\(action)")
                session = viewer.editSession
                #expect(session != nil)
                autoreleasepool { viewer.nextImage(nil) }
                await waitUntil { session == nil }
                #expect(session == nil, "\(action)")
                if viewer.model.index == list.count - 1 { viewer.firstImage(nil) }
            }
        }

        /// The viewer opened and closed fifty times, flipping an image each
        /// time: none of them stays behind.
        @Test func viewerOpenedFiftyTimesIsFreed() async throws {
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg", "c.jpg"], in: folder)
            var alive: [Weak<ViewerWindowController>] = []
            var canvases: [Weak<ImageCanvasView>] = []
            for index in 0..<50 {
                autoreleasepool {
                    ViewerWindowController.show(images: list, index: index % 3, fullScreen: false) { _ in }
                    alive.append(Weak(ViewerWindowController.current))
                    canvases.append(Weak(ViewerWindowController.current?.canvas))
                    ViewerWindowController.current?.nextImage(nil)
                }
                if index % 10 == 0 { await waitUntil { ViewerWindowController.current?.canvasTexture != nil } }
                autoreleasepool { ViewerWindowController.current?.exitViewer(nil) }
            }
            await waitUntil { alive.allSatisfy { $0.value == nil } && canvases.allSatisfy { $0.value == nil } }
            #expect(alive.filter { $0.value != nil }.count == 0)
            #expect(canvases.filter { $0.value != nil }.count == 0)
        }

        /// The compare window opened and closed fifty times.
        @Test func compareOpenedFiftyTimesIsFreed() async throws {
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg", "c.jpg"], in: folder)
            var alive: [Weak<CompareWindowController>] = []
            var panes: [Weak<CompareImagePane>] = []
            for index in 0..<50 {
                autoreleasepool {
                    CompareWindowController.show(entries: Array(list.prefix(2 + index % 2)), allImages: list)
                    alive.append(Weak(CompareWindowController.current))
                    panes += (CompareWindowController.current?.paneViews ?? []).map { Weak($0) }
                }
                if index % 10 == 0 {
                    await waitUntil { CompareWindowController.current?.paneViews.allSatisfy { $0.canvas.image != nil } == true }
                }
                autoreleasepool { CompareWindowController.current?.window?.close() }
            }
            await waitUntil { alive.allSatisfy { $0.value == nil } && panes.allSatisfy { $0.value == nil } }
            #expect(CompareWindowController.current == nil)
            #expect(alive.filter { $0.value != nil }.count == 0)
            #expect(panes.filter { $0.value != nil }.count == 0)
        }

        /// The browser's tool sheets (contact sheet, montage, batch convert and
        /// rename), each opened and cancelled on one window: none of their
        /// controllers, sheets or models survive.
        @Test func toolSheetsAreFreed() async throws {
            let scratchDefaults = ScratchDefaults("minivu-window-release-tests")
            defer { scratchDefaults.remove() }
            let defaults = scratchDefaults.defaults
            // Real sheets: other suites leave a recorder of their own here.
            let savedSheets = BatchTools.sheets
            BatchTools.sheets = .system
            defer { BatchTools.sheets = savedSheets }
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg"], in: folder)
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            defer { parent.close() }
            let display = MontageModel.Display(id: 0, displayID: 1, name: "Test Display",
                                               points: CGSize(width: 400, height: 250), scale: 2)
            var alive: [(String, Weak<AnyObject>)] = []
            // Two rounds, not fifty: AppKit animates each sheet in and out
            // on the main thread (about half a second a sheet here).
            for _ in 0..<2 {
                autoreleasepool {
                    let contact = ContactSheetController(items: list.map { LayoutItem(entry: $0) }, folderName: "Trip",
                                                         startFolder: folder.url,
                                                         store: ContactSheetStore(defaults: defaults))
                    contact.begin(on: parent)
                    alive.append(("contact sheet", Weak(contact)))
                    alive.append(("contact sheet window", Weak(contact.sheet)))
                    contact.close()

                    let model = MontageModel(images: list, fromSelection: false, displays: [display],
                                             preferredDisplay: 0, settings: MontageSettingsStore(defaults: defaults))
                    let montage = MontageSheetController(model: model)
                    montage.begin(on: parent)
                    alive.append(("montage", Weak(montage)))
                    alive.append(("montage model", Weak(model)))
                    montage.cancel()

                    let convert = BatchConvertSheet(model: BatchConvertModel(entries: list,
                                                                             store: BatchStore(defaults: defaults)))
                    convert.begin(on: parent) { _ in }
                    alive.append(("batch convert", Weak(convert)))
                    alive.append(("batch convert window", Weak(convert.window)))
                    convert.end()

                    let rename = BatchRenameSheet(model: BatchRenameModel(entries: list,
                                                                          store: BatchStore(defaults: defaults)))
                    rename.begin(on: parent) { _ in }
                    alive.append(("batch rename", Weak(rename)))
                    alive.append(("batch rename window", Weak(rename.window)))
                    rename.end()
                }
                await drain()
            }
            await waitUntil { alive.allSatisfy { $0.1.value == nil } }
            let survivors = Dictionary(grouping: alive.filter { $0.1.value != nil }, by: \.0).mapValues(\.count)
            #expect(survivors.isEmpty, "\(survivors)")
            #expect(parent.attachedSheet == nil)
        }

        /// A slideshow started and ended fifty times from a viewer.
        @Test func slideshowStartedFiftyTimesIsFreed() async throws {
            let scratchDefaults = ScratchDefaults("minivu-window-release-tests")
            let store = SlideshowSettingsStore(defaults: scratchDefaults.defaults)
            store.settings.interval = 60
            let savedStore = SlideshowWindowController.settingsStore
            let savedPlayer = SlideshowWindowController.makeAudioPlayer
            SlideshowWindowController.settingsStore = store
            SlideshowWindowController.makeAudioPlayer = { FakeSlideshowAudioPlayer() }
            defer {
                SlideshowWindowController.settingsStore = savedStore
                SlideshowWindowController.makeAudioPlayer = savedPlayer
                scratchDefaults.remove()
            }
            let folder = try ScratchFolder()
            let list = try jpegs(["a.jpg", "b.jpg", "c.jpg"], in: folder)
            var alive: [Weak<SlideshowWindowController>] = []
            var windows: [Weak<NSWindow>] = []
            for index in 0..<50 {
                autoreleasepool {
                    let show = SlideshowWindowController.start(images: list, startIndex: index % 3, from: nil) { _ in }
                    alive.append(Weak(show))
                    windows.append(Weak(show?.window))
                }
                if index % 10 == 0 { await waitUntil { SlideshowWindowController.current?.shownIndex != nil } }
                autoreleasepool { SlideshowWindowController.current?.end() }
            }
            await waitUntil { alive.allSatisfy { $0.value == nil } && windows.allSatisfy { $0.value == nil } }
            #expect(SlideshowWindowController.current == nil)
            #expect(alive.filter { $0.value != nil }.count == 0)
            #expect(windows.filter { $0.value != nil }.count == 0)
        }
    }
}
