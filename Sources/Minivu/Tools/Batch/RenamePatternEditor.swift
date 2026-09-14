import SwiftUI
import MinivuCore

/// The rename pattern controls, shared by Batch Rename and Batch Convert:
/// the pattern with an Insert Token menu, the counter, find and replace,
/// and letter case.
///
/// Two layouts of the same controls: `.grid`, right-aligned labels in a
/// column of their own, for the rename sheet; `.form`, one labelled row
/// each, for the convert sheet's grouped form.
struct RenamePatternEditor: View {
    enum Layout { case grid, form }

    @Binding var pattern: RenamePattern
    var layout: Layout = .form

    /// The tokens offered by the Insert Token menu, with what each does.
    static let tokens: [(title: String, token: String)] = [
        ("Original Name", "{name}"),
        ("Counter", "{#}"),
        ("Counter, 3 Digits", "{###}"),
        ("Date Taken", "{date}"),
        ("Date and Time Taken", "{date:yyyy-MM-dd HH.mm.ss}"),
        ("Date Modified", "{modified}"),
        ("Width", "{width}"),
        ("Height", "{height}"),
        ("Original Extension", "{ext}"),
    ]

    var body: some View {
        switch layout {
        case .grid:
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Pattern:")
                    patternControls
                }
                GridRow {
                    label("Counter:")
                    counterControls
                }
                GridRow {
                    label("Replace:")
                    replaceControls
                }
                GridRow {
                    label("Letter case:")
                    caseControls
                }
            }
        case .form:
            LabeledContent("Pattern") { patternControls }
            LabeledContent("Counter") { counterControls }
            LabeledContent("Replace") { replaceControls }
            LabeledContent("Letter case") { caseControls }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }

    private var patternControls: some View {
        HStack(spacing: 6) {
            // Leading even in a grouped form, whose values sit on the right:
            // a pattern reads from its start.
            TextField("Pattern", text: $pattern.text, prompt: Text("{name}"))
                .labelsHidden()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(minWidth: 220)
            Menu("Insert Token") {
                ForEach(Self.tokens, id: \.token) { item in
                    Button("\(item.title)  \(item.token)") { pattern.text += item.token }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Adds a token at the end of the pattern")
        }
    }

    private var counterControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            numberField("Start", value: $pattern.counterStart)
            Text("start").foregroundStyle(.secondary)
            numberField("Step", value: $pattern.counterStep)
                .padding(.leading, 8)
            Text("step").foregroundStyle(.secondary)
            Stepper(value: $pattern.counterDigits, in: 1...9) {
                Text("\(pattern.counterDigits)").monospacedDigit()
            }
            .accessibilityLabel("Minimum digits")
            .accessibilityValue("\(pattern.counterDigits)")
            .padding(.leading, 8)
            Text(pattern.counterDigits == 1 ? "digit minimum" : "digits minimum").foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var replaceControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("Find", text: $pattern.find, prompt: Text("Find"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            Text("with").foregroundStyle(.secondary)
            TextField("Replace with", text: $pattern.replacement, prompt: Text("Replacement"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            Toggle("Match case", isOn: $pattern.matchesCase)
                .fixedSize()
        }
    }

    private var caseControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Picker("Name", selection: $pattern.nameCase) {
                ForEach(RenamePattern.LetterCase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text("name").foregroundStyle(.secondary)
            Picker("Extension", selection: $pattern.extensionCase) {
                ForEach(RenamePattern.ExtensionCase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
            Text("extension").foregroundStyle(.secondary)
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
    }
}
