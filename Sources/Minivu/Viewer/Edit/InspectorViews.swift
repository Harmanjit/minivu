import AppKit
import SwiftUI
import MinivuRender

/// What an inspector's buttons do; the viewer supplies them.
struct InspectorActions {
    var back: () -> Void
    var reset: () -> Void
    var cancel: () -> Void
    var apply: () -> Void
}

/// The frame every tool inspector shares: a header with a back chevron,
/// the tool's controls in a grouped form, and Reset, Cancel and Apply.
///
/// Apply is the default button and Cancel the cancel button, so Return and
/// Esc work from the text fields too. (With the canvas focused the viewer
/// handles those keys itself, before its own meanings for them.)
struct ToolInspector<Content: View>: View {
    let title: String
    let actions: InspectorActions
    var showsApply = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(title: title, back: actions.back)
            Divider()
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            Divider()
            HStack {
                if showsApply {
                    Button("Reset", action: actions.reset)
                    Spacer()
                    Button("Cancel", action: actions.cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Apply", action: actions.apply)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("Done", action: actions.back)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }
}

/// A hint under a form section, leading-aligned as System Settings has them
/// (a grouped form's footer otherwise follows the trailing edge).
struct InspectorFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Back to Tools")
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

// MARK: - Sliders

/// A labelled slider with a number field. The label row holds the name and
/// the field; the slider takes the full width under it, which a narrow
/// panel needs.
struct AdjustmentSliderRow: View {
    let slider: AdjustmentSlider
    let value: Double
    let setValue: (Double) -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // The unit beside the name, so every field lines up at the edge.
                if slider.unit.isEmpty {
                    Text(slider.title)
                } else {
                    Text(slider.title) + Text(verbatim: " (\(slider.unit.trimmingCharacters(in: .whitespaces)))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField(slider.title, value: Binding(get: { value * slider.displayScale },
                                                        set: { setValue($0 / slider.displayScale) }),
                          format: .number.precision(.fractionLength(slider.decimals)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
            }
            ResettableSlider(value: slider.position(for: value), range: slider.positionRange,
                             onChange: { setValue(slider.value(forPosition: $0)) }, onReset: reset)
                .help("Double-click to reset")
        }
    }
}

/// An `NSSlider` that reports a double-click, which resets it. SwiftUI's own
/// slider tracks the mouse inside AppKit, where a SwiftUI tap gesture never
/// sees the second click.
struct ResettableSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                                       target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.onDoubleClick = { context.coordinator.parent.onReset() }
        return slider
    }

    func updateNSView(_ slider: DoubleClickSlider, context: Context) {
        context.coordinator.parent = self
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(parent: ResettableSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            parent.onChange(sender.doubleValue)
        }
    }
}

final class DoubleClickSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

private struct SliderID: Hashable, Identifiable {
    let section: Int
    let slider: Int
    var id: Self { self }
}

/// The Lighting, Colors, Sharpen, Blur and Straighten inspectors.
struct AdjustmentInspectorView: View {
    @Bindable var state: AdjustmentToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            ForEach(state.sections.indices, id: \.self) { index in
                // A grouped form counts an empty header or footer view as a
                // row, which misplaces the section's background; each is
                // given only when it has something to say.
                let section = state.sections[index]
                switch (section.title, footnote(for: index)) {
                case (let title?, let note?):
                    Section { rows(index) } header: { Text(title) } footer: { InspectorFootnote(note) }
                case (let title?, nil):
                    Section { rows(index) } header: { Text(title) }
                case (nil, let note?):
                    Section { rows(index) } footer: { InspectorFootnote(note) }
                case (nil, nil):
                    Section { rows(index) }
                }
            }
        }
    }

    /// Row ids unique across sections: a form reuses rows by id, and two
    /// sections both counting from 0 get each other's rows.
    private func rows(_ sectionIndex: Int) -> some View {
        ForEach(state.sections[sectionIndex].sliders.indices.map { SliderID(section: sectionIndex, slider: $0) }) { id in
            let sliderIndex = id.slider
            AdjustmentSliderRow(slider: state.sections[sectionIndex].sliders[sliderIndex],
                                value: state.value(section: sectionIndex, slider: sliderIndex),
                                setValue: { state.setValue($0, section: sectionIndex, slider: sliderIndex) },
                                reset: { state.resetSlider(section: sectionIndex, slider: sliderIndex) })
        }
    }

    private func footnote(for sectionIndex: Int) -> String? {
        switch state.kind {
        case .colors where sectionIndex == state.sections.count - 1:
            "Color and RGB changes apply as separate steps."
        case .straighten:
            "The corners are cropped away as the image turns."
        default:
            nil
        }
    }
}

// MARK: - Crop

struct CropInspectorView: View {
    @Bindable var state: CropToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Aspect", selection: Binding(get: { state.preset }, set: { state.setPreset($0) })) {
                    ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Orientation") {
                    Button {
                        state.swapOrientation()
                    } label: {
                        Label(state.portrait ? "Portrait" : "Landscape",
                              systemImage: state.portrait ? "rectangle.portrait" : "rectangle")
                    }
                    .help("Swap Width and Height")
                    .disabled(state.preset == .square)
                }
            }
            Section {
                let rect = state.selection.pixelRect
                LabeledContent("Size") {
                    // Verbatim: pixel counts read without thousands separators.
                    Text(verbatim: "\(Int(rect.width)) × \(Int(rect.height)) px").monospacedDigit()
                }
                LabeledContent("Position") {
                    Text(verbatim: "\(Int(rect.minX)), \(Int(rect.minY))").monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                InspectorFootnote("Drag the handles or draw a new rectangle. Return crops.")
            }
        }
    }
}

// MARK: - Immediate actions

/// A button of an inspector whose commands apply at once (rotate, flip,
/// colour effects), sent down the responder chain like the menu's.
struct ImmediateAction: Identifiable {
    let title: String
    let symbol: String
    let action: Selector
    var id: String { title }
}

struct ImmediateActionsInspectorView: View {
    let title: String
    let actions: [ImmediateAction]
    var footer: String?
    let back: () -> Void
    let perform: (Selector) -> Void

    var body: some View {
        ToolInspector(title: title, actions: InspectorActions(back: back, reset: {}, cancel: back, apply: back),
                      showsApply: false) {
            Section {
                ForEach(actions) { item in
                    Button {
                        perform(item.action)
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                }
            } footer: {
                if let footer {
                    InspectorFootnote(footer)
                }
            }
        }
    }
}
