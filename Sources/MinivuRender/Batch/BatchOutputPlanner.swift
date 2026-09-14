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

    public var source: URL
    public var destination: URL
    public var action: Action

    public init(source: URL, destination: URL, action: Action) {
        self.source = source
        self.destination = destination
        self.action = action
    }

    public var replacesOriginal: Bool { action == .replace(original: true) }
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
    public static func plan(_ sources: [RenameSource], settings: BatchConvertSettings, folder: URL?,
                            probe: BatchFileProbe = .system) -> [BatchOutput] {
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
        for source in sources {
            sourceIdentity[source.url] = probe.identity(source.url)
            sourceKeys.insert(key(source.url.deletingLastPathComponent(), source.url.lastPathComponent))
        }

        var claimed: Set<String> = []
        var outputs: [BatchOutput] = []
        outputs.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            let outputFolder = folder ?? source.url.deletingLastPathComponent()
            let name = settings.outputName(for: source, index: index, namer: namer)
            var destination = outputFolder.appendingPathComponent(name)
            let ownKey = key(source.url.deletingLastPathComponent(), source.url.lastPathComponent)

            if let problem = BatchNameKey.problem(with: name) {
                outputs.append(BatchOutput(source: source.url, destination: destination, action: .fail(reason: problem)))
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
            if isTaken(name) {
                destination = numbered()
            } else if let existing = probe.identity(destination) {
                let isOwnSource = sourceIdentity[source.url].map { existing.isSameItem(as: $0) } ?? false
                if existing.isDirectory && settings.existingFiles == .replace {
                    action = .fail(reason: "A folder named “\(name)” is in the way.")
                } else {
                    switch settings.existingFiles {
                    case .skip:
                        action = .skip(reason: isOwnSource
                            ? "It would replace the original."
                            : "An item named “\(name)” already exists.")
                    case .keepBoth:
                        destination = numbered()
                    case .replace:
                        action = .replace(original: isOwnSource)
                    }
                }
            }
            claimed.insert(key(outputFolder, destination.lastPathComponent))
            outputs.append(BatchOutput(source: source.url, destination: destination, action: action))
        }
        return outputs
    }
}
