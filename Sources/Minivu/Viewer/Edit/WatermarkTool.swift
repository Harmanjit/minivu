import AppKit
import SwiftUI
import MinivuRender

/// Nine buttons in a square, one per `EditAnchor`, for Canvas Size's anchor
/// and the watermark's position. The chosen one is filled.
struct AnchorGrid: View {
    let selection: EditAnchor
    /// What VoiceOver says before each place: "Position: Top Left".
    let label: String
    let onSelect: (EditAnchor) -> Void

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        cell(EditAnchor.allCases[row * 3 + column])
                    }
                }
            }
        }
    }

    private func cell(_ anchor: EditAnchor) -> some View {
        let selected = anchor == selection
        return Button { onSelect(anchor) } label: {
            Image(systemName: selected ? "square.fill" : "square")
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .help(anchor.title)
        .accessibilityLabel("\(label): \(anchor.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Watermark {
    /// What the watermark tool opens with: "© " and this year, in the
    /// default place and size.
    static func starting(now: Date = Date()) -> Watermark {
        var watermark = Watermark()
        watermark.text = "© " + String(Calendar(identifier: .gregorian).component(.year, from: now))
        return watermark
    }
}

/// The watermark's inspector: text (with font, weight and colour) or a
/// chosen picture, then its size, opacity, place and tiling.
struct WatermarkInspectorView: View {
    @Bindable var state: EffectToolState<Watermark>
    let actions: InspectorActions
    let chooseImage: () -> Void

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Kind", selection: state.binding(\.kind)) {
                    ForEach(Watermark.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if state.payload.kind == .text {
                    TextField("Text", text: state.binding(\.text))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Watermark text")
                    LabeledContent("Font") {
                        FontFamilyPopUp(family: state.payload.fontFamily) { family in
                            state.update { $0.fontFamily = family }
                        }
                        .accessibilityLabel("Font")
                    }
                    Picker("Weight", selection: state.binding(\.fontWeight)) {
                        ForEach(Annotation.FontWeight.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    ColorPicker("Color", selection: state.colorBinding(\.color), supportsOpacity: false)
                } else {
                    LabeledContent("Picture") {
                        Text(state.payload.imageName ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(state.payload.imageBookmark == nil ? .secondary : .primary)
                    }
                    Button(state.payload.imageBookmark == nil ? "Choose Picture…" : "Choose Another…", action: chooseImage)
                }
            } footer: {
                if state.payload.kind == .image {
                    InspectorFootnote("PNG or HEIC pictures with transparency work best. minivu remembers the file, so a saved watermark finds it again; if it moves, choose it again.")
                }
            }
            Section {
                state.slider(\.size, "Size", range: Watermark.sizeRange, displayScale: 100, decimals: 1, unit: "%")
                state.slider(\.opacity, "Opacity", range: 0...1, displayScale: 100, unit: "%")
                LabeledContent("Position") {
                    AnchorGrid(selection: state.payload.position, label: "Position") { anchor in
                        state.update { $0.position = anchor }
                    }
                }
                state.slider(\.margin, "Margin", range: Watermark.marginRange, displayScale: 100, decimals: 1, unit: "%")
                Toggle("Tile across the photo", isOn: state.binding(\.tiled))
                if state.payload.tiled {
                    state.slider(\.spacing, "Spacing", range: Watermark.spacingRange, decimals: 1, unit: "×")
                }
            } header: {
                Text("Placement")
            } footer: {
                InspectorFootnote("Size and margin are percentages of the photo’s short side, so the watermark covers the same share of any photo. Spacing is in watermark heights.")
            }
        }
    }
}
