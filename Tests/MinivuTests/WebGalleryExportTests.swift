import Testing
import AppKit
import ImageIO
import MinivuCore
import MinivuRender
@testable import Minivu

/// Create Web Gallery: whole galleries written from hostile file names and
/// read back (every link followed, nothing from outside), metadata and
/// location, originals, formats, names already taken, pictures that can't
/// be read, and Cancel.
@MainActor @Suite struct WebGalleryExportTests {
    /// File names a Mac allows and a web page must survive ("/" can't be in
    /// a file name; the planner's tests cover it).
    static let hostileNames = [
        // ":" is the "/" Finder shows; a real "/" can't be in a name.
        "<script>alert('x')<:script>.png",
        "Tom & \"Jerry's\".png",
        "cafe\u{301} ☕️.png",
        "a#b?c=d%20e.png",
        "javascript:alert(1).png",
    ]

    static func pictures(_ names: [String] = hostileNames, in folder: URL) throws -> [FolderEntry] {
        try names.enumerated().map { index, name in
            let shade = Double(index) / Double(max(names.count, 1))
            return try ContactSheetTests.png(name, in: folder, shade, 0.4, 1 - shade, width: 160, height: 90)
        }
    }

    static func converter() -> BatchConverter {
        BatchConverter(renderer: EditRenderer.shared, displaySettings: DisplaySettings()) { _, _, _ in
            CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    /// Small pictures, quickly: thumbnails 64 pt (128 px), large 320 px.
    static var smallSettings: WebGallerySettings {
        var settings = WebGallerySettings()
        settings.thumbnailSize = 64
        settings.largeSize = 320
        settings.showsTitle = false
        return settings
    }

    static func export(_ images: [FolderEntry], title: String = "Trip", settings: WebGallerySettings = smallSettings,
                       into folder: URL, cancel: CancellationFlag = CancellationFlag(),
                       progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws
        -> WebGalleryExport.Outcome {
        try await WebGalleryExport.export(images: images, title: title, settings: settings, into: folder, cancel: cancel,
                                          converter: converter(), progress: progress)
    }

    /// Every file in `folder`, relative paths, sorted.
    static func files(in folder: URL) throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.count)) }
            .sorted()
    }

    /// The href and src values of a page, as written.
    static func links(in html: String) throws -> [(attribute: String, value: String)] {
        try html.matches(of: Regex(#"(href|src)="([^"]*)""#)).map {
            (String($0.output[1].substring ?? ""), String($0.output[2].substring ?? ""))
        }
    }

    /// Where a link in `page` leads, fragment dropped, percent-decoded.
    static func resolve(_ link: String, from page: URL) throws -> URL {
        let path = String(link.split(separator: "#", omittingEmptySubsequences: false)[0])
        let decoded = try #require(path.removingPercentEncoding)
        return page.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }

    static func pixelSize(_ url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func writesACompleteSelfContainedGallery() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        var settings = Self.smallSettings
        settings.sort = .name
        var steps: [Int] = []
        let outcome = try await Self.export(entries, title: "Trip <1> & \"2\"", settings: settings, into: output,
                                            progress: { done, total in
                                                #expect(total == entries.count + 1)
                                                steps.append(done)
                                            })
        #expect(steps == Array(0...(entries.count + 1)))
        #expect(outcome.skipped.isEmpty)
        let gallery = outcome.folder
        #expect(gallery.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL)
        #expect(gallery.lastPathComponent == "Trip <1> & \"2\"")
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == [gallery.lastPathComponent])

        // index.html, the style sheet, and a page, a picture and a thumbnail
        // for each, under safe names.
        let files = try Self.files(in: gallery)
        let stems = outcome.items.map(\.stem)
        #expect(Set(stems).count == entries.count)
        var expected = ["index.html", "style.css"]
        for stem in stems {
            expected += ["pages/\(stem).html", "images/\(stem).jpg", "thumbnails/\(stem).jpg"]
        }
        #expect(files == expected.sorted())
        for file in files {
            let name = (file as NSString).lastPathComponent
            #expect(BatchNameKey.problem(with: name) == nil, "\(file)")
        }

        // Every link and source of every page leads to a file of the gallery,
        // and nothing anywhere names the internet.
        let root = gallery.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var pagesReached = Set<String>()
        for file in files where file.hasSuffix(".html") || file.hasSuffix(".css") {
            let url = gallery.appendingPathComponent(file)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.lowercased().contains("http:") && !text.lowercased().contains("https:"), "\(file)")
            #expect(!text.contains("<script") && !text.contains("</script>"), "\(file)")
            for (_, value) in try Self.links(in: text) {
                #expect(!value.contains(":") && !value.hasPrefix("/"), "\(value) in \(file)")
                let target = try Self.resolve(value, from: url).resolvingSymlinksInPath()
                #expect(target.path.hasPrefix(root), "\(value) in \(file) leaves the gallery")
                #expect(FileManager.default.fileExists(atPath: target.path), "\(value) in \(file) leads nowhere")
                if target.pathExtension == "html", target.lastPathComponent != "index.html" {
                    pagesReached.insert(target.lastPathComponent)
                }
            }
        }
        #expect(pagesReached == Set(stems.map { "\($0).html" }))

        // The names show escaped, in name order.
        let index = try String(contentsOf: gallery.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.contains("<h1>Trip &lt;1&gt; &amp; &quot;2&quot;</h1>"))
        #expect(index.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;:script&gt;.png"))
        #expect(index.contains("Tom &amp; &quot;Jerry&#39;s&quot;.png"))
        #expect(index.contains("café ☕️.png"))
        #expect(index.components(separatedBy: "<li id=").count - 1 == entries.count)
        let order = outcome.items.map(\.fileName)
        #expect(order == entries.map(\.url.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        // Next from the first page reaches every page once, in order, and
        // the last has none; Previous goes back the same way.
        var page = gallery.appendingPathComponent("pages/\(stems[0]).html")
        var visited: [String] = []
        while true {
            visited.append(page.deletingPathExtension().lastPathComponent)
            let html = try String(contentsOf: page, encoding: .utf8)
            guard let next = html.firstMatch(of: try Regex(#"<a class="step" rel="next" href="([^"]*)""#)) else {
                #expect(html.contains("aria-disabled=\"true\">Next"))
                break
            }
            page = try Self.resolve(String(next.output[1].substring ?? ""), from: page)
            #expect(visited.count < entries.count + 1)
        }
        #expect(visited == stems)
        let last = try String(contentsOf: page, encoding: .utf8)
        #expect(last.contains("<a class=\"step\" rel=\"prev\" href=\"\(WebGalleryHTML.encodeComponent(stems[stems.count - 2])).html\""))
        #expect(last.contains("\(entries.count) of \(entries.count)"))

        // A picture smaller than the large size keeps its size; thumbnails
        // are at twice their CSS size.
        let first = try #require(outcome.items.first)
        #expect(try Self.pixelSize(gallery.appendingPathComponent("images/\(first.stem).jpg")) == (160, 90))
        #expect(try Self.pixelSize(gallery.appendingPathComponent("thumbnails/\(first.stem).jpg")) == (128, 72))
        #expect(first.thumbnailWidth == 64 && first.thumbnailHeight == 36)
    }

    @Test func keepsMetadataWithoutTheLocation() async throws {
        let scratch = try ScratchFolder()
        var properties = ScratchFolder.location
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCObjectName] = "Bridge <at> night"
        properties[kCGImagePropertyIPTCDictionary] = iptc
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 14:30:00"]
        let url = try scratch.jpeg("bridge.jpg", width: 640, height: 480, properties: properties)
        let entry = try #require(FolderEntry(url: url))
        var settings = Self.smallSettings
        settings.showsTitle = true
        settings.showsDate = true
        let output = try scratch.folder("Out")
        let outcome = try await WebGalleryExport.export(images: [entry], title: "Trip", settings: settings, into: output,
                                                        cancel: CancellationFlag(), converter: Self.converter(),
                                                        formatDate: { _ in "the first of May" })
        let large = outcome.folder.appendingPathComponent("images/bridge.jpg")
        #expect(try Self.pixelSize(large) == (320, 240))
        #expect(ScratchFolder.location(of: large).latitude == nil && ScratchFolder.location(of: large).city == nil)
        let exif = CGImageSourceCreateWithURL(large as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:01 14:30:00")
        // Thumbnails carry nothing.
        #expect(ScratchFolder.location(of: outcome.folder.appendingPathComponent("thumbnails/bridge.jpg")).latitude == nil)
        let index = try String(contentsOf: outcome.folder.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.contains("<span class=\"title\">Bridge &lt;at&gt; night</span>"))
        #expect(index.contains("<span class=\"date\">the first of May</span>"))

        // Remove location off: the position stays. Metadata off: none at all.
        settings.removesLocation = false
        let kept = try await Self.export([entry], title: "Kept", settings: settings, into: output)
        #expect(ScratchFolder.location(of: kept.folder.appendingPathComponent("images/bridge.jpg")).latitude == 51.5)
        settings.keepsMetadata = false
        let bare = try await Self.export([entry], title: "Bare", settings: settings, into: output)
        let bareProperties = CGImageSourceCreateWithURL(bare.folder.appendingPathComponent("images/bridge.jpg") as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        #expect(bareProperties[kCGImagePropertyGPSDictionary] == nil && bareProperties[kCGImagePropertyIPTCDictionary] == nil)
    }

    @Test func copiesTheOriginalsWhenAsked() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(["IMG_1.png", "<b>&.png"], in: scratch.url)
        var settings = Self.smallSettings
        settings.includesOriginals = true
        let output = try scratch.folder("Out")
        let outcome = try await Self.export(entries, settings: settings, into: output)
        for (entry, item) in zip(entries, outcome.items) {
            let name = try #require(item.originalName)
            let copy = outcome.folder.appendingPathComponent("originals").appendingPathComponent(name)
            #expect(try Data(contentsOf: copy) == Data(contentsOf: entry.url))
            let page = try String(contentsOf: outcome.folder.appendingPathComponent("pages/\(item.stem).html"),
                                  encoding: .utf8)
            #expect(page.contains("href=\"../originals/\(WebGalleryHTML.encodeComponent(name))\" download"))
        }
        // The sources are untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).count == entries.count + 1)
    }

    /// The originals keep where each photo was taken only when the large
    /// pictures do; otherwise it is removed from the copies, losslessly.
    @Test func originalsLoseTheirLocationWithTheLargePictures() async throws {
        let scratch = try ScratchFolder()
        let url = try scratch.jpeg("bridge.jpg", width: 640, height: 480, properties: ScratchFolder.location)
        let entry = try #require(FolderEntry(url: url))
        var settings = Self.smallSettings
        settings.includesOriginals = true
        let output = try scratch.folder("Out")
        // Remove location on, as by default.
        let outcome = try await Self.export([entry], title: "Shared", settings: settings, into: output)
        let copy = outcome.folder.appendingPathComponent("originals/bridge.jpg")
        #expect(ScratchFolder.location(of: copy).latitude == nil && ScratchFolder.location(of: copy).city == nil)
        #expect(try Self.pixelSize(copy) == (640, 480))
        #expect(outcome.items.first?.originalName == "bridge.jpg" && outcome.withheldOriginals.isEmpty)
        // The source keeps its own.
        #expect(ScratchFolder.location(of: url).latitude == 51.5)

        // Metadata off: the large pictures carry no location, nor do the originals.
        settings.keepsMetadata = false
        let bare = try await Self.export([entry], title: "Bare", settings: settings, into: output)
        #expect(ScratchFolder.location(of: bare.folder.appendingPathComponent("originals/bridge.jpg")).latitude == nil)

        // Location kept in the large pictures: the originals are copied as they are.
        settings.keepsMetadata = true
        settings.removesLocation = false
        let kept = try await Self.export([entry], title: "Kept", settings: settings, into: output)
        #expect(try Data(contentsOf: kept.folder.appendingPathComponent("originals/bridge.jpg")) == Data(contentsOf: url))
    }

    /// An original whose location can't be removed in the file (a camera
    /// raw gets only a sidecar) is left out, leaving nothing behind, and
    /// named afterwards.
    @Test func anOriginalWhoseLocationCantBeRemovedIsLeftOut() throws {
        let scratch = try ScratchFolder()
        let raw = try scratch.jpeg("IMG_1.dng", width: 64, height: 48, properties: ScratchFolder.location)
        let output = try scratch.folder("Out")
        let copy = output.appendingPathComponent("IMG_1.dng")
        #expect(try !WebGalleryExport.copyOriginal(raw, to: copy, keepingLocation: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(try WebGalleryExport.copyOriginal(raw, to: copy, keepingLocation: true))
        #expect(try Data(contentsOf: copy) == Data(contentsOf: raw))

        let message = WebGalleryController.skippedMessage([], withheld: ["IMG_1.dng"])
        #expect(message.title == "1 original file was left out of the gallery.")
        #expect(message.detail.hasSuffix(":\nIMG_1.dng"))
        let both = WebGalleryController.skippedMessage([WebGalleryExport.Skipped(name: "x.jpg", reason: "Broken.")],
                                                       withheld: ["a.dng", "b.dng"])
        #expect(both.title == "1 picture was left out of the gallery.")
        #expect(both.detail.hasPrefix("x.jpg: Broken.\n\nWhere these photos were taken"))
        #expect(both.detail.hasSuffix("\na.dng\nb.dng"))
    }

    /// The dialog says what happens to the originals' metadata.
    @Test func dialogExplainsTheOriginalsMetadata() throws {
        let defaults = ScratchDefaults("minivu-web-gallery-tests")
        defer { defaults.remove() }
        let model = WebGalleryModel(images: [], title: "Trip", store: WebGallerySettingsStore(defaults: defaults.defaults))
        model.settings.includesOriginals = false
        #expect(model.originalsNote == nil)
        model.settings.includesOriginals = true
        #expect(model.originalsNote?.hasPrefix("Where each photo was taken is removed from the original files") == true)
        model.settings.removesLocation = false
        #expect(model.originalsNote?.contains("including where each photo was taken") == true)
        model.settings.keepsMetadata = false
        #expect(model.originalsNote?.hasPrefix("Where each photo was taken is removed") == true)
    }

    /// Internal storage only (DESIGN.md 1), as Batch Convert's output folder.
    @Test func refusesAFolderOffTheInternalStorage() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(["a.png"], in: scratch.url)
        let output = try scratch.folder("Out")
        await #expect(throws: ExternalVolumeError(folder: output)) {
            _ = try await WebGalleryExport.export(images: entries, title: "Trip", settings: Self.smallSettings,
                                                  into: output, cancel: CancellationFlag(), converter: Self.converter(),
                                                  isAllowedVolume: { _ in false })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(SaveAlert.message(for: ExternalVolumeError(folder: output))
                == "“Out” isn’t on this Mac’s internal storage. minivu only writes to folders on this Mac’s internal storage.")
    }

    @Test(arguments: [WebGalleryFormat.heic, .avif])
    func writesTheChosenFormat(_ format: WebGalleryFormat) async throws {
        try #require(format.isAvailable)
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(["a.png"], in: scratch.url)
        var settings = Self.smallSettings
        settings.format = format
        let outcome = try await Self.export(entries, settings: settings, into: try scratch.folder("Out"))
        for folder in ["images", "thumbnails"] {
            let url = outcome.folder.appendingPathComponent("\(folder)/a.\(format.fileExtension)")
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == format.typeIdentifier)
        }
        let index = try String(contentsOf: outcome.folder.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.contains("src=\"thumbnails/a.\(format.fileExtension)\""))
    }

    /// The gallery's folder never replaces anything: a name taken is numbered.
    @Test func takesAFreeFolderName() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(["a.png"], in: scratch.url)
        let output = try scratch.folder("Out")
        let existing = try scratch.folder("Trip", in: output)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("index.html"))
        let outcome = try await Self.export(entries, title: "Trip", into: output)
        #expect(outcome.folder.lastPathComponent == "Trip 2")
        #expect(try Data(contentsOf: existing.appendingPathComponent("index.html")) == Data("keep".utf8))
        // A title that can't be a name.
        let odd = try await Self.export(entries, title: "../..", into: output)
        #expect(odd.folder.lastPathComponent == "-..")
        let blank = try await Self.export(entries, title: "...", into: output)
        #expect(blank.folder.lastPathComponent == "Web Gallery")
        #expect(WebGalleryExport.folderName(for: "a/b:c") == "a-b-c")
    }

    @Test func leavesOutWhatCantBeRead() async throws {
        let scratch = try ScratchFolder()
        let good = try Self.pictures(["good.png"], in: scratch.url)
        let brokenURL = try scratch.file("broken.jpg", bytes: 64)
        let broken = try #require(FolderEntry(url: brokenURL))
        let output = try scratch.folder("Out")
        let outcome = try await Self.export([broken] + good, into: output)
        #expect(outcome.items.map(\.fileName) == ["good.png"])
        #expect(outcome.skipped.map(\.name) == ["broken.jpg"])
        #expect(try Self.files(in: outcome.folder).filter { $0.hasPrefix("pages/") } == ["pages/good.html"])
        let message = WebGalleryController.skippedMessage(outcome.skipped)
        #expect(message.title == "1 picture was left out of the gallery.")
        #expect(message.detail.hasPrefix("broken.jpg: "))

        // Nothing readable: an error, and no gallery.
        let empty = try scratch.folder("Empty")
        await #expect(throws: (any Error).self) { _ = try await Self.export([broken], into: empty) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
    }

    @Test func cancellingLeavesNoGallery() async throws {
        let scratch = try ScratchFolder()
        let entries = try Self.pictures(in: scratch.url)
        let output = try scratch.folder("Out")
        let cancel = CancellationFlag()
        // Cancel pressed once the second picture is done, as mid-way.
        await #expect(throws: CancellationError.self) {
            _ = try await Self.export(entries, into: output, cancel: cancel, progress: { done, _ in
                if done == 2 { cancel.cancel() }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)

        // Cancelled before anything starts: nothing either.
        let before = CancellationFlag()
        before.cancel()
        await #expect(throws: CancellationError.self) { _ = try await Self.export(entries, into: output, cancel: before) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func choicesAreRemembered() throws {
        let scratch = ScratchDefaults("minivu-web-gallery-tests")
        defer { scratch.remove() }
        let store = WebGallerySettingsStore(defaults: scratch.defaults)
        #expect(store.settings == WebGallerySettings())
        let model = WebGalleryModel(images: [], title: "T", store: store)
        model.settings.columns = 40
        #expect(model.settings.columns == 12)
        model.settings.theme = .dark
        model.settings.includesOriginals = true
        let again = WebGallerySettingsStore(defaults: scratch.defaults).settings
        #expect(again.columns == 12 && again.theme == .dark && again.includesOriginals)
        #expect(WebGalleryModel(images: [], title: "T", store: store).settings == again)
        #expect(model.summary == "0 pictures · 1 page · up to 1600 px")
    }
}

