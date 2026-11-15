import Foundation

/// The text of a web gallery: `index.html` with the thumbnail grid, one
/// page per picture with Previous and Next links, and one style sheet.
///
/// **One page per picture, no JavaScript.** A lightbox would need script
/// to open, step and close; plain pages need none, so the gallery works
/// with JavaScript off, in any browser, opened from disk (`file://`) or
/// from any web server. Each picture gets an address of its own that can be
/// bookmarked or sent, Back and Forward work as people expect, a large
/// picture is loaded only when its page is opened, and screen readers get
/// ordinary links and headings. The cost is a page load per step, which
/// from disk is instant.
///
/// **Nothing from outside.** No fonts, scripts, analytics or CDN links:
/// every link is a relative path inside the gallery, text uses the
/// system's own fonts, and each page carries a Content-Security-Policy
/// that forbids scripts, plugins, frames and forms, a second line of
/// defence should anything ever get through the escaping.
///
/// **Escaping.** Every string that came from a file name or metadata is
/// escaped with `escape` wherever it goes: element text and attribute
/// values alike (attributes are always double-quoted, and `escape` turns
/// both quotes into references). Every link is built by `link`, which
/// percent-encodes each path component outright, leaving only unreserved
/// characters; so a name cannot end an attribute, start a tag, add a URL
/// scheme or query, or climb out of the gallery.
public enum WebGalleryHTML {
    /// The gallery's folders, relative to `index.html`.
    public static let pagesFolder = "pages"
    public static let imagesFolder = "images"
    public static let thumbnailsFolder = "thumbnails"
    public static let originalsFolder = "originals"
    public static let styleSheetName = "style.css"
    public static let indexName = "index.html"

    // MARK: - Escaping

