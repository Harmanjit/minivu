import AppKit
import SwiftUI

/// Help > minivu Help and Help > Keyboard Shortcuts. Named apart from
/// NSApplication's own `showHelp:`, which would answer first in the
/// responder chain and look for a Help Book minivu doesn't have.
extension AppDelegate {
    @objc func showMinivuHelp(_ sender: Any?) {
        HelpWindowController.show(page: nil)
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.show(page: .shortcuts)
    }

    #if DEBUG
    /// Debug only, for the snapshot harness: Help searching for
    /// MINIVU_DEBUG_HELP_SEARCH (default "rename") on MINIVU_DEBUG_HELP_PAGE
    /// (a page's raw value, default Browser).
    @objc func debugHelpSearch(_ sender: Any?) {
        let environment = ProcessInfo.processInfo.environment
        let page = environment["MINIVU_DEBUG_HELP_PAGE"].flatMap(HelpPage.init(rawValue:)) ?? .browser
        HelpWindowController.show(page: page)
        HelpWindowController.shared?.model.query = environment["MINIVU_DEBUG_HELP_SEARCH"] ?? "rename"
    }
    #endif
}

/// The Help window: bundled pages in a sidebar with search, rendered
/// natively. Nothing is fetched: the app has no network access, and no Help
/// Book is registered, so Help Viewer is never involved.
///
/// SwiftUI, as Settings is (DESIGN.md 4.1): a page of text is not a hot
/// path. One window, made on first use and kept, so it reopens on the page
/// and search the user left.
final class HelpWindowController: NSWindowController {
    private(set) static var shared: HelpWindowController?

    let model = HelpModel()

    static let defaultSize = NSSize(width: 880, height: 640)
    static let minimumSize = NSSize(width: 640, height: 420)

    /// Brings the window forward, on `page` if given.
    static func show(page: HelpPage?) {
        let controller = shared ?? HelpWindowController()
        shared = controller
        if let page { controller.model.select(page) }
        controller.model.refreshShortcuts()
        controller.showWindow(nil)
    }

    private init() {
        let hosting = NSHostingController(rootView: HelpView(model: model))
        // The window's size is the user's, not the content's: a split view
        // would otherwise shrink it to its smallest fitting size.
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.contentViewController = hosting
        window.title = "minivu Help"
        window.minSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName("Help")
        if window.frame.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
            window.setContentSize(Self.defaultSize)
            window.center()
        }
        super.init(window: window)
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// What the Help window shows: the loaded pages, the page selected and the
/// search.
@Observable final class HelpModel {
    var selection: HelpPage? = .gettingStarted
    var query = ""
    private(set) var pages: [HelpPage: [HelpBlock]] = [:]
    private(set) var shortcuts: [ShortcutSection] = []
    private(set) var isLoaded = false

    func select(_ page: HelpPage) {
        selection = page
    }

    /// Reads the Markdown pages in the background; the window shows as soon
    /// as it opens, and pages appear when read (a few milliseconds).
    func load() {
        Task {
            pages = await HelpLibrary.loadAll()
            isLoaded = true
        }
    }

    /// Made again each time the window comes forward: the external editors
    /// in the Tools menu (and so ⌘E) can change while it is closed.
    func refreshShortcuts() {
        shortcuts = KeyboardShortcutsPage.sections()
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func matchCount(_ page: HelpPage) -> Int {
        guard isSearching else { return 0 }
        let text = page == .shortcuts
            ? shortcuts.map(\.plainText).joined(separator: "\n")
            : (pages[page] ?? []).map(\.plainText).joined(separator: "\n")
        return HelpMarkdown.matchCount(of: query, in: page.title + "\n" + text)
    }

    /// The sidebar: every page, or while searching only pages that match.
    var visiblePages: [HelpPage] {
        guard isSearching else { return HelpPage.allCases }
        return HelpPage.allCases.filter { matchCount($0) > 0 }
    }
}

struct HelpView: View {
    @Bindable var model: HelpModel

