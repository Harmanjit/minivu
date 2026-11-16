import AppKit
import SwiftUI
import MinivuCore

/// The fields of the metadata conditions (G3), as the form edits them:
/// text for the numbers, so a half-typed "2." is never turned into
/// something else under the user's fingers, read back into criteria only
/// when the sheet is confirmed.
@MainActor @Observable final class CriteriaFormModel {
    var fileTypes: Set<FileTypeGroup>
    var usesTakenFrom: Bool
    var takenFrom: Date
    var usesTakenTo: Bool
    var takenTo: Date
    var camera: String
    var lens: String
    var isoMinimum: String
    var isoMaximum: String
    var apertureMinimum: String
    var apertureMaximum: String
    var focalMinimum: String
    var focalMaximum: String
    /// Comma separated.
    var keywords: String
    /// -1 any label, else a `ColorLabel` raw value (0 is "no label").
    var colorLabel: Int
    /// -1 any, 1 with a location, 0 without.
    var location: Int
    var shape: ShapeFilter?
    var minimumWidth: String
    var minimumHeight: String

    init(_ criteria: MetadataCriteria) {
        fileTypes = criteria.fileTypes
        usesTakenFrom = criteria.takenFrom != nil
        takenFrom = criteria.takenFrom.flatMap(Self.date(day:)) ?? Date()
        usesTakenTo = criteria.takenTo != nil
        takenTo = criteria.takenTo.flatMap(Self.date(day:)) ?? Date()
        camera = criteria.camera
        lens = criteria.lens
        isoMinimum = Self.text(criteria.iso.minimum)
        isoMaximum = Self.text(criteria.iso.maximum)
        apertureMinimum = Self.text(criteria.aperture.minimum)
        apertureMaximum = Self.text(criteria.aperture.maximum)
        focalMinimum = Self.text(criteria.focalLength.minimum)
        focalMaximum = Self.text(criteria.focalLength.maximum)
        keywords = criteria.keywords.joined(separator: ", ")
        colorLabel = criteria.colorLabel?.rawValue ?? -1
        location = criteria.hasLocation.map { $0 ? 1 : 0 } ?? -1
        shape = criteria.shape
        minimumWidth = criteria.minimumWidth.map(String.init) ?? ""
        minimumHeight = criteria.minimumHeight.map(String.init) ?? ""
    }

    /// The criteria the fields say. A number that doesn't read as one is
    /// left out rather than refused: the form shows what will be used.
    var criteria: MetadataCriteria {
        var c = MetadataCriteria()
        c.fileTypes = fileTypes
        c.takenFrom = usesTakenFrom ? Self.day(of: takenFrom) : nil
        c.takenTo = usesTakenTo ? Self.day(of: takenTo) : nil
        c.camera = camera.trimmingCharacters(in: .whitespaces)
        c.lens = lens.trimmingCharacters(in: .whitespaces)
        c.iso = NumberRange(minimum: Self.number(isoMinimum), maximum: Self.number(isoMaximum))
        c.aperture = NumberRange(minimum: Self.number(apertureMinimum), maximum: Self.number(apertureMaximum))
        c.focalLength = NumberRange(minimum: Self.number(focalMinimum), maximum: Self.number(focalMaximum))
        c.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        c.colorLabel = ColorLabel(rawValue: colorLabel)
        c.hasLocation = location < 0 ? nil : location == 1
        c.shape = shape
        c.minimumWidth = Self.number(minimumWidth).flatMap { Int(exactly: $0.rounded()) }
        c.minimumHeight = Self.number(minimumHeight).flatMap { Int(exactly: $0.rounded()) }
        return c
    }

    func clear() {
        let empty = CriteriaFormModel(MetadataCriteria())
        fileTypes = empty.fileTypes
        usesTakenFrom = false
        usesTakenTo = false
        camera = ""
        lens = ""
        isoMinimum = ""; isoMaximum = ""
        apertureMinimum = ""; apertureMaximum = ""
        focalMinimum = ""; focalMaximum = ""
        keywords = ""
        colorLabel = -1
        location = -1
        shape = nil
        minimumWidth = ""; minimumHeight = ""
    }

