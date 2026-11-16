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
                    textRow(localized(.init("Title", comment: "Metadata field: the image's title")), $model.title,
                            keep: localized("Keep each file’s own title"), remove: localized("Remove the title from every file"))
                    textRow(localized(.init("Caption", comment: "Metadata field: the image's description")), $model.caption,
                            keep: localized("Keep each file’s own caption"), remove: localized("Remove the caption from every file"))
                    textRow(localized(.init("Creator", comment: "Metadata field: who made the image")), $model.creator,
                            prompt: localized("Names, separated by semicolons"),
                            keep: localized("Keep each file’s own creator"), remove: localized("Remove the creator from every file"))
                    textRow(localized(.init("Copyright", comment: "Metadata field: the copyright notice")), $model.copyright,
                            keep: localized("Keep each file’s own copyright"), remove: localized("Remove the copyright from every file"))
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
        let text = model.count == 1
            ? localized(.init("“\(model.subject)”, written without re-encoding the image.", comment: "Metadata editor header; %@ is a file name"))
            : localized(.init("\(model.subject). Fields that differ show as mixed; only fields you change are written.",
                              comment: "Metadata editor header; %@ is a number of images, such as “12 images”"))
        let sidecars = model.sidecarCount
        guard sidecars > 0 else { return text }
        let note = sidecars < model.count
            ? localized(.init("\(sidecars) of them can’t be rewritten (camera raw, or a format ImageIO can’t rewrite), so the metadata goes in an XMP sidecar beside each.",
                              comment: "Metadata editor header, after the number of images being edited"))
            : model.count == 1
                ? localized("This file can’t be rewritten (camera raw, or a format ImageIO can’t rewrite), so the metadata goes in an XMP sidecar beside it.")
                : localized("These files can’t be rewritten (camera raw, or a format ImageIO can’t rewrite), so the metadata goes in an XMP sidecar beside each.")
        return localized(.init("\(text) \(note)", comment: "Two sentences, one after the other"))
    }

    private var locationDetail: String {
        let located = model.locatedCount
        if located == 0 {
            return model.count == 1 ? localized("This image has no location.") : localized("None of these images has a location.")
        }
        if model.count == 1 {
            return localized("This image has a location. Removing it takes out the GPS position and the IPTC place names, and keeps everything else.")
        }
        if located == model.count {
            return localized("All of these images have a location. Removing it takes out the GPS position and the IPTC place names, and keeps everything else.")
        }
        return localized(.init("\(located) of these images have a location. Removing it takes out the GPS position and the IPTC place names, and keeps everything else.",
                               comment: "Metadata editor, Location section"))
    }

    // MARK: Text

    /// `keep` and `remove` say what the button beside a mixed field does.
    private func textRow(_ label: String, _ field: Binding<MetadataTextField>, prompt: String? = nil,
                         keep: String, remove: String) -> some View {
        let value = field.wrappedValue
        let mixed = localized(.init("Mixed", comment: "A field whose value differs between the files being edited"))
        let placeholder = value.isCleared ? localized("Removed from every file") : value.isMixed ? mixed : prompt ?? ""
        return LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: field.text, prompt: Text(placeholder))
                    .labelsHidden()
                    .disabled(value.isCleared)
                    .accessibilityLabel(label)
                    .accessibilityValue(value.isMixed && value.text.isEmpty && !value.isCleared ? mixed : value.text)
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
                    .help(value.isCleared ? keep : remove)
                    .accessibilityLabel(value.isCleared ? keep : remove)
                }
            }
        }
    }

    // MARK: Keywords

    private var keywordSection: some View {
        Section("Keywords") {
            if model.keywords.isEmpty, model.newKeywords.isEmpty {
                Text(model.count == 1 ? localized("No keywords.") : localized("None of these images has keywords."))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.keywords) { keyword in
                HStack(spacing: 8) {
                    Text(keyword.name)
                        .strikethrough(keyword.isRemoved)
                        .foregroundStyle(keyword.isRemoved ? .secondary : .primary)
                    if keyword.count < model.count {
                        Text(keyword.isAddedToAll ? localized(.init("adding to all", comment: "Beside a keyword only some images have: it will be added to every image"))
                             : localized(.init("\(keyword.count) of \(model.count)", comment: "A number out of a total")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if keyword.count < model.count, !keyword.isRemoved {
                        Button { model.toggleAddedToAll(keyword) } label: {
                            Image(systemName: keyword.isAddedToAll ? "plus.circle.fill" : "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(keyword.isAddedToAll ? localized("Don’t add it to the other images") : localized("Add to every image"))
                        .accessibilityLabel(keyword.isAddedToAll
                            ? localized(.init("Don’t add \(keyword.name) to every image", comment: "VoiceOver; %@ is a keyword"))
                            : localized(.init("Add \(keyword.name) to every image", comment: "VoiceOver; %@ is a keyword")))
                    }
                    Button { model.toggleRemoved(keyword) } label: {
                        Image(systemName: keyword.isRemoved ? "arrow.uturn.backward.circle" : "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(keyword.isRemoved ? localized("Keep this keyword") : localized("Remove from every image"))
                    .accessibilityLabel(keyword.isRemoved
                        ? localized(.init("Keep \(keyword.name)", comment: "VoiceOver: undo removing a keyword; %@ is the keyword"))
                        : localized(.init("Remove \(keyword.name) from every image", comment: "VoiceOver; %@ is a keyword")))
                }
                .accessibilityElement(children: .contain)
            }
            ForEach(model.newKeywords, id: \.self) { keyword in
                HStack(spacing: 8) {
                    Text(keyword)
                    Text(localized(.init("new", comment: "Beside a keyword that will be added to the images"))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.removeNewKeyword(keyword) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Don’t add this keyword")
                        .accessibilityLabel(localized(.init("Don’t add \(keyword)", comment: "VoiceOver; %@ is a keyword")))
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
            LabeledContent(localized(.init("Now", comment: "Label of the date taken the images have now")), value: model.dateDescription)
            Picker(localized(.init("Change", comment: "Noun: label of a choice of how to change the date taken")), selection: $model.dateMode) {
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
                        amount(localized(.init("days", comment: "Unit after a number of days")), localized("Days"),
                               $model.shiftDays, 0...36_500, width: 56)
                        amount(localized(.init("h", comment: "Abbreviation of hours, after a number")), localized("Hours"),
                               $model.shiftHours, 0...23)
                        amount(localized(.init("unit.minutes.short", defaultValue: "min", comment: "Abbreviation of minutes, after a number")), localized("Minutes"),
                               $model.shiftMinutes, 0...59)
                        amount(localized(.init("s", comment: "Abbreviation of seconds, after a number")), localized("Seconds"),
                               $model.shiftSeconds, 0...59)
                    }
                }
            case .set:
                DatePicker("Date and time", selection: $model.setDate, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            }
            if let new = model.newDateDescription {
                LabeledContent(localized(.init("New", comment: "Label of the date taken the images will have")), value: new)
            } else if model.dateMode == .shift, model.dateChange != nil {
                Text("Each image’s own date taken moves by the same amount.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A number field and stepper; `unit` follows the number, `name` is
    /// what VoiceOver calls it.
    private func amount(_ unit: String, _ name: String, _ value: Binding<Int>, _ range: ClosedRange<Int>,
                        width: CGFloat = 36) -> some View {
        HStack(spacing: 2) {
            TextField(name, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .accessibilityLabel(name)
            Stepper(name, value: value, in: range)
                .labelsHidden()
                .accessibilityLabel(name)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
