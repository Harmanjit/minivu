import AppKit
import SwiftUI
import MinivuCore

/// The text of a JPEG comment being edited, and what writing it costs.
@MainActor @Observable final class CommentEditorModel {
    let url: URL
    let original: String
    var text: String
    private(set) var isSaving = false

    init(url: URL, comment: String) {
        self.url = url
        original = comment
        text = comment
    }

    var hasChanges: Bool { text != original }

    /// Comments are stored as UTF-8.
    var byteCount: Int { text.utf8.count }

    var byteCountText: String {
        Self.byteCountText(byteCount)
    }

    /// "1 byte", "1,204 bytes". One COM segment holds 65,533 bytes; a longer
    /// comment is split across several, which minivu and FastStone read back
    /// as one, so that is noted rather than refused.
    nonisolated static func byteCountText(_ bytes: Int) -> String {
        let count = bytes == 1 ? "1 byte" : "\(bytes.formatted()) bytes"
        let segments = (bytes + JPEGCommentLimits.segmentPayload - 1) / JPEGCommentLimits.segmentPayload
        return segments > 1 ? "\(count) (stored in \(segments) segments)" : count
    }

    /// Writes the comment in the background, replacing the file atomically
    /// without touching the compressed image. In line behind any other write
    /// (`FileWriteQueue`): a rotate still running on this file would
    /// otherwise be undone by the comment's rewrite, or undo it.
    func save() async throws {
        isSaving = true
        defer { isSaving = false }
        let text = self.text, url = self.url
        _ = try await FileWriteQueue.shared.enqueue(touching: [url]) {
            try await BlockingWork.run {
                try JPEGComment.write(text, to: url)
            }
        }.value
    }
}

nonisolated enum JPEGCommentLimits {
    /// The payload of one COM segment: a 16-bit length that counts itself.
    static let segmentPayload = 65_533
}

/// The comment editor as a sheet on the browser or viewer window.
@MainActor final class CommentEditorSheet {
    let model: CommentEditorModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var completion: ((Bool) -> Void)?
    /// Keeps the controller alive while its sheet is up.
    private var retainedSelf: CommentEditorSheet?

    init(url: URL, comment: String) {
        model = CommentEditorModel(url: url, comment: comment)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 420, height: 240)
        let view = CommentEditorView(model: model,
                                     onCancel: { [weak self] in self?.end(saved: false) },
                                     onSave: { [weak self] in self?.save() })
        window.contentView = NSHostingView(rootView: view)
    }

    func begin(on parent: NSWindow, completion: @escaping (Bool) -> Void) {
        self.parent = parent
        self.completion = completion
        retainedSelf = self
        parent.beginSheet(window)
    }

    private func save() {
        guard !model.isSaving else { return }
        guard model.hasChanges else { return end(saved: false) }
        Task {
            do {
                try await model.save()
                SavePresenter.didWrite(model.url)
                end(saved: true)
            } catch {
                SaveAlert.show(error, title: "The comment couldn’t be saved.", on: window)
            }
        }
    }

    private func end(saved: Bool) {
        parent?.endSheet(window)
        window.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        retainedSelf = nil
        completion?(saved)
    }
}

struct CommentEditorView: View {
    @Bindable var model: CommentEditorModel
    var onCancel: () -> Void
    var onSave: () -> Void
    /// The text is focused when the sheet opens, so typing, ⌘Return and Esc
    /// work without a click first.
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("JPEG Comment")
                    .font(.headline)
                Text("Written into “\(model.url.lastPathComponent)” without re-encoding the image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(minHeight: 120)
                .focused($isEditing)
                .onAppear { isEditing = true }

            HStack(spacing: 10) {
                Text(model.byteCountText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Return is a line break in a comment, so saving is ⌘Return;
                // prominent, since it can't take the default button's Return.
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save the comment (⌘Return)")
                    .disabled(!model.hasChanges || model.isSaving)
            }
            .controlSize(.regular)
        }
        .padding(20)
    }
}
