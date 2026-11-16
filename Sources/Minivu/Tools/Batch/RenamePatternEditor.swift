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
    /// Whether the Insert Token menu offers `{page}`: in Batch Convert and
    /// Extract Pages, whose outputs can be pages of one file, never in Batch
    /// Rename, which renames whole files.
    var offersPageNumber = false

    /// The tokens offered by the Insert Token menu, with what each does.
    static var tokens: [(title: String, token: String)] {
        [(localized(.init("Original Name", comment: "Rename token: the file's name")), "{name}"),
         (localized(.init("Counter", comment: "Rename token: a number that counts up")), "{#}"),
         (localized(.init("Counter, 3 Digits", comment: "Rename token")), "{###}"),
         (localized(.init("Date Taken", comment: "Rename token")), "{date}"),
         (localized(.init("Date and Time Taken", comment: "Rename token")), "{date:yyyy-MM-dd HH.mm.ss}"),
         (localized("Date Modified"), "{modified}"),
         (localized(.init("Width", comment: "Rename token: the image's width in pixels")), "{width}"),
         (localized(.init("Height", comment: "Rename token: the image's height in pixels")), "{height}"),
         (localized(.init("Original Extension", comment: "Rename token: the file name extension")), "{ext}")]
    }

    /// The page or frame number, for outputs taken from one page of a file.
    static var pageTokens: [(title: String, token: String)] {
        [(localized(.init("Page Number", comment: "Rename token: the page or frame number")), "{page}")]
    }

    var body: some View {
        switch layout {
        case .grid:
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Pattern")
                    patternControls
                }
                GridRow {
                    label("Counter")
                    counterControls
                }
                GridRow {
                    label("Replace")
                    replaceControls
                }
                GridRow {
                    label("Letter case")
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

    private func label(_ text: LocalizedStringKey) -> some View {
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
                ForEach(Self.tokens + (offersPageNumber ? Self.pageTokens : []), id: \.token) { item in
                    Button("\(item.title)  \(item.token)" as String) { pattern.text += item.token }
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
            Text("start", comment: "Label after the counter's first number").foregroundStyle(.secondary)
            numberField("Step", value: $pattern.counterStep)
                .padding(.leading, 8)
            Text("step", comment: "Label after the number the counter goes up by").foregroundStyle(.secondary)
            Stepper(value: $pattern.counterDigits, in: 1...9) {
                Text("\(pattern.counterDigits)").monospacedDigit()
            }
            .accessibilityLabel("Minimum digits")
            .accessibilityValue("\(pattern.counterDigits)")
            .padding(.leading, 8)
            // One or several, not a plural rule: the number is in the stepper.
            Text(pattern.counterDigits == 1
                 ? localized(.init("digit minimum", comment: "Label after a stepper showing 1: the counter's minimum number of digits"))
                 : localized(.init("digits minimum", comment: "Label after a stepper showing 2 to 9: the counter's minimum number of digits")))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var replaceControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("Find", text: $pattern.find, prompt: Text("Find"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            Text("with", comment: "Between the text to find and its replacement: replace … with …").foregroundStyle(.secondary)
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
            Text("name", comment: "Label after the letter case picker for the file name").foregroundStyle(.secondary)
            Picker("Extension", selection: $pattern.extensionCase) {
                ForEach(RenamePattern.ExtensionCase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
            Text("extension", comment: "Label after the letter case picker for the file name extension").foregroundStyle(.secondary)
        }
    }

    private func numberField(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
    }
}
