import AppKit
import SwiftUI
import Observation
import MinivuCore
import MinivuRender

/// Runs a planned Batch Convert: a couple of files at a time off the main
/// thread, each write in line behind every other image write, with progress
/// and Cancel, and an account of what was written, skipped and failed.
///
/// **Per file:** decode and render and encode on GCD threads
/// (`BatchWorkExecutor`), then the finished bytes go through
/// `FileWriteQueue.shared`, where `BatchFileWriter` puts them in place
/// atomically. Encoding before queueing keeps the conversions parallel; the
/// write itself is quick. At most `concurrency` files are in hand at once,
/// so memory stays bounded however many files are selected.
///
/// **Cancel** stops new files from starting, and a file whose encode
/// finishes after Cancel is dropped without being written. A write already
/// in the queue completes (it is atomic, never partial), so what is on disk
/// afterwards is a set of whole files.
///
/// **Memory:** two files at a time, one on Macs with 8 GB or less, and only
/// one camera RAW at a time whatever the Mac, because Apple's RAW engine
/// takes about 1.6 GB per full-size render (DESIGN.md 4.5).
@MainActor final class BatchConvertJob {
    struct Entry: Equatable {
        var source: URL
        var detail: String
    }

    struct Outcome {
        /// Output files written, in batch order.
        var written: [URL] = []
        /// Files the replaced ones went to in the Trash.
        var trashed: [URL] = []
        var skipped: [Entry] = []
        var failed: [Entry] = []
        var wasCancelled = false
    }

    let outputs: [BatchOutput]
    let settings: BatchConvertSettings
    let converter: BatchConverter
    let trash: BatchFileWriter.Trasher
    let writes: FileWriteQueue
    let concurrency: Int
    let progress: BatchProgress
    /// Called after each file has been converted, before it is written; for
    /// tests (cancel part way).
    var onEncoded: ((Int) -> Void)?

    private var nextIndex = 0
    private var results: [Int: FileResult] = [:]
    private let rawSlot = AsyncSlot()

    private enum FileResult {
        case written(URL, trashed: URL?)
        case skipped(String)
        case failed(String)
    }

    init(outputs: [BatchOutput], settings: BatchConvertSettings, converter: BatchConverter,
         trash: @escaping BatchFileWriter.Trasher, writes: FileWriteQueue = .shared,
         concurrency: Int = BatchConvertJob.defaultConcurrency()) {
        self.outputs = outputs
        self.settings = settings
        self.converter = converter
        self.trash = trash
        self.writes = writes
        self.concurrency = max(1, concurrency)
        progress = BatchProgress(total: outputs.count)
    }

    nonisolated static func defaultConcurrency(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory <= 8 << 30 ? 1 : 2
    }

    /// The converter minivu uses: the shared edit renderer, RAW files as the
    /// viewer's settings decode them, and colour spaces by the Save policy.
    static func makeConverter() -> BatchConverter {
        BatchConverter(renderer: EditRenderer.shared, displaySettings: ImageLoader.shared.settings) { url, kind, options in
            guard options.format.supportsColorProfile else { return CGColorSpace(name: CGColorSpace.sRGB)! }
            if let named = SavePolicy.namedColorSpace(options.colorProfile) { return named }
            // Turning and resizing don't widen the gamut, so an ordinary photo
            // stays in its own space; RAW renders keep their wide one.
            return SavePolicy.renderColorSpace(source: kind == .raw ? nil : SavePolicy.sourceColorSpace(of: url),
                                               isHDR: false, preferWideGamut: kind == .raw)
        }
    }

    func run() async -> Outcome {
        // Workers are tasks on the main actor that spend nearly all their
        // time suspended, awaiting a conversion or a write.
        // Every planned name, for Keep Both to step past if a name is taken
        // after planning.
        let taken = Set(outputs.map { Self.pathKey($0.destination) })
        let workers = (0..<min(concurrency, max(outputs.count, 1))).map { _ in Task { await self.work(taken: taken) } }
        for worker in workers { await worker.value }
        var outcome = Outcome(wasCancelled: progress.isCancelled)
        for index in outputs.indices {
            switch results[index] {
            case .written(let url, let trashed)?:
                outcome.written.append(url)
                if let trashed { outcome.trashed.append(trashed) }
            case .skipped(let reason)?:
                outcome.skipped.append(Entry(source: outputs[index].source, detail: reason))
            case .failed(let reason)?:
                outcome.failed.append(Entry(source: outputs[index].source, detail: reason))
            case nil:
                break
            }
        }
        progress.finish()
        return outcome
    }

