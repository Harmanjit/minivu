import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MinivuCore

@Suite struct ExportSafeFileWriterTests {
    struct Boom: Error {}

    func xattr(_ url: URL, _ name: String) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    func tags(_ url: URL) throws -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    @Test func writesANewFileWithoutLeftovers() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("new.bin")
        try SafeFileWriter.write(Data([1, 2, 3]), to: url)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["new.bin"])
    }

    @Test func replacingKeepsCreationDateTagsAttributesAndPermissions() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("photo.jpg")
        try Data("old contents".utf8).write(to: url)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old, .posixPermissions: 0o600], ofItemAtPath: url.path)
        // URLResourceValues.tagNames is read-only before macOS 26; NSURL's setter works everywhere.
        try (url as NSURL).setResourceValue(["Red", "Holiday"], forKey: .tagNamesKey)
        #expect("custom".withCString { setxattr(url.path, "org.minivu.test", $0, 6, 0, 0) } == 0)

        var temporary: URL?
        try SafeFileWriter.replace(url) { temp in
            temporary = temp
            #expect(temp.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL)
            #expect(temp.lastPathComponent.hasPrefix("."))
            try Data("new contents".utf8).write(to: temp)
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "new contents")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.creationDate] as? Date == old)
        #expect((attributes[.modificationDate] as? Date ?? old).timeIntervalSinceNow > -60)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(Set(try tags(url)) == ["Red", "Holiday"])
        #expect(xattr(url, "org.minivu.test") == "custom")
        #expect(!FileManager.default.fileExists(atPath: temporary!.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["photo.jpg"])
    }

    @Test func aFailedWriteLeavesTheOriginalAndNoTemporaryFile() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: url)

        #expect(throws: Boom.self) {
            try SafeFileWriter.replace(url) { temp in
                try Data("half written".utf8).write(to: temp)
                throw Boom()
            }
        }
        // A writer that never creates its file fails too, rather than deleting the original.
        #expect(throws: (any Error).self) {
            try SafeFileWriter.replace(url) { _ in }
        }
        // And a file that can't be moved into place: the folder is gone.
        let missing = t.url.appendingPathComponent("gone/photo.jpg")
        #expect(throws: (any Error).self) {
            try SafeFileWriter.write(Data("x".utf8), to: missing)
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["photo.jpg"])
    }

    @Test func aSymbolicLinkIsWrittenThrough() throws {
        let t = try TemporaryFolder()
        let target = t.url.appendingPathComponent("target.jpg")
        try Data("old".utf8).write(to: target)
        let link = t.url.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try SafeFileWriter.write(Data("new".utf8), to: link)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).sorted() == ["link.jpg", "target.jpg"])
    }

    /// `replaceItemAt` happily swaps a file in for a folder and deletes the
    /// folder with its contents (measured), so a folder must be refused.
    @Test func aFolderIsNeverReplaced() throws {
        let t = try TemporaryFolder()
        let folder = t.url.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: folder.appendingPathComponent("inside.txt"))

        #expect(throws: CocoaError.self) { try SafeFileWriter.write(Data("x".utf8), to: folder) }
        #expect(try String(contentsOf: folder.appendingPathComponent("inside.txt"), encoding: .utf8) == "precious")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path) == ["photo.jpg"])
    }

    @Test func veryLongNamesStillGetATemporaryFile() throws {
        let t = try TemporaryFolder()
        // 251 bytes: a legal name, but not with ".minivu-XXXXXXXX.tmp" added.
        // (Three-byte characters, so shortening must not cut one in half.)
        let url = t.url.appendingPathComponent(String(repeating: "日", count: 70) + String(repeating: "a", count: 37) + ".jpg")
        #expect(url.lastPathComponent.utf8.count == 251)
        try Data("old".utf8).write(to: url)
        try SafeFileWriter.write(Data("new".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        #expect(SafeFileWriter.temporaryURL(for: url).lastPathComponent.utf8.count <= 255)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).count == 1)
    }
}
