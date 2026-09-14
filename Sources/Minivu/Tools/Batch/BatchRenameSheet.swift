import AppKit
import SwiftUI
import MinivuCore

/// Batch Rename as a sheet on the browser window: the pattern controls
/// above a live Before → After list, problems marked in the list and
/// explained under it, and Rename enabled only when every name works.
@MainActor final class BatchRenameSheet {
    let model: BatchRenameModel
    let window: NSWindow
    private weak var parent: NSWindow?
    private var onRename: (([BatchRenamer.Request]) -> Void)?
    /// Keeps the controller alive while its sheet is up.
    private var retainedSelf: BatchRenameSheet?

    init(model: BatchRenameModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 520)
        let view = BatchRenameView(model: model,
                                   onCancel: { [weak self] in self?.end() },
                                   onRename: { [weak self] in self?.rename() })
        window.contentView = NSHostingView(rootView: view)
    }

    /// Shows the sheet. `onRename` gets the renames to carry out; the
    /// sheet stays up (showing progress) until `end()`.
    func begin(on parent: NSWindow, onRename: @escaping ([BatchRenamer.Request]) -> Void) {
        self.parent = parent
        self.onRename = onRename
        retainedSelf = self
        BatchTools.beginSheet(window, on: parent)
    }

    private func rename() {
        guard let requests = model.beginRenaming() else { return NSSound.beep() }
        onRename?(requests)
    }

    func end() {
        if let parent { BatchTools.endSheet(window, on: parent) }
        onRename = nil
        retainedSelf = nil
    }
}

struct BatchRenameView: View {
    @Bindable var model: BatchRenameModel
    var onCancel: () -> Void
    var onRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(BatchRenameModel.actionName(count: model.entries.count))
                    .font(.headline)
                Text("Names are made from the pattern for each file, in the order shown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            RenamePatternEditor(pattern: $model.pattern, layout: .grid)
                .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .disabled(model.isRenaming)

            BatchRenameTable(items: model.plan?.items ?? [])
                .frame(minHeight: 200)
                .padding(.horizontal, 20)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if model.hasProblems {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.medium)
                }
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(model.hasProblems ? .primary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRenaming || !model.isPlanCurrent {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRenaming)
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRename)
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}

/// Before and after, one row per file. SwiftUI's table only makes the rows
/// on screen, so a 5000-file batch costs what the visible rows cost.
struct BatchRenameTable: View {
    let items: [RenamePlan.Item]

    struct Row: Identifiable {
        let id: Int
        let item: RenamePlan.Item
    }

    var body: some View {
        let rows = items.enumerated().map { Row(id: $0.offset, item: $0.element) }
        Table(rows) {
            TableColumn("Before") { row in
                Text(row.item.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("After") { row in
                HStack(spacing: 5) {
                    if let problem = row.item.problem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(problem.message)
                    }
                    Text(row.item.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.item.problem != nil ? Color.red
                                         : row.item.isUnchanged ? Color.secondary : Color.primary)
                }
                .help(row.item.problem?.message ?? (row.item.isUnchanged ? "The name doesn’t change." : ""))
            }
            TableColumn("") { row in
                Text(row.item.problem?.message ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 170)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
    }
}
