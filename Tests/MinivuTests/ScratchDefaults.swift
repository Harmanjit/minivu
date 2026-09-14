import Foundation

/// A defaults store of a test's own, that leaves nothing behind.
///
/// `UserDefaults(suiteName: "minivu-tests-…")` keeps its domain in
/// ~/Library/Preferences, and `removePersistentDomain(forName:)` doesn't
/// delete the file: cfprefsd writes an empty plist there a moment later, so
/// every test run used to leave dozens of them in the user's Preferences.
/// Deleting that file straight away races cfprefsd's write.
///
/// So the suite is named by an absolute path instead, which CFPreferences
/// takes as the plist's own location: the domain lives in a temporary
/// folder of its own, never in the user's Preferences, and `remove()`
/// clears the domain and deletes the folder. cfprefsd never recreates a
/// folder that has gone. A second `UserDefaults(suiteName: name)` reads the
/// same domain, as with an ordinary suite name.
final class ScratchDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    /// The suite name (a path), for reading the domain back.
    let name: String
    private let folder: URL

    init(_ label: String = "minivu-tests") {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: name)!
    }

    /// Clears the domain and deletes its folder. Safe to call more than once.
    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    deinit { remove() }
}
