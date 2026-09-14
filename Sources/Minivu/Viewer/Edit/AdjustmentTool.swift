import Foundation
import Observation
import MinivuRender

/// One slider of an inspector: its range in the operation's own units and
/// how the number beside it reads.
nonisolated struct AdjustmentSlider: Hashable, Sendable {
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// The field shows `value * displayScale`: -1...1 amounts read as -100
    /// to 100, the way photo apps label them.
    var displayScale: Double = 1
    var decimals: Int = 0
    var unit: String = ""
    /// The slider moves in log scale, so a gamma of 1 sits in the middle of
    /// 0.2...5 and halving and doubling take the same travel.
    var logarithmic = false

    /// Slider position for a value, and back.
    func position(for value: Double) -> Double {
        logarithmic ? Foundation.log(max(value, range.lowerBound)) : value
    }

    func value(forPosition position: Double) -> Double {
        logarithmic ? exp(position) : position
    }

    var positionRange: ClosedRange<Double> {
        logarithmic ? Foundation.log(range.lowerBound)...Foundation.log(range.upperBound) : range
    }

    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A group of sliders that together make one operation.
nonisolated struct AdjustmentSection: Sendable {
    let title: String?
    let sliders: [AdjustmentSlider]
    let operation: @Sendable ([Double]) -> EditOperation
}

/// The slider inspectors: every tool whose state is a few numbers that make
/// one operation per section.
nonisolated enum AdjustmentKind: String, CaseIterable, Sendable {
    case lighting, colors, sharpen, blur, straighten

    var title: String {
        switch self {
        case .lighting: "Lighting"
        case .colors: "Colors"
        case .sharpen: "Sharpen"
        case .blur: "Blur"
        case .straighten: "Straighten"
        }
    }

    /// A -1...1 amount shown as -100 to 100.
    private static func amount(_ title: String) -> AdjustmentSlider {
        AdjustmentSlider(title: title, range: -1...1, defaultValue: 0, displayScale: 100)
    }

    var sections: [AdjustmentSection] {
        switch self {
        case .lighting:
            [AdjustmentSection(title: nil, sliders: [
                Self.amount("Brightness"), Self.amount("Contrast"),
                AdjustmentSlider(title: "Gamma", range: 0.2...5, defaultValue: 1, decimals: 2, logarithmic: true),
                Self.amount("Shadows"), Self.amount("Highlights"),
            ]) { v in .lighting(brightness: v[0], contrast: v[1], gamma: v[2], shadows: v[3], highlights: v[4]) }]
        case .colors:
            [
                AdjustmentSection(title: "Color", sliders: [
                    AdjustmentSlider(title: "Hue", range: -180...180, defaultValue: 0, unit: "°"),
                    Self.amount("Saturation"), Self.amount("Lightness"),
                    Self.amount("Temperature"), Self.amount("Tint"),
                ]) { v in .colors(hue: v[0], saturation: v[1], lightness: v[2], temperature: v[3], tint: v[4]) },
                AdjustmentSection(title: "RGB", sliders: [
                    Self.amount("Red"), Self.amount("Green"), Self.amount("Blue"),
                ]) { v in .rgbAdjust(red: v[0], green: v[1], blue: v[2]) },
            ]
        case .sharpen:
            [AdjustmentSection(title: nil, sliders: [
                AdjustmentSlider(title: "Amount", range: 0...5, defaultValue: 1, decimals: 2),
                AdjustmentSlider(title: "Radius", range: 0.5...20, defaultValue: 1.5, decimals: 1, unit: " px"),
            ]) { v in .sharpen(amount: v[0], radius: v[1]) }]
        case .blur:
            [AdjustmentSection(title: nil, sliders: [
                AdjustmentSlider(title: "Radius", range: 0.5...100, defaultValue: 2, decimals: 1, unit: " px"),
            ]) { v in .blur(radius: v[0]) }]
        case .straighten:
            [AdjustmentSection(title: nil, sliders: [
                AdjustmentSlider(title: "Angle", range: -45...45, defaultValue: 0, decimals: 1, unit: "°"),
            ]) { v in .rotate(degrees: v[0], autoCrop: true) }]
        }
    }
}

/// Anything an inspector in the tools panel edits: a live preview on the
/// document until Apply commits it or Cancel drops it.
protocol EditToolState: AnyObject {
    var title: String { get }
    /// Something would be lost by cancelling.
    var hasPendingChanges: Bool { get }
    func apply()
    func cancel()
    func reset()
    /// True while the tool itself needs Return and Esc (typing text on the
    /// canvas), so the viewer doesn't apply or cancel the tool on them.
    var capturesKeyboard: Bool { get }
}

extension EditToolState {
    var capturesKeyboard: Bool { false }
}

/// The state of a slider inspector, and how it shows on the document.
///
/// Moving a slider sets `document.preview` to the section's operation;
/// Apply commits it and Cancel clears it.
///
/// **Colors has two sections** (colours, and the RGB gains), and a document
/// previews one operation at a time. Changing both is handled by staging:
/// while the user moves one section's sliders, the other section's
/// operation is committed to the document and the moved one is the
/// preview, so both show on screen. Moving back to the first section swaps
/// them (an undo and an apply, which leaves no redo behind). Apply commits
/// the live one after the staged one, so a Colors change with both sections
/// is **two undo steps** ("Undo RGB Adjust", then "Undo Colors"): the
/// document has no compound step, and two honest steps beat a preview that
/// shows only half the change. Cancel undoes the staged operation, which
/// leaves it available to Redo, the one trace a cancelled two-section
/// change leaves.
@Observable final class AdjustmentToolState: EditToolState {
    let kind: AdjustmentKind
    let sections: [AdjustmentSection]
    private(set) var values: [[Double]]

    @ObservationIgnored private let document: EditDocument
    /// The section whose operation is `document.preview`.
    @ObservationIgnored private var live: Int?
    /// The section whose operation this tool committed to show both at once.
    @ObservationIgnored private var staged: (section: Int, operation: EditOperation)?

    var title: String { kind.title }

    init(kind: AdjustmentKind, document: EditDocument) {
        self.kind = kind
        self.document = document
        sections = kind.sections
        values = sections.map { $0.sliders.map(\.defaultValue) }
        // Sharpen and blur start at a visible setting, shown at once as a
        // dialog with a preview would.
        for index in sections.indices where !operation(for: index).isIdentity {
            update(section: index)
        }
    }

    var hasPendingChanges: Bool { document.preview != nil || staged != nil }

    func value(section: Int, slider: Int) -> Double { values[section][slider] }

    func setValue(_ value: Double, section: Int, slider: Int) {
        let clamped = sections[section].sliders[slider].clamped(value)
        guard values[section][slider] != clamped else { return }
        values[section][slider] = clamped
        update(section: section)
    }

    /// A double-click on a slider.
    func resetSlider(section: Int, slider: Int) {
        setValue(sections[section].sliders[slider].defaultValue, section: section, slider: slider)
    }

    func operation(for section: Int) -> EditOperation {
        sections[section].operation(values[section])
    }

    func reset() {
        values = sections.map { $0.sliders.map(\.defaultValue) }
        document.preview = nil
        unstage()
        live = nil
        for index in sections.indices where !operation(for: index).isIdentity {
            update(section: index)
        }
    }

    func apply() {
        if let live {
            document.apply(operation(for: live))   // an identity commits nothing and clears the preview
        } else {
            document.preview = nil
        }
        live = nil
        staged = nil
    }

    func cancel() {
        document.preview = nil
        unstage()
        live = nil
    }

    private func update(section: Int) {
        let op = operation(for: section)
        if let other = live, other != section {
            // The other section stops being the preview: commit it so it stays
            // on screen. A section staged earlier is this one, whose values
            // are now live again.
            let otherOp = operation(for: other)
            document.preview = nil
            unstage()
            if !otherOp.isIdentity {
                document.apply(otherOp)
                staged = (other, otherOp)
            }
        }
        live = section
        document.preview = op.isIdentity ? nil : op
    }

    /// Takes back the operation this tool committed for staging, as long as
    /// it is still the last one (nothing else can commit while a tool is
    /// open, but the check keeps a mistake from undoing the user's work).
    private func unstage() {
        guard let staged else { return }
        self.staged = nil
        if document.operations.last == staged.operation { document.undo() }
    }
}
