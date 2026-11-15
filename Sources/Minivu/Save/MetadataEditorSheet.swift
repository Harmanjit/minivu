import AppKit
import SwiftUI
import MinivuCore

/// Edit Metadata as a sheet on the browser or viewer window.
@MainActor final class MetadataEditorSheet {
    let model: MetadataEditorModel
    private let window: NSWindow
    private weak var parent: NSWindow?
    private var completion: ((MetadataEdit?) -> Void)?
    /// Keeps the controller alive while its sheet is up.
    private var retainedSelf: MetadataEditorSheet?

    init(model: MetadataEditorModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 500, height: 440)
        window.isReleasedWhenClosed = false
        let view = MetadataEditorView(model: model,
                                      onCancel: { [weak self] in self?.end(nil) },
                                      onSave: { [weak self] in self?.save() })
        window.contentView = NSHostingView(rootView: view)
    }

    func begin(on parent: NSWindow, completion: @escaping (MetadataEdit?) -> Void) {
        self.parent = parent
        self.completion = completion
        retainedSelf = self
        parent.beginSheet(window)
    }

    private func save() {
        // A keyword typed but not yet added with Return counts.
        model.commitKeywordEntry()
        end(model.edit.isEmpty ? nil : model.edit)
    }

    private func end(_ edit: MetadataEdit?) {
        parent?.endSheet(window)
        window.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        retainedSelf = nil
        completion?(edit)
    }
}

struct MetadataEditorView: View {
    @Bindable var model: MetadataEditorModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Metadata")
                    .font(.headline)
                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section("Description") {
                    textRow("Title", $model.title)
                    textRow("Caption", $model.caption)
                    textRow("Creator", $model.creator, prompt: "Names, separated by semicolons")
                    textRow("Copyright", $model.copyright)
                }
                keywordSection
                dateSection
                Section("Location") {
                    Toggle("Remove location", isOn: $model.removeLocation)
                        .disabled(model.locatedCount == 0)
                        .accessibilityHint("Removes the GPS position and IPTC place names, keeping the rest")
                    Text(locationDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 500, minHeight: 440)
    }

    private var headerDetail: String {
        var text = model.count == 1
            ? "“\(model.subject)”, written without re-encoding the image."
            : "\(model.subject). Fields that differ show as mixed; only fields you change are written."
        let sidecars = model.sidecarCount
        if sidecars > 0 {
            let which = sidecars == model.count ? (model.count == 1 ? "This file" : "These files")
                : sidecars == 1 ? "1 of them" : "\(sidecars.formatted()) of them"
            text += " \(which) can’t be rewritten (camera raw, or a format ImageIO can’t rewrite), "
                + "so the metadata goes in an XMP sidecar beside \(sidecars == 1 ? "it" : "each")."
        }
        return text
    }

    private var locationDetail: String {
        let located = model.locatedCount
        if located == 0 { return model.count == 1 ? "This image has no location." : "None of these images has a location." }
        let which = model.count == 1 ? "This image has" : located == model.count ? "All of these images have"
            : "\(located.formatted()) of these images have"
        return "\(which) a location. Removing it takes out the GPS position and the IPTC place names, and keeps everything else."
    }

    // MARK: Text

