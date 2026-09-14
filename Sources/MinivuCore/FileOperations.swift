import Foundation

/// Copying, moving, renaming and new folders for the browser.
///
/// PLACEHOLDER: a plain implementation that defines the API. The catalog
/// work package hardens it (conflict handling, progress, cancellation,
/// catalog updates, undo information) keeping these signatures.
public enum FileOperations {
    /// What to do when the destination already has a file of that name.
    public enum ConflictPolicy: Sendable, Equatable {
        case skip, replace, keepBoth
    }

    public struct Transfer: Sendable, Equatable {
        public var from: URL
        public var to: URL
        public init(from: URL, to: URL) { self.from = from; self.to = to }
    }

    public struct Result: Sendable {
        public var completed: [Transfer] = []
        public var skipped: [URL] = []
        public var failed: [(url: URL, message: String)] = []
        public var wasCancelled = false
        public init() {}
    }

    /// Copies `urls` into `folder`. Synchronous: call off the main thread.
    /// `progress(done, total)` is called on the calling thread.
    public static func copy(_ urls: [URL], to folder: URL, conflict: ConflictPolicy,
                            progress: ((Int, Int) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> Result {
        transfer(urls, to: folder, conflict: conflict, move: false, progress: progress, isCancelled: isCancelled)
    }

    /// Moves `urls` into `folder` (a rename on the same volume).
    public static func move(_ urls: [URL], to folder: URL, conflict: ConflictPolicy,
                            progress: ((Int, Int) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> Result {
        transfer(urls, to: folder, conflict: conflict, move: true, progress: progress, isCancelled: isCancelled)
    }

    /// Renames in place and returns the new URL. Throws for invalid names or
    /// an existing file of that name.
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        if let problem = validateName(newName, in: url.deletingLastPathComponent(), excluding: url) {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: destination)
        Catalog.shared.fileMoved(from: url, to: destination)
        return destination
    }

    /// A user-facing reason the name can't be used, or nil when it can.
    public static func validateName(_ name: String, in folder: URL, excluding: URL?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The name can’t be empty." }
        if name.contains("/") || name.contains(":") { return "The name can’t contain “/” or “:”." }
        if name.hasPrefix(".") { return "Names starting with a dot are hidden." }
        if name.utf8.count > 255 { return "The name is too long." }
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path),
           excluding.map({ $0.standardizedFileURL.path.lowercased() != destination.standardizedFileURL.path.lowercased() }) ?? true {
            return "“\(name)” already exists."
        }
        return nil
    }

    public static func createFolder(in folder: URL, name: String = "untitled folder") throws -> URL {
        let url = folder.appendingPathComponent(uniqueName(for: name, in: folder), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// "photo.jpg" -> "photo 2.jpg", "photo 3.jpg"… the first that is free.
    public static func uniqueName(for name: String, in folder: URL) -> String {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    private static func transfer(_ urls: [URL], to folder: URL, conflict: ConflictPolicy, move: Bool,
                                 progress: ((Int, Int) -> Void)?, isCancelled: () -> Bool) -> Result {
        var result = Result()
        for (i, url) in urls.enumerated() {
            if isCancelled() { result.wasCancelled = true; break }
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    switch conflict {
                    case .skip: result.skipped.append(url); progress?(i + 1, urls.count); continue
                    case .replace: try FileManager.default.removeItem(at: destination)
                    case .keepBoth:
                        destination = folder.appendingPathComponent(uniqueName(for: url.lastPathComponent, in: folder))
                    }
                }
                if move {
                    try FileManager.default.moveItem(at: url, to: destination)
                    Catalog.shared.fileMoved(from: url, to: destination)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                    Catalog.shared.fileCopied(from: url, to: destination)
                }
                result.completed.append(Transfer(from: url, to: destination))
            } catch {
                result.failed.append((url, error.localizedDescription))
            }
            progress?(i + 1, urls.count)
        }
        return result
    }
}