    /// `text` safe as HTML element text or as a double- or single-quoted
    /// attribute value. Control characters other than tab and line breaks,
    /// and the noncharacters U+FFFE and U+FFFF, aren't allowed in HTML and
    /// become U+FFFD.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\t", "\n": result.unicodeScalars.append(scalar)
            case "\r": result += "\n"
            default:
                switch scalar.value {
                case 0..<0x20, 0x7F...0x9F, 0xFFFE, 0xFFFF: result += "\u{FFFD}"
                default: result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Letters, digits and "-._~": the only characters a link component
    /// keeps as they are (RFC 3986's unreserved set).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// One path component, percent-encoded as UTF-8 (precomposed, so "é"
    /// typed either way gives the same link).
    public static func encodeComponent(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// A relative link: each component percent-encoded, joined by "/".
    /// `up` adds that many leading "../" (a picture's page reaching the
    /// gallery's top folder), the only way a link leaves its folder. An
    /// optional fragment is percent-encoded too.
    public static func link(_ components: [String], up: Int = 0, fragment: String? = nil) -> String {
        let path = Array(repeating: "..", count: up) + components.map(encodeComponent)
        return path.joined(separator: "/") + (fragment.map { "#" + encodeComponent($0) } ?? "")
    }

    // MARK: - Pages

    /// `index.html`: the title, the count, and the thumbnails, each linked
    /// to its picture's page.
    public static func indexPage(title: String, items: [WebGalleryItem], settings: WebGallerySettings,
                                 language: String = "en") -> String {
        let count = items.count == 1 ? "1 picture" : "\(items.count) pictures"
        var body = """
        <header class="gallery-header">
        <h1>\(escape(title))</h1>
        <p class="count">\(count)</p>
        </header>
        <main>
        <ul class="grid">

        """
        for (index, item) in items.enumerated() {
            let page = link([pagesFolder, item.stem + ".html"])
            let thumbnail = link([thumbnailsFolder, item.stem + "." + settings.format.fileExtension])
            body += """
            <li id="\(anchor(index))"><a class="thumb" href="\(escape(page))">\
            <img src="\(escape(thumbnail))" width="\(item.thumbnailWidth)" height="\(item.thumbnailHeight)" \
            alt="\(escape(altText(item)))" loading="lazy" decoding="async"></a>\(gridCaption(item, settings))</li>

            """
        }
        body += """
        </ul>
        </main>
        """
        return document(title: title, styleSheet: link([styleSheetName]), language: language, head: "",
                        bodyClass: "index", body: body)
    }

    /// The page of the picture at `index`: a bar with the way back to the
    /// grid, the position, Previous and Next, then the large picture and its
    /// captions, and the original file when included.
    public static func picturePage(at index: Int, title: String, items: [WebGalleryItem], settings: WebGallerySettings,
                                   language: String = "en") -> String {
        let item = items[index]
        let previous = index > 0 ? link([items[index - 1].stem + ".html"]) : nil
        let next = index + 1 < items.count ? link([items[index + 1].stem + ".html"]) : nil
        var head = ""
        if let previous { head += "<link rel=\"prev\" href=\"\(escape(previous))\">\n" }
        if let next { head += "<link rel=\"next\" href=\"\(escape(next))\">\n" }

        let back = link([indexName], up: 1, fragment: anchor(index))
        func step(_ href: String?, rel: String, label: String) -> String {
            guard let href else { return "<span class=\"step disabled\" aria-disabled=\"true\">\(label)</span>" }
            return "<a class=\"step\" rel=\"\(rel)\" href=\"\(escape(href))\">\(label)</a>"
        }
        let image = link([imagesFolder, item.stem + "." + settings.format.fileExtension], up: 1)
        // The picture itself steps on, as in most galleries; the last one
        // goes back to the grid.
        let onward = next ?? back
        var body = """
        <nav class="bar" aria-label="Gallery">
        <a class="up" href="\(escape(back))">\(escape(title))</a>
        <span class="position">\(index + 1) of \(items.count)</span>
        <span class="steps">\(step(previous, rel: "prev", label: "&larr; Previous")) \
        \(step(next, rel: "next", label: "Next &rarr;"))</span>
        </nav>
        <main>
        <figure>
        <a class="picture" href="\(escape(onward))"><img src="\(escape(image))" width="\(item.largeWidth)" \
        height="\(item.largeHeight)" alt="\(escape(altText(item)))"></a>
        \(pageCaption(item, settings))</figure>

        """
        if let original = item.originalName {
            let href = link([originalsFolder, original], up: 1)
            body += "<p class=\"original\"><a href=\"\(escape(href))\" download>Download the original file "
                + "(\(escape(item.fileName)))</a></p>\n"
        }
        body += "</main>"
        let pageTitle = "\(pageHeading(item)) – \(title)"
        return document(title: pageTitle, styleSheet: link([styleSheetName], up: 1), language: language, head: head,
                        bodyClass: "page", body: body)
    }

    /// The whole page around `body`. `title` and `language` are escaped
    /// here; `head` and `body` are already HTML.
    static func document(title: String, styleSheet: String, language: String, head: String, bodyClass: String,
                         body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(escape(language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none'; \
        form-action 'none'; base-uri 'none'">
        <meta name="referrer" content="no-referrer">
        <meta name="generator" content="minivu">
        <title>\(escape(title))</title>
        <link rel="stylesheet" href="\(escape(styleSheet))">
        \(head)</head>
        <body class="\(bodyClass)">
        \(body)
        </body>
        </html>

        """
    }

    /// The id of the thumbnail at `index`: made of digits only, never of a
    /// name, so it needs no escaping and never repeats.
    static func anchor(_ index: Int) -> String { "p\(index + 1)" }

    /// What a picture is described as to someone who can't see it: its
    /// title, else its file name.
    static func altText(_ item: WebGalleryItem) -> String {
        item.title.isEmpty ? item.fileName : item.title
    }

    static func pageHeading(_ item: WebGalleryItem) -> String {
        item.title.isEmpty ? item.fileName : item.title
    }

    /// The lines under a thumbnail, as chosen; none when nothing applies.
    static func gridCaption(_ item: WebGalleryItem, _ settings: WebGallerySettings) -> String {
        var lines: [String] = []
        if settings.showsTitle, !item.title.isEmpty { lines.append("<span class=\"title\">\(escape(item.title))</span>") }
        if settings.showsFileName { lines.append("<span class=\"name\">\(escape(item.fileName))</span>") }
        if settings.showsDate, !item.dateText.isEmpty {
            lines.append("<span class=\"date\">\(escape(item.dateText))</span>")
        }
        return lines.isEmpty ? "" : "<p class=\"caption\">" + lines.joined(separator: "<br>") + "</p>"
    }

    /// The captions under a large picture: the title and the caption (the
    /// metadata's description), the file name and the date, as chosen.
    static func pageCaption(_ item: WebGalleryItem, _ settings: WebGallerySettings) -> String {
        var lines: [String] = []
        if settings.showsTitle, !item.title.isEmpty { lines.append("<h1 class=\"title\">\(escape(item.title))</h1>") }
        if settings.showsTitle, !item.caption.isEmpty {
            lines.append("<p class=\"description\">\(escape(item.caption))</p>")
        }
        if settings.showsFileName { lines.append("<p class=\"name\">\(escape(item.fileName))</p>") }
        if settings.showsDate, !item.dateText.isEmpty {
            lines.append("<p class=\"date\">\(escape(item.dateText))</p>")
        }
        return lines.isEmpty ? "" : "<figcaption>\n" + lines.joined(separator: "\n") + "\n</figcaption>\n"
    }

    // MARK: - Style sheet

    /// `style.css`: the theme's colours, the grid (fixed columns, or as many
    /// as fit), and the picture pages. Numbers only come from the settings,
    /// never text.
    public static func styleSheet(settings: WebGallerySettings) -> String {
        let settings = settings.validated
        let light = """
            --background: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --cell: #f2f2f4; --link: #0066cc;
            --focus: #0071e3; color-scheme: light;
        """
        let dark = """
            --background: #161617; --text: #f5f5f7; --muted: #a1a1a6; --cell: #262628; --link: #4da3ff;
            --focus: #4da3ff; color-scheme: dark;
        """
        let colours: String
        switch settings.theme {
        case .light: colours = ":root {\n\(light)\n}"
        case .dark: colours = ":root {\n\(dark)\n}"
        case .automatic: colours = ":root {\n\(light)\n}\n@media (prefers-color-scheme: dark) {\n:root {\n\(dark)\n}\n}"
        }
        let cell = settings.thumbnailSize
        let columns: String
        if settings.columns == 0 {
            columns = "grid-template-columns: repeat(auto-fill, minmax(min(\(cell)px, 100%), 1fr));"
        } else {
            columns = "grid-template-columns: repeat(\(settings.columns), minmax(0, 1fr));"
        }
        // Fixed columns become fewer on a phone, rather than tiny.
        let narrow = settings.columns > 2
            ? "@media (max-width: 640px) {\n.grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }\n}\n" : ""
        return """
        /* Made by minivu. Only system fonts and files in this folder are used. */
        \(colours)
        * { box-sizing: border-box; }
        html { background: var(--background); color: var(--text); }
        body { margin: 0; font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, \
        sans-serif; }
        a { color: var(--link); }
        a:focus-visible { outline: 3px solid var(--focus); outline-offset: 2px; }
        .gallery-header { padding: 32px 24px 8px; }
        .gallery-header h1 { margin: 0; font-size: 28px; font-weight: 600; overflow-wrap: anywhere; }
        .count { margin: 4px 0 0; color: var(--muted); }
        .grid { list-style: none; margin: 0; padding: 16px 24px 40px; display: grid; gap: 20px; \(columns) }
        .grid li { min-width: 0; }
        .thumb { display: flex; align-items: center; justify-content: center; aspect-ratio: 1; \
        background: var(--cell); border-radius: 6px; overflow: hidden; }
        .thumb img { display: block; max-width: 100%; max-height: 100%; width: auto; height: auto; }
        .caption { margin: 6px 0 0; font-size: 13px; color: var(--muted); overflow-wrap: anywhere; }
        .caption .title { color: var(--text); font-weight: 500; }
        .bar { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px 20px; padding: 14px 24px; }
        .bar .up { font-weight: 600; text-decoration: none; overflow-wrap: anywhere; }
        .position { color: var(--muted); }
        .steps { margin-left: auto; display: flex; gap: 16px; }
        .step { text-decoration: none; }
        .step.disabled { color: var(--muted); opacity: 0.5; }
        figure { margin: 0; padding: 0 24px 24px; text-align: center; }
        .picture { display: inline-block; }
        .picture img { display: block; max-width: 100%; max-height: calc(100vh - 120px); width: auto; height: auto; \
        margin: 0 auto; }
        figcaption { margin: 12px auto 0; max-width: 60em; color: var(--muted); overflow-wrap: anywhere; }
        figcaption .title { margin: 0 0 4px; font-size: 20px; font-weight: 600; color: var(--text); }
        figcaption p { margin: 2px 0; }
        figcaption .description { color: var(--text); white-space: pre-line; }
        .original { text-align: center; margin: 0 0 32px; }
        \(narrow)
        """
    }
}
