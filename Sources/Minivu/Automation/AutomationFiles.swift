import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The files a shortcut passed to one of minivu's intents, made readable for
/// as long as the intent runs.
///
/// A file from Finder arrives as a URL with its own sandbox permission (a
/// security-scoped URL): minivu may read that file, and nothing else in its
/// folder. Its access is started here and stopped by `finish()`. A file from
/// another app may arrive as data only, with no place on disk; Convert and
/// Resize can still read it, from a copy in a folder of minivu's own that
/// `finish()` removes, but a rename or a rating is about the file itself
/// and refuses it.
@MainActor final class AutomationInput {
    let urls: [URL]
    private var accessed: [URL]
    private let copies: URL?

    /// - Parameter originalsOnly: the intent changes or marks the files
    ///   themselves, so each must be a file on disk.
    init(_ files: [IntentFile], originalsOnly: Bool) throws {
        var urls: [URL] = []
        var accessed: [URL] = []
        var copies: URL?
        do {
            for file in files {
                if let url = file.fileURL {
                    if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                    urls.append(url)
                    continue
                }
                guard !originalsOnly else { throw Automation.Failure.notAFileOnDisk(file.filename) }
                let folder = try copies ?? Automation.makeRunFolder()
                copies = folder
                urls.append(try Self.copy(file, into: folder))
            }
        } catch {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
            if let copies { try? FileManager.default.removeItem(at: copies) }
            throw error
        }
        guard !urls.isEmpty else { throw Automation.Failure.noImages }
        self.urls = urls
        self.accessed = accessed
        self.copies = copies
    }

    /// Writes a file that came as data under its own name (numbered when two
    /// share one), so the converted file is named after it too.
    private static func copy(_ file: IntentFile, into folder: URL) throws -> URL {
        let given = (file.filename as NSString).lastPathComponent
        var name = given.isEmpty || given.hasPrefix(".") ? "Image" : given
        if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension {
            name += "." + ext
        }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        try file.data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Ends access to the shortcut's files and removes any copies. Files the
    /// intent hands on (`keepingAccess`) keep their permission: Open in
    /// minivu shows them for the rest of the session, as a file opened from
    /// Finder stays readable.
    func finish(keepingAccess: Bool = false) {
        if !keepingAccess {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
        }
        accessed = []
        if let copies { try? FileManager.default.removeItem(at: copies) }
    }

    /// Runs `work` on the files, then finishes, whether it threw or not.
    func use<T>(keepingAccess: Bool = false, _ work: ([URL]) async throws -> T) async rethrows -> T {
        defer { finish(keepingAccess: keepingAccess) }
        return try await work(urls)
    }

    /// Converted files for the shortcut to take on. Shortcuts removes each
    /// one from minivu's folder once it is done with it.
    static func output(_ urls: [URL]) -> [IntentFile] {
        urls.map { url in
            var file = IntentFile(fileURL: url, filename: url.lastPathComponent,
                                  type: UTType(filenameExtension: url.pathExtension))
            file.removedOnCompletion = true
            return file
        }
    }

    /// Files changed in place (renamed, rated), handed on as they now are.
    static func files(_ urls: [URL]) -> [IntentFile] {
        urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
    }
}
