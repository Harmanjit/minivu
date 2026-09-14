import Testing
import Foundation
@testable import MinivuCore

/// Batch renames on disk, in an order that works (swaps, rings, chains,
/// letter case), undone exactly; and Batch Convert's writer, which never
/// leaves a partial file or loses an existing one.
@Suite struct BatchRenamerTests {
    func write(_ folder: TemporaryFolder, _ name: String, _ text: String) throws -> URL {
        let url = folder.url.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Names in the folder as the file system spells them, hidden ones too.
    func names(_ folder: TemporaryFolder) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    }

    func request(_ url: URL, _ name: String) -> BatchRenamer.Request {
        BatchRenamer.Request(url: url, newName: name)
    }

    @Test func swapsRingsAndChainsOnDisk() throws {
        let t = try TemporaryFolder()
        let a = try write(t, "a.jpg", "A"), b = try write(t, "b.jpg", "B")
        let one = try write(t, "1.jpg", "one"), two = try write(t, "2.jpg", "two"), three = try write(t, "3.jpg", "three")
        let catalog = Catalog.inMemory()
        catalog.setRating(4, for: [a])

        let outcome = BatchRenamer.perform([
            request(a, "b.jpg"), request(b, "a.jpg"),                              // a swap
            request(one, "2.jpg"), request(two, "3.jpg"), request(three, "4.jpg"),   // a chain in the awkward order
        ], catalog: catalog)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.renamed.map(\.to.lastPathComponent) == ["b.jpg", "a.jpg", "2.jpg", "3.jpg", "4.jpg"])
        #expect(text(t.url.appendingPathComponent("a.jpg")) == "B")
        #expect(text(t.url.appendingPathComponent("b.jpg")) == "A")
        #expect(text(t.url.appendingPathComponent("2.jpg")) == "one")
        #expect(text(t.url.appendingPathComponent("4.jpg")) == "three")
        #expect(try names(t) == ["2.jpg", "3.jpg", "4.jpg", "a.jpg", "b.jpg"], "no temporary name left behind")
        #expect(catalog.marks(for: t.url.appendingPathComponent("b.jpg")).rating == 4, "the stars followed the file")
        #expect(catalog.marks(for: t.url.appendingPathComponent("a.jpg")).rating == 0)

