import SwiftUI
import MinivuRender

/// The clone stamp and healing brush inspector: brush size in pixels of the
/// full image, hardness and opacity, and how to paint.
struct RetouchBrushInspectorView: View {
    @Bindable var state: RetouchToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                AdjustmentSliderRow(
                    slider: AdjustmentSlider(title: localized(.init("edit.size", defaultValue: "Size", comment: "Label: the size of a brush, text or watermark")),
                        range: state.brushSizeRange,
                                             defaultValue: RetouchToolState.defaultBrushSize(for: state.imageSize),
                                             unit: " px", logarithmic: true),
                    value: state.brushSize, setValue: { state.setBrushSize($0) },
                    reset: { state.setBrushSize(RetouchToolState.defaultBrushSize(for: state.imageSize)) })
                AdjustmentSliderRow(
                    slider: AdjustmentSlider(title: localized("Hardness"), range: 0...1, defaultValue: RetouchStroke.defaultHardness,
                                             displayScale: 100, unit: " %"),
                    value: state.hardness, setValue: { state.setHardness($0) },
                    reset: { state.setHardness(RetouchStroke.defaultHardness) })
                AdjustmentSliderRow(
                    slider: AdjustmentSlider(title: localized("Opacity"), range: 0.01...1, defaultValue: 1, displayScale: 100,
                                             unit: " %"),
                    value: state.opacity, setValue: { state.setOpacity($0) }, reset: { state.setOpacity(1) })
                Toggle("Aligned", isOn: .constant(true))
                    .disabled(true)
                    .help("The source follows the brush at the same distance for every stroke.")
            } footer: {
                InspectorFootnote(localized("[ and ] change the size."))
            }
            Section {
                LabeledContent("Source") {
                    Text(sourceDescription)
                        .foregroundStyle(state.needsSourceHint && state.source == .unset ? .red : .secondary)
                }
                LabeledContent("Strokes") {
                    Text(verbatim: "\(state.strokes.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                InspectorFootnote(state.mode == .clone
                    ? localized("Option-click where to copy from, then paint. ⌘Z removes the last stroke.")
                    : localized("Option-click on clean texture, then paint over the blemish: the texture is copied and matched to the surroundings. ⌘Z removes the last stroke."))
            }
        }
    }

    private var sourceDescription: String {
        switch state.source {
        case .unset: localized(.init("Option-click to set", comment: "Clone source: not set yet"))
        case .pending: localized(.init("retouch.source.set", defaultValue: "Set", comment: "Clone source: chosen, not used yet"))
        case .aligned: localized("Aligned")
        }
    }
}

/// The red-eye inspector: automatic detection, then a strength slider and
/// a remove button for each circle.
struct RedEyeInspectorView: View {
    @Bindable var state: RedEyeToolState
    let actions: InspectorActions
    let detect: () -> Void

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                HStack {
                    Button(action: detect) {
                        Label("Auto Detect", systemImage: "eye")
                    }
                    .disabled(state.detection == .running)
                    Spacer()
                    detectionStatus
                }
            } footer: {
                InspectorFootnote(localized("Or drag a circle over each red pupil, or click one. Only red pixels inside a circle change; the catchlight stays."))
            }
            if !state.spots.isEmpty {
                Section("Eyes") {
                    ForEach(Array(state.spots.indices), id: \.self) { index in
                        spotRow(index)
                    }
                }
            }
        }
    }

    @ViewBuilder private var detectionStatus: some View {
        switch state.detection {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .found(let count):
            Text(localized(.init("Found \(count) red eyes", comment: "Red-eye removal: eyes found by Auto Detect"))).foregroundStyle(.secondary)
        case .none:
            Text("No red eyes found").foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t look for faces").foregroundStyle(.secondary)
        }
    }

    private func spotRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(localized(.init("Eye \(index + 1)", comment: "Red-eye removal: the circle on one eye, numbered")))
                    .fontWeight(state.selection == index ? .semibold : .regular)
                Spacer()
                Button(role: .destructive) {
                    state.removeSpot(index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove This Circle")
            }
            AdjustmentSliderRow(
                slider: AdjustmentSlider(title: localized("Strength"), range: 0...1, defaultValue: 1, displayScale: 100, unit: " %"),
                value: state.spots[index].strength, setValue: { state.setStrength(index, $0) },
                reset: { state.setStrength(index, 1) })
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selection = index }
    }
}
