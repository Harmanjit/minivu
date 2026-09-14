import Foundation

/// Copying, moving, renaming and new folders for the browser.
///
/// Everything here is synchronous file-system work: call it off the main
/// thread. Marks follow the files (`Catalog.fileMoved`/`fileCopied`, which
/// also carry the rows of everything inside a folder), and every operation
/// returns what it did so the UI can offer Undo.
///
/// **Safety rules.** Nothing is ever deleted: a file replaced by `.replace`
/// goes to the Trash and comes back on undo. A folder is never replaced by a
/// file or a file by a folder, a folder never goes into itself, and nothing
/// goes to a volume `VolumePolicy` refuses. Moves on one volume are atomic
/// renames that refuse to overwrite (`RENAME_EXCL`), so a file that appears
/// at the destination between the check and the move is not clobbered.
///
/// **Progress** counts the items passed in, not the files inside a folder:
/// on APFS a copy is a clone and a move is a rename, so each item takes
/// about as long as a file would, and per-file progress inside folders
/// would mean reimplementing `copyfile`'s metadata handling.
public enum FileOperations {
    /// What to do when the destination already has an item of that name.
    public enum ConflictPolicy: Sendable, Equatable {
        case skip, replace, keepBoth
    }

    public struct Transfer: Sendable, Equatable {
        public var from: URL
        public var to: URL
        /// Where `.replace` put the item that was at `to` before (in the
        /// Trash), so undo can bring it back.
        public var replaced: URL?
        public init(from: URL, to: URL, replaced: URL? = nil) {
            self.from = from
            self.to = to
            self.replaced = replaced
        }
    }

    public struct Result: Sendable {
        public var completed: [Transfer] = []
        public var skipped: [URL] = []
        public var failed: [(url: URL, message: String)] = []
        public var wasCancelled = false
        public init() {}
    }

    /// The outside world, replaceable in tests so they neither fill the
    /// user's Trash nor need an external disk to test the volume rule.
    struct Environment: Sendable {
        /// Moves an item to the Trash and returns where it went.
        var trash: @Sendable (URL) throws -> URL
        var isAllowedVolume: @Sendable (URL) -> Bool

        static let system = Environment(
            trash: { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return (resulting as URL?) ?? url
            },
            isAllowedVolume: VolumePolicy.isAllowed)
    }

    // MARK: - Copy and move

