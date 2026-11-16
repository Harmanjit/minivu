import Foundation
import MinivuCore

/// Where each converted file goes and what happens there, decided for the
/// whole batch before anything is written.
public struct BatchOutput: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// A new file.
        case write
        /// An existing file of that name goes to the Trash. `original` when
        /// that file is the source itself (JPEG to JPEG beside the originals
        /// with the names kept), which needs the user's confirmation.
        case replace(original: Bool)
        /// Nothing is written.
        case skip(reason: String)
        case fail(reason: String)
    }

    /// Which pages of the source the output holds.
    public enum Pages: Hashable, Sendable {
        /// The file's first page or frame (every single-page file).
        case primary
        /// All `count` pages, in one multi-page file.
        case all(count: Int)
        /// Page `index` (from 0) of the source's `count`.
        case page(index: Int, of: Int)
    }

    public var source: URL
    public var destination: URL
    public var action: Action
    public var pages: Pages

    public init(source: URL, destination: URL, action: Action, pages: Pages = .primary) {
        self.source = source
        self.destination = destination
        self.action = action
        self.pages = pages
    }

    public var replacesOriginal: Bool { action == .replace(original: true) }
}

/// What a batch would send to the Trash, which the app names and confirms
/// before anything is written: sources replaced by their own conversions,
/// and existing files that aren't part of the batch at all (the camera's
/// JPEG beside a NEF converted to JPEG with the names kept). The Replace
/// policy was chosen for earlier exports; a file that only happens to have
/// an output's name is the user's to decide about.
public struct BatchReplacements: Equatable, Sendable {
    /// Sources that their own conversion replaces.
    public var originals: [URL]
    /// Existing files outside the batch, in batch order.
    public var others: [URL]

    public init(_ outputs: [BatchOutput]) {
        originals = outputs.filter(\.replacesOriginal).map(\.source)
        others = outputs.filter { $0.action == .replace(original: false) }.map(\.destination)
    }

    public var isEmpty: Bool { originals.isEmpty && others.isEmpty }
}

/// A file's identity without its kind, for looking items up by identity.
struct BatchFileIdentityKey: Hashable {
    var device: Int32
    var inode: UInt64

    init(_ identity: BatchItemIdentity) {
        device = identity.device
        inode = identity.inode
    }
}

