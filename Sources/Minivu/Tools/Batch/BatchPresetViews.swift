import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// The Preset row of the batch sheets (G6): a popup of the named presets,
/// None first, and a menu to save the sheet as a preset, rename the chosen
/// one or delete it. Names are asked for in an alert with a text field; a
/// preset saved under a name already used replaces that preset.
struct BatchPresetControls: View {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    let items: [Item]
    let selection: UUID?
    /// The Save alert's text: what a preset keeps.
    let saveMessage: String
    let onChoose: (UUID?) -> Void
    let onSave: (String) -> Bool
    let onRename: (String) -> Bool
    let onDelete: () -> Void

    private enum Naming { case save, rename }
    @State private var naming: Naming?
    @State private var name = ""
    @State private var confirmingDelete = false

    private var selectedName: String? { items.first { $0.id == selection }?.name }

    var body: some View {
        LabeledContent("Preset") {
            HStack(spacing: 6) {
                Picker("Preset", selection: Binding(get: { selection }, set: onChoose)) {
                    Text("None").tag(UUID?.none)
                    if !items.isEmpty { Divider() }
                    ForEach(items) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Preset")
                Menu {
                    Button("Save Preset…") {
                        name = selectedName ?? ""
                        naming = .save
                    }
                    Button("Rename Preset…") {
                        name = selectedName ?? ""
                        naming = .rename
                    }
                    .disabled(selection == nil)
                    Divider()
                    Button("Delete Preset…", role: .destructive) { confirmingDelete = true }
                        .disabled(selection == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Save, rename or delete presets")
                .accessibilityLabel("Preset Actions")
            }
        }
        .alert(naming == .rename ? localized("Rename Preset") : localized("Save Preset"), isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
                .accessibilityLabel("Preset name")
            Button(naming == .rename ? localized("Rename") : localized("Save")) {
                let ok = naming == .rename ? onRename(name) : onSave(name)
                if !ok { NSSound.beep() }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming == .rename ? localized("A name no other preset has.") : saveMessage)
        }
        .alert(localized("Delete the preset “\(selectedName ?? "")”?"), isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone. Images already converted or renamed aren’t affected.")
        }
    }
}

/// Batch Convert's watermark, edited in the viewer's own watermark inspector
/// as a sheet over the Convert sheet. There is no photo to preview on, so
/// the inspector's state has no document; Apply hands back the watermark
/// (nil when it would draw nothing) and Cancel leaves the batch as it was.
@MainActor final class BatchWatermarkSheet {
    let state: EffectToolState<Watermark>
    let window: NSWindow
    private weak var parent: NSWindow?
    private var onDone: ((Watermark?) -> Void)?
    private var retainedSelf: BatchWatermarkSheet?

    init(watermark: Watermark?) {
        state = EffectToolState(kind: .watermark, document: nil, initial: watermark ?? Watermark.starting()) {
            .watermark($0)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 420)
        let actions = InspectorActions(back: { [weak self] in self?.cancel() },
                                       reset: { [weak self] in self?.state.reset() },
                                       cancel: { [weak self] in self?.cancel() },
                                       apply: { [weak self] in self?.apply() })
        let view = WatermarkInspectorView(state: state, actions: actions,
                                          chooseImage: { [weak self] in self?.chooseImage() })
        window.contentView = NSHostingView(rootView: view)
    }

    func begin(on parent: NSWindow, onDone: @escaping (Watermark?) -> Void) {
        self.parent = parent
        self.onDone = onDone
        retainedSelf = self
        window.setContentSize(NSSize(width: 360, height: min(max(parent.frame.height - 60, 420), 680)))
        BatchTools.beginSheet(window, on: parent)
    }

    func apply() {
        let watermark = state.payload
        let done = onDone
        end()
        done?(watermark.isIdentity ? nil : watermark)
    }

    func cancel() {
        end()
    }

    /// The picture, chosen with the viewer's open panel (a hook tests
    /// replace), kept as a read-only bookmark as the viewer keeps it. Files
    /// on removable or network volumes are refused, as everywhere in minivu.
    func chooseImage() {
        ViewerWindowController.askForWatermarkImage(window) { [weak self] url in
            guard let self, let url else { return }
            guard VolumePolicy.isAllowed(url), let bookmark = Watermark.bookmark(for: url) else {
                NSSound.beep()
                return
            }
            self.state.update {
                $0.kind = .image
                $0.imageBookmark = bookmark
                $0.imageName = url.lastPathComponent
            }
        }
    }

    private func end() {
        if let parent { BatchTools.endSheet(window, on: parent) }
        onDone = nil
        retainedSelf = nil
    }
}
