import AppKit
import SwiftUI
import Observation
import MinivuRender

/// The special effects the tools panel opens (DESIGN.md 5 and 7).
nonisolated enum EffectKind: String, CaseIterable, Sendable {
    case dropShadow, frame, bumpMap, sketch, oilPaint, lens

    var title: String {
        switch self {
        case .dropShadow: "Drop Shadow"
        case .frame: "Frame"
        case .bumpMap: "Bump Map"
        case .sketch: "Sketch"
        case .oilPaint: "Oil Painting"
        case .lens: "Lens"
        }
    }
}

/// An open effect tool, whatever its payload, so the viewer can tell which
/// effect is showing.
protocol EffectTool: EditToolState {
    var kind: EffectKind { get }
}

/// The state of an effect inspector: one payload, previewed on the document
/// as it changes, committed by Apply as one undo step.
///
/// The effect shows at once with its defaults, as a dialog with a preview
/// would, so opening Drop Shadow already shows a shadow.
@Observable final class EffectToolState<Payload: Hashable & Sendable>: EffectTool {
    let kind: EffectKind
    /// What the tool opened with, and what Reset returns to.
    let initial: Payload
    private(set) var payload: Payload

    /// For a canvas overlay, which isn't SwiftUI: every change to the payload.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let document: EditDocument
    @ObservationIgnored private let makeOperation: (Payload) -> EditOperation

    init(kind: EffectKind, document: EditDocument, initial: Payload,
         operation: @escaping (Payload) -> EditOperation) {
        self.kind = kind
        self.document = document
        self.initial = initial
        payload = initial
        makeOperation = operation
        showPreview()
    }

    var title: String { kind.title }
    var operation: EditOperation { makeOperation(payload) }
    var hasPendingChanges: Bool { document.preview != nil }

    /// Changes the payload; the preview follows (renders coalesce, so a
    /// dragged slider skips states the GPU can't keep up with).
    func update(_ body: (inout Payload) -> Void) {
        var next = payload
        body(&next)
        guard next != payload else { return }
        payload = next
        showPreview()
        onChange?()
    }

    func apply() {
        document.apply(operation)   // an identity commits nothing and clears the preview
    }

    func cancel() {
        document.preview = nil
    }

    func reset() {
        update { $0 = initial }
    }

    private func showPreview() {
        let op = operation
        document.preview = op.isIdentity ? nil : op
    }

    /// A slider row bound to one number of the payload; double-clicking it
    /// returns to the value the tool opened with.
    func slider(_ key: WritableKeyPath<Payload, Double>, _ title: String, range: ClosedRange<Double>,
                displayScale: Double = 1, decimals: Int = 0, unit: String = "", logarithmic: Bool = false)
        -> AdjustmentSliderRow {
        let spec = AdjustmentSlider(title: title, range: range, defaultValue: initial[keyPath: key],
                                    displayScale: displayScale, decimals: decimals, unit: unit, logarithmic: logarithmic)
        return AdjustmentSliderRow(slider: spec, value: payload[keyPath: key],
                                   setValue: { [weak self] value in self?.update { $0[keyPath: key] = spec.clamped(value) } },
                                   reset: { [weak self] in
                                       guard let self else { return }
                                       let original = self.initial[keyPath: key]
                                       self.update { $0[keyPath: key] = original }
                                   })
    }

    /// A colour well bound to one colour of the payload.
    func colorBinding(_ key: WritableKeyPath<Payload, EditColor>) -> Binding<CGColor> {
        Binding(get: { [weak self] in self?.payload[keyPath: key].cgColor ?? EditColor.black.cgColor },
                set: { [weak self] color in self?.update { $0[keyPath: key] = EditColor(color) } })
    }

    /// A control bound to any other field of the payload. The binding holds
    /// the state, which is harmless: the state never holds a binding.
    func binding<Value>(_ key: WritableKeyPath<Payload, Value>) -> Binding<Value> {
        Binding(get: { self.payload[keyPath: key] }, set: { value in self.update { $0[keyPath: key] = value } })
    }
}

extension EditColor {
    /// The colour a colour well picked, in sRGB. Colours outside sRGB (the
    /// wells offer Display P3) are clipped to it, as `EditColor` promises.
    init(_ color: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = color.converted(to: srgb, intent: .relativeColorimetric, options: nil)?.components ?? []
        if c.count >= 4 {
            self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
        } else if c.count == 2 {
            self.init(red: Double(c[0]), green: Double(c[0]), blue: Double(c[0]), alpha: Double(c[1]))
        } else {
            self = .black
        }
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]) ?? CGColor(gray: 0, alpha: 1)
    }
}

extension OilPaint {
    /// `levels` for a slider.
    var levelsValue: Double {
        get { Double(levels) }
        set { levels = Int(newValue.rounded()) }
    }
}

// MARK: - Inspectors