    private func work(taken: Set<String>) async {
        while !progress.isCancelled, nextIndex < outputs.count {
            let index = nextIndex
            nextIndex += 1
            let output = outputs[index]
            let policy: BatchFileWriter.ExistingFilePolicy
            switch output.action {
            case .skip(let reason):
                results[index] = .skipped(reason)
                progress.advance()
                continue
            case .fail(let reason):
                results[index] = .failed(reason)
                progress.advance()
                continue
            case .replace:
                policy = .replace
            case .write:
                policy = settings.existingFiles
            }

            progress.currentName = output.source.lastPathComponent
            let isRaw = ImageFormats.kind(of: output.source) == .raw
            if isRaw { await rawSlot.acquire() }
            let data: Data
            do {
                let converter = self.converter, settings = self.settings, source = output.source
                data = try await withTaskExecutorPreference(BatchWorkExecutor.shared) {
                    try await converter.encodedData(for: source, settings: settings)
                }
                if isRaw { rawSlot.release() }
            } catch {
                if isRaw { rawSlot.release() }
                results[index] = .failed(SaveAlert.message(for: error))
                progress.advance()
                continue
            }
            onEncoded?(index)
            // Converted after Cancel: dropped, never written.
            guard !progress.isCancelled else { break }

            let destination = output.destination, trash = self.trash
            let folder = destination.deletingLastPathComponent()
            let write = writes.enqueue(replacing: [destination]) {
                try await BlockingWork.run {
                    try BatchFileWriter.commit(data, to: destination, policy: policy, trash: trash) { name in
                        taken.contains(Self.pathKey(folder.appendingPathComponent(name)))
                    }
                }
            }
            do {
                switch try await write.value.value {
                case .written(let url, let trashed):
                    results[index] = .written(url, trashed: trashed)
                case .skipped:
                    results[index] = .skipped("An item named “\(destination.lastPathComponent)” already exists.")
                }
            } catch {
                results[index] = .failed(SaveAlert.message(for: error))
            }
            progress.advance()
        }
    }

    nonisolated static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    // MARK: - Summary

    /// The alert after a batch, or nil when every file was converted (or
    /// the user cancelled and nothing went wrong).
    nonisolated static func summary(for outcome: Outcome) -> (title: String, detail: String)? {
        guard !outcome.failed.isEmpty || !outcome.skipped.isEmpty else { return nil }
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count.formatted()) files" }
        func list(_ entries: [Entry]) -> String {
            let limit = 8
            var lines = entries.prefix(limit).map { "\($0.source.lastPathComponent): \($0.detail)" }
            if entries.count > limit { lines.append("…and \((entries.count - limit).formatted()) more.") }
            return lines.joined(separator: "\n")
        }
        let written = outcome.written.count
        let title = !outcome.failed.isEmpty
            ? "\(files(outcome.failed.count).capitalizedFirst) couldn’t be converted."
            : "\(files(outcome.skipped.count).capitalizedFirst) \(outcome.skipped.count == 1 ? "was" : "were") skipped."
        var parts: [String] = []
        parts.append(written == 0 ? "No files were converted." : "\(files(written).capitalizedFirst) converted.")
        if !outcome.failed.isEmpty { parts.append(list(outcome.failed)) }
        if !outcome.skipped.isEmpty {
            parts.append((outcome.failed.isEmpty ? "" : "Skipped:\n") + list(outcome.skipped))
        }
        return (title, parts.joined(separator: "\n\n"))
    }
}

/// How far a batch has got, for the progress sheet.
@MainActor @Observable final class BatchProgress {
    let total: Int
    private(set) var done = 0
    var currentName = ""
    private(set) var isCancelled = false
    private(set) var isFinished = false

    init(total: Int) {
        self.total = total
    }

    func advance() { done = min(done + 1, total) }
    func cancel() { isCancelled = true }
    func finish() { isFinished = true }
}

/// One at a time, for async work on the main actor: a camera RAW render
/// waits here for the one before it.
@MainActor final class AsyncSlot {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The sheet while a batch converts: what, how far, the file in hand, Cancel.
@MainActor final class BatchProgressSheet {
    let window: NSWindow

    init(title: String, progress: BatchProgress) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BatchProgressView(title: title, progress: progress))
        window.contentView = host
        window.setContentSize(host.fittingSize)
    }
}

struct BatchProgressView: View {
    let title: String
    let progress: BatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
            HStack(alignment: .firstTextBaseline) {
                Text(progress.isCancelled ? "Stopping…" : detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.isCancelled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var detail: String {
        let count = "\(min(progress.done + 1, progress.total).formatted()) of \(progress.total.formatted())"
        return progress.currentName.isEmpty ? count : "\(count): \(progress.currentName)"
    }
}
