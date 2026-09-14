import Foundation

/// Writes one converted file into place for Batch Convert, so that nothing
/// is ever half written and nothing is overwritten except by choice.
///
/// The encoded file is written in full to a hidden temporary sibling and
/// flushed to disk first (as `SafeFileWriter` does), then renamed to its
/// name with `RENAME_EXCL`, which fails rather than replace an item that
/// has appeared there since the batch was planned. So a cancelled, failed
/// or crashed conversion leaves no partial output under a real name, and
/// the rename is atomic within the volume.
///
/// **Replace** writes the new file first, then moves the existing one to the
/// Trash, then renames the new one into its place. If that last step fails
/// the old file comes back from the Trash. At no point is the old file
/// deleted, and it is only ever in the Trash while the new one is whole.
public enum BatchFileWriter {
    public enum ExistingFilePolicy: String, Codable, CaseIterable, Sendable {
        /// Leave the existing file alone and don't write this one.
        case skip
        /// Write under the next free numbered name ("photo 2.jpg").
        case keepBoth
        /// Put the existing file in the Trash and write in its place.
        case replace

        public var title: String {
            switch self {
            case .skip: "Skip"
            case .keepBoth: "Keep Both"
            case .replace: "Replace (Move Old to Trash)"
            }
        }
    }

    public enum Result: Equatable, Sendable {
        /// Written at `url`; `trashed` is where a replaced file went.
        case written(URL, trashed: URL?)
        /// Not written, because the name was taken and the policy is Skip.
        case skipped
    }

    /// Moves an item to the Trash and says where it went. Tests pass a
    /// folder of their own so the user's Trash is never touched.
    ///
    /// Only the file moves: the writer itself decides where its marks go
    /// (a trasher that moved them too would have them moved twice, and the
    /// second move, finding the new file under the old name, deletes them).
    public typealias Trasher = @Sendable (URL) throws -> URL

    public static let systemTrash: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// Writes `data` as `url`. When something is already there (planned, or
    /// appeared meanwhile), `policy` decides; `isTaken` names other outputs
    /// of the batch that Keep Both must not pick. A folder is never replaced.
    ///
    /// - Parameter original: the source this output was converted from, when
    ///   the user confirmed replacing it. The new file then keeps the
    ///   original's stars, tag and Custom Order place, as Save does: it is
    ///   the same photo under the same name. Any other replaced file takes
    ///   its marks to the Trash, as Copy's Replace does.
    public static func commit(_ data: Data, to url: URL, policy: ExistingFilePolicy,
                              catalog: Catalog = .shared, trash: Trasher = systemTrash, original: URL? = nil,
                              isTaken: (String) -> Bool = { _ in false }) throws -> Result {
        let folder = url.deletingLastPathComponent()
        let temporary = try writeTemporary(data, beside: url)
        var target = url
        do {
            while true {
                do {
                    try FileOperations.moveExclusively(temporary, to: target)
                    return .written(target, trashed: nil)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    switch policy {
                    case .skip:
                        try? FileManager.default.removeItem(at: temporary)
                        return .skipped
                    case .keepBoth:
                        // Another app may take the numbered name too; the loop
                        // then picks the next one.
                        target = folder.appendingPathComponent(
                            BatchNameKey.uniqueName(for: url.lastPathComponent, in: folder, isTaken: isTaken))
                    case .replace:
                        let trashed = try replace(target, with: temporary, catalog: catalog, trash: trash,
                                                  original: original)
                        return .written(target, trashed: trashed)
                    }
                }
            }
        } catch {
            if FileOperations.itemExists(temporary) { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }

    /// The Trash step of Replace: the old item out, the new one in, the old
    /// one back if the new one can't go in.
    private static func replace(_ url: URL, with temporary: URL, catalog: Catalog, trash: Trasher,
                                original: URL?) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A folder named “\(url.lastPathComponent)” is in the way.",
                NSFilePathErrorKey: url.path,
            ])
        }
        let trashed = try trash(url)
        do {
            try FileOperations.moveExclusively(temporary, to: url)
        } catch {
            if (try? FileOperations.moveExclusively(trashed, to: url)) == nil {
                // Still safe in the Trash; say where.
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” couldn’t be replaced, and the old file is in the Trash.",
                    NSUnderlyingErrorKey: error,
                ])
            }
            throw error
        }
        if let original {
            // Marks are kept by path, so under the same name they stay put;
            // a name that changed only in letter case takes them along.
            if original.standardizedFileURL.path != url.standardizedFileURL.path {
                catalog.fileMoved(from: original, to: url)
            }
        } else {
            // The marks go with the old file, as they do when Copy replaces one.
            catalog.fileMoved(from: url, to: trashed)
        }
        return trashed
    }

    /// The complete file under a hidden name in the destination's folder,
    /// flushed to disk.
    static func writeTemporary(_ data: Data, beside url: URL) throws -> URL {
        let temporary = SafeFileWriter.temporaryURL(for: url)
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try SafeFileWriter.synchronize(temporary)
        } catch {
            if FileOperations.itemExists(temporary) { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
        return temporary
    }
}
