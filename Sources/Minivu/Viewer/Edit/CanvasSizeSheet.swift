import AppKit
import SwiftUI
import MinivuRender

/// The Canvas Size dialog's numbers: the new canvas in pixels, entered as
/// pixels or a percentage of the image, where the image sits on it, and
/// what fills the rest.
nonisolated struct CanvasSizeModel: Equatable, Sendable {
    let originalWidth: Int
    let originalHeight: Int
    private(set) var width: Int
    private(set) var height: Int
    var unit: ResizeModel.Unit = .pixels
    var anchor = EditAnchor.center
    /// Opaque; `transparent` decides whether it is used.
    var fill = EditColor.white
    var transparent = false

    init(width: Int, height: Int) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
    }

    mutating func setWidth(_ value: Int) { width = Self.clamp(value) }
    mutating func setHeight(_ value: Int) { height = Self.clamp(value) }

    var widthPercent: Double { Double(width) / Double(originalWidth) * 100 }
    var heightPercent: Double { Double(height) / Double(originalHeight) * 100 }

    mutating func setWidthPercent(_ percent: Double) {
        guard percent.isFinite else { return }
        setWidth(Int((Double(originalWidth) * percent / 100).rounded()))
    }

    mutating func setHeightPercent(_ percent: Double) {
        guard percent.isFinite else { return }
        setHeight(Int((Double(originalHeight) * percent / 100).rounded()))
    }

    var isUnchanged: Bool { width == originalWidth && height == originalHeight }

    /// A smaller canvas crops the image; the dialog says so.
    var crops: Bool { width < originalWidth || height < originalHeight }

    var operation: EditOperation {
        var color = fill
        color.alpha = transparent ? 0 : 1
        return .canvasSize(CanvasSize(width: width, height: height, anchor: anchor, fill: color))
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 1), CanvasSize.maximumSide) }
}

/// Observable wrapper the sheet binds to.
@Observable final class CanvasSizeSheetState {
    var model: CanvasSizeModel
    init(model: CanvasSizeModel) { self.model = model }
}

/// The Canvas Size sheet: width and height in pixels or percent, the
/// anchor, the fill, and the size the result will have.
struct CanvasSizeSheetView: View {
    @Bindable var state: CanvasSizeSheetState
    var onCancel: () -> Void
    var onApply: (CanvasSizeModel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Canvas Size")
                .font(.headline)
                .padding(.top, 18)
            Form {
                Section {
                    Picker("Unit", selection: $state.model.unit) {
                        ForEach(ResizeModel.Unit.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    dimensionRow(localized("Width"), pixels: state.model.width, percent: state.model.widthPercent,
                                 setPixels: { state.model.setWidth($0) }, setPercent: { state.model.setWidthPercent($0) })
                    dimensionRow(localized("Height"), pixels: state.model.height, percent: state.model.heightPercent,
                                 setPixels: { state.model.setHeight($0) }, setPercent: { state.model.setHeightPercent($0) })
                }
                Section {
                    LabeledContent("Anchor") {
                        AnchorGrid(selection: state.model.anchor, label: localized("Anchor")) { state.model.anchor = $0 }
                    }
                    Toggle("Transparent", isOn: $state.model.transparent)
                    ColorPicker(localized(.init("canvas.fill", defaultValue: "Fill", comment: "Noun: the colour of the added canvas area")), selection: Binding(get: { state.model.fill.cgColor },
                                                           set: { state.model.fill = EditColor($0) }),
                                supportsOpacity: false)
                        .disabled(state.model.transparent)
                } footer: {
                    Text(state.model.transparent
                         ? "PNG, TIFF and HEIC keep a transparent canvas; other formats fill it when saving."
                         : "The image stays at full size; the anchor is where it sits on the new canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Current size") {
                        Text(ResizeModel.sizeText(width: state.model.originalWidth, height: state.model.originalHeight))
                            .monospacedDigit()
                    }
                    LabeledContent("New size") {
                        Text(ResizeModel.sizeText(width: state.model.width, height: state.model.height))
                            .monospacedDigit()
                            .foregroundStyle(state.model.isUnchanged ? .secondary : .primary)
                    }
                } footer: {
                    if state.model.crops {
                        Text("A canvas smaller than the image crops it about the anchor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(state.model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.model.isUnchanged)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 440)
    }

    private func dimensionRow(_ title: String, pixels: Int, percent: Double, setPixels: @escaping (Int) -> Void,
                              setPercent: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if state.model.unit == .pixels {
                    TextField(title, value: Binding(get: { pixels }, set: { setPixels($0) }), format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("px").foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                } else {
                    TextField(title, value: Binding(get: { percent }, set: { setPercent($0) }),
                              format: .number.precision(.fractionLength(0...2)).grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("%").foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                }
            }
        }
    }
}

/// Presents the Canvas Size sheet on a window.
enum CanvasSizeSheet {
    /// Calls `completion` with the chosen operation, or nil when cancelled.
    static func present(size: CGSize, on window: NSWindow, completion: @escaping (EditOperation?) -> Void) {
        let state = CanvasSizeSheetState(model: CanvasSizeModel(width: Int(size.width.rounded()),
                                                                height: Int(size.height.rounded())))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.title = localized("Canvas Size")
        var finished = false
        // Weak holds, for the reason `ResizeSheet.present` gives.
        let finish = { [weak window, weak sheet] (op: EditOperation?) in
            guard !finished, let sheet else { return }
            finished = true
            window?.endSheet(sheet)
            completion(op)
        }
        let host = NSHostingView(rootView: CanvasSizeSheetView(state: state, onCancel: { finish(nil) },
                                                               onApply: { finish($0.isUnchanged ? nil : $0.operation) }))
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        window.beginSheet(sheet)
    }
}
