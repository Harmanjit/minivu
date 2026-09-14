import AppKit
import SwiftUI
import MinivuCore

/// The layout settings the accessory's form edits.
@Observable final class PrintAccessoryModel {
    var settings: PrintLayoutSettings {
        didSet { if settings != oldValue { onChange?(settings) } }
    }
    @ObservationIgnored var onChange: ((PrintLayoutSettings) -> Void)?

    init(settings: PrintLayoutSettings) {
        self.settings = settings
    }
}

/// minivu's section of the print panel: images per page, fit or fill,
/// margins, spacing, captions and auto-rotate, beside the system's paper
/// and printer settings, with the panel's own live preview.
///
/// The panel redraws its preview when a key path named by
/// `keyPathsForValuesAffectingPreview` changes. Every setting feeds one
/// counter, `layoutRevision`, which is bumped after the print job has the
/// new settings; background decodes for the preview bump it too.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let model: PrintAccessoryModel
    private let job: PrintJob
    private let store: PrintLayoutStore

    @objc dynamic var layoutRevision = 0

    init(job: PrintJob, store: PrintLayoutStore) {
        self.job = job
        self.store = store
        model = PrintAccessoryModel(settings: job.currentSettings)
        super.init(nibName: nil, bundle: nil)
        // The panel already has a "Layout" section (pages per sheet, borders).
        title = "Picture Layout"
        model.onChange = { [weak self] settings in self?.settingsChanged(settings) }
        job.onPreviewReady { [weak self] in self?.layoutRevision += 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let host = NSHostingView(rootView: PrintAccessoryView(model: model))
        host.frame.size = host.fittingSize
        view = host
    }

    private func settingsChanged(_ settings: PrintLayoutSettings) {
        job.update(settings: settings)
        if remembers { store.settings = settings }
        layoutRevision += 1
    }

    /// False while a debug action sets up a state for a snapshot, so the
    /// picture doesn't change what the user's next print starts with.
    var remembers = true

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["layoutRevision"]
    }

    /// The lines under "Layout" in the panel's summary (Show Details off).
    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let settings = model.settings
        return Self.summary(settings).map { [.itemName: $0.name, .itemDescription: $0.value] }
    }

    nonisolated static func summary(_ settings: PrintLayoutSettings) -> [(name: String, value: String)] {
        [
            ("Images per Page", "\(settings.imagesPerPage)"),
            ("Scaling", settings.scaling == .fit ? "Fit" : "Fill"),
            ("Margins", PrintLength.text(points: settings.margin)),
            ("Spacing", PrintLength.text(points: settings.spacing)),
            ("Captions", settings.caption.title),
            ("Auto-Rotate", settings.autoRotate ? "On" : "Off"),
        ]
    }
}

/// Lengths as people measure paper: millimetres, or inches where the
/// locale uses them.
nonisolated enum PrintLength {
    static func text(points: Double, locale: Locale = .current) -> String {
        if locale.measurementSystem == .us {
            return (points / 72).formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + " in"
        }
        return (points / 72 * 25.4).formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " mm"
    }
}

struct PrintAccessoryView: View {
    @Bindable var model: PrintAccessoryModel

    var body: some View {
        Form {
            Picker("Images per page:", selection: $model.settings.imagesPerPage) {
                ForEach(PageLayout.imagesPerPageChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
            Picker("Scaling:", selection: $model.settings.scaling) {
                Text("Fit").tag(LayoutScaling.fit)
                Text("Fill").tag(LayoutScaling.fill)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Rotate pictures to fill the cells", isOn: $model.settings.autoRotate)
            LabeledContent("Margins:") {
                slider($model.settings.margin, range: PrintLayoutSettings.marginRange)
            }
            LabeledContent("Spacing:") {
                slider($model.settings.spacing, range: PrintLayoutSettings.spacingRange)
            }
            Picker("Captions:", selection: $model.settings.caption) {
                ForEach(PrintLayoutSettings.captionChoices) { Text($0.title).tag($0) }
            }
            .fixedSize()
        }
        .formStyle(.columns)
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .frame(width: 440)
    }

    private func slider(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / 3).rounded() * 3 }),
                   in: range)
                .frame(width: 180)
            Text(PrintLength.text(points: value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
        }
    }
}
