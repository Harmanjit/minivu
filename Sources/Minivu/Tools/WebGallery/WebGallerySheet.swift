import AppKit
import SwiftUI
import MinivuCore

/// The Create Web Gallery dialog's state: the pictures, the title, and the
/// choices (remembered).
@Observable final class WebGalleryModel {
    let images: [FolderEntry]
    var title: String
    var settings: WebGallerySettings {
        didSet {
            // A number typed out of range shows what will be used.
            if settings != settings.validated { settings = settings.validated }
            if settings != oldValue { store.settings = settings }
        }
    }
    @ObservationIgnored let store: WebGallerySettingsStore

    init(images: [FolderEntry], title: String, store: WebGallerySettingsStore) {
        self.images = images
        self.title = title
        self.store = store
        var settings = store.settings
        // Settings remembered on a Mac that could write AVIF, opened on one
        // that can't.
        if !settings.format.isAvailable { settings.format = .jpeg }
        self.settings = settings
    }

    /// The formats this Mac can write.
    static var formats: [WebGalleryFormat] { WebGalleryFormat.allCases.filter(\.isAvailable) }

    /// "24 pictures · 25 pages · up to 1600 px": a page each, and the index.
    var summary: String {
        [localized("\(images.count) pictures"), localized("\(images.count + 1) pages"),
         localized(.init("up to \(String(settings.largeSize)) px", comment: "The largest picture size in pixels"))]
            .joined(separator: " · ")
    }

    /// What happens to the originals' metadata, under the Pictures section
    /// while they are included: they keep everything except, unless the
    /// large pictures keep it too, where each photo was taken.
    var originalsNote: String? {
        guard settings.includesOriginals else { return nil }
        if settings.originalsKeepLocation {
            return localized("The original files keep all their metadata, including where each photo was taken.")
        }
        return localized("Where each photo was taken is removed from the original files too; they keep their other metadata. An original it can’t be removed from, such as a camera raw file, is left out.")
    }

    /// What the chosen format plays in, under the File section.
    var formatNote: String {
        switch settings.format {
        case .jpeg: localized("JPEG shows in every browser.")
        case .heic: localized("HEIC shows in Safari only (macOS 14, iOS 17 and later).")
        case .avif: localized("AVIF shows in current Safari, Chrome, Firefox and Edge.")
        }
    }
}

