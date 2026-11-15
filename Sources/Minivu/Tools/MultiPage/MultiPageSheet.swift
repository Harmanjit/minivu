import AppKit
import SwiftUI
import Observation
import MinivuCore

/// The state of the Create Multi-Page File sheet: the pictures in order,
/// the format and its options, and what the headers say (page counts, the
/// first picture's size) for the page count and the memory check.
@MainActor @Observable final class MultiPageModel {
    var order: ImageOrder
    var settings: MultiPageSettings
    /// Page counts and sizes, read off the main thread; a file not read
    /// yet counts as one page.
    private(set) var headers: [URL: Header] = [:]
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let byteLimit: Int
    /// For tests: the header reads in flight.
    @ObservationIgnored private(set) var headerWork: Task<Void, Never>?

    struct Header: Sendable, Equatable {
        var pages: Int
        var size: CGSize
    }

    init(entries: [FolderEntry], store: BatchStore = BatchStore(),
         byteLimit: Int = ImageDecoder.exportDecodeLimit()) {
        order = ImageOrder(entries)
        var settings = store.multiPageSettings
        // Animated HEIC remembered on a Mac without the encoder.
        if !settings.format.isWritable { settings.format = .tiff }
        self.settings = settings
        self.store = store
        self.byteLimit = byteLimit
        let urls = entries.map(\.url)
        headerWork = Task { [weak self] in
            let read = await BlockingWork.run { () -> [URL: Header] in
                var headers: [URL: Header] = [:]
                for url in urls {
                    let sequence = PageSequence(url: url)
                    headers[url] = Header(pages: sequence?.count ?? 1, size: sequence?.pixelSize(ofPage: 0) ?? .zero)
                }
                return headers
            }
            self?.headers = read
        }
    }

    var title: String {
        let count = order.entries.count
        return "Create Multi-Page File from \(count == 1 ? "1 Image" : "\(count.formatted()) Images")"
    }

    /// The pages the file will have.
    var pageCount: Int {
        order.entries.reduce(0) { $0 + (settings.includesEveryPage ? headers[$1.url]?.pages ?? 1 : 1) }
    }

    /// "12 pages", for a row whose file has more than one.
    func detail(for entry: FolderEntry) -> String? {
        guard let pages = headers[entry.url]?.pages, pages > 1 else { return nil }
        return settings.format.isAnimation ? "\(pages.formatted()) frames" : "\(pages.formatted()) pages"
    }

