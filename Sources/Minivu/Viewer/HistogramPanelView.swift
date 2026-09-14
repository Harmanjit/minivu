import AppKit
import SwiftUI
import MinivuCore
import MinivuRender

/// Which channels the histogram plots.
nonisolated enum HistogramDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case rgb, red, green, blue, luminance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "Luminance"
        }
    }

    var channels: [HistogramData.Channel] {
        switch self {
        case .rgb: [.red, .green, .blue]
        case .red: [.red]
        case .green: [.green]
        case .blue: [.blue]
        case .luminance: [.luminance]
        }
    }
}

/// The plot's arithmetic, apart from drawing so it can be tested.
nonisolated enum HistogramPlot {
    /// A clipping warning lights when more than this fraction of pixels sit
    /// in an end bin.
    static let clippingThreshold = 0.001

    /// The count drawn full height. The end bins are left out: a photo with
    /// blown highlights has one enormous spike at 255 that would flatten
    /// everything else, and the clipping warnings already report it. Bins
    /// taller than this are cut off at the top.
    static func scale(_ data: HistogramData, channels: [HistogramData.Channel]) -> Double {
        let inner = channels.map { data.bins($0)[1..<(HistogramData.binCount - 1)].max() ?? 0 }.max() ?? 0
        let ends = channels.map { max(data.bins($0).first ?? 0, data.bins($0).last ?? 0) }.max() ?? 0
        return Double(max(inner > 0 ? inner : ends, 1))
    }

    /// Which of `channels` clip at the dark (`highlights` false) or bright
    /// end, beyond the threshold.
    static func clipped(_ data: HistogramData, channels: [HistogramData.Channel], highlights: Bool) -> [HistogramData.Channel] {
        channels.filter {
            (highlights ? data.highlightClipping($0) : data.shadowClipping($0)) > clippingThreshold
        }
    }

    /// The bin under a horizontal position in a plot `width` points wide.
    static func level(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return min(max(Int(x / width * CGFloat(HistogramData.binCount)), 0), HistogramData.binCount - 1)
    }
}

/// What the panel shows; the controller below fills it in.
@Observable final class HistogramPanelModel {
    enum ColorCount: Equatable {
        /// Not counted yet (the Count button shows).
        case idle
        case counting
        case counted(Int)
        case failed
    }

    var data: HistogramData?
    var colorCount: ColorCount = .idle
    /// False when there is no file to count.
    var canCountColors = false
    @ObservationIgnored var onCountColors: (() -> Void)?
}

/// Keeps the viewer's histogram up to date and counts colours on request.
///
/// Recomputing is cheap on the GPU (one mip level, a millisecond or two),
/// but an edit slider replaces the texture sixty times a second, and each
/// result redraws the panel. So a new texture starts a computation at once
/// if none ran in the last 100 ms, and otherwise waits out the rest of that
/// interval, taking whichever texture is newest by then: at most ten a
/// second while dragging, and the final state always arrives. A playing
/// animation, which would otherwise keep that going for as long as it
/// loops, waits `animationInterval` instead. Nothing is computed while the
/// panel is hidden; showing it catches up.
final class HistogramPanelController {
    static let height: CGFloat = 232
    static let minimumInterval: TimeInterval = 0.1
    static let animationInterval: TimeInterval = 1

    let model = HistogramPanelModel()
    private(set) lazy var view: NSHostingView<HistogramPanelView> = {
        let host = NSHostingView(rootView: HistogramPanelView(model: model))
        // The panel decides the size, not the SwiftUI content.
        host.sizingOptions = []
        return host
    }()

    private(set) var isActive = false
    /// The texture on the canvas, the one to measure next.
    private var texture: ImageTexture?
    /// The texture the plot shows; weak so a histogram never keeps GPU
    /// memory alive.
    private weak var measured: ImageTexture?
    private var computeTask: Task<Void, Never>?
    private var waitWork: DispatchWorkItem?
    private var lastStart: TimeInterval = -.infinity
    private var interval = HistogramPanelController.minimumInterval
    /// Computations started, for tests.
    private(set) var computeCount = 0

    private var entry: FolderEntry?
    private var countTask: Task<Void, Never>?
    private struct CountKey: Hashable {
        var url: URL
        var modified: Date
    }
    /// Colour counts already made this session, by file and modification
    /// date: counting decodes the whole image, so a second look is free.
    private static var counts: [CountKey: Int] = [:]

    init() {
        model.onCountColors = { [weak self] in self?.countColors() }
    }

