import SwiftUI
import MinivuCore

/// The order of the pictures a multi-page file or an image strip is made
/// from: the browser's order to start with, changed in the sheet by
/// dragging, by Move Up and Move Down on the selected rows, or by Reverse.
struct ImageOrder: Equatable {
    private(set) var entries: [FolderEntry]

    init(_ entries: [FolderEntry]) {
        self.entries = entries
    }

    var urls: [URL] { entries.map(\.url) }

    /// A drag in the list.
    mutating func move(from offsets: IndexSet, to destination: Int) {
        entries.move(fromOffsets: offsets, toOffset: destination)
    }

    /// The selected entries one place earlier (those already first stay).
    mutating func moveUp(_ selection: Set<URL>) {
        guard entries.count > 1 else { return }
        for index in 1..<entries.count where selection.contains(entries[index].url)
            && !selection.contains(entries[index - 1].url) {
            entries.swapAt(index, index - 1)
        }
    }

    /// The selected entries one place later (those already last stay).
    mutating func moveDown(_ selection: Set<URL>) {
        guard entries.count > 1 else { return }
        for index in stride(from: entries.count - 2, through: 0, by: -1) where selection.contains(entries[index].url)
            && !selection.contains(entries[index + 1].url) {
            entries.swapAt(index, index + 1)
        }
    }

    mutating func reverse() {
        entries.reverse()
    }

    func canMoveUp(_ selection: Set<URL>) -> Bool {
        entries.indices.contains { $0 > 0 && selection.contains(entries[$0].url) && !selection.contains(entries[$0 - 1].url) }
    }

    func canMoveDown(_ selection: Set<URL>) -> Bool {
        entries.indices.contains {
            $0 < entries.count - 1 && selection.contains(entries[$0].url) && !selection.contains(entries[$0 + 1].url)
        }
    }
}

/// The order as a list with its buttons, for the multi-page and strip
/// sheets. `detail` adds a note to a row ("12 pages").
struct ImageOrderList: View {
    @Binding var order: ImageOrder
    var detail: (FolderEntry) -> String? = { _ in nil }
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(Array(order.entries.enumerated()), id: \.element.url) { index, entry in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let note = detail(entry) {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(index + 1): \(entry.name)\(detail(entry).map { ", \($0)" } ?? "")")
                }
                .onMove { order.move(from: $0, to: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 120, idealHeight: 170)
            .accessibilityLabel("Order")
            HStack(spacing: 8) {
                Button {
                    order.moveUp(selection)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(!order.canMoveUp(selection))
                Button {
                    order.moveDown(selection)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(!order.canMoveDown(selection))
                Button("Reverse") { order.reverse() }
                    .disabled(order.entries.count < 2)
                    .accessibilityLabel("Reverse Order")
                Spacer()
                Text("Drag to change the order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