        // A ring of three.
        let ring = BatchRenamer.perform([
            request(t.url.appendingPathComponent("2.jpg"), "3.jpg"),
            request(t.url.appendingPathComponent("3.jpg"), "4.jpg"),
            request(t.url.appendingPathComponent("4.jpg"), "2.jpg"),
        ], catalog: catalog)
        #expect(ring.failed.isEmpty && ring.renamed.count == 3)
        #expect(text(t.url.appendingPathComponent("3.jpg")) == "one")
        #expect(text(t.url.appendingPathComponent("4.jpg")) == "two")
        #expect(text(t.url.appendingPathComponent("2.jpg")) == "three")
        #expect(try names(t) == ["2.jpg", "3.jpg", "4.jpg", "a.jpg", "b.jpg"])
    }

    @Test func caseOnlyRenamesAndUndo() throws {
        let t = try TemporaryFolder()
        let upper = try write(t, "IMG_1.JPG", "1"), other = try write(t, "IMG_2.JPG", "2")
        let catalog = Catalog.inMemory()
        let outcome = BatchRenamer.perform([request(upper, "img_1.jpg"), request(other, "Beach.jpg")], catalog: catalog)
        #expect(outcome.failed.isEmpty)
        #expect(try names(t) == ["Beach.jpg", "img_1.jpg"])

        let undo = BatchRenamer.perform(outcome.inverse, restoring: true, catalog: catalog)
        #expect(undo.failed.isEmpty)
        #expect(try names(t) == ["IMG_1.JPG", "IMG_2.JPG"])
        #expect(text(t.url.appendingPathComponent("IMG_1.JPG")) == "1")

        // Undoing a swap goes through a temporary name too.
        let a = try write(t, "a.jpg", "A"), b = try write(t, "b.jpg", "B")
        let swap = BatchRenamer.perform([request(a, "b.jpg"), request(b, "a.jpg")], catalog: catalog)
        let back = BatchRenamer.perform(swap.inverse, restoring: true, catalog: catalog)
        #expect(back.failed.isEmpty && back.renamed.count == 2)
        #expect(text(a) == "A" && text(b) == "B")
        #expect(try names(t) == ["IMG_1.JPG", "IMG_2.JPG", "a.jpg", "b.jpg"])
    }

    /// Custom Order keeps each file's place under its new name, a swap included.
    @Test func customOrderFollowsTheFiles() throws {
        let t = try TemporaryFolder()
        let a = try write(t, "a.jpg", "A"), b = try write(t, "b.jpg", "B"), c = try write(t, "c.jpg", "C")
        let catalog = Catalog.inMemory()
        catalog.setCustomOrder(["c.jpg", "a.jpg", "b.jpg"], in: t.url)
        _ = BatchRenamer.perform([request(a, "b.jpg"), request(b, "a.jpg"), request(c, "z.jpg")], catalog: catalog)
        #expect(catalog.customOrder(in: t.url) == ["z.jpg", "b.jpg", "a.jpg"])
    }

    /// However many files a batch renames, the catalog changes in one
    /// transaction and says so once: thousands of notifications, each a
    /// main-queue update of every window, made big renames slow.
    @Test func aBatchPostsOneCatalogChange() async throws {
        let t = try TemporaryFolder()
        let count = 300
        let urls = try (0..<count).map { try write(t, String(format: "IMG_%04d.jpg", $0), "\($0)") }
        let catalog = Catalog.inMemory()
        catalog.setRating(3, for: [urls[0], urls[1], urls[299]])
        catalog.setCustomOrder(urls.reversed().map(\.lastPathComponent), in: t.url)
        await Self.drainMainQueue()

        let folder = t.url.standardizedFileURL.path
        let posts = Counter()
        let observer = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: nil, queue: nil) { note in
            // Other tests' catalogs post too; count this folder's only.
            let urls = note.object as? [URL] ?? []
            if urls.contains(where: { $0.deletingLastPathComponent().standardizedFileURL.path == folder }) {
                posts.add(urls.count)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // A swap (through a temporary name) and a new name for all the rest.
        var requests = [request(urls[0], "IMG_0001.jpg"), request(urls[1], "IMG_0000.jpg")]
        requests += urls.dropFirst(2).enumerated().map { request($1, String(format: "Trip %03d.jpg", $0)) }
        let outcome = BatchRenamer.perform(requests, catalog: catalog)
        #expect(outcome.failed.isEmpty && outcome.renamed.count == count)
        await Self.drainMainQueue()
        #expect(posts.value == (1, 2 * (count + 1)), "one notification naming every step, the temporary name's too")

        #expect(catalog.marks(for: t.url.appendingPathComponent("IMG_0001.jpg")).rating == 3, "the swap kept the stars")
        #expect(catalog.marks(for: t.url.appendingPathComponent("IMG_0000.jpg")).rating == 3)
        #expect(catalog.marks(for: t.url.appendingPathComponent("Trip 297.jpg")).rating == 3)
        let order = catalog.customOrder(in: t.url)
        #expect(order.first == "Trip 297.jpg" && order.suffix(2) == ["IMG_0000.jpg", "IMG_0001.jpg"])

        // Undo is one change too.
        _ = BatchRenamer.perform(outcome.inverse, restoring: true, catalog: catalog)
        await Self.drainMainQueue()
        #expect(posts.value.posts == 2)
        #expect(catalog.marks(for: urls[299]).rating == 3)
    }

    static func drainMainQueue() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var posts = 0, urls = 0
        func add(_ count: Int) { lock.withLock { posts += 1; urls += count } }
        var value: (posts: Int, urls: Int) { lock.withLock { (posts, urls) } }
    }

    /// A name taken by another app meanwhile fails that file only; the rest
    /// go ahead, and a file that stepped aside is never left hidden.
    @Test func aNameTakenMeanwhileFailsOnlyThatFile() throws {
        let t = try TemporaryFolder()
        let a = try write(t, "a.jpg", "A"), b = try write(t, "b.jpg", "B"), c = try write(t, "c.jpg", "C")
        _ = try write(t, "taken.jpg", "someone else's")
        let catalog = Catalog.inMemory()
        let outcome = BatchRenamer.perform([request(a, "taken.jpg"), request(b, "c.jpg"), request(c, "d.jpg")],
                                           catalog: catalog)
        #expect(outcome.failed.map(\.url) == [a])
        #expect(outcome.renamed.map(\.to.lastPathComponent) == ["c.jpg", "d.jpg"])
        #expect(text(t.url.appendingPathComponent("taken.jpg")) == "someone else's")
        #expect(try names(t) == ["a.jpg", "c.jpg", "d.jpg", "taken.jpg"])

        // A file waiting for a name its holder couldn't give up is refused,
        // not stuck: x → y fails (y is taken outside), z → x waits for x.
        let x = try write(t, "x.jpg", "X"), z = try write(t, "z.jpg", "Z")
        _ = try write(t, "y.jpg", "outside")
        let stuck = BatchRenamer.perform([request(x, "y.jpg"), request(z, "x.jpg")], catalog: catalog)
        #expect(Set(stuck.failed.map(\.url)) == [x, z])
        #expect(text(x) == "X" && text(z) == "Z")
    }

    @Test func uniqueNamesAvoidTheDiskAndTheBatch() throws {
        let t = try TemporaryFolder()
        _ = try write(t, "photo.jpg", "")
        _ = try write(t, "photo 2.jpg", "")
        #expect(BatchNameKey.uniqueName(for: "new.jpg", in: t.url) { _ in false } == "new.jpg")
        #expect(BatchNameKey.uniqueName(for: "photo.jpg", in: t.url) { _ in false } == "photo 3.jpg")
        #expect(BatchNameKey.uniqueName(for: "photo.jpg", in: t.url) { $0 == "photo 3.jpg" } == "photo 4.jpg")
        #expect(BatchNameKey.uniqueName(for: "a.jpg", in: t.url) { $0 == "a.jpg" } == "a 2.jpg")
        #expect(BatchNameKey.key("Café.JPG", caseSensitive: false) == BatchNameKey.key("cafe\u{301}.jpg", caseSensitive: false))
        #expect(BatchNameKey.key("A.jpg", caseSensitive: true) != BatchNameKey.key("a.jpg", caseSensitive: true))
    }

    // MARK: - Writing converted files

    /// A stand-in Trash inside the test's folder.
    func fakeTrash(_ t: TemporaryFolder) throws -> (BatchFileWriter.Trasher, URL) {
        let trash = t.url.appendingPathComponent(".FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return ({ url in
            let place = trash.appendingPathComponent(UUID().uuidString + " " + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: place)
            return place
        }, trash)
    }

    @Test func writerFollowsTheExistingFilePolicy() throws {
        let t = try TemporaryFolder()
        let (trash, trashFolder) = try fakeTrash(t)
        let target = t.url.appendingPathComponent("out.jpg")

        #expect(try BatchFileWriter.commit(Data("new".utf8), to: target, policy: .skip, trash: trash)
                == .written(target, trashed: nil))
        #expect(text(target) == "new")

        #expect(try BatchFileWriter.commit(Data("second".utf8), to: target, policy: .skip, trash: trash) == .skipped)
        #expect(text(target) == "new")

        let kept = t.url.appendingPathComponent("out 2.jpg")
        #expect(try BatchFileWriter.commit(Data("both".utf8), to: target, policy: .keepBoth, trash: trash)
                == .written(kept, trashed: nil))
        #expect(text(target) == "new" && text(kept) == "both")
        // Keep Both steps past names promised to other outputs.
        let promised = try BatchFileWriter.commit(Data("third".utf8), to: target, policy: .keepBoth, trash: trash) {
            $0 == "out 3.jpg"
        }
        #expect(promised == .written(t.url.appendingPathComponent("out 4.jpg"), trashed: nil))

        let result = try BatchFileWriter.commit(Data("replaced".utf8), to: target, policy: .replace, trash: trash)
        guard case .written(let url, let trashed?) = result else { Issue.record("expected a replace"); return }
        #expect(url == target && text(target) == "replaced")
        #expect(text(trashed) == "new", "the old file is in the Trash, whole")
        #expect(trashed.deletingLastPathComponent().standardizedFileURL == trashFolder.standardizedFileURL)

        // Nothing half written or hidden is left behind.
        #expect(try names(t) == [".FakeTrash", "out 2.jpg", "out 4.jpg", "out.jpg"])
    }

    /// Replacing someone else's file sends its marks to the Trash with it;
    /// replacing the original (confirmed) keeps them on the converted file,
    /// under the same name or one that differs only in letter case.
    @Test func replacedFilesMarksGoWhereTheFileBelongs() throws {
        let t = try TemporaryFolder()
        let (trash, _) = try fakeTrash(t)
        let catalog = Catalog.inMemory()
        let other = try write(t, "other.jpg", "an earlier export")
        let original = try write(t, "photo.jpg", "the original")
        let upper = try write(t, "SHOT.JPG", "another original")
        catalog.setRating(2, for: [other])
        catalog.setRating(5, for: [original])
        catalog.setTagged(true, for: [upper])
        catalog.setCustomOrder(["SHOT.JPG", "photo.jpg", "other.jpg"], in: t.url)

        let replaced = try BatchFileWriter.commit(Data("new".utf8), to: other, policy: .replace, catalog: catalog,
                                                  trash: trash)
        guard case .written(_, let trashedOther?) = replaced else { Issue.record("expected a replace"); return }
        #expect(catalog.marks(for: trashedOther).rating == 2, "the old file's stars went to the Trash with it")
        #expect(catalog.marks(for: other).rating == 0)

        _ = try BatchFileWriter.commit(Data("converted".utf8), to: original, policy: .replace, catalog: catalog,
                                       trash: trash, original: original)
        #expect(text(original) == "converted")
        #expect(catalog.marks(for: original).rating == 5, "the converted photo keeps the original's stars")

        let lower = t.url.appendingPathComponent("SHOT.jpg")
        let result = try BatchFileWriter.commit(Data("converted".utf8), to: lower, policy: .replace, catalog: catalog,
                                                trash: trash, original: upper)
        #expect(result != .skipped)
        #expect(catalog.marks(for: lower).isTagged, "a change of letter case takes the marks along")
        #expect(catalog.customOrder(in: t.url) == ["SHOT.jpg", "photo.jpg"], "places kept for the originals")
    }

    @Test func writerNeverReplacesAFolderOrLosesAFileWhenTrashFails() throws {
        let t = try TemporaryFolder()
        let (trash, _) = try fakeTrash(t)
        let folder = try t.folder("shot.jpg")
        #expect(throws: CocoaError.self) {
            _ = try BatchFileWriter.commit(Data("x".utf8), to: folder, policy: .replace, trash: trash)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)

        let existing = try write(t, "keep.jpg", "precious")
        #expect(throws: CocoaError.self) {
            _ = try BatchFileWriter.commit(Data("x".utf8), to: existing, policy: .replace) { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(text(existing) == "precious")
        #expect(try names(t) == [".FakeTrash", "keep.jpg", "shot.jpg"], "the temporary file was removed")
    }
}