    /// The right-hand panel's content: the histogram above `info`.
    func makePanel(with info: NSView, width: CGFloat) -> NSView {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        view.frame = NSRect(x: 0, y: panel.bounds.height - Self.height, width: width, height: Self.height)
        view.autoresizingMask = [.width, .minYMargin]
        info.frame = NSRect(x: 0, y: 0, width: width, height: panel.bounds.height - Self.height)
        info.autoresizingMask = [.width, .height]
        panel.addSubview(view)
        panel.addSubview(info)
        return panel
    }

    // MARK: - Histogram

    /// The canvas shows another texture (another image, a sharper copy, an
    /// edit preview, an animation frame), or none. `interval` is the least
    /// time between computations from now on.
    func show(_ texture: ImageTexture?, interval: TimeInterval = HistogramPanelController.minimumInterval) {
        self.texture = texture
        if interval < self.interval {
            // Paused: a wait timed for playback would hold the frame back.
            waitWork?.cancel()
            waitWork = nil
        }
        self.interval = interval
        guard isActive else { return }
        update()
    }

    /// The panel became visible (true) or finished hiding (false).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            update()
        } else {
            waitWork?.cancel()
            waitWork = nil
        }
    }

    private func update() {
        guard let texture else {
            waitWork?.cancel()
            waitWork = nil
            measured = nil
            model.data = nil
            return
        }
        // One at a time; the one running looks again when it's done.
        guard texture !== measured, computeTask == nil, waitWork == nil else { return }
        let wait = lastStart + interval - ProcessInfo.processInfo.systemUptime
        if wait > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.waitWork = nil
                self?.update()
            }
            waitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        lastStart = ProcessInfo.processInfo.systemUptime
        computeCount += 1
        computeTask = Task { [weak self] in
            let data = await BlockingWork.run { try? Histogram.compute(texture: texture) }
            guard let self else { return }
            self.computeTask = nil
            guard self.isActive else { return }
            self.measured = texture
            self.model.data = data
            // A newer texture may have arrived meanwhile.
            self.update()
        }
    }

    // MARK: - Colour count

    /// The viewer moved to another image: its count, if made before.
    func setEntry(_ entry: FolderEntry?) {
        guard entry != self.entry else { return }
        countTask?.cancel()
        countTask = nil
        self.entry = entry
        model.canCountColors = entry != nil
        model.colorCount = entry.flatMap { Self.counts[CountKey(url: $0.url, modified: $0.modified)] }
            .map { .counted($0) } ?? .idle
    }

    /// Decodes the file at full resolution off the main thread and counts
    /// its colours. The file as saved is counted, not an unsaved edit, and
    /// HDR photos as their SDR rendition (the counter works in 8 bits).
    ///
    /// The file's modification date is read afresh (one stat): the viewer's
    /// entry keeps the date the folder was listed with, so after a save in
    /// place or a change on disk its date would find the old file's count.
    func countColors() {
        guard let entry, countTask == nil else { return }
        var file = entry.url
        file.removeAllCachedResourceValues()
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? entry.modified
        let key = CountKey(url: entry.url, modified: modified)
        if let known = Self.counts[key] {
            model.colorCount = .counted(known)
            return
        }
        model.colorCount = .counting
        let url = entry.url
        // A full decode and a count of every pixel block their thread for
        // seconds: on GCD (BlockingWork), with a flag in place of task
        // cancellation so a closed viewer skips the count after the decode.
        let cancel = CancellationFlag()
        countTask = Task { [weak self] in
            let count = await withTaskCancellationHandler {
                await BlockingWork.run { () -> Int? in
                    guard let decoded = try? ImageDecoder.decode(url, allowHDR: false), !cancel.isCancelled
                    else { return nil }
                    return try? ColorCounter.countUniqueColors(in: decoded.image)
                }
            } onCancel: { cancel.cancel() }
            guard !Task.isCancelled, let self, self.entry == entry else { return }
            self.countTask = nil
            if let count {
                Self.counts[key] = count
                self.model.colorCount = .counted(count)
            } else {
                self.model.colorCount = .failed
            }
        }
    }

    /// The viewer is closing.
    func stop() {
        setActive(false)
        computeTask?.cancel()
        computeTask = nil
        countTask?.cancel()
        countTask = nil
        texture = nil
    }
}