/// The dialog itself, which opens windows: part of the serialized window suite.
extension AppWindowTests {
    @MainActor @Suite(.serialized) struct WebGalleryDialogTests {
        @Test func createGoesThroughTheDialogAndTheOpenPanel() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entries = try WebGalleryExportTests.pictures(["a.png", "b.png"], in: scratch.url)
            let output = try scratch.folder("Out")
            let defaults = ScratchDefaults("minivu-web-gallery-dialog-tests")
            defer { defaults.remove() }
            let store = WebGallerySettingsStore(defaults: defaults.defaults)
            store.settings = WebGalleryExportTests.smallSettings

            // The open panel is replaced: the first time it is cancelled,
            // the second it names a folder.
            let original = WebGalleryExport.chooseFolder
            defer { WebGalleryExport.chooseFolder = original }
            var asked: [String] = []
            var answer: URL?
            WebGalleryExport.chooseFolder = { title, _, _, completion in
                asked.append(title)
                completion(answer)
            }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let controller = WebGalleryController(images: entries, title: "Holiday", startFolder: scratch.url,
                                                  store: store)
            controller.begin(on: window)
            #expect(window.attachedSheet === controller.sheet)
            #expect(WebGalleryController.controller(for: window) === controller)

            // Cancel in the open panel comes back to the dialog.
            controller.create()
            #expect(WebGalleryController.controller(for: window) == nil)
            try await waitUntil { window.attachedSheet != nil }
            #expect(window.attachedSheet === controller.sheet)

