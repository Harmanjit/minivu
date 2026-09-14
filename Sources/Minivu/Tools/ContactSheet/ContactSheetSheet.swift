import AppKit
import SwiftUI
import MinivuCore

/// The Contact Sheet dialog's state: the settings, the header, and a small
/// preview of the first page that follows them.
@Observable final class ContactSheetModel {
    let items: [LayoutItem]
    var settings: ContactSheetSettings {
        didSet {
            guard settings != oldValue else { return }
            if remembers { store?.settings = settings }
            schedulePreview()
        }
    }
    var header: String {
        didSet { if header != oldValue { schedulePreview() } }
    }
    private(set) var preview: CGImage?
    /// False while a debug action sets up a state for a snapshot, so the
    /// picture doesn't change what the next sheet starts with.
    @ObservationIgnored var remembers = true
    /// Previews finished so far; for tests.
    @ObservationIgnored private(set) var previewRenders = 0

    @ObservationIgnored private let store: ContactSheetStore?
    @ObservationIgnored let previewProvider: LayoutImageProvider
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewCancel: CancellationFlag?

    /// The preview's long edge in pixels: about 300 points on a Retina screen.
    static let previewLongEdge = 600.0
    /// Changes closer together than this make one preview.
    static let previewDelay: Duration = .milliseconds(150)

    init(items: [LayoutItem], header: String, store: ContactSheetStore?,
         previewProvider: LayoutImageProvider = LayoutImageProvider(byteBudget: 48 << 20)) {
        self.items = items
        self.header = header
        self.store = store
        settings = store?.settings ?? ContactSheetSettings()
        self.previewProvider = previewProvider
    }

    var pageCount: Int { settings.pageCount(imageCount: items.count) }

    /// The scale the preview is drawn at, page pixels to preview pixels.
    var previewScale: Double {
        let size = settings.pagePixelSize
        return min(1, Self.previewLongEdge / max(size.width, size.height))
    }

    /// "24 images · 2 pages · 2480 × 3508 px".
    var summary: String {
        let size = settings.pagePixelSize
        let images = items.count == 1 ? "1 image" : "\(items.count) images"
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(images) · \(pages) · \(Int(size.width)) × \(Int(size.height)) px"
    }

    /// Renders page 1 small, after a short pause so a slider dragged or a
    /// number typed makes one render, not one per step. A newer change
    /// cancels a render still running.
    func schedulePreview(after delay: Duration = ContactSheetModel.previewDelay) {
        previewTask?.cancel()
        previewCancel?.cancel()
        let cancel = CancellationFlag()
        previewCancel = cancel
        let items = items, settings = settings, header = header, scale = previewScale, provider = previewProvider
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let box = await BlockingWork.run { () -> CGImageBox? in
                (try? ContactSheetRenderer.renderPage(0, items: items, settings: settings, header: header,
                                                      scale: scale, provider: provider, cancel: cancel))?
                    .map(CGImageBox.init)
            }
            guard !Task.isCancelled, !cancel.isCancelled, let self, let box else { return }
            self.preview = box.image
            self.previewRenders += 1
        }
    }

    /// For tests: waits for the preview asked for last.
    func waitForPreview() async {
        await previewTask?.value
    }

    func stopPreview() {
        previewTask?.cancel()
        previewCancel?.cancel()
    }
}