/// The histogram at the top of the viewer's right-hand panel: RGB overlaid
/// or one channel, clipping warnings, the level and counts under the
/// pointer, and the colour count.
struct HistogramPanelView: View {
    let model: HistogramPanelModel
    @AppStorage("HistogramDisplayMode") private var mode: HistogramDisplayMode = .rgb
    @State private var hoverLevel: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Histogram")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let data = model.data, data.aboveSDRWhite > 0 {
                    Text("HDR \(Self.percent(data.aboveSDRWhiteFraction)) above SDR white")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Pixels brighter than SDR white, which an SDR screen or file would clip")
                }
            }
            Picker("Channels", selection: $mode) {
                ForEach(HistogramDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            plot
                .frame(height: 96)
            readout
            Divider()
            colorCountRow
        }
        .padding(12)
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let data = model.data {
                    Canvas { context, size in draw(data, in: &context, size: size) }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Text("No Image")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverLevel = HistogramPlot.level(at: point.x, width: size.width)
                case .ended: hoverLevel = nil
                }
            }
        }
    }

    private func draw(_ data: HistogramData, in context: inout GraphicsContext, size: CGSize) {
        let channels = mode.channels
        let scale = HistogramPlot.scale(data, channels: channels)
        let binWidth = size.width / CGFloat(HistogramData.binCount)
        context.drawLayer { layer in
            // Screen blending: where red and green overlap the plot turns
            // yellow, and all three make white, as light does.
            if channels.count > 1 { layer.blendMode = .screen }
            for channel in channels {
                let bins = data.bins(channel)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, count) in bins.enumerated() {
                    let height = min(Double(count) / scale, 1) * (size.height - 2)
                    path.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) * binWidth, y: size.height - height))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                layer.fill(path, with: .color(Self.color(channel).opacity(channels.count > 1 ? 0.9 : 0.8)))
            }
        }
        if let hoverLevel {
            let x = (CGFloat(hoverLevel) + 0.5) * binWidth
            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.6)))
        }
    }

    // MARK: Readout

    /// Clipping warnings at either end, and between them the clipped
    /// percentages, or the level and counts under the pointer.
    private var readout: some View {
        HStack(spacing: 6) {
            clippingTriangle(highlights: false)
            Spacer(minLength: 0)
            Text(readoutText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            clippingTriangle(highlights: true)
        }
        .frame(height: 14)
    }

    private var readoutText: String {
        guard let data = model.data else { return " " }
        let channels = mode.channels
        if let level = hoverLevel {
            let counts = channels.map { channel -> String in
                let count = Self.number(Int(data.bins(channel)[level]))
                return channels.count > 1 ? "\(Self.letter(channel)) \(count)" : count
            }
            return "Level \(level)   " + counts.joined(separator: "  ")
        }
        let shadows = channels.map { data.shadowClipping($0) }.max() ?? 0
        let highlights = channels.map { data.highlightClipping($0) }.max() ?? 0
        return "Shadows \(Self.percent(shadows))   Highlights \(Self.percent(highlights))"
    }

    /// Lit in the colour of the clipped channels combined (red and green
    /// clipping together shows yellow), dim when nothing clips.
    private func clippingTriangle(highlights: Bool) -> some View {
        let clipped = model.data.map { HistogramPlot.clipped($0, channels: mode.channels, highlights: highlights) } ?? []
        let color: Color
        if clipped.isEmpty {
            color = Color.secondary.opacity(0.35)
        } else if mode == .rgb {
            color = Color(red: clipped.contains(.red) ? 1 : 0.25, green: clipped.contains(.green) ? 1 : 0.25,
                          blue: clipped.contains(.blue) ? 1 : 0.25)
        } else {
            color = Self.color(clipped[0])
        }
        return Image(systemName: highlights ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .help(highlights ? "Highlight clipping" : "Shadow clipping")
    }

    // MARK: Colour count

    private var colorCountRow: some View {
        HStack(spacing: 8) {
            switch model.colorCount {
            case .idle:
                Text("Unique colours").foregroundStyle(.secondary)
                Spacer()
                Button("Count") { model.onCountColors?() }
                    .controlSize(.small)
                    .disabled(!model.canCountColors)
            case .counting:
                ProgressView().controlSize(.small)
                Text("Counting colours…").foregroundStyle(.secondary)
                Spacer()
            case .counted(let count):
                Text(count == 1 ? "1 colour" : "\(Self.number(count)) colours")
                    .monospacedDigit()
                    .textSelection(.enabled)
                Spacer()
            case .failed:
                Text("Couldn’t count colours").foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.onCountColors?() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .frame(height: 22)
    }

    // MARK: Formatting

    static func color(_ channel: HistogramData.Channel) -> Color {
        switch channel {
        case .red: Color(red: 1, green: 0.22, blue: 0.2)
        case .green: Color(red: 0.2, green: 0.9, blue: 0.3)
        case .blue: Color(red: 0.25, green: 0.45, blue: 1)
        case .luminance: Color(white: 0.85)
        }
    }

    static func letter(_ channel: HistogramData.Channel) -> String {
        switch channel {
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "L"
        }
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// "0%", "0.4%", "12%".
    nonisolated static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value == 0 { return "0%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }
}