    /// Accepts "2.8", "2,8" (a decimal comma) and "f/2.8"; nil for blank or
    /// anything else, and for a value that is not positive.
    nonisolated static func number(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("f/") { t.removeFirst(2) }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(t), value.isFinite, value > 0 else { return nil }
        return value
    }

    nonisolated static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// yyyymmdd of a date picked in the user's calendar, the wall-clock day
    /// the filter compares (`MetadataCriteria.takenFrom`).
    nonisolated static func day(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    nonisolated static func date(day: Int) -> Date? {
        Calendar.current.date(from: DateComponents(year: day / 10_000, month: day / 100 % 100, day: day % 100))
    }
}

/// Find's own fields beside the criteria: where, which name and marks.
@MainActor @Observable final class SearchFormModel {
    /// The folders a search can start from: the sidebar's (each a grant
    /// the user gave) and the folder shown.
    let scopes: [URL]
    var scope: URL
    var includeSubfolders: Bool
    var name: String
    var minimumRating: Int
    var taggedOnly: Bool
    let criteria: CriteriaFormModel

    init(query: SearchQuery, scopes: [URL]) {
        var all = scopes
        if !all.contains(where: { BrowserModel.samePath($0, query.scopeURL) }) { all.insert(query.scopeURL, at: 0) }
        self.scopes = all
        scope = all.first { BrowserModel.samePath($0, query.scopeURL) } ?? query.scopeURL
        includeSubfolders = query.includeSubfolders
        name = query.name
        minimumRating = query.minimumRating
        taggedOnly = query.taggedOnly
        criteria = CriteriaFormModel(query.criteria)
    }

    var query: SearchQuery {
        SearchQuery(scope: scope, includeSubfolders: includeSubfolders, name: name.trimmingCharacters(in: .whitespaces),
                    minimumRating: minimumRating, taggedOnly: taggedOnly, criteria: criteria.criteria)
    }
}

/// The conditions shared by Find and More Filters, as one form section.
struct CriteriaFormSections: View {
    @Bindable var model: CriteriaFormModel

    var body: some View {
        Section("Type") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                ForEach(FileTypeGroup.allCases, id: \.self) { group in
                    Toggle(group.title, isOn: Binding(
                        get: { model.fileTypes.contains(group) },
                        set: { if $0 { model.fileTypes.insert(group) } else { model.fileTypes.remove(group) } }))
                    .accessibilityLabel("Show \(group.title) files")
                }
            }
            Text("None ticked shows every type.").font(.callout).foregroundStyle(.secondary)
        }
        Section("Date Taken") {
            HStack {
                Toggle("From", isOn: $model.usesTakenFrom)
                DatePicker("From", selection: $model.takenFrom, displayedComponents: .date)
                    .labelsHidden().disabled(!model.usesTakenFrom)
                    .accessibilityLabel("Taken on or after")
                Toggle("To", isOn: $model.usesTakenTo)
                DatePicker("To", selection: $model.takenTo, displayedComponents: .date)
                    .labelsHidden().disabled(!model.usesTakenTo)
                    .accessibilityLabel("Taken on or before")
            }
        }
        Section("Camera") {
            TextField("Camera model", text: $model.camera, prompt: Text("Any camera"))
            TextField("Lens", text: $model.lens, prompt: Text("Any lens"))
            rangeRow("ISO", $model.isoMinimum, $model.isoMaximum)
            rangeRow(localized(.init("Aperture (f/)", comment: "Search field: the lens aperture, as an f-number")), $model.apertureMinimum, $model.apertureMaximum)
            rangeRow(localized("Focal length (mm)"), $model.focalMinimum, $model.focalMaximum)
        }
        Section("Description") {
            TextField("Keywords", text: $model.keywords, prompt: Text("All of these, comma separated"))
            Picker("Label", selection: $model.colorLabel) {
                Text("Any").tag(-1)
                Text("No Label").tag(ColorLabel.none.rawValue)
                ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.rawValue) { label in
                    Text(verbatim: label.localizedName).tag(label.rawValue)
                }
            }
            Picker("Location", selection: $model.location) {
                Text("Any").tag(-1)
                Text("Has a location").tag(1)
                Text("Has no location").tag(0)
            }
        }
        Section("Picture") {
            Picker("Orientation", selection: $model.shape) {
                Text("Any").tag(ShapeFilter?.none)
                ForEach(ShapeFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag(ShapeFilter?.some($0)) }
            }
            HStack {
                Text("At least", comment: "Before the minimum width and height fields")
                TextField("Width", text: $model.minimumWidth, prompt: Text("width", comment: "Placeholder: minimum width in pixels"))
                    .frame(width: 80).accessibilityLabel("Minimum width in pixels")
                Text("×")
                TextField("Height", text: $model.minimumHeight, prompt: Text("height", comment: "Placeholder: minimum height in pixels"))
                    .frame(width: 80).accessibilityLabel("Minimum height in pixels")
                Text("pixels", comment: "After the minimum width and height fields")
            }
        }
    }

    /// `title` is already localized ("ISO" stays as it is).
    private func rangeRow(_ title: String, _ minimum: Binding<String>, _ maximum: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("Minimum", text: minimum, prompt: Text("min", comment: "Placeholder: lowest value of a range"))
                    .frame(width: 70).accessibilityLabel("\(title), minimum")
                Text("to", comment: "Between the lowest and highest value of a range")
                TextField("Maximum", text: maximum, prompt: Text("max", comment: "Placeholder: highest value of a range"))
                    .frame(width: 70).accessibilityLabel("\(title), maximum")
            }
        }
    }
}

