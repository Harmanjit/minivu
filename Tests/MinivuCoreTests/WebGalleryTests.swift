import Testing
import Foundation
@testable import MinivuCore

/// Create Web Gallery's text: escaping, links, safe and unique names, the
/// order, and the pages themselves, with hostile names throughout.
@Suite struct WebGalleryTests {
    /// Names a file system allows and a web page must survive.
    static let hostileNames = [
        "<script>alert('x')</script>.jpg",
        "Tom & \"Jerry's\" <b>.png",
        "../../etc/passwd",
        "a#b?c=d%20e.heic",
        "café ☕️ 写真.jpg",
        "javascript:alert(1).jpg",
        "line\nbreak\u{0}null.jpg",
    ]

    static func item(_ name: String, title: String = "", caption: String = "", stem: String? = nil,
                     original: String? = nil) -> WebGalleryItem {
        var item = WebGalleryItem(source: URL(fileURLWithPath: "/pictures").appendingPathComponent(name), fileName: name,
                                  title: title, caption: caption, dateText: "1 May 2024 at 10:00",
                                  stem: stem ?? WebGalleryPlanner.stem(for: name), originalName: original)
        item.largeWidth = 1600
        item.largeHeight = 1067
        item.thumbnailWidth = 200
        item.thumbnailHeight = 133
        return item
    }

    // MARK: - Escaping and links

