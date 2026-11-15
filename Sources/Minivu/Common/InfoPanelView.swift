import SwiftUI
import MinivuCore

/// File information and EXIF for one image, as a grouped list.
///
/// Used by the browser's preview pane and the viewer's right-hand fly-out.
/// Metadata is read off the main thread (it touches the disk) and the view
/// shows the previous file's values until the new ones arrive, so arrowing
/// through a folder doesn't flash empty panels.
///
/// With `editKeywords` set (a file whose metadata can be written), the
/// keywords are their own section, each with a button that removes it, and
/// a field that adds more: quicker than Edit Metadata for the commonest
/// change. The host writes the change as Edit Metadata does.
struct InfoPanelView: View {
    /// The file to describe, or nil for "nothing selected".
    let url: URL?
    /// The file's date as listed: a new one (another application saved the
    /// file) reads the metadata again, for the same URL.
    var modified: Date?
    /// Writes a keyword change to `url`; nil shows the keywords read-only.
    var editKeywords: ((MetadataEdit) -> Void)?

    @State private var sections: [MetadataSection] = []
    @State private var keywords: [String]?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if url == nil {
                Text("No Selection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // One grid for every section, so the labels of File, Image
                    // and Camera share one column instead of each section
                    // lining up on its own longest label.
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            GridRow {
                                SectionTitle(title: section.title, isFirst: index == 0)
                                    .gridCellColumns(2)
                            }
                            ForEach(shownItems(of: section), id: \.self) { item in
                                GridRow {
                                    Text(item.label)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(item.value)
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                }
                                .font(.callout)
                            }
                        }
                        if let editKeywords, let keywords, loadedURL == url {
                            GridRow {
                                SectionTitle(title: "Keywords", isFirst: sections.isEmpty)
                                    .gridCellColumns(2)
                            }
                            GridRow {
                                KeywordEditor(keywords: keywords, edit: editKeywords)
                                    .gridCellColumns(2)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: Subject(url: url, modified: modified, revision: MetadataRevisions.shared.revision(of: url))) {
            guard let url else { sections = []; keywords = nil; return }
            let read = await BlockingWork.run {
                MetadataReader.sectionsAndFields(for: url)
            }
            guard !Task.isCancelled else { return }
            sections = read.sections
            keywords = read.fields?.keywords
            loadedURL = url
        }
    }

    /// The section's rows, less the keywords when they have a section of
    /// their own to be edited in.
    private func shownItems(of section: MetadataSection) -> [MetadataItem] {
        guard editKeywords != nil, keywords != nil, section.title == "Description" else { return section.items }
        return section.items.filter { $0.label != "Keywords" }
    }

    /// What the panel describes. `revision` counts minivu's metadata writes
    /// to the file: one into an XMP sidecar leaves the file's date alone.
    private struct Subject: Hashable {
        var url: URL?
        var modified: Date?
        var revision: Int
    }
}

/// A section's heading, as the info panel draws them.
private struct SectionTitle: View {
    var title: String
    var isFirst: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, isFirst ? 0 : 11)
            .padding(.bottom, 1)
    }
}

/// A file's keywords as tokens, each with a button that removes it, then a
/// field that adds more, separated by commas, with Return (G4). Adding
/// skips a keyword the file has in another letter case, as Edit Metadata
/// does.
struct KeywordEditor: View {
    var keywords: [String]
    var edit: (MetadataEdit) -> Void
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if keywords.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                KeywordFlow(spacing: 4) {
                    ForEach(keywords, id: \.self) { keyword in
                        HStack(spacing: 3) {
                            Text(keyword)
                            Button {
                                edit(MetadataEdit(removedKeywords: [keyword]))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove “\(keyword)”")
                            .accessibilityLabel("Remove keyword \(keyword)")
                        }
                        .font(.callout)
                        .padding(.leading, 7)
                        .padding(.trailing, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    }
                }
            }
            TextField("Add Keywords", text: $entry, prompt: Text("Add keywords"))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .accessibilityLabel("Add keywords")
                .accessibilityHint("Separate keywords with commas, then press Return.")
                .onSubmit(commit)
        }
    }

    private func commit() {
        let added = Self.keywords(in: entry)
        entry = ""
        guard !added.isEmpty else { return }
        edit(MetadataEdit(addedKeywords: added))
    }

    /// "Paris, Seine ,, night" to its keywords.
    nonisolated static func keywords(in text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Lays its views out in rows, left to right, wrapping to the next row
/// where the width runs out: the keywords, however many there are.
struct KeywordFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
