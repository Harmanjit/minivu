import SwiftUI
import MinivuCore

/// The Find Duplicates window's content (G5): what to look in and for, the
/// run's progress, the groups with their files, and the commands. Nothing
/// here animates, so Reduce Motion has nothing to change.
struct DuplicatesView: View {
    /// The commands the window controller carries out.
    struct Actions {
        var trash: () -> Void
        var showInBrowser: () -> Void
        var compare: () -> Void
    }

    @Bindable var model: DuplicatesModel
    let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(12)
            Divider()
            if model.groups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: DuplicatesWindowController.minimumSize.width,
               minHeight: DuplicatesWindowController.minimumSize.height)
    }

    // MARK: - Choices and progress

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Look in:", selection: $model.scope) {
                    ForEach(model.source.scopes) { scope in
                        Text(model.source.title(of: scope)).tag(scope)
                    }
                }
                .fixedSize()
                Picker("Find:", selection: $model.mode) {
                    Text("Identical Files").tag(DuplicateFinder.Mode.exact)
                    Text("Similar Images").tag(DuplicateFinder.Mode.similar)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Find") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.source.scopes.isEmpty)
                }
            }
            if case .running(let progress) = model.state {
                HStack(spacing: 8) {
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(Self.describe(progress))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            } else if model.resultMode == .similar, model.state == .finished {
                similaritySlider
            }
            if let note = model.note {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var similaritySlider: some View {
        HStack(spacing: 8) {
            Text("Similarity:")
            Slider(value: Binding(get: { Double(model.threshold) }, set: { model.threshold = Float($0) }),
                   in: Double(SimilarityIndex.thresholdRange.lowerBound)...Double(SimilarityIndex.thresholdRange.upperBound)) {
                Text("Similarity threshold")
            } minimumValueLabel: {
                Text("Stricter")
            } maximumValueLabel: {
                Text("Looser")
            }
            .frame(maxWidth: 360)
            .accessibilityValue("\(model.threshold.formatted(.number.precision(.fractionLength(2)))), "
                + "\(model.groups.count) groups")
            Text(model.threshold.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    static func describe(_ progress: DuplicateFinder.Progress?) -> String {
        guard let progress else { return "Listing images…" }
        let count = "\(progress.done.formatted()) of \(progress.total.formatted())"
        return switch progress.phase {
        case .comparing: "Comparing files of the same size… \(count)"
        case .analysing: "Analysing images… \(count)"
        case .grouping: "Comparing images with each other…"
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .ready:
            Text("Choose where to look and what to find, then click Find.")
                .foregroundStyle(.secondary)
        case .running:
            Text("Looking…")
                .foregroundStyle(.secondary)
        case .finished:
            Text(model.scanned == 1 ? "No duplicates: 1 image was compared."
                 : "No duplicates among \(model.scanned.formatted()) images.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Groups

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.files) { file in
                        DuplicateRow(file: file, model: model, isKeeper: model.keeper(of: group) == file.url)
                            .tag(file.url)
                    }
                } header: {
                    Text(header(for: group))
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .accessibilityLabel("Duplicate groups")
    }

    private func header(for group: DuplicateGroup) -> String {
        if model.resultMode == .exact, let size = group.files.first?.fileSize {
            return "\(group.files.count) identical files, \(size.formatted(.byteCount(style: .file))) each"
        }
        return "\(group.files.count) similar images"
    }

    // MARK: - Commands

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Keep:", selection: $model.keepRule) {
                Text("Highest Resolution").tag(KeepRule.highestResolution)
                Text("Largest File").tag(KeepRule.largestFile)
                Text("Oldest").tag(KeepRule.oldest)
            }
            .fixedSize()
            .help("Which file of each group is suggested to keep")
            Button("Mark Suggested") { model.markSuggested() }
                .help("Marks every file but the one suggested to keep in each group")
                .disabled(model.groups.isEmpty)
            Button("Clear Marks") { model.clearMarks() }
                .disabled(model.marked.isEmpty)
            Spacer()
            Text(markedSummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Show in Browser") { actions.showInBrowser() }
                .help("Shows the selected files, or every file found, in the browser")
                .disabled(model.groups.isEmpty)
            Button("Compare") { actions.compare() }
                .help("Shows 2 to 4 selected files side by side")
                .disabled(!CompareModel.paneRange.contains(model.selection.count))
            Button("Move to Trash…", role: .destructive) { actions.trash() }
                .disabled(model.marked.isEmpty || model.isRunning)
        }
        .disabled(model.isRunning)
    }

    private var markedSummary: String {
        let files = model.markedFiles
        guard !files.isEmpty else { return "" }
        let bytes = files.reduce(Int64(0)) { $0 + $1.fileSize }.formatted(.byteCount(style: .file))
        return files.count == 1 ? "1 marked, \(bytes)" : "\(files.count.formatted()) marked, \(bytes)"
    }
}

/// One file of a group: the mark, its thumbnail, name, size, dimensions,
/// date and folder, and whether the keep rule suggests keeping it.
private struct DuplicateRow: View {
    let file: FolderEntry
    let model: DuplicatesModel
    let isKeeper: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.marked.contains(file.url) }, set: { model.setMarked(file.url, $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Mark \(file.name) for the Trash")
            // The checkbox stays its own element; the rest reads as one.
            details
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
        HStack(spacing: 10) {
            DuplicateThumbnail(entry: file)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if isKeeper {
                        Text("Keep")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .help("Suggested to keep by the Keep rule")
                    }
                }
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.url.deletingLastPathComponent().path)
            }
            Spacer(minLength: 12)
            Text(dimensions).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(file.fileSize.formatted(.byteCount(style: .file))).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var folder: String {
        (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    private var dimensions: String {
        guard let size = model.pixelSizes[file.url] else { return "" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var accessibilityText: String {
        var parts = [file.name, file.fileSize.formatted(.byteCount(style: .file))]
        if let size = model.pixelSizes[file.url] { parts.append("\(Int(size.width)) by \(Int(size.height))") }
        parts.append(file.modified.formatted(date: .abbreviated, time: .shortened))
        parts.append("in \(FileManager.default.displayName(atPath: file.url.deletingLastPathComponent().path))")
        if isKeeper { parts.append("suggested to keep") }
        return parts.joined(separator: ", ")
    }
}

/// A file's thumbnail from the browser's thumbnail service, asked for when
/// the row appears and given up when it scrolls away.
private struct DuplicateThumbnail: View {
    let entry: FolderEntry
    @State private var loader = ThumbnailLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
        .onAppear { loader.load(entry) }
        .onDisappear { loader.cancel() }
    }
}

@MainActor @Observable private final class ThumbnailLoader {
    var image: CGImage?
    @ObservationIgnored private var request: ThumbnailRequest?

    func load(_ entry: FolderEntry) {
        guard image == nil, request == nil else { return }
        request = AppServices.thumbnails.request(entry, pixelSize: 112) { [weak self] image in
            self?.image = image
            self?.request = nil
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
    }
}
