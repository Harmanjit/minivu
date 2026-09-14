import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MinivuRender

/// Settings > Slideshow. Every control binds to `SlideshowSettingsStore`,
/// which saves at once; a slideshow already running takes up the interval,
/// transition and captions from its next slide.
struct SlideshowSettingsView: View {
    @ObservedObject var store = SlideshowSettingsStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Show each slide for") {
                    HStack {
                        Slider(value: wholeSeconds($store.settings.interval), in: SlideshowSettings.intervalRange)
                        SlideshowValueLabel(text: "\(Int(store.settings.interval)) s")
                    }
                }
                Picker("Order", selection: $store.settings.order) {
                    ForEach(SlideshowSettings.Order.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Start again after the last slide", isOn: $store.settings.loop)
                Picker("Captions", selection: $store.settings.caption) {
                    ForEach(SlideshowSettings.Caption.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                // The display is the viewer's setting, not a second one here:
                // a show started from a full-screen viewer plays over it.
                Text("Slideshows play full screen on the display chosen for the full-screen viewer in Viewer settings.")
                    .paragraphFooter()
            }

            Section("Transition") {
                Picker("Transition", selection: $store.settings.transition) {
                    Text("Random").tag(SlideshowSettings.TransitionChoice.random)
                    Divider()
                    ForEach(SlideshowTransition.allCases) { transition in
                        Text(transition.title).tag(SlideshowSettings.TransitionChoice.fixed(transition))
                    }
                }
                LabeledContent("Duration") {
                    HStack {
                        Slider(value: tenths($store.settings.transitionDuration),
                               in: SlideshowSettings.transitionDurationRange)
                        SlideshowValueLabel(text: String(format: "%.1f s", store.settings.transitionDuration))
                    }
                }
                VStack(spacing: 4) {
                    SlideshowTransitionPreview(choice: store.settings.transition,
                                               duration: store.settings.transitionDuration)
                        .frame(width: 256, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Click the preview to play it").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                Toggle("Play music", isOn: $store.settings.musicEnabled)
                ForEach(store.settings.playlist) { item in
                    HStack {
                        Image(systemName: item.isFolder ? "folder" : "music.note")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { remove(item) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    if store.settings.playlist.isEmpty {
                        Text("No music chosen").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add…") { addMusic() }
                }
                Group {
                    Toggle("Shuffle", isOn: $store.settings.shuffleMusic)
                    LabeledContent("Volume") {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $store.settings.volume, in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!store.settings.musicEnabled)
            } header: {
                Text("Music")
            } footer: {
                Text("MP3, AAC, WAV and AIFF files, or folders of them. The music fades in when a slideshow starts, pauses with it, and fades out when it ends.")
                    .paragraphFooter()
            }
        }
        .settingsForm()
    }

    private func remove(_ item: SlideshowSettings.PlaylistItem) {
        store.settings.playlist.removeAll { $0.id == item.id }
    }

    /// An open panel for songs and folders, as a sheet on Settings. The
    /// bookmarks are made from the URLs the panel returns, which carry the
    /// permission the user just gave. Choosing music turns it on.
    private func addMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SlideshowPlaylistResolver.audioTypes
        panel.prompt = "Add"
        panel.message = "Choose songs, or folders of songs, to play during slideshows."
        let store = store
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let items = panel.urls.compactMap(SlideshowPlaylistResolver.item(for:))
            guard !items.isEmpty else { return }
            store.settings.playlist += items
            store.settings.musicEnabled = true
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    private func wholeSeconds(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() })
    }

    private func tenths(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 10).rounded() / 10 })
    }
}

/// A slider's value in a fixed width, so the sliders line up and don't shift
/// as the number changes (as in the other settings panes).
private struct SlideshowValueLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
    }
}