    var body: some View {
        NavigationSplitView {
            List(model.visiblePages, selection: $model.selection) { page in
                Label(page.title, systemImage: page.symbol)
                    .badge(model.matchCount(page))
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
            .overlay {
                if model.isSearching && model.visiblePages.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
        } detail: {
            detail
        }
        // Pages link to each other with help: links. Anything else is
        // refused: help never opens a browser.
        .environment(\.openURL, OpenURLAction { url in
            guard let page = HelpPage(link: url) else { return .discarded }
            model.select(page)
            return .handled
        })
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .shortcuts:
            ShortcutsPageView(sections: model.shortcuts, query: model.isSearching ? model.query : "")
        case let page?:
            if let blocks = model.pages[page] {
                // A page of its own identity, so each opens at its top.
                HelpPageView(blocks: blocks, query: model.isSearching ? model.query : "")
                    .id(page)
            } else if model.isLoaded {
                ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("This help page couldn’t be read from the app."))
            } else {
                Color.clear
            }
        case nil:
            ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle")
        }
    }
}

/// A Markdown page: blocks in a readable column, search matches highlighted
/// and the first one scrolled into view.
struct HelpPageView: View {
    let blocks: [HelpBlock]
    let query: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        HelpBlockView(block: block, query: query)
                            .padding(.top, topSpacing(before: index))
                            .id(block.id)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scrollToFirstMatch(proxy) }
            .onChange(of: query) { scrollToFirstMatch(proxy) }
        }
    }

    /// Headings get room above them; list items sit close together.
    private func topSpacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (blocks[index - 1].kind, blocks[index].kind) {
        case (_, .heading(let level)): return level <= 2 ? 22 : 14
        case (.heading(let level), _): return level == 1 ? 12 : 8
        case (.listItem, .listItem(_, let marker)): return marker == nil ? 4 : 6
        default: return 10
        }
    }

    /// While searching, brings the first match into view, a little below
    /// the top so the title bar never covers it. Without a search the page
    /// stays where the reader put it.
    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        guard !query.isEmpty,
              let target = blocks.first(where: { HelpMarkdown.matchCount(of: query, in: $0.plainText) > 0 }) else { return }
        proxy.scrollTo(target.id, anchor: UnitPoint(x: 0, y: 0.25))
    }
}

struct HelpBlockView: View {
    let block: HelpBlock
    let query: String

    var body: some View {
        switch block.kind {
        case .heading(let level):
            text.font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            text.fixedSize(horizontal: false, vertical: true)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                text.fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 22)
        case .code:
            text.font(.body.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb").foregroundStyle(.secondary)
                text.fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var text: Text {
        Text(HelpHighlight.highlighting(query, in: block.text))
    }
}

/// Search matches, marked the way Find marks them.
enum HelpHighlight {
    static func highlighting(_ query: String, in text: AttributedString) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let found = result[searchStart...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[found].backgroundColor = Color(nsColor: .findHighlightColor).opacity(0.6)
            searchStart = found.upperBound
        }
        return result
    }
}

/// Keyboard Shortcuts: groups of rows in rounded boxes, as System Settings
/// lists shortcuts, in the same column as the other pages. While searching,
/// only matching rows show.
struct ShortcutsPageView: View {
    let sections: [ShortcutSection]
    let query: String

    var body: some View {
        let shown = sections.compactMap { $0.filtered(by: query) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard Shortcuts").font(.largeTitle.bold())
                Text("The shortcuts in the menus, then the keys the browser, viewer and tools use directly. "
                    + "Menu commands act on the window in front.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                ForEach(shown) { section in
                    ShortcutSectionView(section: section, query: query)
                        .padding(.top, 22)
                }
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 40)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ShortcutSectionView: View {
    let section: ShortcutSection
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HelpHighlight.highlighting(query, in: AttributedString(section.title))).font(.title3.weight(.semibold))
            if let note = section.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(HelpHighlight.highlighting(query, in: AttributedString(row.title)))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(HelpHighlight.highlighting(query, in: AttributedString(row.keys)))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
            .padding(.top, 4)
        }
    }
}
