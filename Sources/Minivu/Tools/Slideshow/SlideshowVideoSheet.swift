import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// The Export Slideshow Video dialog's state: the pictures, the encoding
/// choices (remembered), and the slideshow settings they will play with.
@Observable final class SlideshowVideoModel {
    let images: [FolderEntry]
    let start: Int
    /// The screen's size in pixels, for the Screen size choice.
    let screen: CGSize?
    var settings: SlideshowVideoSettings {
        didSet {
            if settings != settings.validated { settings = settings.validated }
            if settings != oldValue { store.settings = settings }
        }
    }
    @ObservationIgnored let store: SlideshowVideoSettingsStore
    @ObservationIgnored let slideshowStore: SlideshowSettingsStore

    init(images: [FolderEntry], start: Int, screen: CGSize?, store: SlideshowVideoSettingsStore,
         slideshowStore: SlideshowSettingsStore) {
        self.images = images
        self.start = start
        self.screen = screen
        self.store = store
        self.slideshowStore = slideshowStore
        settings = store.settings
    }

    var format: SlideshowVideoFormat { settings.format(screen: screen) }

    /// "12 pictures · 1:05 · 1920 × 1080".
    func summary(slideshow: SlideshowSettings) -> String {
        let seconds = SlideshowVideoPlanner.duration(count: images.count, settings: slideshow,
                                                     frameRate: settings.frameRate)
        let length = Duration.seconds(seconds.rounded(.up)).formatted(.time(pattern: .minuteSecond))
        return localized(.init("\(images.count) pictures · \(length) · \(String(format.width)) × \(String(format.height))",
                               comment: "Slideshow video: number of pictures, length (1:05), then width × height in pixels"))
    }

    /// What the video plays with, from Settings > Slideshow, one line each.
    static func slideshowLines(_ slideshow: SlideshowSettings) -> [String] {
        let transition: String
        let interval = Int(slideshow.interval)
        let duration = slideshow.transitionDuration.formatted(.number.precision(.fractionLength(1)))
        switch slideshow.transition {
        case .random:
            transition = localized(.init("Each slide for \(interval) s, Random transitions of \(duration) s",
                                         comment: "Slideshow video: seconds per slide, then the transitions' length in seconds"))
        case .fixed(let kind):
            transition = localized(.init("Each slide for \(interval) s, \(kind.title) transitions of \(duration) s",
                                         comment: "Slideshow video: seconds per slide, a transition such as Push, then its length in seconds"))
        }
        let music: String
        if slideshow.playsMusic {
            let count = slideshow.playlist.count
            music = count == 1 ? localized(.init("Music: \(slideshow.playlist[0].name)", comment: "%@ is a song or folder name"))
                : localized(.init("Music: \(count) items", comment: "Songs or folders of songs"))
        } else {
            music = localized("No music")
        }
        return [
            transition,
            localized(.init("\(slideshow.order.title), captions: \(slideshow.caption.inlineTitle)",
                            comment: "Slideshow video: the order (In order, Shuffled), then the captions")),
            music,
        ]
    }
}

