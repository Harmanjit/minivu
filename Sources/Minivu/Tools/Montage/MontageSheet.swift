import AppKit
import SwiftUI
import MinivuCore

/// Tools > Montage Wallpaper…: a sheet on the browser with the choices and
/// a live preview; Set as Wallpaper draws the montage at each display's
/// size, saves it to Pictures/minivu Wallpapers and makes it that display's
/// desktop picture.
final class MontageSheetController: NSObject, NSWindowDelegate {
    let model: MontageModel
    private let sheet: NSWindow
    private weak var parent: NSWindow?
    /// Keeps the controller alive while its sheet is up.
    private var retainedSelf: MontageSheetController?
    private(set) var work: Task<Void, Never>?

    var desktop: DesktopPictureSetting = NSWorkspace.shared
    var picturesFolder: URL = BookmarkStore.picturesFolder
    /// False in the debug action that only writes the file.
    var setsDesktopPicture = true

    var wallpapersFolder: URL {
        picturesFolder.appendingPathComponent(MontageOutput.wallpapersFolderName, isDirectory: true)
    }

    init(model: MontageModel) {
        self.model = model
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled],
                         backing: .buffered, defer: true)
        super.init()
        let view = MontageSheetView(model: model,
                                    onCancel: { [weak self] in self?.cancel() },
                                    onCreate: { [weak self] in self?.create() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        sheet.contentView = hosting
        sheet.setContentSize(hosting.fittingSize)
        sheet.delegate = self
    }

    func begin(on parent: NSWindow) {
        self.parent = parent
        retainedSelf = self
        model.start()
        parent.beginSheet(sheet)
    }

    func create() {
        guard work == nil else { return }
        let folder = wallpapersFolder
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let written = try await model.makeMontages(in: folder, date: Date())
                if setsDesktopPicture {
                    for (url, display) in written {
                        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else {
                            continue
                        }
                        try desktop.setDesktopImageURL(url, for: screen, options: DesktopPictureSetter.options)
                    }
                } else {
                    let paths = written.map(\.url.path).joined(separator: ", ")
                    FileHandle.standardError.write(Data("minivu: montage written to \(paths)\n".utf8))
                }
                work = nil
                end()
            } catch is CancellationError {
                work = nil
            } catch {
                work = nil
                let alert = NSAlert()
                alert.messageText = "The montage couldn’t be made."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: sheet, completionHandler: nil)
            }
        }
    }

    /// Cancel stops a montage being drawn; nothing is written until a
    /// montage is complete, so nothing is left behind.
    func cancel() {
        work?.cancel()
        work = nil
        end()
    }

    private func end() {
        model.stop()
        // The Background well opens the shared colour panel, which would
        // otherwise stay on screen, still bound to a sheet that has gone.
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.orderOut(nil) }
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
        retainedSelf = nil
    }

    // MARK: - Debug (snapshot harness only)

    /// Debug only, for the snapshot harness: switches to the scattered layout.
    @objc func debugMontageScattered(_ sender: Any?) {
        model.remembersChoices = false
        model.style = .scattered
    }

    /// Debug only, for the snapshot harness: switches to the grid layout
    /// (whatever layout was last remembered).
    @objc func debugMontageGrid(_ sender: Any?) {
        model.remembersChoices = false
        model.style = .grid
    }

    /// Debug only, for the snapshot harness: switches to the mosaic layout.
    @objc func debugMontageMosaic(_ sender: Any?) {
        model.remembersChoices = false
        model.style = .mosaic
    }

    /// Debug only, for the snapshot harness: draws the montage and writes it
    /// to a temporary folder (MINIVU_DEBUG_OUTPUT, or minivu Debug Montages
    /// in the temporary directory) without touching the desktop picture or
    /// the Pictures folder.
    @objc func debugMontageWriteOnly(_ sender: Any?) {
        let output = ProcessInfo.processInfo.environment["MINIVU_DEBUG_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("minivu Debug Montages")
        picturesFolder = output
        setsDesktopPicture = false
        create()
    }
}

struct MontageSheetView: View {
    @Bindable var model: MontageModel
    var onCancel: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Montage Wallpaper").font(.headline)
                Text("A collage of \(model.entries.count == 1 ? "1 photo" : "\(model.entries.count) photos") at the size of the display, saved to Pictures › minivu Wallpapers and set as its desktop picture.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            MontagePreview(image: model.preview, aspect: previewAspect)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            if let note = model.limitNote {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            Form {
                Picker("Display", selection: $model.displayChoice) {
                    ForEach(model.displays) { Text($0.title).tag($0.id) }
                    if model.displays.count > 1 {
                        Divider()
                        Text("All Displays").tag(MontageModel.allDisplays)
                    }
                }
                LabeledContent("Layout") {
                    HStack {
                        Picker("Layout", selection: $model.style) {
                            ForEach(MontageStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Button("Shuffle", systemImage: "shuffle") { model.shuffle() }
                            .disabled(model.style != .scattered)
                            .help("Scatter the photos another way")
                    }
                }
                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: Binding(get: { model.spacing }, set: { model.spacing = $0.rounded() }), in: 0...40)
                            .accessibilityLabel("Spacing")
                            .accessibilityValue("\(Int(model.spacing)) points")
                        Text("\(Int(model.spacing)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                ColorPicker("Background", selection: $model.background, supportsOpacity: false)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if case .working(let status) = model.phase {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set as Wallpaper", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.entries.isEmpty || model.targets.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 560)
    }

    private var previewAspect: CGFloat {
        guard let size = model.previewDisplay?.pixelSize, size.height > 0 else { return 16.0 / 10 }
        return size.width / size.height
    }
}

/// The preview, at the display's shape, like a small screen.
private struct MontagePreview: View {
    var image: CGImage?
    var aspect: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(3)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}
