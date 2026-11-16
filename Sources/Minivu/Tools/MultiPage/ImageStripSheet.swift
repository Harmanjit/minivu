import AppKit
import SwiftUI
import Observation
import MinivuCore

/// The state of the Image Strip sheet: the pictures in order, the layout
/// and the file format, and the strip's size worked out from the headers.
@MainActor @Observable final class ImageStripModel {
    var order: ImageOrder
    var settings: ImageStripSettings
    /// Sizes as displayed, read off the main thread.
    private(set) var sizes: [URL: CGSize] = [:]
    @ObservationIgnored let store: BatchStore
    @ObservationIgnored let byteLimit: Int
    @ObservationIgnored private(set) var headerWork: Task<Void, Never>?

    init(entries: [FolderEntry], store: BatchStore = BatchStore(),
         byteLimit: Int = ImageDecoder.exportDecodeLimit()) {
        order = ImageOrder(entries)
        var settings = store.imageStripSettings
        if !settings.options.format.isWritable || settings.options.format == .ico {
            settings.options = .defaults(for: .jpeg)
        }
        self.settings = settings
        self.store = store
        self.byteLimit = byteLimit
        let urls = entries.map(\.url)
        headerWork = Task { [weak self] in
            let read = await BlockingWork.run { Dictionary(zip(urls, ImageStripRenderer.sizes(of: urls))) { a, _ in a } }
            self?.sizes = read
        }
    }

    /// The formats a strip can be saved in: every writable one but ICO,
    /// whose 256 px limit no strip fits.
    static var formats: [ExportFormat] { ExportFormat.writableCases.filter { $0 != .ico } }

    var title: String {
        let count = order.entries.count
        return localized(.init("Image Strip of \(count) Images", comment: "Sheet title"))
    }

    var layout: ImageStripLayout {
        ImageStripLayout.make(sizes: order.urls.map { sizes[$0] ?? .zero }, settings: settings)
    }

    var format: ExportFormat {
        get { settings.options.format }
        set {
            guard newValue != settings.options.format else { return }
            let background = settings.options.backgroundForOpaqueFormats
            settings.options = .defaults(for: newValue)
            settings.options.backgroundForOpaqueFormats = background
        }
    }

    /// Why the strip can't be made as set, or nil.
    var problem: String? {
        if settings.size < 16 || settings.size > ImageStripLayout.maximumSide {
            return localized("The size must be between 16 and \(ImageStripLayout.maximumSide.formatted()) pixels.")
        }
        if settings.spacing < 0 || settings.spacing > 1000 || settings.margin < 0 || settings.margin > 1000 {
            return localized("Spacing and margin must be between 0 and 1,000 pixels.")
        }
        if settings.arrangement == .grid, !(1...100).contains(settings.columns) {
            return localized("The number of columns must be between 1 and 100.")
        }
        let deep = settings.options.format.supports16Bit && settings.options.sixteenBit
        return layout.problem(byteLimit: byteLimit, bytesPerPixel: deep ? 8 : 4)
    }

    var canSave: Bool { !order.entries.isEmpty && problem == nil && !sizes.isEmpty }

    /// "5,120 × 1,080 pixels".
    var sizeText: String {
        guard !sizes.isEmpty else { return "" }
        let layout = self.layout
        return localized(.init("\(layout.width.formatted()) × \(layout.height.formatted()) pixels", comment: "Width × height"))
    }

    var suggestedName: String {
        let base = order.entries.first.map { RenameNamer.split($0.name).base } ?? localized(.init("Untitled", comment: "Name for a new file that has none"))
        return localized(.init("\(base) Strip", comment: "Suggested file name: the first picture's name, then Strip"))
            + "." + settings.options.format.fileExtension
    }

    func commit() -> ImageStripSettings {
        store.imageStripSettings = settings
        return settings
    }
}

/// Tools > Image Strip… as a sheet on the browser window.
@MainActor final class ImageStripSheet {
    let model: ImageStripModel
    let window: NSWindow
    private weak var parent: NSWindow?
    private var onSave: ((ImageStripSettings, [URL]) -> Void)?
    private var retainedSelf: ImageStripSheet?

