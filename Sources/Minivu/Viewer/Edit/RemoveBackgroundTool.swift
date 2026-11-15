import AppKit
import SwiftUI
import Observation
import MinivuRender

/// The Remove Background tool's state: Vision looks for the subject when
/// the tool opens, and once it has found one the cut-out previews at once,
/// transparent or on a chosen colour; Apply commits it as one step, "Undo
/// Remove Background".
@Observable final class RemoveBackgroundToolState: EditToolState {
    enum Search: Equatable {
        case running
        case found
        /// Vision found no subject (a landscape, a texture) or couldn't run.
        case none
    }

    static let transparent = EditColor(red: 1, green: 1, blue: 1, alpha: 0)

    private(set) var search = Search.running
    /// Alpha 0 is transparent.
    private(set) var fill = RemoveBackgroundToolState.transparent
    /// The colour the well shows, kept while Transparent is on so turning it
    /// off brings the same colour back.
    private(set) var color = EditColor.white

    @ObservationIgnored private let document: EditDocument
    @ObservationIgnored private var mask: SubjectMask?
    @ObservationIgnored private var isClosed = false

    init(document: EditDocument) {
        self.document = document
    }

    var title: String { "Remove Background" }
    var hasPendingChanges: Bool { document.preview != nil }
    var isTransparent: Bool { fill.alpha == 0 }

    /// What Vision found: the cut-out shows at once.
    func useMask(_ found: SubjectMask?) {
        guard !isClosed, search == .running else { return }
        mask = found
        search = found == nil ? .none : .found
        showPreview()
    }

    func setTransparent(_ on: Bool) {
        setFill(on ? Self.transparent : color)
    }

    func setColor(_ value: EditColor) {
        var opaque = value
        opaque.alpha = 1
        color = opaque
        setFill(opaque)
    }

    private func setFill(_ value: EditColor) {
        guard !isClosed, value != fill else { return }
        fill = value
        showPreview()
    }

    func apply() {
        guard !isClosed else { return }
        isClosed = true
        if let operation { document.apply(operation) } else { document.preview = nil }
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        document.preview = nil
    }

    func reset() {
        setFill(Self.transparent)
    }

    var operation: EditOperation? {
        mask.map { .removeBackground(RemoveBackground(mask: $0, fill: fill)) }
    }

    private func showPreview() {
        document.preview = operation
    }

    var colorBinding: Binding<CGColor> {
        Binding(get: { [weak self] in self?.color.cgColor ?? EditColor.white.cgColor },
                set: { [weak self] value in self?.setColor(EditColor(value)) })
    }

    var transparentBinding: Binding<Bool> {
        Binding(get: { [weak self] in self?.isTransparent ?? true }, set: { [weak self] on in self?.setTransparent(on) })
    }
}

/// The Remove Background inspector: what Vision found, and what takes the
/// background's place.
struct RemoveBackgroundInspectorView: View {
    @Bindable var state: RemoveBackgroundToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                switch state.search {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finding the subject…")
                    }
                    .accessibilityElement(children: .combine)
                case .found:
                    Label("Subject found", systemImage: "checkmark.circle")
                case .none:
                    Label("No subject found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if state.search == .none {
                    InspectorFootnote("This works best on a photo with a clear subject, such as a person, a pet or an object, standing out from its background.")
                }
            }
            Section {
                Toggle("Transparent", isOn: state.transparentBinding)
                if !state.isTransparent {
                    ColorPicker("Background color", selection: state.colorBinding, supportsOpacity: false)
                }
            } header: {
                Text("Background")
            } footer: {
                InspectorFootnote("PNG, TIFF and HEIC keep the transparency; saving as JPEG fills it with Save As’s background colour.")
            }
            .disabled(state.search != .found)
        }
    }
}
