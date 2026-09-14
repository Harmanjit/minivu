import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// Batch Convert as a sheet on the browser window: format and options,
/// size and orientation, destination and names, with the first output's
/// name as a preview.
@MainActor final class BatchConvertSheet {
    let model: BatchConvertModel
    let window: NSWindow
    private weak var parent: NSWindow?
    private var onConvert: ((BatchConvertSettings) -> Void)?
    private var retainedSelf: BatchConvertSheet?

    init(model: BatchConvertModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        let view = BatchConvertView(model: model,
                                    onChooseFolder: { [weak self] in self?.chooseFolder() },
                                    onCancel: { [weak self] in self?.end() },
                                    onConvert: { [weak self] in self?.convert() })
        window.contentView = NSHostingView(rootView: view)
    }

    func begin(on parent: NSWindow, onConvert: @escaping (BatchConvertSettings) -> Void) {
        self.parent = parent
        self.onConvert = onConvert
        retainedSelf = self
        // As tall as the window allows, up to what the form needs with its
        // name pattern open, so most of it shows without scrolling.
        window.setContentSize(NSSize(width: 620, height: min(max(parent.frame.height - 90, 480), 940)))
        BatchTools.sheets.begin(window, parent)
    }

    /// Asks for the destination with an open panel over the sheet. Cancelling
    /// leaves the destination as it was.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for the converted images."
        panel.directoryURL = model.chosenFolder ?? model.entries.first?.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let folder = panel.url else { return }
                if !self.model.choose(folder: folder) {
                    let alert = NSAlert()
                    alert.messageText = "This folder can’t be used."
                    alert.informativeText = "minivu works only with folders on this Mac’s internal storage."
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func convert() {
        guard model.canConvert else { return NSSound.beep() }
        let settings = model.commit()
        let onConvert = self.onConvert
        end()
        onConvert?(settings)
    }

    func end() {
        if let parent { BatchTools.sheets.end(window, parent) }
        onConvert = nil
        retainedSelf = nil
    }
}

struct BatchConvertView: View {
    @Bindable var model: BatchConvertModel
    var onChooseFolder: () -> Void
    var onCancel: () -> Void
    var onConvert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding(.top, 16)

            Form {
                formatSection
                sizeSection
                destinationSection
                namesSection
            }
            .formStyle(.grouped)

            // The form scrolls when the sheet is short; the line keeps the
            // buttons from looking like one more row of it.
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.previewText)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let problem = model.resizeProblem ?? model.previewProblem
                        ?? model.unknownTokens.first.map({ "Unknown token \($0)" }) {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Convert", action: onConvert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConvert)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Sections

    @ViewBuilder private var formatSection: some View {
        let format = model.settings.options.format
        Section("Format") {
            Picker("Format", selection: $model.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if format.supportsQuality {
                LabeledContent("Quality") {
                    HStack(spacing: 8) {
                        Slider(value: $model.qualityPercent, in: 1...100)
                        TextField("Quality", value: $model.qualityPercent, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 46)
                    }
                }
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
            if !format.supportsAlpha {
                ColorPicker("Background for transparency", selection: backgroundColor, supportsOpacity: false)
            }
            if format == .jpeg {
                Toggle("Progressive", isOn: $model.settings.options.progressive)
            }
            if format.supports16Bit {
                Toggle("16 bits per channel", isOn: $model.settings.options.sixteenBit)
            }
            if format.supportsMetadata {
                Toggle("Keep metadata (EXIF, GPS, IPTC, XMP)", isOn: $model.settings.options.keepMetadata)
            }
        }
    }

    @ViewBuilder private var sizeSection: some View {
        let resize = model.settings.resize
        Section("Size and Orientation") {
            Picker("Resize", selection: $model.settings.resize.mode) {
                ForEach(BatchResize.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if resize.mode != .none {
                LabeledContent(resize.mode == .percent ? "Scale" : "Size") {
                    HStack(spacing: 6) {
                        if resize.mode == .percent {
                            TextField("Percent", value: $model.settings.resize.percent,
                                      format: .number.precision(.fractionLength(0...2)).grouping(.never))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("%").foregroundStyle(.secondary)
                        } else {
                            TextField("Pixels", value: $model.settings.resize.pixels, format: .number.grouping(.never))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Resampling", selection: $model.settings.resize.filter) {
                    ForEach(ResampleFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Don’t enlarge smaller images", isOn: $model.settings.resize.doesNotEnlarge)
            }
            Picker("Rotate", selection: $model.settings.quarterTurns) {
                Text("None").tag(0)
                Text("90° Right").tag(1)
                Text("180°").tag(2)
                Text("90° Left").tag(3)
            }
            LabeledContent("Flip") {
                HStack(spacing: 14) {
                    Toggle("Horizontal", isOn: $model.settings.flipHorizontal)
                    Toggle("Vertical", isOn: $model.settings.flipVertical)
                }
            }
        }
    }

    @ViewBuilder private var destinationSection: some View {
        Section("Destination") {
            LabeledContent("Save to") {
                HStack(spacing: 8) {
                    Picker("Save to", selection: Binding(get: { model.usesChosenFolder },
                                                         set: { chosen in
                                                             model.setUsesChosenFolder(chosen)
                                                             if chosen && model.chosenFolder == nil { onChooseFolder() }
                                                         })) {
                        Text("Beside the originals").tag(false)
                        Text(model.chosenFolder.map { FileManager.default.displayName(atPath: $0.path) } ?? "Other Folder")
                            .tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Choose…", action: onChooseFolder)
                }
            }
            Picker("If a file exists", selection: $model.settings.existingFiles) {
                ForEach(BatchFileWriter.ExistingFilePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    @ViewBuilder private var namesSection: some View {
        Section("File Names") {
            Picker("Names", selection: $model.usesPattern) {
                Text("Keep the original names").tag(false)
                Text("Use a pattern").tag(true)
            }
            .pickerStyle(.radioGroup)
            if model.usesPattern {
                RenamePatternEditor(pattern: $model.pattern)
            }
        }
    }

    private var backgroundColor: Binding<CGColor> {
        Binding {
            model.settings.options.backgroundForOpaqueFormats.cgColor
        } set: { color in
            if let converted = ExportColor(color) { model.settings.options.backgroundForOpaqueFormats = converted }
        }
    }
}
