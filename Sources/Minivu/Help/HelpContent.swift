import Foundation
import MinivuCore

/// The pages of Help > minivu Help, in sidebar order.
///
/// Every page but Keyboard Shortcuts is a Markdown file in HelpPages, named
/// by the raw value. Keyboard Shortcuts is made at runtime from the menu bar
/// (`KeyboardShortcutsPage`), so it can never disagree with the menus.
nonisolated enum HelpPage: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted = "GettingStarted"
    case browser = "Browser"
    case viewer = "Viewer"
    case editing = "Editing"
    case effects = "Effects"
    case tools = "Tools"
    case settings = "Settings"
    case privacy = "Privacy"
    case shortcuts = "KeyboardShortcuts"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "Getting Started"
        case .browser: "Browser"
        case .viewer: "Viewer"
        case .editing: "Editing"
        case .effects: "Effects & Retouching"
        case .tools: "Tools"
        case .settings: "Settings"
        case .privacy: "Privacy"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    /// SF Symbol for the sidebar.
    var symbol: String {
        switch self {
        case .gettingStarted: "star"
        case .browser: "square.grid.3x3"
        case .viewer: "photo"
        case .editing: "slider.horizontal.3"
        case .effects: "wand.and.stars"
        case .tools: "hammer"
        case .settings: "gearshape"
        case .privacy: "hand.raised"
        case .shortcuts: "keyboard"
        }
    }

    /// The bundled Markdown file's name, or nil for the generated page.
    var resourceName: String? { self == .shortcuts ? nil : rawValue }

    /// Pages link to each other as `help:Browser` (the raw value), so a
    /// link never needs a web address.
    static let linkScheme = "help"

    init?(link: URL) {
        guard link.scheme == Self.linkScheme,
              let name = URLComponents(url: link, resolvingAgainstBaseURL: false)?.path,
              let page = HelpPage(rawValue: name) else { return nil }
        self = page
    }
}

/// Reads the bundled pages.
nonisolated enum HelpLibrary {
    /// The resource folder (Package.swift copies it whole).
    static let folder = "HelpPages"

    /// The Markdown text of `page`, or nil for the generated page or a file
    /// that is missing. Small files, but still file I/O: callers read them
    /// through `BlockingWork`.
    static func markdown(for page: HelpPage, bundle: Bundle = .minivuHelp) -> String? {
        guard let name = page.resourceName,
              let url = bundle.url(forResource: name, withExtension: "md", subdirectory: folder) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Every Markdown page, read and parsed off the main thread. Pages that
    /// fail to load are left out, and the window says so.
    static func loadAll() async -> [HelpPage: [HelpBlock]] {
        await BlockingWork.run {
            var pages: [HelpPage: [HelpBlock]] = [:]
            for page in HelpPage.allCases {
                guard let text = markdown(for: page), let blocks = try? HelpMarkdown.blocks(from: text) else { continue }
                pages[page] = blocks
            }
            return pages
        }
    }
}

extension Bundle {
    /// The app target's resource bundle (the help pages), found where a
    /// shipped app keeps it.
    ///
    /// As with `Bundle.minivuRender`, an .app keeps resources in
    /// Contents/Resources, where SwiftPM's `Bundle.module` doesn't look. That
    /// accessor is also main-actor isolated in this target and stops the app
    /// when it finds nothing; a missing page should only say so. So the
    /// places are tried here: the app's Resources, beside `swift build`'s
    /// executable, and beside the test bundle.
    nonisolated static let minivuHelp: Bundle = {
        let name = "minivu_Minivu.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                      Bundle(for: HelpBundleToken.self).bundleURL.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.main
    }()
}

/// A class of this module, so `Bundle(for:)` finds the binary holding it.
private nonisolated final class HelpBundleToken {}

/// One block of a help page: a heading, a paragraph, a list item's
/// paragraph or a code block, with its inline styling (bold, italic, code,
/// links) kept in the attributed text.
nonisolated struct HelpBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        /// A paragraph inside a list, `depth` lists deep (1 for a top-level
        /// list). `marker` is "•" or "3." on an item's first paragraph and
        /// nil on the ones after it.
        case listItem(depth: Int, marker: String?)
        case code
        /// A paragraph inside a block quote: shown as a note.
        case note
    }

    let id: Int
    let kind: Kind
    let text: AttributedString

    var plainText: String { String(text.characters) }
}

/// Turns Markdown into `HelpBlock`s.
///
/// `AttributedString(markdown:)` with full syntax parses the block structure
/// but leaves it as `presentationIntent` attributes: SwiftUI's `Text` would
/// run every paragraph, heading and list item together. So the runs are
/// grouped by their block here, and the window lays each block out itself.
nonisolated enum HelpMarkdown {
    static func blocks(from markdown: String) throws -> [HelpBlock] {
        let document = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        var blocks: [HelpBlock] = []
        var itemsWithMarker = Set<Int>()
        for (intent, range) in document.runs[\.presentationIntent] {
            guard let intent else { continue }
            var text = AttributedString(document[range])
            text.presentationIntent = nil
            guard let kind = kind(of: intent, itemsWithMarker: &itemsWithMarker) else { continue }
            if kind == .code {
                // A code block's text ends with its closing newline.
                while text.characters.last == "\n" { text.characters.removeLast() }
            }
            // Blocks of one kind that follow each other with the same intent
            // are one block split by an attribute the grouping didn't see.
            if let last = blocks.last, last.kind == kind, last.id == intent.components.first?.identity {
                blocks[blocks.count - 1] = HelpBlock(id: last.id, kind: kind, text: last.text + text)
                continue
            }
            blocks.append(HelpBlock(id: intent.components.first?.identity ?? blocks.count, kind: kind, text: text))
        }
        return blocks
    }

    /// Components run from the innermost block outwards.
    private static func kind(of intent: PresentationIntent, itemsWithMarker: inout Set<Int>) -> HelpBlock.Kind? {
        var base: HelpBlock.Kind = .paragraph
        var depth = 0
        var item: (identity: Int, ordinal: Int)?
        var innermostListIsOrdered: Bool?
        var quoted = false
        for component in intent.components {
            switch component.kind {
            case .header(let level): base = .heading(level: level)
            case .codeBlock: base = .code
            case .thematicBreak: return nil
            case .blockQuote: quoted = true
            case .listItem(let ordinal):
                if item == nil { item = (component.identity, ordinal) }
            case .orderedList, .unorderedList:
                depth += 1
                if innermostListIsOrdered == nil { innermostListIsOrdered = component.kind == .orderedList }
            default: break
            }
        }
        if base != .paragraph { return base }
        if let item {
            let isFirst = itemsWithMarker.insert(item.identity).inserted
            let marker = innermostListIsOrdered == true ? "\(item.ordinal)." : "•"
            return .listItem(depth: depth, marker: isFirst ? marker : nil)
        }
        return quoted ? .note : .paragraph
    }

    /// How many times `query` appears in `text`, ignoring case and accents.
    static func matchCount(of query: String, in text: String) -> Int {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }
}