/// The dialog: how to encode, and a summary of the slideshow settings the
/// video follows, with a way to change them.
struct SlideshowVideoView: View {
    @Bindable var model: SlideshowVideoModel
    @ObservedObject var slideshow: SlideshowSettingsStore
    var onSlideshowSettings: () -> Void
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $model.settings.resolution) {
                        ForEach(SlideshowVideoResolution.allCases) { resolution in
                            Text(resolution == .screen ? screenTitle : resolution.title).tag(resolution)
                        }
                    }
                    Picker("Frame rate", selection: $model.settings.frameRate) {
                        ForEach(SlideshowVideoFormat.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Codec", selection: $model.settings.codec) {
                        ForEach(SlideshowVideoCodec.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Quality", selection: $model.settings.quality) {
                        ForEach(SlideshowVideoQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker(localized(.init("section.file", defaultValue: "File", comment: "Noun: the output file and its options (heading or label), not the File menu")), selection: $model.settings.container) {
                        ForEach(SlideshowVideoContainer.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    ForEach(SlideshowVideoModel.slideshowLines(slideshow.settings), id: \.self) { line in
                        Text(line)
                    }
                    HStack {
                        Spacer()
                        Button("Slideshow Settings…", action: onSlideshowSettings)
                    }
                } header: {
                    Text("Slideshow")
                } footer: {
                    Text("The video plays as a slideshow would: the first picture fades in from black and the last fades out. HDR photos are shown as on a standard display. Transitions play as chosen, even with Reduce Motion on.")
                        .paragraphFooter()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(model.summary(slideshow: slideshow.settings))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.images.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 520)
    }

    private var screenTitle: String {
        let size = SlideshowVideoResolution.screen.pixelSize(screen: model.screen)
        return localized(.init("Screen size (\(String(Int(size.width))) × \(String(Int(size.height))))",
                               comment: "Video resolution: width × height in pixels"))
    }
}

/// Presents the dialog as a sheet and carries an Export through choosing a
/// file, writing the video with progress and Cancel, and reporting a failure.
final class SlideshowVideoController {
    let model: SlideshowVideoModel
    private weak var parent: NSWindow?
    private let startFolder: URL?
    private(set) var sheet: NSWindow?
    /// The export under way, for tests to await.
    private(set) var work: Task<Void, Never>?
    /// The progress sheet of the export under way; tests press its Cancel.
    private(set) var progress: ContactSheetProgress?
    /// Where the last export went, for tests.
    private(set) var exported: URL?

    /// The dialog open on each window, so a second command doesn't stack another.
    private static var open: [ObjectIdentifier: SlideshowVideoController] = [:]

    static func controller(for window: NSWindow) -> SlideshowVideoController? {
        open[ObjectIdentifier(window)]
    }

    init(images: [FolderEntry], start: Int, screen: CGSize?, startFolder: URL?,
         store: SlideshowVideoSettingsStore = SlideshowVideoSettingsStore(),
         slideshowStore: SlideshowSettingsStore = SlideshowWindowController.settingsStore) {
        model = SlideshowVideoModel(images: images, start: start, screen: screen, store: store,
                                    slideshowStore: slideshowStore)
        self.startFolder = startFolder
    }

    /// The screen size, in pixels, of the screen `window` is on.
    static func screenPixels(of window: NSWindow?) -> CGSize? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    func begin(on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        parent = window
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled],
                             backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = localized("Export Slideshow Video")
        let view = SlideshowVideoView(model: model, slideshow: model.slideshowStore,
                                      onSlideshowSettings: { (NSApp.delegate as? AppDelegate)?.showSettings(pane: .slideshow) },
                                      onCancel: { [weak self] in self?.close() },
                                      onExport: { [weak self] in self?.export() })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        sheet = panel
        Self.open[ObjectIdentifier(window)] = self
        window.beginSheet(panel)
        panel.makeFirstResponder(nil)
    }

    func close() {
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
        if let parent { Self.open[ObjectIdentifier(parent)] = nil }
    }

    /// Closes the dialog and asks where to save; Cancel in the save panel
    /// comes back to the dialog.
    func export() {
        guard let window = parent else { return }
        let name = SlideshowVideoExport.suggestedName(for: model.images, container: model.settings.container)
        let container = model.settings.container
        close()
        // The dialog is closed, so nothing else holds this controller: the
        // panel's completion keeps it until the export has started.
        SlideshowVideoExport.chooseDestination(name, container, startFolder, window) { [weak window] url in
            guard let window else { return }
            // The panel's sheet is still closing; begin the next one after it.
            DispatchQueue.main.async {
                guard let url else { return self.begin(on: window) }
                self.run(to: url, on: window)
            }
        }
    }

    private func run(to destination: URL, on window: NSWindow) {
        let images = model.images, start = model.start, video = model.settings, screen = model.screen
        let slideshow = model.slideshowStore.settings
        let progress = ContactSheetProgress(on: window, title: localized(.init("Exporting “\(destination.lastPathComponent)”…", comment: "%@ is a file name")),
                                            pageCount: 100, delay: .milliseconds(300),
                                            describe: { done, _ in localized(.init("\(done)%", comment: "A percentage")) })
        self.progress = progress
        work = Task { [weak window] in
            do {
                exported = try await SlideshowVideoExport.export(
                    images: images, start: start, slideshow: slideshow, video: video, screen: screen,
                    destination: destination, cancel: progress.cancel,
                    refreshBookmarks: { [store = model.slideshowStore] in store.refreshPlaylistBookmarks($0) },
                    progress: { fraction in progress.update(done: Int((fraction * 100).rounded(.down)), of: 100) })
                progress.finish()
            } catch is CancellationError {
                progress.finish()
            } catch {
                progress.finish()
                SaveAlert.show(error, title: localized("The slideshow video couldn’t be exported."), on: window)
            }
            self.progress = nil
        }
    }
}