    @Test func escapesTextAndAttributes() {
        #expect(WebGalleryHTML.escape("<script>alert('x')</script>")
                == "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;")
        #expect(WebGalleryHTML.escape("Tom & \"Jerry's\"") == "Tom &amp; &quot;Jerry&#39;s&quot;")
        // Already-escaped text is escaped again, never trusted.
        #expect(WebGalleryHTML.escape("&amp;") == "&amp;amp;")
        // Unicode passes through; controls HTML forbids become U+FFFD.
        #expect(WebGalleryHTML.escape("café ☕️ 写真") == "café ☕️ 写真")
        #expect(WebGalleryHTML.escape("a\u{0}b\u{7}c\u{FFFF}") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}")
        #expect(WebGalleryHTML.escape("one\r\ntwo\tthree") == "one\n\ntwo\tthree")
        for name in Self.hostileNames {
            let escaped = WebGalleryHTML.escape(name)
            #expect(!escaped.contains("<") && !escaped.contains(">") && !escaped.contains("\"")
                    && !escaped.contains("'"))
        }
    }

    @Test func linksArePercentEncodedRelativePaths() {
        #expect(WebGalleryHTML.link(["pages", "a b#?%.html"]) == "pages/a%20b%23%3F%25.html")
        #expect(WebGalleryHTML.link(["images", "x.jpg"], up: 1) == "../images/x.jpg")
        #expect(WebGalleryHTML.link(["index.html"], up: 1, fragment: "p3") == "../index.html#p3")
        // A component can't climb, add a scheme or a query: "/" and ":" are
        // encoded, and ".." alone stays a name in its folder.
        #expect(WebGalleryHTML.link(["../../etc/passwd"]) == "..%2F..%2Fetc%2Fpasswd")
        #expect(WebGalleryHTML.link(["javascript:alert(1)"]) == "javascript%3Aalert%281%29")
        // UTF-8, precomposed: "é" typed either way is one link.
        #expect(WebGalleryHTML.encodeComponent("cafe\u{301}") == "caf%C3%A9")
        #expect(WebGalleryHTML.encodeComponent("café") == "caf%C3%A9")
        for name in Self.hostileNames {
            let link = WebGalleryHTML.encodeComponent(name)
            #expect(link.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%".contains($0)) }, "\(link)")
            #expect(link.removingPercentEncoding == name.precomposedStringWithCanonicalMapping)
        }
    }

    // MARK: - Names

    @Test func namesAreMadeSafe() {
        #expect(WebGalleryPlanner.stem(for: "IMG_0001.JPG") == "IMG_0001")
        #expect(WebGalleryPlanner.stem(for: "../../etc/passwd") == "-..-etc-passwd")
        #expect(WebGalleryPlanner.stem(for: ".hidden.jpg") == "hidden")
        #expect(WebGalleryPlanner.stem(for: "...jpg") == "jpg")
        #expect(WebGalleryPlanner.stem(for: "a:b\\c.png") == "a-b-c")
        #expect(WebGalleryPlanner.stem(for: "line\nbreak\u{0}null.jpg") == "line-break-null")
        #expect(WebGalleryPlanner.stem(for: "  .jpg") == "picture")
        #expect(WebGalleryPlanner.originalName(for: "..") == "picture")
        #expect(WebGalleryPlanner.originalName(for: ".profile") == "profile")
        #expect(WebGalleryPlanner.originalName(for: "<b>&.NEF") == "<b>&.NEF")
        let long = String(repeating: "写", count: 200) + ".jpg"
        #expect(WebGalleryPlanner.stem(for: long).utf8.count <= 200)
        for name in Self.hostileNames {
            let stem = WebGalleryPlanner.stem(for: name)
            #expect(FileOperations.nameProblem(stem + ".html") == nil)
            #expect(!stem.contains("/") && !stem.hasPrefix("."))
            let original = WebGalleryPlanner.originalName(for: name)
            #expect(FileOperations.nameProblem(original) == nil)
        }
    }

    @Test func namesNeverCollide() {
        let names = ["photo.jpg", "Photo.png", "photo.heic", "cafe\u{301}.jpg", "café.png", "photo 2.jpg", "x\\y.jpg",
                     "x:y.jpg"]
        var settings = WebGallerySettings()
        settings.includesOriginals = true
        let items = WebGalleryPlanner.items(names.map { WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/\($0)"),
                                                                                modified: .distantPast) },
                                            settings: settings, formatDate: { _ in "" })
        #expect(items.map(\.stem) == ["photo", "Photo 2", "photo 3", "café", "café 2", "photo 4", "x-y", "x-y 2"])
        let keys = items.map { $0.stem.precomposedStringWithCanonicalMapping.lowercased() }
        #expect(Set(keys).count == keys.count)
        // Originals keep their extensions, and so their own names where they can.
        #expect(items.map(\.originalName) == ["photo.jpg", "Photo.png", "photo.heic", "café.jpg", "café.png",
                                             "photo 2.jpg", "x-y.jpg", "x-y 2.jpg"])
        settings.includesOriginals = false
        #expect(WebGalleryPlanner.items([WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/a.jpg"),
                                                                  modified: .distantPast)],
                                        settings: settings).first?.originalName == nil)
    }

    @Test func sortsAsChosen() {
        let day: TimeInterval = 86_400
        let sources = [
            WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/IMG 10.jpg"), modified: Date(timeIntervalSince1970: 3 * day),
                                     dateTaken: WallClock(year: 2020, month: 1, day: 1)),
            WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/IMG 2.jpg"), modified: Date(timeIntervalSince1970: 1 * day)),
            WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/b.jpg"), modified: Date(timeIntervalSince1970: 2 * day),
                                     dateTaken: WallClock(year: 1969, month: 6, day: 1)),
        ]
        func names(_ sort: WebGallerySettings.Sort) -> [String] {
            WebGalleryPlanner.sorted(sources, by: sort).map(\.url.lastPathComponent)
        }
        #expect(names(.asShown) == ["IMG 10.jpg", "IMG 2.jpg", "b.jpg"])
        #expect(names(.name) == ["b.jpg", "IMG 2.jpg", "IMG 10.jpg"])
        #expect(names(.dateModified) == ["IMG 2.jpg", "b.jpg", "IMG 10.jpg"])
        // Taken in 1969, then the file of 1970 without a date, then 2020.
        #expect(names(.dateTaken) == ["b.jpg", "IMG 2.jpg", "IMG 10.jpg"])
    }

    @Test func datesSayWhenTakenElseModified() {
        let locale = Locale(identifier: "en_GB"), zone = TimeZone(identifier: "Europe/London")!
        let taken = WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/a.jpg"), modified: .distantPast,
                                             dateTaken: WallClock(year: 2024, month: 5, day: 1, hour: 14, minute: 30))
        #expect(WebGalleryPlanner.dateText(for: taken, locale: locale, timeZone: zone).hasPrefix("1 May 2024"))
        #expect(WebGalleryPlanner.dateText(for: taken, locale: locale, timeZone: zone).contains("14:30"))
        let modified = WebGalleryPlanner.Source(url: URL(fileURLWithPath: "/p/a.jpg"),
                                                modified: Date(timeIntervalSince1970: 0))
        #expect(WebGalleryPlanner.dateText(for: modified, locale: locale, timeZone: zone).hasPrefix("1 January 1970"))
    }

    // MARK: - Pages

    @Test func indexEscapesEveryNameAndLinksEveryPage() throws {
        let items = Self.hostileNames.enumerated().map { index, name in
            Self.item(name, title: index == 0 ? "\"><img src=x onerror=alert(1)>" : "", stem: "s\(index)")
        }
        var settings = WebGallerySettings()
        settings.showsDate = true
        let html = WebGalleryHTML.indexPage(title: "<Trip> & \"friends\"", items: items, settings: settings)
        #expect(html.contains("<title>&lt;Trip&gt; &amp; &quot;friends&quot;</title>"))
        #expect(html.contains("<h1>&lt;Trip&gt; &amp; &quot;friends&quot;</h1>"))
        #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;.jpg"))
        #expect(html.contains("alt=\"&quot;&gt;&lt;img src=x onerror=alert(1)&gt;\""))
        #expect(!html.contains("<script") && !html.contains("onerror=alert(1)>"))
        #expect(html.components(separatedBy: "<li id=").count - 1 == items.count)
        for index in items.indices {
            #expect(html.contains("<li id=\"p\(index + 1)\"><a class=\"thumb\" href=\"pages/s\(index).html\">"))
            #expect(html.contains("src=\"thumbnails/s\(index).jpg\" width=\"200\" height=\"133\""))
        }
        try Self.expectSelfContained(html)
    }

    @Test func picturePagesStepThroughTheGallery() throws {
        var settings = WebGallerySettings()
        settings.format = .avif
        let items = [Self.item("a.jpg", title: "First", caption: "A <long> caption", original: "a.jpg"),
                     Self.item("b c.jpg"), Self.item("d&e.jpg")]
        let pages = items.indices.map { WebGalleryHTML.picturePage(at: $0, title: "Trip", items: items, settings: settings) }
        #expect(pages.count == 3)

        // First: no Previous, Next to the second, the picture onwards too.
        #expect(pages[0].contains("<span class=\"step disabled\" aria-disabled=\"true\">&larr; Previous</span>"))
        #expect(pages[0].contains("<a class=\"step\" rel=\"next\" href=\"b%20c.html\">Next &rarr;</a>"))
        #expect(pages[0].contains("<link rel=\"next\" href=\"b%20c.html\">"))
        #expect(!pages[0].contains("rel=\"prev\""))
        #expect(pages[0].contains("<a class=\"picture\" href=\"b%20c.html\"><img src=\"../images/a.avif\" width=\"1600\" height=\"1067\" alt=\"First\">"))
        #expect(pages[0].contains("<h1 class=\"title\">First</h1>"))
        #expect(pages[0].contains("<p class=\"description\">A &lt;long&gt; caption</p>"))
        #expect(pages[0].contains("href=\"../originals/a.jpg\" download"))
        #expect(pages[0].contains("<a class=\"up\" href=\"../index.html#p1\">Trip</a>"))
        #expect(pages[0].contains("<span class=\"position\">1 of 3</span>"))
        #expect(pages[0].contains("<title>First – Trip</title>"))

        // Middle: both ways.
        #expect(pages[1].contains("rel=\"prev\" href=\"a.html\""))
        #expect(pages[1].contains("rel=\"next\" href=\"d%26e.html\""))
        #expect(!pages[1].contains("originals"))

        // Last: no Next, and the picture leads back to the grid.
        #expect(pages[2].contains("<span class=\"step disabled\" aria-disabled=\"true\">Next &rarr;</span>"))
        #expect(pages[2].contains("<a class=\"picture\" href=\"../index.html#p3\">"))
        #expect(pages[2].contains("alt=\"d&amp;e.jpg\""))
        for page in pages { try Self.expectSelfContained(page) }
    }

    @Test func captionsFollowTheSettings() {
        let item = Self.item("a.jpg", title: "Title", caption: "Caption")
        var settings = WebGallerySettings()
        settings.showsFileName = false
        settings.showsTitle = false
        settings.showsDate = false
        #expect(!WebGalleryHTML.indexPage(title: "T", items: [item], settings: settings).contains("class=\"caption\""))
        #expect(!WebGalleryHTML.picturePage(at: 0, title: "T", items: [item], settings: settings).contains("<figcaption>"))
        settings.showsDate = true
        let index = WebGalleryHTML.indexPage(title: "T", items: [item], settings: settings)
        #expect(index.contains("<p class=\"caption\"><span class=\"date\">1 May 2024 at 10:00</span></p>"))
        settings.showsTitle = true
        settings.showsFileName = true
        let page = WebGalleryHTML.picturePage(at: 0, title: "T", items: [item], settings: settings)
        #expect(page.contains("<h1 class=\"title\">Title</h1>\n<p class=\"description\">Caption</p>\n<p class=\"name\">a.jpg</p>\n<p class=\"date\">"))
    }

    @Test func styleSheetFollowsLayoutAndTheme() throws {
        var settings = WebGallerySettings()
        settings.thumbnailSize = 180
        var css = WebGalleryHTML.styleSheet(settings: settings)
        #expect(css.contains("repeat(auto-fill, minmax(min(180px, 100%), 1fr))"))
        #expect(css.contains("@media (prefers-color-scheme: dark)"))
        settings.columns = 5
        settings.theme = .dark
        css = WebGalleryHTML.styleSheet(settings: settings)
        #expect(css.contains("repeat(5, minmax(0, 1fr))"))
        #expect(css.contains("@media (max-width: 640px)"))
        #expect(!css.contains("prefers-color-scheme") && css.contains("color-scheme: dark"))
        settings.theme = .light
        #expect(WebGalleryHTML.styleSheet(settings: settings).contains("color-scheme: light"))
        #expect(!css.contains("url(") && !css.contains("@import") && !css.contains("@font-face"))
        try Self.expectSelfContained(css)
    }

    @Test func settingsLoadAndRepair() throws {
        let decoded = try JSONDecoder().decode(WebGallerySettings.self,
                                               from: Data(#"{"columns": 99, "quality": 7, "format": "webp", "theme": "dark"}"#.utf8))
        #expect(decoded.columns == 12 && decoded.quality == 1 && decoded.format == .jpeg && decoded.theme == .dark)
        #expect(decoded.largeSize == 1600 && decoded.removesLocation)
        var settings = WebGallerySettings()
        settings.thumbnailSize = 5
        settings.largeSize = 100_000
        #expect(settings.validated.thumbnailSize == 64 && settings.validated.largeSize == 8192)
        #expect(settings.exportOptions.colorProfile == .sRGB && settings.exportOptions.removeLocation)
        #expect(settings.thumbnailOptions.keepMetadata == false)
        settings.format = .avif
        #expect(settings.exportOptions.format == .heic)
        #expect(WebGalleryFormat.jpeg.isAvailable && WebGalleryFormat.heic.isAvailable)
    }

    /// No address outside the gallery: no scheme, no protocol-relative or
    /// absolute path, nothing to fetch from the network.
    static func expectSelfContained(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let lower = text.lowercased()
        for banned in ["http:", "https:", "<script", "@import", "url("] {
            #expect(!lower.contains(banned), "found \(banned)", sourceLocation: sourceLocation)
        }
        // Every link and source a relative path: no scheme ("javascript:",
        // "data:", "file:"), no absolute or protocol-relative path.
        let attribute = try Regex(#"(?:href|src)="([^"]*)""#)
        for match in text.matches(of: attribute) {
            let value = String(match.output[1].substring ?? "")
            #expect(!value.hasPrefix("/") && !value.contains(":"), "\(value)", sourceLocation: sourceLocation)
        }
    }
}
