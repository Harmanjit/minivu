import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MinivuCore

/// Settings > Editors: the applications Open in External Editor lists, in
/// order, with suggestions of image editors already installed.
struct ExternalEditorsSettingsView: View {
    var store: ExternalEditorsStore
    @State private var suggestions: [ExternalEditor] = []

    init(store: ExternalEditorsStore = .shared) {
        self.store = store
    }

    var body: some View {
        Form {
            Section {
                if store.editors.isEmpty {
                    Text("No editors yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
                ForEach(Array(store.editors.enumerated()), id: \.element.id) { index, editor in
                    EditorRow(editor: editor, index: index, count: store.editors.count,
                              move: { store.move(at: index, by: $0) },
                              remove: { store.remove(at: index) })
                }
                .onMove { store.move(from: $0, to: $1) }
                HStack {
                    Spacer()
                    Button("Add…") { chooseApplications() }
                }
            } header: {
                Text("Open in External Editor")
            } footer: {
                Text("The first editor opens with ⌘E. The images open as saved; when the editor saves one, minivu shows the change.")
                    .paragraphFooter()
            }

            if !suggestions.isEmpty {
                Section {
                    LabeledContent("Suggestions") {
                        FlowLayout(spacing: 6) {
                            ForEach(suggestions) { editor in
                                Button {
                                    add(editor)
                                } label: {
                                    Label {
                                        Text(editor.name)
                                    } icon: {
                                        Image(nsImage: ExternalEditorsStore.icon(for: editor, size: 16))
                                    }
                                }
                                .help("Add \(editor.name)")
                            }
                        }
                    }
                }
            }
        }
        .settingsForm()
        .task(id: store.editors.map(\.id)) { await findSuggestions() }
    }

    private func add(_ editor: ExternalEditor) {
        store.add(editor)
    }

    /// Installed image editors not yet in the list, looked up off the main
    /// thread (Launch Services and a few Info.plist reads).
    private func findSuggestions() async {
        let existing = Set(store.editors.flatMap { [$0.id, $0.path] })
        let found = await BlockingWork.run(qos: .utility) { ExternalEditorSuggestions.find(excluding: existing) }
        suggestions = found
    }

    /// An open panel in Applications. The URLs it returns carry the sandbox's
    /// permission, so their bookmarks are made from them.
    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose applications to open images in."
        let store = self.store
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            for url in panel.urls { store.add(applicationAt: url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

private struct EditorRow: View {
    var editor: ExternalEditor
    var index: Int
    var count: Int
    var move: (Int) -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ExternalEditorsStore.icon(for: editor, size: 24))
            Text(editor.name)
            if index == 0 {
                Text("⌘E")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(.tertiary))
            }
            if !FileManager.default.fileExists(atPath: editor.path) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("The application is no longer where it was added.")
            }
            Spacer()
            HStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move Up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .help("Move Down")
                Button(role: .destructive) { remove() } label: { Image(systemName: "minus.circle") }
                    .help("Remove \(editor.name)")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full,
/// aligned to the trailing edge like the rest of a settings row.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.maxX - row.width
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

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
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
