import AppKit
import SwiftUI
import MinivuRender

/// The Resize dialog's numbers: new size in pixels, entered as pixels or a
/// percentage, with the aspect ratio optionally locked.
nonisolated struct ResizeModel: Equatable, Sendable {
    enum Unit: String, CaseIterable, Identifiable, Sendable {
        case pixels, percent
        var id: String { rawValue }
        var title: String { self == .pixels ? "Pixels" : "Percent" }
    }

    /// Largest side accepted. Beyond this a single photo is hundreds of
    /// megapixels, more than any format minivu writes handles well.
    static let maximumSide = 32768

    let originalWidth: Int
    let originalHeight: Int
    private(set) var width: Int
    private(set) var height: Int
    var keepsAspectRatio = true
    var unit: Unit = .pixels
    var filter: ResampleFilter = .lanczos3

    init(width: Int, height: Int) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
    }

    mutating func setWidth(_ value: Int) {
        width = Self.clamp(value)
        if keepsAspectRatio {
            height = Self.clamp(Int((Double(width) * Double(originalHeight) / Double(originalWidth)).rounded()))
        }
    }

    mutating func setHeight(_ value: Int) {
        height = Self.clamp(value)
        if keepsAspectRatio {
            width = Self.clamp(Int((Double(height) * Double(originalWidth) / Double(originalHeight)).rounded()))
        }
    }

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

    /// Locking again snaps the height back to the original's proportions.
    mutating func setKeepsAspectRatio(_ keeps: Bool) {
        keepsAspectRatio = keeps
        if keeps { setWidth(width) }
    }

    var megapixels: Double { Double(width) * Double(height) / 1_000_000 }
    var isUnchanged: Bool { width == originalWidth && height == originalHeight }
    var operation: EditOperation { .resize(width: width, height: height, filter: filter) }

    /// "6000 × 4000 px · 24.0 MP".
    static func sizeText(width: Int, height: Int) -> String {
        let mp = Double(width) * Double(height) / 1_000_000
        return "\(width) × \(height) px  ·  \(String(format: mp < 0.1 ? "%.2f" : "%.1f", mp)) MP"
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 1), maximumSide) }
}

/// Observable wrapper the sheet binds to.
@Observable final class ResizeSheetState {
    var model: ResizeModel
    init(model: ResizeModel) { self.model = model }
}

/// The Resize sheet: width and height in pixels or percent, the aspect lock,
/// the resampling filter, and the size the result will have.
struct ResizeSheetView: View {
    @Bindable var state: ResizeSheetState
    var onCancel: () -> Void
    var onResize: (ResizeModel) -> Void

    /// The last filter chosen, remembered across images and launches.
    @AppStorage("ResizeFilter") private var storedFilter = ResampleFilter.lanczos3.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Text("Resize Image")
                .font(.headline)
                .padding(.top, 18)
            Form {
                Section {
                    Picker("Unit", selection: $state.model.unit) {
                        ForEach(ResizeModel.Unit.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    dimensionRow("Width", pixels: state.model.width, percent: state.model.widthPercent,
                                 setPixels: { state.model.setWidth($0) }, setPercent: { state.model.setWidthPercent($0) })
                    dimensionRow("Height", pixels: state.model.height, percent: state.model.heightPercent,
                                 setPixels: { state.model.setHeight($0) }, setPercent: { state.model.setHeightPercent($0) })
                    Toggle("Keep aspect ratio", isOn: Binding(get: { state.model.keepsAspectRatio },
                                                              set: { state.model.setKeepsAspectRatio($0) }))
                }
                Section {
                    Picker("Resampling", selection: Binding(get: { state.model.filter }, set: {
                        state.model.filter = $0
                        storedFilter = $0.rawValue
                    })) {
                        ForEach(ResampleFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
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
                Button("Resize") { onResize(state.model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.model.isUnchanged)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 440)
        .onAppear {
            if let filter = ResampleFilter(rawValue: storedFilter) { state.model.filter = filter }
        }
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

/// Presents the Resize sheet on a window.
enum ResizeSheet {
    /// Calls `completion` with the chosen operation, or nil when cancelled.
    static func present(size: CGSize, on window: NSWindow, completion: @escaping (EditOperation?) -> Void) {
        let state = ResizeSheetState(model: ResizeModel(width: Int(size.width.rounded()), height: Int(size.height.rounded())))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.title = "Resize"
        var finished = false
        func finish(_ op: EditOperation?) {
            guard !finished else { return }
            finished = true
            window.endSheet(sheet)
            completion(op)
        }
        let host = NSHostingView(rootView: ResizeSheetView(state: state, onCancel: { finish(nil) },
                                                           onResize: { finish($0.isUnchanged ? nil : $0.operation) }))
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        window.beginSheet(sheet)
    }
}