/// The dialog: the title, the pictures' sizes and file format, the grid's
/// layout and look, captions and order.
struct WebGalleryView: View {
    @Bindable var model: WebGalleryModel
    var onCancel: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $model.title, prompt: Text(WebGalleryExport.defaultTitle))
                } footer: {
                    Text("The gallery is a folder with index.html, a page for each picture and a style sheet. It needs nothing from the internet, and opens from disk in any browser.")
                        .paragraphFooter()
                }
                Section {
                    LabeledContent("Thumbnails") {
                        pixelField("Thumbnail size", $model.settings.thumbnailSize)
                    }
                    LabeledContent("Large pictures") {
                        pixelField("Large picture size", $model.settings.largeSize)
                    }
                    Toggle("Include the original files", isOn: $model.settings.includesOriginals)
                } header: {
                    Text("Pictures")
                } footer: {
                    if let note = model.originalsNote {
                        Text(note).paragraphFooter()
                    }
                }
                Section("Layout") {
                    LabeledContent("Columns") {
                        HStack(spacing: 6) {
                            let text = model.settings.columns == 0
                                ? localized(.init("Fit the window", comment: "Web gallery columns: as many as fit the browser window"))
                                : "\(model.settings.columns)"
                            Text(text).monospacedDigit()
                            Stepper("Columns", value: $model.settings.columns, in: WebGallerySettings.columnRange)
                                .labelsHidden()
                                .accessibilityValue(text)
                        }
                    }
                    Picker("Theme", selection: $model.settings.theme) {
                        ForEach(WebGallerySettings.Theme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Order", selection: $model.settings.sort) {
                        ForEach(WebGallerySettings.Sort.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Captions") {
                    Toggle("File name", isOn: $model.settings.showsFileName)
                    Toggle("Title and caption from the metadata", isOn: $model.settings.showsTitle)
                    Toggle("Date taken", isOn: $model.settings.showsDate)
                }
                Section {
                    Picker("Format", selection: $model.settings.format) {
                        ForEach(WebGalleryModel.formats) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $model.settings.quality, in: WebGallerySettings.qualityRange)
                                .accessibilityLabel("Quality")
                                .accessibilityValue("\(Int((model.settings.quality * 100).rounded())) percent")
                            Text("\(Int((model.settings.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Toggle("Keep metadata", isOn: $model.settings.keepsMetadata)
                    Toggle("Remove location", isOn: $model.settings.removesLocation)
                        .disabled(!model.settings.keepsMetadata)
                } header: {
                    Text("File")
                } footer: {
                    Text("\(model.formatNote) Pictures are written in sRGB; HDR photos are shown as on a standard display.")
                        .paragraphFooter()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create…", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.images.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 640)
    }

    private func pixelField(_ label: LocalizedStringKey, _ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .accessibilityLabel(label)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

/// Presents the dialog as a sheet and carries a Create through choosing a
/// folder, making the gallery with progress and Cancel, and reporting
/// pictures left out or a failure.
final class WebGalleryController {
    let model: WebGalleryModel
    private weak var parent: NSWindow?
    private let startFolder: URL?
    private(set) var sheet: NSWindow?
    /// The export under way, for tests to await.
    private(set) var work: Task<Void, Never>?
    /// The progress sheet of the export under way; tests press its Cancel.
    private(set) var progress: ContactSheetProgress?
    /// What the last export made, for tests.
    private(set) var outcome: WebGalleryExport.Outcome?

    /// The dialog open on each window, so a second command doesn't stack another.
    private static var open: [ObjectIdentifier: WebGalleryController] = [:]

    static func controller(for window: NSWindow) -> WebGalleryController? {
        open[ObjectIdentifier(window)]
    }

    init(images: [FolderEntry], title: String, startFolder: URL?,
         store: WebGallerySettingsStore = WebGallerySettingsStore()) {
        model = WebGalleryModel(images: images, title: title, store: store)
        self.startFolder = startFolder
    }

    func begin(on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        parent = window
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled],
                             backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = localized("Create Web Gallery")
        let host = NSHostingView(rootView: WebGalleryView(model: model, onCancel: { [weak self] in self?.close() },
                                                          onCreate: { [weak self] in self?.create() }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        sheet = panel
        Self.open[ObjectIdentifier(window)] = self
        window.beginSheet(panel)
        // Nothing focused at first, so Return creates rather than landing
        // in the title.
        panel.makeFirstResponder(nil)
    }

    func close() {
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
        if let parent { Self.open[ObjectIdentifier(parent)] = nil }
    }

    /// Closes the dialog and asks where the gallery goes; Cancel in the
    /// open panel comes back to the dialog.
    func create() {
        guard let window = parent else { return }
        // The text fields commit what is typed when they lose focus.
        sheet?.makeFirstResponder(nil)
        let title = model.title
        close()
        // The dialog is closed, so nothing else holds this controller: the
        // panel's completion keeps it until the export has started.
        WebGalleryExport.chooseFolder(title, startFolder, window) { [weak window] folder in
            guard let window else { return }
            // The panel's sheet is still closing; begin the next one after it.
            DispatchQueue.main.async {
                guard let folder else { return self.begin(on: window) }
                self.run(into: folder, on: window)
            }
        }
    }

    private func run(into folder: URL, on window: NSWindow) {
        let images = model.images, settings = model.settings
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = images.count
        let progress = ContactSheetProgress(
            on: window, title: localized(.init("Making “\(WebGalleryExport.folderName(for: title))”…", comment: "%@ is the name of the file or folder being made")),
            pageCount: count + 1, delay: .milliseconds(300),
            describe: { done, _ in done < count ? localized("Picture \(done + 1) of \(count)") : localized("Writing the pages") })
        self.progress = progress
        work = Task { [weak window] in
            do {
                let outcome = try await WebGalleryExport.export(
                    images: images, title: title.isEmpty ? WebGalleryExport.defaultTitle : title, settings: settings, into: folder,
                    cancel: progress.cancel, progress: { done, total in progress.update(done: done, of: total) })
                self.outcome = outcome
                progress.finish()
                if !outcome.skipped.isEmpty || !outcome.withheldOriginals.isEmpty, let window {
                    Self.reportSkipped(outcome.skipped, withheld: outcome.withheldOriginals, on: window)
                }
            } catch is CancellationError {
                progress.finish()
            } catch {
                progress.finish()
                SaveAlert.show(error, title: localized("The web gallery couldn’t be created."), on: window)
            }
            self.progress = nil
        }
    }

    /// The pictures left out of a gallery that was made, and the original
    /// files left out because their location couldn't be removed, up to
    /// eight of each named.
    nonisolated static func skippedMessage(_ skipped: [WebGalleryExport.Skipped],
                                           withheld: [String] = []) -> (title: String, detail: String) {
        func named(_ lines: [String]) -> [String] {
            lines.count > 8
                ? Array(lines.prefix(8)) + [localized(.init("…and \(lines.count - 8) more.", comment: "Last line of a list of file names that was cut short"))]
                : lines
        }
        let title: String
        var lines: [String] = []
        if !skipped.isEmpty {
            title = localized("\(skipped.count) pictures were left out of the gallery.")
            lines = named(skipped.map {
                localized(.init("\($0.name): \($0.reason)", comment: "A file name, then what went wrong with it"))
            })
            if !withheld.isEmpty { lines.append("") }
        } else {
            title = localized("\(withheld.count) original files were left out of the gallery.")
        }
        if !withheld.isEmpty {
            // One or several, not a plural rule: the text doesn't show the number.
            lines.append(withheld.count == 1
                ? localized("Where this photo was taken couldn’t be removed from its original file, so only its large picture is in the gallery:")
                : localized("Where these photos were taken couldn’t be removed from their original files, so only their large pictures are in the gallery:"))
            lines += named(withheld)
        }
        return (title, lines.joined(separator: "\n"))
    }

    private static func reportSkipped(_ skipped: [WebGalleryExport.Skipped], withheld: [String], on window: NSWindow) {
        let message = skippedMessage(skipped, withheld: withheld)
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.detail
        alert.beginSheetModal(for: window)
    }
}
