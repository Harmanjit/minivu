import SwiftUI
import MinivuCore

/// File information and EXIF for one image, as a grouped list.
///
/// Used by the browser's preview pane and the viewer's right-hand fly-out.
/// Metadata is read off the main thread (it touches the disk) and the view
/// shows the previous file's values until the new ones arrive, so arrowing
/// through a folder doesn't flash empty panels.
struct InfoPanelView: View {
    /// The file to describe, or nil for "nothing selected".
    let url: URL?

    @State private var sections: [MetadataSection] = []
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if url == nil {
                Text("No Selection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            SectionView(section: section)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: url) {
            guard let url else { sections = []; return }
            let read = await BlockingWork.run {
                MetadataReader.sections(for: url)
            }
            guard !Task.isCancelled else { return }
            sections = read
            loadedURL = url
        }
    }

    private struct SectionView: View {
        let section: MetadataSection

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(section.items, id: \.self) { item in
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
            }
        }
    }
}