    init(model: ImageStripModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 480)
        let view = ImageStripView(model: model,
                                  onCancel: { [weak self] in self?.end() },
                                  onSave: { [weak self] in self?.save() })
        window.contentView = NSHostingView(rootView: view)
    }

    func begin(on parent: NSWindow, onSave: @escaping (ImageStripSettings, [URL]) -> Void) {
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

struct ImageStripView: View {
    @Bindable var model: ImageStripModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    ImageOrderList(order: $model.order)
                } header: {
                    Text("Order")
                }
                layoutSection
                formatSection
            }
            .formStyle(.grouped)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sizeText).font(.callout)
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

    private var layoutNote: String {
        switch model.settings.arrangement {
        case .grid: localized("Each picture is fitted into its cell, centred. Cells take the pictures’ middle shape.")
        case .horizontal: localized("Every picture is scaled to the same height.")
        case .vertical: localized("Every picture is scaled to the same width.")
        }
    }

    @ViewBuilder private var layoutSection: some View {
        Section {
            Picker("Arrange", selection: $model.settings.arrangement) {
                ForEach(ImageStripSettings.Arrangement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent(model.settings.arrangement.sizeTitle) {
                NumberField(label: model.settings.arrangement.sizeTitle, value: integer(\.size), unit: "px")
            }
            if model.settings.arrangement == .grid {
                LabeledContent("Columns") {
                    NumberField(label: localized("Columns"), value: integer(\.columns), unit: "")
                }
            }
            LabeledContent("Spacing") {
                NumberField(label: localized("Spacing"), value: integer(\.spacing), unit: "px")
            }
            LabeledContent("Margin") {
                NumberField(label: localized("Margin"), value: integer(\.margin), unit: "px")
            }
            LabeledContent("Background") {
                HStack(spacing: 8) {
                    if model.settings.options.format.supportsAlpha {
                        Toggle("Transparent", isOn: Binding(get: { model.settings.background == nil },
                                                            set: { model.settings.background = $0 ? nil : .white }))
                    }
                    if model.settings.background != nil || !model.settings.options.format.supportsAlpha {
                        ColorPicker("Background colour", selection: background, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
        } header: {
            Text("Layout")
        } footer: {
            InspectorFootnote(layoutNote)
        }
    }

    @ViewBuilder private var formatSection: some View {
        let format = model.settings.options.format
        Section {
            Picker("Format", selection: $model.format) {
                ForEach(ImageStripModel.formats, id: \.self) { Text($0.title).tag($0) }
            }
            if format.supportsQuality {
                PercentSlider(label: localized("Quality"), value: $model.settings.options.quality)
            }
            if format.supportsColorProfile {
                Picker("Color profile", selection: $model.settings.options.colorProfile) {
                    ForEach(ExportColorProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if format == .tiff {
                Picker("Compression", selection: $model.settings.options.tiffCompression) {
                    ForEach(TIFFCompression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if format.supports16Bit {
                Toggle("\(format.deepBitDepth ?? 16) bits per channel", isOn: $model.settings.options.sixteenBit)
            }
        } header: {
            Text(localized(.init("section.file", defaultValue: "File", comment: "Noun: the output file and its options (heading or label), not the File menu")))
        } footer: {
            InspectorFootnote(localized("The strip is saved as a new file and opens in the viewer, where it can be edited like any photo. HDR photos come out SDR: a strip keeps no gain map."))
        }
    }

    private func integer(_ keyPath: WritableKeyPath<ImageStripSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(model.settings[keyPath: keyPath]) },
                set: { model.settings[keyPath: keyPath] = Int(min(max($0, -1), 1_000_000)) })
    }

    private var background: Binding<CGColor> {
        Binding {
            (model.settings.background ?? model.settings.options.backgroundForOpaqueFormats).cgColor
        } set: { color in
            if let converted = ExportColor(color) {
                model.settings.background = converted
                model.settings.options.backgroundForOpaqueFormats = converted
            }
        }
    }
}