    /// Copies `urls` into `folder`, keeping Finder tags, dates and extended
    /// attributes (`copyItem` is `copyfile` with everything, a clone on
    /// APFS). A copy into the item's own folder is always a duplicate
    /// ("photo 2.jpg"), whatever the policy. `progress(done, total)` is
    /// called on the calling thread after each item.
    public static func copy(_ urls: [URL], to folder: URL, conflict: ConflictPolicy, catalog: Catalog = .shared,
                            progress: ((Int, Int) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> Result {
        transfer(urls, to: folder, conflict: conflict, move: false, catalog: catalog, environment: .system,
                 progress: progress, isCancelled: isCancelled)
    }

    /// Moves `urls` into `folder` (a rename on the same volume). Items
    /// already in `folder` are skipped.
    public static func move(_ urls: [URL], to folder: URL, conflict: ConflictPolicy, catalog: Catalog = .shared,
                            progress: ((Int, Int) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> Result {
        transfer(urls, to: folder, conflict: conflict, move: true, catalog: catalog, environment: .system,
                 progress: progress, isCancelled: isCancelled)
    }

    /// Undoes a move: each item goes back to where it was, newest first, and
    /// anything a `.replace` sent to the Trash returns to its place. An item
    /// whose old place has been taken since fails rather than overwrite.
    public static func undoMove(_ result: Result, catalog: Catalog = .shared,
                                progress: ((Int, Int) -> Void)? = nil,
                                isCancelled: () -> Bool = { false }) -> Result {
        var undo = Result()
        catalog.pauseHealing()
        defer { catalog.resumeHealing() }
        let transfers = Array(result.completed.reversed())
        for (i, transfer) in transfers.enumerated() {
            if isCancelled() { undo.wasCancelled = true; break }
            defer { progress?(i + 1, transfers.count) }
            do {
                try moveExclusively(transfer.to, to: transfer.from)
                catalog.fileMoved(from: transfer.to, to: transfer.from)
                undo.completed.append(Transfer(from: transfer.to, to: transfer.from))
            } catch {
                undo.failed.append((transfer.to, error.localizedDescription))
                continue
            }
            restoreReplaced(transfer, into: &undo, catalog: catalog)
        }
        return undo
    }

    /// Undoes a copy by moving the copies to the Trash (an undo shouldn't be
    /// the one step that can't be undone), newest first, and bringing back
    /// anything a `.replace` displaced.
    public static func undoCopy(_ result: Result, catalog: Catalog = .shared) -> Result {
        undoCopy(result, catalog: catalog, environment: .system)
    }

    static func undoCopy(_ result: Result, catalog: Catalog, environment: Environment) -> Result {
        var undo = Result()
        for transfer in result.completed.reversed() {
            do {
                guard itemExists(transfer.to) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: transfer.to.path]) }
                let trashed = try environment.trash(transfer.to)
                catalog.fileRemoved(transfer.to)
                undo.completed.append(Transfer(from: transfer.to, to: trashed))
            } catch {
                undo.failed.append((transfer.to, error.localizedDescription))
                continue
            }
            restoreReplaced(transfer, into: &undo, catalog: catalog)
        }
        return undo
    }

    private static func restoreReplaced(_ transfer: Transfer, into undo: inout Result, catalog: Catalog) {
        guard let replaced = transfer.replaced else { return }
        do {
            try moveExclusively(replaced, to: transfer.to)
            catalog.fileMoved(from: replaced, to: transfer.to)
            undo.completed.append(Transfer(from: replaced, to: transfer.to))
        } catch {
            undo.failed.append((replaced, error.localizedDescription))
        }
    }

    static func transfer(_ urls: [URL], to folder: URL, conflict: ConflictPolicy, move: Bool,
                         catalog: Catalog, environment: Environment,
                         progress: ((Int, Int) -> Void)?, isCancelled: () -> Bool) -> Result {
        var result = Result()
        let total = urls.count
        catalog.pauseHealing()
        defer { catalog.resumeHealing() }

        // The destination is checked once for the whole batch.
        let folderInfo = info(folder.path, followingLinks: true)
        let folderProblem: String? =
            if folderInfo?.isDirectory != true { "The destination folder can’t be found." }
            else if !environment.isAllowedVolume(folder) { "minivu works only with folders on this Mac’s internal storage." }
            else { nil }
        if let folderProblem {
            result.failed = urls.map { ($0, folderProblem) }
            if total > 0 { progress?(total, total) }
            return result
        }
        // The destination and every folder above it, by identity, so "into
        // itself" is caught through symlinks and differences of case.
        let destinationChain = ancestorChain(of: folder)

        for (i, url) in urls.enumerated() {
            if isCancelled() { result.wasCancelled = true; break }
            defer { progress?(i + 1, total) }
            let name = url.lastPathComponent
            guard let source = info(url.path, followingLinks: false) else {
                result.failed.append((url, "“\(name)” can’t be found."))
                continue
            }
            if source.isDirectory && destinationChain.contains(source.identity) {
                result.failed.append((url, "“\(name)” can’t be \(move ? "moved" : "copied") into itself."))
                continue
            }
            let parent = info(url.deletingLastPathComponent().path, followingLinks: true)
            let sameFolder = parent?.identity == folderInfo?.identity
            if sameFolder && move {
                result.skipped.append(url)
                continue
            }

            var destination = folder.appendingPathComponent(name, isDirectory: source.isDirectory)
            var replaced: URL?
            if sameFolder {
                destination = folder.appendingPathComponent(uniqueName(for: name, in: folder, isDirectory: source.isDirectory))
            } else if let existing = info(destination.path, followingLinks: false) {
                switch conflict {
                case .skip:
                    result.skipped.append(url)
                    continue
                case .keepBoth:
                    destination = folder.appendingPathComponent(uniqueName(for: name, in: folder, isDirectory: source.isDirectory))
                case .replace:
                    if existing.identity == source.identity {
                        result.skipped.append(url)       // the same item under another spelling
                        continue
                    }
                    if existing.isDirectory != source.isDirectory {
                        result.failed.append((url, existing.isDirectory
                            ? "The folder “\(name)” can’t be replaced by a file."
                            : "The file “\(name)” can’t be replaced by a folder."))
                        continue
                    }
                    if existing.isDirectory && ancestorChain(of: url.deletingLastPathComponent()).contains(existing.identity) {
                        result.failed.append((url, "“\(name)” can’t replace the folder it’s in."))
                        continue
                    }
                    do {
                        let trashed = try environment.trash(destination)
                        catalog.fileMoved(from: destination, to: trashed)
                        replaced = trashed
                    } catch {
                        result.failed.append((url, error.localizedDescription))
                        continue
                    }
                }
            }

            do {
                if move {
                    try moveExclusively(url, to: destination)
                    catalog.fileMoved(from: url, to: destination)
                } else {
                    try copyExclusively(url, to: destination)
                    catalog.fileCopied(from: url, to: destination)
                }
                result.completed.append(Transfer(from: url, to: destination, replaced: replaced))
            } catch {
                // Nothing of ours is left at `destination` (see
                // copyExclusively), so whatever was replaced goes back, unless
                // another app has put something there meanwhile.
                if let replaced, (try? moveExclusively(replaced, to: destination)) != nil {
                    catalog.fileMoved(from: replaced, to: destination)
                }
                result.failed.append((url, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: - Rename

    /// Renames in place and returns the new URL. Throws for invalid names or
    /// an existing item of that name. A rename that changes only letter case
    /// (or Unicode normalisation) works on case-insensitive volumes.
    public static func rename(_ url: URL, to newName: String, catalog: Catalog = .shared) throws -> URL {
        catalog.pauseHealing()
        defer { catalog.resumeHealing() }
        return try rename(url, to: newName) { catalog.fileMoved(from: $0, to: $1) }
    }

    /// `rename`, reporting the move to `moved` instead of the catalog, so a
    /// batch can move the marks of all its files in one transaction.
    static func rename(_ url: URL, to newName: String, moved: (URL, URL) -> Void) throws -> URL {
        if let problem = validateName(newName, in: url.deletingLastPathComponent(), excluding: url) {
            throw CocoaError(.fileWriteInvalidFileName,
                             userInfo: [NSLocalizedDescriptionKey: problem, NSFilePathErrorKey: url.path])
        }
        return try performRename(url, to: newName, moved: moved)
    }

    /// Undoes `rename`: `renamed` (what it returned) takes `original`'s name
    /// again. The old name isn't re-validated, only checked to be free.
    public static func undoRename(_ renamed: URL, to original: URL, catalog: Catalog = .shared) throws -> URL {
        catalog.pauseHealing()
        defer { catalog.resumeHealing() }
        return try undoRename(renamed, to: original) { catalog.fileMoved(from: $0, to: $1) }
    }

    static func undoRename(_ renamed: URL, to original: URL, moved: (URL, URL) -> Void) throws -> URL {
        let name = original.lastPathComponent
        let destination = renamed.deletingLastPathComponent().appendingPathComponent(name)
        if let existing = info(destination.path, followingLinks: false),
           existing.identity != info(renamed.path, followingLinks: false)?.identity {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return try performRename(renamed, to: name, moved: moved)
    }

    private static func performRename(_ url: URL, to newName: String, moved: (URL, URL) -> Void) throws -> URL {
        guard newName != url.lastPathComponent else { return url }
        let folder = url.deletingLastPathComponent()
        let destination = folder.appendingPathComponent(newName)
        do {
            try moveExclusively(url, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // The destination "exists" because it is this item under another
            // case: go through a temporary name where the volume insists.
            let temporary = folder.appendingPathComponent(".minivu-rename-\(UUID().uuidString)")
            try moveExclusively(url, to: temporary)
            do {
                try moveExclusively(temporary, to: destination)
            } catch {
                try? moveExclusively(temporary, to: url)
                throw error
            }
        }
        moved(url, destination)
        return destination
    }

    /// A user-facing reason the name can't be used, or nil when it can.
    /// `excluding` is the item being renamed: its own name (in any case) is
    /// not a conflict.
    public static func validateName(_ name: String, in folder: URL, excluding: URL?) -> String? {
        if let problem = nameProblem(name) { return problem }
        let destination = folder.appendingPathComponent(name)
        guard let existing = info(destination.path, followingLinks: false) else { return nil }
        if let excluding, info(excluding.path, followingLinks: false)?.identity == existing.identity { return nil }
        return "The name “\(name)” is already taken. Please choose a different name."
    }

    /// The rules for a name in itself, whatever folder it goes in.
    static func nameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The name can’t be empty." }
        if name.contains("/") || name.contains(":") { return "The name can’t contain “/” or “:”." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "The name can’t contain control characters."
        }
        if name.hasPrefix(".") { return "Names that begin with a dot “.” are reserved for the system." }
        // APFS allows 255 bytes of UTF-8 in a name.
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }

    // MARK: - New folders and unique names

    /// Creates "untitled folder" (or "untitled folder 2"…) in `folder`.
    public static func createFolder(in folder: URL, name: String = "untitled folder") throws -> URL {
        if let problem = nameProblem(name) {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        // Another app can take the name between choosing it and creating it;
        // try the next free one rather than fail.
        for _ in 0..<20 {
            let url = folder.appendingPathComponent(uniqueName(for: name, in: folder, isDirectory: true), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.appendingPathComponent(name).path])
    }

    /// "photo.jpg" -> "photo 2.jpg", "photo 3.jpg"… the first that is free.
    /// A name that already ends in a counter continues it ("photo 2.jpg" ->
    /// "photo 3.jpg"). Only 1–3 digits without a leading zero count as a
    /// counter, so "IMG 0042.jpg" and "Trip 2024" keep their numbers and
    /// become "IMG 0042 2.jpg" and "Trip 2024 2". Folder names are never
    /// split at a dot ("2024.06 Trip 2").
    public static func uniqueName(for name: String, in folder: URL, isDirectory: Bool = false) -> String {
        guard itemExists(folder.appendingPathComponent(name)) else { return name }
        var base = name, ext = ""
        if !isDirectory {
            let e = (name as NSString).pathExtension
            let b = (name as NSString).deletingPathExtension
            if !e.isEmpty && !b.isEmpty { base = b; ext = e }
        }
        var n = 2
        if let (stem, counter) = trailingCounter(base) { base = stem; n = counter + 1 }
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !itemExists(folder.appendingPathComponent(candidate)) { return candidate }
            n += 1
        }
    }

    /// "photo 2" -> ("photo", 2); nil when there's no counter.
    static func trailingCounter(_ base: String) -> (String, Int)? {
        guard let space = base.lastIndex(of: " ") else { return nil }
        let digits = base[base.index(after: space)...]
        let stem = base[..<space]
        guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.first != "0", let value = Int(digits), value >= 2,
              !stem.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (String(stem), value)
    }

    // MARK: - File system helpers

    struct ItemInfo {
        struct Identity: Hashable { var device: Int32; var inode: UInt64 }
        var identity: Identity
        var isDirectory: Bool
    }

    static func info(_ path: String, followingLinks: Bool) -> ItemInfo? {
        var st = stat()
        let code = followingLinks ? stat(path, &st) : lstat(path, &st)
        guard code == 0 else { return nil }
        return ItemInfo(identity: .init(device: st.st_dev, inode: st.st_ino), isDirectory: (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// lstat, so a broken symlink counts as taking its name.
    static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// The identities of `folder` and every folder above it.
    static func ancestorChain(of folder: URL) -> Set<ItemInfo.Identity> {
        var chain = Set<ItemInfo.Identity>()
        var path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        while true {
            if let identity = info(path, followingLinks: true)?.identity { chain.insert(identity) }
            guard path != "/", !path.isEmpty else { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return chain
    }

    /// Copies to a hidden temporary name beside `destination`, then renames
    /// the copy into place without overwriting. A copy that fails partway, or
    /// finds the name taken by another app since it was checked, leaves only
    /// its own temporary item to remove: cleaning up after a direct copy
    /// could delete a file someone else had just put at `destination`. The
    /// browser also never lists a half-copied file under its real name.
    static func copyExclusively(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".minivu-copy-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try moveExclusively(temporary, to: destination)
        } catch {
            if itemExists(temporary) { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }

    /// A rename that refuses to overwrite. Across volumes, where rename(2)
    /// can't go, the item is copied and then the original deleted.
    public static func moveExclusively(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == EXDEV {
            try moveByCopying(source, to: destination)
            return
        }
        throw cocoaError(errno: code, source: source, destination: destination)
    }

    /// A move to another volume: a complete copy under a hidden name, renamed
    /// into place without overwriting, and only then the original deleted.
    /// (`FileManager.moveItem` copies straight to the destination, so a copy
    /// cut short by a full disk or a quit left a partial item under the real
    /// name.) If the original can't be deleted afterwards (a locked file, a
    /// folder partly removed), the copy stays: it is whole, and deleting it
    /// could lose what is already gone from the original.
    static func moveByCopying(_ source: URL, to destination: URL) throws {
        try copyExclusively(source, to: destination)
        try? FileManager.default.removeItem(at: source)
    }

    /// POSIX failures as Cocoa errors, whose descriptions read as sentences.
    static func cocoaError(errno code: Int32, source: URL, destination: URL) -> Error {
        let underlying = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        switch code {
        case EEXIST, ENOTEMPTY:
            return CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case ENOENT:
            return CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path, NSUnderlyingErrorKey: underlying])
        case EACCES, EPERM:
            return CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case ENOSPC:
            return CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case EROFS:
            return CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        default:
            return CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: source.path, NSUnderlyingErrorKey: underlying])
        }
    }
}