    private func textRow(_ label: String, _ field: Binding<MetadataTextField>, prompt: String? = nil) -> some View {
        let value = field.wrappedValue
        let placeholder = value.isCleared ? "Removed from every file" : value.isMixed ? "Mixed" : prompt ?? ""
        return LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: field.text, prompt: Text(placeholder))
                    .labelsHidden()
                    .disabled(value.isCleared)
                    .accessibilityLabel(label)
                    .accessibilityValue(value.isMixed && value.text.isEmpty && !value.isCleared ? "Mixed" : value.text)
                if value.isMixed {
                    // A mixed field left empty keeps each file's value, so
                    // clearing every file's needs saying.
                    Button {
                        field.wrappedValue.isCleared.toggle()
                        field.wrappedValue.text = ""
                    } label: {
                        Image(systemName: value.isCleared ? "arrow.uturn.backward.circle" : "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(value.isCleared ? "Keep each file’s own \(label.lowercased())" : "Remove the \(label.lowercased()) from every file")
                    .accessibilityLabel(value.isCleared ? "Keep each file’s \(label.lowercased())" : "Remove \(label.lowercased()) from every file")
                }
            }
        }
    }

    // MARK: Keywords

    private var keywordSection: some View {
        Section("Keywords") {
            if model.keywords.isEmpty, model.newKeywords.isEmpty {
                Text(model.count == 1 ? "No keywords." : "None of these images has keywords.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.keywords) { keyword in
                HStack(spacing: 8) {
                    Text(keyword.name)
                        .strikethrough(keyword.isRemoved)
                        .foregroundStyle(keyword.isRemoved ? .secondary : .primary)
                    if keyword.count < model.count {
                        Text(keyword.isAddedToAll ? "adding to all" : "\(keyword.count.formatted()) of \(model.count.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if keyword.count < model.count, !keyword.isRemoved {
                        Button { model.toggleAddedToAll(keyword) } label: {
                            Image(systemName: keyword.isAddedToAll ? "plus.circle.fill" : "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(keyword.isAddedToAll ? "Don’t add it to the other images" : "Add to every image")
                        .accessibilityLabel(keyword.isAddedToAll ? "Don’t add \(keyword.name) to every image"
                                                                 : "Add \(keyword.name) to every image")
                    }
                    Button { model.toggleRemoved(keyword) } label: {
                        Image(systemName: keyword.isRemoved ? "arrow.uturn.backward.circle" : "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(keyword.isRemoved ? "Keep this keyword" : "Remove from every image")
                    .accessibilityLabel(keyword.isRemoved ? "Keep \(keyword.name)" : "Remove \(keyword.name) from every image")
                }
                .accessibilityElement(children: .contain)
            }
            ForEach(model.newKeywords, id: \.self) { keyword in
                HStack(spacing: 8) {
                    Text(keyword)
                    Text("new").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.removeNewKeyword(keyword) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Don’t add this keyword")
                        .accessibilityLabel("Don’t add \(keyword)")
                }
                .accessibilityElement(children: .contain)
            }
            TextField("Add keywords", text: $model.keywordEntry,
                      prompt: Text("Add keywords, separated by commas"))
                .labelsHidden()
                .accessibilityLabel("Add keywords")
                .onSubmit { model.commitKeywordEntry() }
        }
    }

    // MARK: Date

    private var dateSection: some View {
        Section("Date Taken") {
            LabeledContent("Now", value: model.dateDescription)
            Picker("Change", selection: $model.dateMode) {
                Text("Leave unchanged").tag(MetadataEditorModel.DateMode.unchanged)
                Text("Shift by").tag(MetadataEditorModel.DateMode.shift)
                Text("Set to").tag(MetadataEditorModel.DateMode.set)
            }
            switch model.dateMode {
            case .unchanged:
                EmptyView()
            case .shift:
                Picker("Direction", selection: $model.shiftLater) {
                    Text("Later").tag(true)
                    Text("Earlier").tag(false)
                }
                .pickerStyle(.segmented)
                LabeledContent("Amount") {
                    HStack(spacing: 6) {
                        amount("days", $model.shiftDays, 0...36_500)
                        amount("h", $model.shiftHours, 0...23)
                        amount("min", $model.shiftMinutes, 0...59)
                        amount("s", $model.shiftSeconds, 0...59)
                    }
                }
            case .set:
                DatePicker("Date and time", selection: $model.setDate, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            }
            if let new = model.newDateDescription {
                LabeledContent("New", value: new)
            } else if model.dateMode == .shift, model.dateChange != nil {
                Text("Each image’s own date taken moves by the same amount.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func amount(_ unit: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            TextField(unit, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: unit == "days" ? 56 : 36)
                .accessibilityLabel(unitName(unit))
            Stepper(unitName(unit), value: value, in: range)
                .labelsHidden()
                .accessibilityLabel(unitName(unit))
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func unitName(_ unit: String) -> String {
        switch unit {
        case "h": "Hours"
        case "min": "Minutes"
        case "s": "Seconds"
        default: "Days"
        }
    }
}
