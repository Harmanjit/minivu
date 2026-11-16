import AppKit
import SwiftUI
import Observation
import MinivuRender

/// The RAW tool's state: Apple's RAW engine's settings for the file, shown
/// on the document as they change and committed by Apply as one step, "Undo
/// RAW Adjustments".
///
/// It opens on the settings in effect (an earlier RAW step's) or, with none,
/// the camera's, and previews them at once: the canvas then shows the
/// engine's own rendering, which is what the sliders change, rather than
/// the preview JPEG the camera may have embedded. Every setting is stored,
/// so a step reads the same whatever came before it. Reset and a slider's
/// double-click go back to the camera's settings ("as shot"), not to what
/// the tool opened with: that is what a RAW developer's reset means, and
/// Cancel already returns to the other.
@Observable final class RawDevelopToolState: EditToolState {
    /// The camera's settings, and which ones the engine can change for it.
    let defaults: RawDefaults
    /// What the tool opened with.
    let initial: RawDevelop
    private(set) var settings: RawDevelop

    @ObservationIgnored private let document: EditDocument
    /// Applied or cancelled: a colour panel or a late field edit can't put
    /// the preview back.
    @ObservationIgnored private var isClosed = false

    init(document: EditDocument, defaults: RawDefaults) {
        self.document = document
        self.defaults = defaults
        initial = (RawDevelop.inEffect(document.operations) ?? RawDevelop()).filled(from: defaults)
        settings = initial
        document.preview = .rawDevelop(settings)
    }

    var title: String { localized("RAW Adjustments") }
    var hasPendingChanges: Bool { settings != initial }
    /// The camera's settings, every one given.
    var asShot: RawDevelop { RawDevelop().filled(from: defaults) }

    func update(_ body: (inout RawDevelop) -> Void) {
        guard !isClosed else { return }
        var next = settings
        body(&next)
        guard next != settings else { return }
        settings = next
        document.preview = .rawDevelop(settings)
    }

    /// Commits the settings if they changed; otherwise the document goes
    /// back to what it showed before the tool opened.
    func apply() {
        guard !isClosed else { return }
        isClosed = true
        if settings != initial {
            document.apply(.rawDevelop(settings))
        } else {
            document.preview = nil
        }
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        document.preview = nil
    }

    func reset() {
        let camera = asShot
        update { $0 = camera }
    }

    /// A slider row bound to one setting; double-clicking it returns to the
    /// camera's value.
    func slider(_ key: WritableKeyPath<RawDevelop, Double?>, _ title: String, range: ClosedRange<Double>,
                displayScale: Double = 1, decimals: Int = 0, unit: String = "", logarithmic: Bool = false)
        -> AdjustmentSliderRow {
        let camera = asShot[keyPath: key] ?? range.lowerBound
        let spec = AdjustmentSlider(title: title, range: range, defaultValue: min(max(camera, range.lowerBound), range.upperBound),
                                    displayScale: displayScale, decimals: decimals, unit: unit, logarithmic: logarithmic)
        return AdjustmentSliderRow(slider: spec, value: settings[keyPath: key] ?? spec.defaultValue,
                                   setValue: { [weak self] value in self?.update { $0[keyPath: key] = spec.clamped(value) } },
                                   reset: { [weak self] in self?.update { $0[keyPath: key] = spec.defaultValue } })
    }

    var recoversHighlights: Binding<Bool> {
        Binding(get: { [weak self] in self?.settings.recoversHighlights ?? true },
                set: { [weak self] on in self?.update { $0.recoversHighlights = on } })
    }
}

/// The RAW tool's inspector: exposure, white balance, boost and noise
/// reduction sliders, and highlight recovery where the engine has it.
struct RawDevelopInspectorView: View {
    @Bindable var state: RawDevelopToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                state.slider(\.exposure, localized("Exposure"), range: RawDevelop.exposureRange, decimals: 2, unit: " EV")
                state.slider(\.boost, localized(.init("Boost", comment: "RAW: how much of the camera's contrast curve is applied")),
                    range: 0...1, displayScale: 100, unit: "%")
                if state.defaults.supportsHighlightRecovery {
                    Toggle("Recover highlights", isOn: state.recoversHighlights)
                }
            } footer: {
                InspectorFootnote(localized("Boost is how much of the RAW engine’s contrast curve is applied; lower is flatter."))
            }
            Section {
                state.slider(\.temperature, localized("Temperature"), range: RawDevelop.temperatureRange, unit: " K",
                             logarithmic: true)
                state.slider(\.tint, localized("Tint"), range: RawDevelop.tintRange)
            } header: {
                Text("White Balance")
            } footer: {
                InspectorFootnote(localized("Starts at the white balance the camera recorded. Higher temperatures make the picture warmer; positive tint adds magenta."))
            }
            if state.defaults.supportsLuminanceNoiseReduction || state.defaults.supportsColorNoiseReduction {
                Section {
                    if state.defaults.supportsLuminanceNoiseReduction {
                        state.slider(\.luminanceNoiseReduction, localized("Luminance Noise"), range: 0...1, displayScale: 100, unit: "%")
                    }
                    if state.defaults.supportsColorNoiseReduction {
                        state.slider(\.colorNoiseReduction, localized("Color Noise"), range: 0...1, displayScale: 100, unit: "%")
                    }
                } header: {
                    Text("Noise Reduction")
                }
            }
            Section {
            } footer: {
                InspectorFootnote(localized("These settings change how Apple’s RAW engine develops the file, before every other edit, so they can be changed again at any time. Reset returns to the camera’s settings."))
            }
        }
    }
}