            answer = output
            controller.model.title = "Summer"
            controller.create()
            try await waitUntil { controller.work != nil }
            await controller.work?.value
            #expect(asked == ["Holiday", "Summer"])
            let gallery = try #require(controller.outcome?.folder)
            #expect(gallery.lastPathComponent == "Summer")
            #expect(FileManager.default.fileExists(atPath: gallery.appendingPathComponent("index.html").path))
            #expect(window.attachedSheet == nil)
        }

        /// Tools > Create Web Gallery… in the browser takes the tools'
        /// pictures, is titled after the folder, and is off while its dialog
        /// is up.
        @Test func browserCommandOpensTheDialog() async throws {
            _ = NSApplication.shared
            let scratch = try ScratchFolder()
            let entries = try WebGalleryExportTests.pictures(["a.png", "b.png", "c.png"], in: scratch.url)
            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            _ = controller.grid.view
            defer { controller.window?.close() }
            controller.open(folder: scratch.url)
            await controller.model.work?.value
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }

            let window = try #require(controller.window)
            #expect(controller.canPerformTools(.createWebGallery) == true)
            controller.createWebGallery(nil)
            let dialog = try #require(WebGalleryController.controller(for: window))
            defer { dialog.close() }
            #expect(dialog.model.images.map(\.url.lastPathComponent) == entries.map(\.url.lastPathComponent))
            #expect(dialog.model.title == FileManager.default.displayName(atPath: scratch.url.path))
            #expect(window.attachedSheet === dialog.sheet)
            #expect(controller.canPerformTools(.createWebGallery) == false)
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + TestTiming.limit(milliseconds: 2000)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
