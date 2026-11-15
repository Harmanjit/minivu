import AppKit
import Observation
import MinivuCore

/// One of Edit Metadata's text fields (title, caption, creator, copyright)
/// across the files being edited.
struct MetadataTextField: Equatable {
    /// The value every file shares, or nil when they differ ("mixed").
    let original: String?
    var text: String
    /// A mixed field the user chose to clear in every file.
    var isCleared = false

    init(values: [String]) {
        let first = values.first ?? ""
        original = values.allSatisfy { $0 == first } ? first : nil
        text = original ?? ""
    }

    var isMixed: Bool { original == nil }

    /// Only a field the user changed is written. A mixed field is changed
    /// by typing a value for all, or by Clear; left empty it keeps each
    /// file's own value.
    var change: String? {
        if isCleared { return "" }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original else { return typed.isEmpty ? nil : typed }
        return typed == original ? nil : typed
    }
}

/// A keyword some or all of the files have, and what the user did with it.
struct MetadataKeyword: Identifiable, Equatable {
    var name: String
    /// How many of the files have it.
    var count: Int
    var isRemoved = false
    /// A keyword only some files had, now to be added to the rest.
    var isAddedToAll = false
    var id: String { name }
}

/// What Edit Metadata shows and changes for one file or several. Fields
/// that differ between the files are mixed and keep each file's value
/// unless the user types one for all; keywords are added to and removed
/// from every file, keeping each file's others.
@MainActor @Observable final class MetadataEditorModel {
    enum DateMode: Hashable { case unchanged, shift, set }

    let urls: [URL]
    let fields: [MetadataFields]

    var title: MetadataTextField
    var caption: MetadataTextField
    var creator: MetadataTextField
    var copyright: MetadataTextField
    var keywords: [MetadataKeyword]
    /// Keywords typed in, for every file.
    var newKeywords: [String] = []
    var keywordEntry = ""

    var dateMode = DateMode.unchanged
    /// Later (true) or earlier.
    var shiftLater = true
    var shiftDays = 0
    var shiftHours = 0
    var shiftMinutes = 0
    var shiftSeconds = 0
    /// The wall clock to set, as an instant in GMT (`WallClock.date`), which
    /// is how the date picker shows it.
    var setDate: Date
    var removeLocation = false

    init(urls: [URL], fields: [MetadataFields]) {
        self.urls = urls
        self.fields = fields
        title = MetadataTextField(values: fields.map(\.title))
        caption = MetadataTextField(values: fields.map(\.caption))
        creator = MetadataTextField(values: fields.map(\.creator))
        copyright = MetadataTextField(values: fields.map(\.copyright))
        var counts: [String: Int] = [:]
        var order: [String] = []
        for file in fields {
            for keyword in Set(file.keywords) {
                if counts[keyword] == nil { order.append(keyword) }
                counts[keyword, default: 0] += 1
            }
        }
        keywords = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { MetadataKeyword(name: $0, count: counts[$0] ?? 0) }
        let dates = fields.compactMap(\.dateTaken)
        setDate = (dates.first ?? WallClock(date: Date(), in: .current)).date
    }

    var count: Int { urls.count }

    /// "photo.jpg", or "12 images".
    var subject: String {
        count == 1 ? urls[0].lastPathComponent : "\(count.formatted()) images"
    }

    /// The date every file was taken, when they agree.
    var commonDate: WallClock? {
        let dates = fields.map(\.dateTaken)
        guard let first = dates.first, dates.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var dateDescription: String {
        let dates = fields.map(\.dateTaken)
        if let date = commonDate { return WallClock.formatted(date) }
        if dates.allSatisfy({ $0 == nil }) { return "None" }
        return dates.contains(nil) ? "Mixed (some files have none)" : "Mixed"
    }

    var locatedCount: Int { fields.filter(\.hasLocation).count }

    /// How many files get a sidecar rather than a rewrite.
    var sidecarCount: Int { urls.filter { MetadataWriter.method(for: $0) == .sidecar }.count }

    var shiftSecondsTotal: Int {
        let magnitude = ((max(shiftDays, 0) * 24 + max(shiftHours, 0)) * 60 + max(shiftMinutes, 0)) * 60 + max(shiftSeconds, 0)
        return shiftLater ? magnitude : -magnitude
    }

    var dateChange: DateChange? {
        switch dateMode {
        case .unchanged: nil
        case .shift: shiftSecondsTotal == 0 ? nil : .shift(seconds: shiftSecondsTotal)
        case .set: .set(WallClock(date: setDate))
        }
    }

    /// For one file, or files that share a date: what a shift or set makes of it.
    var newDateDescription: String? {
        guard let change = dateChange else { return nil }
        if case .shift = change, commonDate == nil { return nil }
        return change.applied(to: commonDate).map(WallClock.formatted)
    }

    // MARK: Keywords

    /// Adds what is typed in the keyword field, split at commas, to every file.
    func commitKeywordEntry() {
        let typed = keywordEntry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        keywordEntry = ""
        for keyword in typed where !keyword.isEmpty {
            if let index = keywords.firstIndex(where: { $0.name.caseInsensitiveCompare(keyword) == .orderedSame }) {
                // Typing one the files have brings it back, or adds it to all.
                keywords[index].isRemoved = false
                if keywords[index].count < count { keywords[index].isAddedToAll = true }
            } else if !newKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                newKeywords.append(keyword)
            }
        }
    }