public enum BatchOutputPlanner {
    /// The outputs of converting `sources` (in batch order) with `settings`
    /// into `folder` (nil: beside each original). Reads the file system but
    /// changes nothing; off the main thread for large batches.
    ///
    /// Name clashes are settled here, all of them:
    /// - Two outputs of the batch never share a name: a later one is
    ///   numbered ("photo 2.jpg"), whatever the policy, so Replace can't
    ///   make a batch overwrite its own work.
    /// - An output never lands on another source of the batch: that file is
    ///   numbered too, so no original is ever replaced by a different
    ///   picture, and none disappears before its turn to be read.
    /// - An existing file follows the policy: skipped, kept beside (numbered)
    ///   or replaced (to the Trash). Replacing the output's own source is
    ///   marked, for the app to confirm first.
    /// - A folder of that name is never replaced.
    /// - A page taken from a multi-page original (`BatchConvertSettings.pages`)
    ///   never replaces that original either: it is numbered like a clash
    ///   with another source.
    ///
    /// With every page, or separate pages, each source's page count is read
    /// from its header (`pageCount`); a multi-page source then has one
    /// output holding all its pages, or one output per page.
    public static func plan(_ sources: [RenameSource], settings: BatchConvertSettings, folder: URL?,
                            probe: BatchFileProbe = .system,
                            pageCount: (URL) -> Int = PageSequence.pageCount(of:)) -> [BatchOutput] {
        let namer = settings.pattern.map { RenameNamer(pattern: $0) }
        var caseSensitivity: [String: Bool] = [:]
        func key(_ folder: URL, _ name: String) -> String {
            let path = folder.standardizedFileURL.path
            let sensitive = caseSensitivity[path] ?? {
                let value = probe.isCaseSensitive(folder)
                caseSensitivity[path] = value
                return value
            }()
            return BatchNameKey.key(folder: folder, name: name, caseSensitive: sensitive)
        }

        var sourceIdentity: [URL: BatchItemIdentity] = [:]
        var sourceKeys: Set<String> = []
        // By file identity as well as by path: a chosen folder that is a
        // source folder under another spelling (a symbolic link) must not
        // let an output replace a source that hasn't been converted yet.
        var sourceItems: [BatchFileIdentityKey: URL] = [:]
        for source in sources {
            let identity = probe.identity(source.url)
            sourceIdentity[source.url] = identity
            if let identity { sourceItems[BatchFileIdentityKey(identity)] = source.url }
            sourceKeys.insert(key(source.url.deletingLastPathComponent(), source.url.lastPathComponent))
        }

        // What each output is made of: the source, the page it holds (for the
        // name), which pages, and a reason it is skipped before naming.
        var items: [(source: RenameSource, pages: BatchOutput.Pages, skip: String?)] = []
        items.reserveCapacity(sources.count)
        for source in sources {
            let count: Int
            switch settings.pages {
            case .first: count = 1
            case .all, .separate: count = max(pageCount(source.url), 1)
            }
            switch settings.pages {
            case .first:
                items.append((source, .primary, nil))
            case .all where count == 1:
                items.append((source, .primary, nil))
            case .all where BatchConvertSettings.holdsPages(settings.options.format):
                items.append((source, .all(count: count), nil))
            case .all:
                for page in 0..<count { items.append((source.page(page, of: count), .page(index: page, of: count), nil)) }
            case .separate(let range):
                let pages = range.indices(count: count)
                if count == 1 {
                    items.append((source, .primary, localized("It has only one page.")))
                } else if pages.isEmpty {
                    items.append((source, .primary, localized("It has only \(count) pages.")))
                } else {
                    for page in pages { items.append((source.page(page, of: count), .page(index: page, of: count), nil)) }
                }
            }
        }

        var claimed: Set<String> = []
        var outputs: [BatchOutput] = []
        outputs.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let source = item.source, pages = item.pages
            let outputFolder = folder ?? source.url.deletingLastPathComponent()
            let name = settings.outputName(for: source, index: index, namer: namer)
            var destination = outputFolder.appendingPathComponent(name)
            // A page never replaces the file it was taken from.
            let isPage = source.page != nil
            let ownKey = isPage ? nil : key(source.url.deletingLastPathComponent(), source.url.lastPathComponent)

            if let reason = item.skip {
                outputs.append(BatchOutput(source: source.url, destination: destination, action: .skip(reason: reason),
                                           pages: pages))
                continue
            }
            if let problem = BatchNameKey.problem(with: name) {
                outputs.append(BatchOutput(source: source.url, destination: destination, action: .fail(reason: problem),
                                           pages: pages))
                continue
            }
            // Names promised to earlier outputs, and every other source's name.
            func isTaken(_ candidate: String) -> Bool {
                let k = key(outputFolder, candidate)
                return claimed.contains(k) || (sourceKeys.contains(k) && k != ownKey)
            }
            func numbered() -> URL {
                outputFolder.appendingPathComponent(
                    BatchNameKey.uniqueName(for: name, in: outputFolder, probe: probe, isTaken: isTaken))
            }

            var action = BatchOutput.Action.write
            let takenInBatch = isTaken(name)
            let existing = takenInBatch ? nil : probe.identity(destination)
            let isOwnSource = !isPage
                && (existing.flatMap { item in sourceIdentity[source.url].map { item.isSameItem(as: $0) } } ?? false)
            let isOtherSource = existing.map { !isOwnSource && sourceItems[BatchFileIdentityKey($0)] != nil } ?? false
            if takenInBatch || isOtherSource {
                destination = numbered()
            } else if let existing {
                if existing.isDirectory && settings.existingFiles == .replace {
                    action = .fail(reason: localized("A folder named “\(name)” is in the way."))
                } else {
                    switch settings.existingFiles {
                    case .skip:
                        action = .skip(reason: isOwnSource
                            ? localized("It would replace the original.")
                            : localized("An item named “\(name)” already exists."))
                    case .keepBoth:
                        destination = numbered()
                    case .replace:
                        action = .replace(original: isOwnSource)
                    }
                }
            }
            claimed.insert(key(outputFolder, destination.lastPathComponent))
            outputs.append(BatchOutput(source: source.url, destination: destination, action: action, pages: pages))
        }
        return outputs
    }
}

private extension RenameSource {
    /// This source as page `index` (from 0) of `count`, for naming.
    func page(_ index: Int, of count: Int) -> RenameSource {
        var copy = self
        copy.page = index + 1
        copy.pageCount = count
        return copy
    }
}