    /// Why the file can't be made as set, or nil: a setting out of range,
    /// or an animation whose frames wouldn't fit in memory.
    var problem: String? {
        if let problem = settings.problem { return problem }
        guard let first = order.entries.first, let size = headers[first.url]?.size else { return nil }
        do {
            try MultiPageBuilder.checkBudget(pageCount: pageCount, first: size, settings: settings, byteLimit: byteLimit)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    var canSave: Bool { !order.entries.isEmpty && problem == nil }

    /// "IMG_0001.tif": the first picture's name with the format's extension.
    var suggestedName: String {
        let base = order.entries.first.map { RenameNamer.split($0.name).base } ?? "Untitled"
        return base + "." + settings.format.fileExtension
    }

    /// Remembers the settings for next time and returns them.
    func commit() -> MultiPageSettings {
        store.multiPageSettings = settings
        return settings
    }
}

/// Tools > Create Multi-Page File… as a sheet on the browser window.
@MainActor final class MultiPageSheet {
    let model: MultiPageModel
    let window: NSWindow
    private weak var parent: NSWindow?
    private var onSave: ((MultiPageSettings, [URL]) -> Void)?
    private var retainedSelf: MultiPageSheet?

    init(model: MultiPageModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 480)
        let view = MultiPageView(model: model,
                                 onCancel: { [weak self] in self?.end() },
                                 onSave: { [weak self] in self?.save() })
        window.contentView = NSHostingView(rootView: view)
    }

    /// Shows the sheet; `onSave` gets the settings and the pictures in order
    /// once the sheet has ended.
    func begin(on parent: NSWindow, onSave: @escaping (MultiPageSettings, [URL]) -> Void) {
        self.parent = parent
        self.onSave = onSave
        retainedSelf = self
        window.setContentSize(NSSize(width: 560, height: min(max(parent.frame.height - 90, 480), 720)))
        BatchTools.beginSheet(window, on: parent)
        window.makeFirstResponder(nil)
    }

    func save() {
        window.makeFirstResponder(nil)
        guard model.canSave else { return NSSound.beep() }
        let settings = model.commit(), urls = model.order.urls
        let onSave = self.onSave
        end()
        onSave?(settings, urls)
    }

    func end() {
        if let parent { BatchTools.endSheet(window, on: parent) }
        onSave = nil
        retainedSelf = nil
    }
}

struct MultiPageView: View {
    @Bindable var model: MultiPageModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    ImageOrderList(order: $model.order, detail: { model.detail(for: $0) })
                    Toggle("Include every page of multi-page files", isOn: $model.settings.includesEveryPage)
                        .help("Every page of a PDF or multi-page TIFF, and every frame of an animation, goes in, not only the first.")
                } header: {
                    Text("Pages")
                } footer: {
                    InspectorFootnote("Pages follow this order; the browser’s order to start with.")
                }
                formatSection
            }
            .formStyle(.grouped)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pageCount == 1 ? "1 page" : "\(model.pageCount.formatted()) pages")
                        .font(.callout)
                    if let problem = model.problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 500, minHeight: 480)
    }

    @ViewBuilder private var formatSection: some View {
        let format = model.settings.format
        Section {
            Picker("Format", selection: $model.settings.format) {
                ForEach(MultiPageFormat.writableCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch format {
            case .tiff:
                Picker("Compression", selection: $model.settings.tiffCompression) {
                    ForEach(TIFFCompression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            case .pdf:
                Picker("Page size", selection: $model.settings.pdfPageSize) {
                    ForEach(PDFPageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.settings.pdfPageSize != .image {
                    LabeledContent("Margin") {
                        NumberField(label: "Margin", value: $model.settings.pdfMargin, unit: "pt")
                    }
                }
                Toggle("Lossless (larger file)", isOn: $model.settings.pdfLossless)
                if !model.settings.pdfLossless {
                    PercentSlider(label: "Quality", value: $model.settings.pdfQuality)
                }
            case .gif, .heics:
                LabeledContent("Frame delay") {
                    NumberField(label: "Frame delay", value: $model.settings.frameDelay, unit: "seconds",
                                fractionDigits: 0...2)
                }
                if format.keepsLoopCount {
                    LabeledContent("Play") {
                        HStack(spacing: 6) {
                            Toggle("Forever", isOn: Binding(get: { model.settings.loopCount == 0 },
                                                            set: { model.settings.loopCount = $0 ? 0 : 1 }))
                            if model.settings.loopCount != 0 {
                                NumberField(label: "Times", value: Binding(get: { Double(model.settings.loopCount) },
                                                                          set: { model.settings.loopCount = Int($0) }),
                                            unit: "times")
                            }
                        }
                    }
                }
                LabeledContent("Frame size") {
                    HStack(spacing: 6) {
                        Toggle("Same as the first image", isOn: Binding(get: { model.settings.frameSize == nil },
                                                                        set: { model.settings.frameSize = $0 ? nil : 800 }))
                        if let size = model.settings.frameSize {
                            NumberField(label: "Long side", value: Binding(get: { Double(size) },
                                                                          set: { model.settings.frameSize = Int($0) }),
                                        unit: "px")
                        }
                    }
                }
                if format == .heics {
                    PercentSlider(label: "Quality", value: $model.settings.quality)
                }
            }
            if format != .tiff {
                LabeledContent("Background") {
                    HStack(spacing: 8) {
                        if format.isAnimation {
                            Toggle("Transparent", isOn: Binding(get: { model.settings.background == nil },
                                                                set: { model.settings.background = $0 ? nil : .white }))
                        }
                        if model.settings.background != nil || format == .pdf {
                            ColorPicker("Background colour", selection: background, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
            }
        } header: {
            Text("Format")
        } footer: {
            InspectorFootnote(footnote(format))
        }
    }

    private func footnote(_ format: MultiPageFormat) -> String {
        switch format {
        case .tiff: "Each page keeps its size and colour profile. Metadata isn’t carried over, and HDR photos come out SDR."
        case .pdf: "One picture per page. Metadata isn’t carried over."
        case .gif: "Every frame is fitted into one size, centred. Frames of animations keep their own timing."
        case .heics: "Every frame is fitted into one size, centred. Animated HEIC files play once, and the last frame shows as long as the one before it. HDR photos come out SDR."
        }
    }

    private var background: Binding<CGColor> {
        Binding {
            (model.settings.background ?? .white).cgColor
        } set: { color in
            if let converted = ExportColor(color) { model.settings.background = converted }
        }
    }
}

/// A number typed in a small field, with its unit after it.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var unit: String
    var fractionDigits: ClosedRange<Int> = 0...0

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, value: $value, format: .number.precision(.fractionLength(fractionDigits)).grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(label)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// A 1–100 slider and field for a 0...1 quality.
struct PercentSlider: View {
    let label: String
    @Binding var value: Double

    private var percent: Binding<Double> {
        Binding(get: { (value * 100).rounded() }, set: { value = min(max($0.rounded(), 1), 100) / 100 })
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: percent, in: 1...100)
                    .accessibilityLabel(label)
                TextField(label, value: percent, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46)
                    .accessibilityLabel(label)
            }
        }
    }
}