/// Edit > Find…: where to look and what for. Also edits a smart folder's
/// search, with Save for its button.
struct SearchFormView: View {
    @Bindable var model: SearchFormModel
    var confirmTitle: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Search in", selection: $model.scope) {
                        ForEach(model.scopes, id: \.self) { url in
                            Text(FileManager.default.displayName(atPath: url.path)).tag(url).help(url.path)
                        }
                    }
                    Toggle("Include subfolders", isOn: $model.includeSubfolders)
                    TextField("Name contains", text: $model.name, prompt: Text("Any name"))
                    Picker("Rating", selection: $model.minimumRating) {
                        ForEach(0...5, id: \.self) { Text(verbatim: $0 == 0 ? localized("Any") : RatingText.filterTitle(minimum: $0)).tag($0) }
                    }
                    Toggle("Tagged only", isOn: $model.taggedOnly)
                }
                CriteriaFormSections(model: model.criteria)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(localized(.init("Clear", comment: "Button: empties every field of the form, so it finds or shows everything again")), action: clear)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private func clear() {
        model.name = ""
        model.minimumRating = 0
        model.taggedOnly = false
        model.criteria.clear()
    }
}

/// View > Filter > More Filters…: the metadata conditions for the folder
/// or list shown.
struct FilterFormView: View {
    @Bindable var model: CriteriaFormModel
    var onCancel: () -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form { CriteriaFormSections(model: model) }
                .formStyle(.grouped)
            Divider()
            HStack {
                Button(localized(.init("Clear", comment: "Button: empties every field of the form, so it finds or shows everything again"))) { model.clear() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(localized(.init("search.filter.apply", defaultValue: "Filter", comment: "Verb: button that applies the filters")),
                       action: onApply).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 520)
    }
}

/// A SwiftUI form as a sheet on the browser window, kept alive while it is
/// up. Shown through `BatchTools.beginSheet`, so tests record it without
/// attaching it, as they do the batch sheets.
@MainActor final class FormSheet {
    let window: NSWindow
    /// The form's state, for tests to fill in: Find's, or More Filters'.
    var searchForm: SearchFormModel?
    var criteriaForm: CriteriaFormModel?
    private weak var parent: NSWindow?
    private var retainedSelf: FormSheet?

    /// `content` is given the sheet, so its buttons can end it.
    init<Content: View>(title: String, size: NSSize, content: (FormSheet) -> Content) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.title = title
        window.minSize = NSSize(width: 500, height: 420)
        let host = NSHostingController(rootView: content(self))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
    }

    func begin(on parent: NSWindow) {
        self.parent = parent
        retainedSelf = self
        BatchTools.beginSheet(window, on: parent)
    }

    func end() {
        if let parent { BatchTools.endSheet(window, on: parent) }
        window.orderOut(nil)
        retainedSelf = nil
    }
}