struct DropShadowInspectorView: View {
    @Bindable var state: EffectToolState<DropShadow>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                state.slider(\.offsetX, "Offset X", range: DropShadow.offsetRange, displayScale: 100, decimals: 1, unit: "%")
                state.slider(\.offsetY, "Offset Y", range: DropShadow.offsetRange, displayScale: 100, decimals: 1, unit: "%")
                state.slider(\.blur, "Blur", range: DropShadow.blurRange, displayScale: 100, decimals: 1, unit: "%")
                state.slider(\.opacity, "Opacity", range: 0...1, displayScale: 100, unit: "%")
                ColorPicker("Color", selection: state.colorBinding(\.color), supportsOpacity: false)
            } header: {
                Text("Shadow")
            }
            Section {
                state.slider(\.margin, "Margin", range: DropShadow.marginRange, displayScale: 100, decimals: 1, unit: "%")
                state.slider(\.cornerRadius, "Corner Radius", range: DropShadow.cornerRadiusRange, displayScale: 100,
                             decimals: 1, unit: "%")
                ColorPicker("Background", selection: state.colorBinding(\.background), supportsOpacity: true)
            } header: {
                Text("Canvas")
            } footer: {
                InspectorFootnote("Sizes are percentages of the photo’s short side. A transparent background is kept by PNG, TIFF and HEIC.")
            }
        }
    }
}

struct FrameInspectorView: View {
    @Bindable var state: EffectToolState<FrameStyle>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Style", selection: state.binding(\.kind)) {
                    ForEach(FrameStyle.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                state.slider(\.width, "Width", range: FrameStyle.widthRange, displayScale: 100, decimals: 1, unit: "%")
                ColorPicker(state.payload.kind == .matte ? "Mat" : "Color", selection: state.colorBinding(\.color),
                            supportsOpacity: false)
            } footer: {
                if state.payload.kind != .matte {
                    InspectorFootnote(footnote)
                }
            }
            if state.payload.kind == .matte {
                Section {
                    ColorPicker("Outer Band", selection: state.colorBinding(\.accentColor), supportsOpacity: false)
                    state.slider(\.lineWidth, "Keyline", range: FrameStyle.lineWidthRange, displayScale: 100,
                                 decimals: 1, unit: "%")
                    ColorPicker("Keyline Color", selection: state.colorBinding(\.lineColor), supportsOpacity: false)
                } header: {
                    Text("Matte")
                } footer: {
                    InspectorFootnote(footnote)
                }
            }
        }
    }

    private var footnote: String {
        switch state.payload.kind {
        case .polaroid: "The bottom is three and a half times as deep. Widths are percentages of the photo’s short side."
        default: "Widths are percentages of the photo’s short side."
        }
    }
}

struct BumpMapInspectorView: View {
    @Bindable var state: EffectToolState<BumpMap>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                state.slider(\.strength, "Strength", range: BumpMap.strengthRange, decimals: 2)
                state.slider(\.step, "Relief Size", range: BumpMap.stepRange, decimals: 1, unit: " px")
                state.slider(\.blend, "Color", range: 0...1, displayScale: 100, unit: "%")
            } footer: {
                InspectorFootnote("At 0% color the relief shows alone, in grey.")
            }
            Section {
                state.slider(\.angle, "Angle", range: 0...360, unit: "°")
                state.slider(\.elevation, "Elevation", range: BumpMap.elevationRange, unit: "°")
            } header: {
                Text("Light")
            }
        }
    }
}

struct SketchInspectorView: View {
    @Bindable var state: EffectToolState<Sketch>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Style", selection: state.binding(\.style)) {
                    ForEach(Sketch.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                state.slider(\.strength, "Strength", range: Sketch.strengthRange, displayScale: 100, unit: "%")
                state.slider(\.radius, "Line Width", range: Sketch.radiusRange, decimals: 1, unit: " px")
            } footer: {
                InspectorFootnote("Wider lines pick up softer edges.")
            }
        }
    }
}

struct OilPaintInspectorView: View {
    @Bindable var state: EffectToolState<OilPaint>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                state.slider(\.radius, "Brush Size", range: OilPaint.radiusRange, decimals: 1, unit: " px")
                state.slider(\.levelsValue, "Levels", range: Double(OilPaint.levelsRange.lowerBound)...Double(OilPaint.levelsRange.upperBound))
            } footer: {
                InspectorFootnote("Brush size is in pixels of the full image; zoom to 100% to judge it. Fewer levels paint flatter patches.")
            }
        }
    }
}

struct LensInspectorView: View {
    @Bindable var state: EffectToolState<LensEffect>
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                state.slider(\.magnification, "Magnification", range: LensEffect.magnificationRange, decimals: 2,
                             unit: "×", logarithmic: true)
                state.slider(\.radius, "Radius", range: LensEffect.radiusRange, displayScale: 100, unit: "%")
                Toggle("Glass Rim", isOn: state.binding(\.ring))
            } footer: {
                InspectorFootnote("Drag inside the circle to move the lens, or its edge to resize it. Below 1× the lens pinches.")
            }
        }
    }
}
