import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MinivuCore

/// Save As: the system save panel as a sheet, with minivu's options below
/// the file browser.
///
/// Why a save panel with an accessory rather than a dialog of our own that
/// ends in one: it is how Preview's Export and every other Mac app with
/// format options works, so the location, name, tags and "Replace?" all
/// behave exactly as people expect, and under the App Sandbox the panel is
/// what grants access to write the chosen file. The options live in a
/// SwiftUI form in `.columns` style, whose right-aligned labels are the
/// standard look for a panel accessory.
@MainActor final class SaveAsPanel: NSObject, NSOpenSavePanelDelegate {
    let model: SaveAsModel
    let panel = NSSavePanel()
    private let hostingView: NSHostingView<SaveAsAccessoryView>
    private var compare: QualityCompareWindowController?
    /// Keeps the panel controller alive while its sheet is up.
    private var retainedSelf: SaveAsPanel?

    init(model: SaveAsModel) {
        self.model = model
        hostingView = NSHostingView(rootView: SaveAsAccessoryView(model: model, onCompare: {}))
        super.init()
        hostingView.rootView = SaveAsAccessoryView(model: model) { [weak self] in self?.showQualityCompare(nil) }
        hostingView.sizingOptions = [.intrinsicContentSize]

        panel.delegate = self
        panel.nameFieldLabel = "Save As:"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true
        panel.allowsOtherFileTypes = false
        panel.accessoryView = hostingView
        let format = model.options.format
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = SaveAsNaming.renamed(model.entry.url.lastPathComponent, to: format)
        let folder = model.store.lastFolder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        panel.directoryURL = folder ?? model.entry.url.deletingLastPathComponent()

        model.onFormatChange = { [weak self] format in self?.formatChanged(to: format) }
    }

    /// Shows the panel as a sheet; `completion` gets the chosen file and the
    /// options, or nil when canceled.
    func begin(on window: NSWindow, completion: @escaping (URL?, ExportOptions) -> Void) {
        retainedSelf = self
        fitAccessory()
        model.refreshEstimate()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retainedSelf = nil
                self.compare?.close()
                self.compare = nil
                self.model.cancel()
                completion(response == .OK ? self.panel.url : nil, self.model.options)
            }
        }
    }

    /// The type filter and extension follow the format popup. The name is
    /// set after the type, since changing the allowed type may rewrite the
    /// extension to the type's preferred one ("jpeg"), and minivu writes the
    /// common one ("jpg").
    private func formatChanged(to format: ExportFormat) {
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = SaveAsNaming.renamed(panel.nameFieldStringValue, to: format)
        if format == .ico { compare?.close() }
        // Rows come and go with the format; let SwiftUI lay out first.
        DispatchQueue.main.async { [weak self] in self?.fitAccessory() }
    }

    private func fitAccessory() {
        let size = hostingView.fittingSize
        if hostingView.frame.size != size { hostingView.setFrameSize(size) }
    }

    /// Opens the comparison window (the accessory's Compare… button; also
    /// an action, so the snapshot harness can open it).
    @objc func showQualityCompare(_ sender: Any?) {
        guard model.options.format != .ico else { return }
        if let compare, compare.window?.isVisible == true {
            compare.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = QualityCompareWindowController(model: model)
        compare = controller
        controller.showWindow(nil)
    }

    // MARK: - NSOpenSavePanelDelegate

    /// A name typed with another image extension ("trip.png" while JPEG is
    /// chosen) gets the format's extension rather than a second one.
    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag else { return filename }
        return SaveAsNaming.renamed(filename, to: model.options.format)
    }
}

/// The options under the save panel's file browser.
struct SaveAsAccessoryView: View {
    @Bindable var model: SaveAsModel
    var onCompare: () -> Void

    var body: some View {
        let format = model.options.format
        Form {
            Picker("Format", selection: $model.format) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .naturalWidth()

            if format.supportsQuality {
                LabeledContent("Quality") {
                    HStack(spacing: 8) {
                        Slider(value: $model.qualityPercent, in: 1...100) {
                            Text("Quality")
                        } minimumValueLabel: {
                            Text("Least").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("Best").font(.caption).foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        TextField("Quality", value: $model.qualityPercent, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 42)
                    }
                }
            }

            if format.supportsColorProfile {
                Picker("Color profile", selection: $model.options.colorProfile) {
                    ForEach(ExportColorProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .naturalWidth()
            }

            if format == .tiff {
                Picker("Compression", selection: $model.options.tiffCompression) {
                    ForEach(TIFFCompression.allCases, id: \.self) { compression in
                        Text(compression.title).tag(compression)
                    }
                }
                .naturalWidth()
            }

            // Only when there is transparency to flatten: an opaque photo
            // saved as JPEG has no use for it.
            if !format.supportsAlpha, model.sourceHasAlpha {
                ColorPicker("Background", selection: backgroundColor, supportsOpacity: false)
            }

            if hasOptions(format) {
                LabeledContent("Options") {
                    VStack(alignment: .leading, spacing: 6) {
                        if format == .jpeg {
                            Toggle("Progressive", isOn: $model.options.progressive)
                        }
                        if format.supports16Bit {
                            Toggle("16 bits per channel", isOn: $model.options.sixteenBit)
                        }
                        if format.supportsMetadata {
                            Toggle("Keep metadata (EXIF, GPS, IPTC, XMP)", isOn: $model.options.keepMetadata)
                        }
                    }
                }
            }

            LabeledContent("Estimated size") {
                HStack(spacing: 8) {
                    Text(model.sizeText)
                        .monospacedDigit()
                        .foregroundStyle(model.renderError == nil ? .primary : .secondary)
                        .help(model.renderError ?? "")
                    if model.isEstimating {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 16)
                    Button("Compare…", action: onCompare)
                        .disabled(format == .ico || model.renderError != nil)
                        .help("Compare the original with the saved result at 100%")
                }
            }
        }
        .formStyle(.columns)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: 480)
    }

    private func hasOptions(_ format: ExportFormat) -> Bool {
        format == .jpeg || format.supports16Bit || format.supportsMetadata
    }

    private var backgroundColor: Binding<CGColor> {
        Binding {
            model.options.backgroundForOpaqueFormats.cgColor
        } set: { color in
            if let converted = ExportColor(color) { model.options.backgroundForOpaqueFormats = converted }
        }
    }
}

private extension View {
    /// Pop-up buttons at their natural width, left-aligned in the column,
    /// rather than stretched across the panel.
    func naturalWidth() -> some View {
        fixedSize(horizontal: true, vertical: false)
    }
}