/// The dialog: a preview of page 1 beside the settings.
struct ContactSheetView: View {
    @Bindable var model: ContactSheetModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                previewPane
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                form
                    .frame(width: 420)
            }
            Divider()
            HStack {
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.items.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 751, height: 640)
        .onAppear { model.schedulePreview(after: .zero) }
        .onDisappear { model.stopPreview() }
    }

    private var previewPane: some View {
        VStack(spacing: 10) {
            Text("Contact Sheet")
                .font(.headline)
            Spacer(minLength: 0)
            let size = model.settings.pagePixelSize
            let fit = min(290 / size.width, 520 / size.height)
            Group {
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Rectangle().fill(Color(cgColor: model.settings.background.cgColor))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: size.width * fit, height: size.height * fit)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Text(model.pageCount > 1 ? "Page 1 of \(model.pageCount)" : "Page 1")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var form: some View {
        Form {
            Section("Page") {
                Picker("Size", selection: $model.settings.pageSize) {
                    ForEach(ContactSheetPageSize.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.pageSize == .custom {
                    LabeledContent("Width") { pixelField($model.settings.customWidth) }
                    LabeledContent("Height") { pixelField($model.settings.customHeight) }
                }
                Picker("Orientation", selection: $model.settings.orientation) {
                    ForEach(ContactSheetOrientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ColorPicker("Background", selection: Binding(
                    get: { model.settings.background.cgColor },
                    set: { model.settings.background = ExportColor($0) ?? .white }), supportsOpacity: false)
            }
            Section("Grid") {
                LabeledContent("Columns") {
                    Stepper(value: $model.settings.columns, in: ContactSheetSettings.columnRange) {
                        Text("\(model.settings.columns)").monospacedDigit()
                    }
                }
                LabeledContent("Rows") {
                    Stepper(value: $model.settings.rows, in: ContactSheetSettings.rowRange) {
                        Text(model.settings.rows == 0 ? "Auto (one page)" : "\(model.settings.rows)").monospacedDigit()
                    }
                }
                LabeledContent("Spacing") { pixelField($model.settings.spacing) }
                LabeledContent("Margin") { pixelField($model.settings.margin) }
                Picker("Pictures", selection: $model.settings.scaling) {
                    Text("Fit in Cell").tag(LayoutScaling.fit)
                    Text("Fill Cell").tag(LayoutScaling.fill)
                }
                .pickerStyle(.segmented)
            }
            Section("Text") {
                Picker("Captions", selection: $model.settings.caption) {
                    ForEach(CaptionContent.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Text size") { pixelField($model.settings.captionSize) }
                Toggle("Header", isOn: $model.settings.showsHeader)
                if model.settings.showsHeader {
                    TextField("Header text", text: $model.header, prompt: Text("Title"))
                }
                Toggle("Page numbers", isOn: $model.settings.showsPageNumbers)
            }
            Section {
                Picker("Format", selection: $model.settings.format) {
                    ForEach(ContactSheetFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Colour profile", selection: $model.settings.colorSpace) {
                    ForEach(ContactSheetColorSpace.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.settings.format == .pdf)
            } header: {
                Text("File")
            } footer: {
                Text(model.settings.format == .pdf
                     ? "One PDF with every page; pictures are embedded at the size of their cells."
                     : model.pageCount > 1 ? "One file per page, saved into a folder you choose." : "One picture file.")
                    .paragraphFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func pixelField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

/// Presents the dialog as a sheet and carries a Save through choosing a
/// destination, making the sheet with progress, and showing the result.
final class ContactSheetController {
    let model: ContactSheetModel
    private weak var parent: NSWindow?
    private let startFolder: URL?
    private(set) var sheet: NSWindow?
    /// Where Save writes without asking; set by the snapshot harness's
    /// debug action only.
    var debugDestinationFolder: URL?
    /// The export under way, for tests and the debug action to await.
    private(set) var work: Task<Void, Never>?

    /// The dialog open on each window, so a second command doesn't stack another.
    private static var open: [ObjectIdentifier: ContactSheetController] = [:]

    static func controller(for window: NSWindow) -> ContactSheetController? {
        open[ObjectIdentifier(window)]
    }

    init(items: [LayoutItem], folderName: String?, startFolder: URL?, store: ContactSheetStore = ContactSheetStore()) {
        model = ContactSheetModel(items: items, header: folderName ?? "", store: store)
        self.startFolder = startFolder
    }

    func begin(on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        parent = window
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 751, height: 640), styleMask: [.titled],
                             backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = "Contact Sheet"
        let host = NSHostingView(rootView: ContactSheetView(model: model, onCancel: { [weak self] in self?.close() },
                                                            onSave: { [weak self] in self?.save() }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        sheet = panel
        Self.open[ObjectIdentifier(window)] = self
        window.beginSheet(panel)
        // Nothing focused at first, so Return saves rather than landing in
        // the first number field.
        panel.makeFirstResponder(nil)
    }

    func close() {
        model.stopPreview()
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
        if let parent { Self.open[ObjectIdentifier(parent)] = nil }
    }

    private var baseName: String {
        ContactSheetNaming.baseName(folderName: model.header.isEmpty ? nil : model.header)
    }

    func save() {
        guard let window = parent else { return }
        // The sheet's text fields commit what is typed when they lose focus.
        sheet?.makeFirstResponder(nil)
        let settings = model.settings, items = model.items, pageCount = model.pageCount
        let header = settings.showsHeader && !model.header.isEmpty ? model.header : nil
        let base = baseName
        close()
        if let folder = debugDestinationFolder {
            let destination: ContactSheetExport.Destination
            if settings.format == .pdf {
                let name = FileOperations.uniqueName(for: ContactSheetNaming.singleName(base: base, format: .pdf), in: folder)
                destination = .file(folder.appendingPathComponent(name))
            } else {
                destination = .folder(folder, names: ContactSheetNaming.pageNames(
                    base: base, count: pageCount, fileExtension: settings.format.fileExtension) {
                        FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                    })
            }
            run(items: items, settings: settings, header: header, destination: destination, base: base,
                on: window, showing: false)
            return
        }
        // The dialog is closed, so nothing else holds this controller: the
        // panel's completion keeps it until the save has started.
        ContactSheetExport.chooseDestination(base: base, settings: settings, pageCount: pageCount,
                                             startFolder: startFolder, on: window) { [weak window] destination in
            guard let window, let destination else { return }
            // The panel's sheet is still closing; begin the next one after it.
            DispatchQueue.main.async {
                self.run(items: items, settings: settings, header: header, destination: destination, base: base,
                         on: window, showing: true)
            }
        }
    }

    private func run(items: [LayoutItem], settings: ContactSheetSettings, header: String?,
                     destination: ContactSheetExport.Destination, base: String, on window: NSWindow, showing: Bool) {
        let pageCount = settings.pageCount(imageCount: items.count)
        // A big sheet shows its progress at once; a small one only if slow.
        let delay: Duration = items.count > 40 || pageCount > 2 ? .zero : .milliseconds(500)
        let progress = ContactSheetProgress(on: window, title: "Making “\(base)”…", pageCount: pageCount, delay: delay)
        work = Task { [weak window] in
            do {
                let urls = try await ContactSheetExport.export(items: items, settings: settings, header: header,
                                                               destination: destination, cancel: progress.cancel,
                                                               progress: { done, total in progress.update(done: done, of: total) })
                progress.finish()
                if showing { ContactSheetExport.showResult(urls) }
            } catch ContactSheetRenderer.Failure.cancelled {
                progress.finish()
            } catch {
                progress.finish()
                SaveAlert.show(error, title: "The contact sheet couldn’t be saved.", on: window)
            }
        }
    }
}