    func toggleRemoved(_ keyword: MetadataKeyword) {
        guard let index = keywords.firstIndex(of: keyword) else { return }
        keywords[index].isRemoved.toggle()
        if keywords[index].isRemoved { keywords[index].isAddedToAll = false }
    }

    func toggleAddedToAll(_ keyword: MetadataKeyword) {
        guard let index = keywords.firstIndex(of: keyword) else { return }
        keywords[index].isAddedToAll.toggle()
        if keywords[index].isAddedToAll { keywords[index].isRemoved = false }
    }

    func removeNewKeyword(_ keyword: String) {
        newKeywords.removeAll { $0 == keyword }
    }

    // MARK: The edit

    /// Only what the user changed.
    var edit: MetadataEdit {
        MetadataEdit(title: title.change, caption: caption.change, creator: creator.change, copyright: copyright.change,
                     addedKeywords: newKeywords + keywords.filter(\.isAddedToAll).map(\.name),
                     removedKeywords: keywords.filter(\.isRemoved).map(\.name),
                     date: dateChange, removeLocation: removeLocation && locatedCount > 0)
    }

    var hasChanges: Bool { !edit.isEmpty || !keywordEntry.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Edit Metadata for the browser's selection or the viewer's image: reads
/// the files, asks with the sheet, writes in the background through the
/// write queue with progress and Cancel, and reports what didn't work.
@MainActor enum MetadataEditor {
    /// Shows the sheet and calls back with the edit, or nil when cancelled.
    /// A hook so tests can answer without a sheet.
    static var askForEdit: (_ model: MetadataEditorModel, _ window: NSWindow,
                            _ answer: @escaping (MetadataEdit?) -> Void) -> Void = { model, window, answer in
        MetadataEditorSheet(model: model).begin(on: window, completion: answer)
    }

    /// Shows the summary alert; a hook so tests can read it instead.
    static var showSummary: (_ summary: (title: String, detail: String), _ isWarning: Bool, _ window: NSWindow) -> Void = {
        summary, isWarning, window in
        let alert = NSAlert()
        alert.alertStyle = isWarning ? .warning : .informational
        alert.messageText = summary.title
        alert.informativeText = summary.detail
        if window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// The batch under way, for tests to await.
    private(set) static var work: Task<Void, Never>?

    /// Edits `urls` (folders already left out). `completion` gets the
    /// outcome once written, or nil when nothing was written (cancelled
    /// before writing, or no file could take metadata).
    static func present(for urls: [URL], on window: NSWindow, completion: @escaping (MetadataBatch.Outcome?) -> Void) {
        let (writable, skipped) = MetadataBatch.partition(urls)
        guard !writable.isEmpty else {
            NSSound.beep()
            return completion(nil)
        }
        Task { [weak window] in
            let fields = await BlockingWork.run { writable.map { MetadataFields.read(from: $0) } }
            guard let window else { return completion(nil) }
            let model = MetadataEditorModel(urls: writable, fields: fields)
            askForEdit(model, window) { [weak window] edit in
                guard let edit, !edit.isEmpty, let window else { return completion(nil) }
                write(edit, to: writable, skipped: skipped, on: window, completion: completion)
            }
        }
    }

    /// Writes in line behind every other image write. More than one file
    /// shows Batch Convert's progress sheet, whose Cancel stops before the
    /// next file.
    static func write(_ edit: MetadataEdit, to urls: [URL], skipped: [URL], on window: NSWindow,
                      completion: @escaping (MetadataBatch.Outcome?) -> Void) {
        let progress = BatchProgress(total: urls.count)
        var sheet: BatchProgressSheet?
        if urls.count > 1, !BatchTools.hasSheet(on: window) {
            let title = "Updating the Metadata of \(urls.count.formatted()) Images"
            sheet = BatchProgressSheet(title: title, progress: progress)
            BatchTools.beginSheet(sheet!.window, on: window)
        }
        // Metadata only: no pixels change, so a save under way isn't superseded.
        let job = FileWriteQueue.shared.enqueue(touching: MetadataBatch.touchedFiles(urls)) {
            await MetadataBatch.run(edit, on: urls, skipped: skipped,
                                    isCancelled: { await MainActor.run { progress.isCancelled } },
                                    starting: { url in await MainActor.run { progress.currentName = url.lastPathComponent } },
                                    finished: { await MainActor.run { progress.advance() } })
        }
        work = Task { [weak window] in
            let outcome = (try? await job.value)?.value ?? MetadataBatch.Outcome()
            progress.finish()
            if let sheet, let window { BatchTools.endSheet(sheet.window, on: window) }
            for url in outcome.rewritten { SavePresenter.didWrite(url) }
            MetadataRevisions.shared.noteChange(outcome.updated)
            completion(outcome)
            if let summary = MetadataBatch.summary(for: outcome), let window {
                showSummary(summary, !outcome.failed.isEmpty, window)
            }
        }
    }
}

/// A count per file of metadata writes minivu has made, which the info
/// panel watches. An in-place write changes the file's date, which the
/// panel already follows; a sidecar write leaves the image as it was, so
/// without this its panel would go on showing the old values.
@MainActor @Observable final class MetadataRevisions {
    static let shared = MetadataRevisions()

    private var revisions: [String: Int] = [:]

    func revision(of url: URL?) -> Int {
        url.map { revisions[FileWriteQueue.key($0)] ?? 0 } ?? 0
    }

    func noteChange(_ urls: [URL]) {
        for url in urls { revisions[FileWriteQueue.key(url), default: 0] += 1 }
    }
}
