import AppKit
import SwiftUI
import MinivuRender

/// The drawing tool's inspector: a toolbar of object kinds, then the style of
/// the selected object, or of the next one the current tool draws.
///
/// Lengths show in pixels of the image being edited (stroke width of its
/// short side, text size of its height), which is how they are measured in
/// the picture, and are stored as fractions so they scale with it.
struct AnnotationInspectorView: View {
    @Bindable var state: AnnotationToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                toolbar
            } footer: {
                InspectorFootnote(hint)
            }
            if let style = state.inspected {
                Section {
                    styleRows(style)
                } header: {
                    Text(state.hasSelection ? "Selected \(style.kind.title)" : "New \(style.kind.title)")
                }
                if style.kind.hasText {
                    Section("Text") { textRows(style) }
                }
                if state.hasSelection {
                    Section { arrangeRow }
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 3) {
            ForEach(AnnotationToolKind.allCases) { kind in
                let selected = state.tool == kind
                Button {
                    state.tool = kind
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 27, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
                .help(kind.title)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var hint: String {
        switch state.tool {
        case .select: "Click an object to select it. Double-click text to edit it."
        case .text: "Click or drag to add text."
        case .callout: "Drag to draw a callout, then drag its yellow handle to point."
        case .line, .arrow: "Drag to draw. Shift keeps it to 45°."
        case .highlight, .rectangle: "Drag to draw. Shift makes a square."
        case .oval: "Drag to draw. Shift makes a circle."
        }
    }

    // MARK: - Style

    private var shortSide: Double { Double(min(state.imageSize.width, state.imageSize.height)) }
    private var imageHeight: Double { Double(state.imageSize.height) }

    @ViewBuilder private func styleRows(_ style: Annotation) -> some View {
        let kind = style.kind
        if kind != .highlight {
            ColorPicker(kind == .text ? "Border" : "Stroke",
                        selection: colorBinding(\.strokeColor, name: "Stroke Color"), supportsOpacity: true)
            AnnotationSliderRow(title: "Width", value: style.strokeWidth * shortSide,
                                range: 0...max(4, (shortSide * 0.04).rounded()), unit: "px", decimals: shortSide < 1000 ? 1 : 0) {
                value in state.updateStyle("Width") { $0.strokeWidth = value / max(shortSide, 1) }
            }
            Picker("Line", selection: Binding(get: { style.dash },
                                              set: { v in state.updateStyle("Line Style") { $0.dash = v } })) {
                Text("Solid").tag(Annotation.Dash.solid)
                Text("Dashed").tag(Annotation.Dash.dashed)
                Text("Dotted").tag(Annotation.Dash.dotted)
            }
            .pickerStyle(.segmented)
        }
        if kind.isLine {
            Picker("Arrowheads", selection: Binding(get: { style.arrowheads },
                                                    set: { v in state.updateStyle("Arrowheads") { $0.arrowheads = v } })) {
                Text("None").tag(Annotation.Arrowheads.none)
                Text("End").tag(Annotation.Arrowheads.end)
                Text("Both").tag(Annotation.Arrowheads.both)
            }
            .pickerStyle(.segmented)
            if style.arrowheads != .none {
                AnnotationSliderRow(title: "Head size", value: style.arrowheadSize, range: 2...12, unit: "×", decimals: 1) {
                    value in state.updateStyle("Head Size") { $0.arrowheadSize = value }
                }
            }
        } else {
            if kind == .highlight {
                ColorPicker("Color", selection: colorBinding(\.fillColor, name: "Color"), supportsOpacity: false)
            } else {
                LabeledContent(kind == .text ? "Background" : "Fill") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { style.fillColor.alpha > 0 }, set: { on in
                            state.updateStyle("Fill") { $0.fillColor.alpha = on ? 1 : 0 }
                        }))
                        .labelsHidden()
                        ColorPicker("", selection: colorBinding(\.fillColor, name: "Fill Color"), supportsOpacity: true)
                            .labelsHidden()
                            .disabled(style.fillColor.alpha <= 0)
                    }
                }
            }
        }
        AnnotationSliderRow(title: "Opacity", value: style.opacity * 100, range: 5...100, unit: "%", decimals: 0) {
            value in state.updateStyle("Opacity") { $0.opacity = value / 100 }
        }
        Toggle("Shadow", isOn: Binding(get: { style.shadow }, set: { on in state.updateStyle("Shadow") { $0.shadow = on } }))
    }

    @ViewBuilder private func textRows(_ style: Annotation) -> some View {
        LabeledContent("Font") {
            FontFamilyPopUp(family: style.fontFamily) { family in
                state.updateStyle("Font") { $0.fontFamily = family }
            }
        }
        Picker("Weight", selection: Binding(get: { style.fontWeight },
                                            set: { v in state.updateStyle("Weight") { $0.fontWeight = v } })) {
            ForEach(Annotation.FontWeight.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        AnnotationSliderRow(title: "Size", value: style.fontSize * imageHeight,
                            range: max(4, (imageHeight * 0.01).rounded())...max(16, (imageHeight * 0.25).rounded()),
                            unit: "px", decimals: 0) { value in
            state.updateStyle("Text Size") { $0.fontSize = value / max(imageHeight, 1) }
        }
        Picker("Alignment", selection: Binding(get: { style.alignment },
                                               set: { v in state.updateStyle("Alignment") { $0.alignment = v } })) {
            Image(systemName: "text.alignleft").tag(Annotation.Alignment.left).accessibilityLabel("Left")
            Image(systemName: "text.aligncenter").tag(Annotation.Alignment.center).accessibilityLabel("Center")
            Image(systemName: "text.alignright").tag(Annotation.Alignment.right).accessibilityLabel("Right")
        }
        .pickerStyle(.segmented)
        ColorPicker("Color", selection: colorBinding(\.textColor, name: "Text Color"), supportsOpacity: true)
        LabeledContent("Outline") {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { style.textOutlineColor.alpha > 0 }, set: { on in
                    state.updateStyle("Outline") { $0.textOutlineColor.alpha = on ? 1 : 0 }
                }))
                .labelsHidden()
                ColorPicker("", selection: colorBinding(\.textOutlineColor, name: "Outline Color"), supportsOpacity: true)
                    .labelsHidden()
                    .disabled(style.textOutlineColor.alpha <= 0)
            }
        }
        Toggle("Fit height to text", isOn: Binding(get: { style.autoresizesHeight }, set: { on in
            state.updateStyle("Fit Height") { $0.autoresizesHeight = on }
        }))
    }

    private var arrangeRow: some View {
        HStack {
            Button { state.arrangeSelection(toFront: true) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .help("Bring to Front")
            Button { state.arrangeSelection(toFront: false) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                .help("Send to Back")
            Spacer()
            Button { state.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate (⌘D)")
            Button(role: .destructive) { state.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
    }

    /// A colour of the inspected style as the colour well edits it.
    private func colorBinding(_ key: WritableKeyPath<Annotation, EditColor>, name: String) -> Binding<CGColor> {
        Binding(get: {
            let c = state.inspected?[keyPath: key] ?? .black
            // A "none" colour shows its hue, fully opaque, in the well.
            return CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue),
                           alpha: c.alpha > 0 ? CGFloat(c.alpha) : 1)
        }, set: { color in
            guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric,
                                                  options: nil),
                  let components = converted.components, components.count >= 4 else { return }
            func unit(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }
            let edit = EditColor(red: unit(components[0]), green: unit(components[1]), blue: unit(components[2]),
                                 alpha: unit(components[3]))
            state.updateStyle(name) { $0[keyPath: key] = edit }
        })
    }
}

/// A labelled slider with its value, for the drawing inspector.
struct AnnotationSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    let decimals: Int
    let setValue: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: String(format: "%.\(decimals)f", value) + (unit == "%" || unit == "×" ? unit : " \(unit)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { setValue($0) }), in: range)
                .controlSize(.small)
        }
    }
}

/// Every installed font family in a pop-up menu, built once: SwiftUI would
/// rebuild a few hundred menu items on every change to the inspector.
struct FontFamilyPopUp: NSViewRepresentable {
    let family: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.addItem(withTitle: "System")
        button.lastItem?.representedObject = Annotation.systemFontFamily
        button.menu?.addItem(.separator())
        for name in NSFontManager.shared.availableFontFamilies where !name.hasPrefix(".") {
            button.addItem(withTitle: name)
            button.lastItem?.representedObject = name
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let index = button.indexOfItem(withRepresentedObject: family)
        if index >= 0 {
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        } else if button.titleOfSelectedItem != family {
            // A family that isn't installed here: shown, so it isn't silently replaced.
            button.addItem(withTitle: family)
            button.lastItem?.representedObject = family
            button.selectItem(at: button.numberOfItems - 1)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FontFamilyPopUp
        init(parent: FontFamilyPopUp) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            if let family = sender.selectedItem?.representedObject as? String { parent.onChange(family) }
        }
    }
}
