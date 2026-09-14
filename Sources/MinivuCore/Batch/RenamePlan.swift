import Foundation

/// How batch tools ask the file system about names, replaceable in tests.
public struct BatchFileProbe: Sendable {
    /// The item at a path (a broken symbolic link counts), by file identity.
    public var identity: @Sendable (URL) -> BatchItemIdentity?
    /// Whether "IMG.JPG" and "img.jpg" are different names in this folder.
    public var isCaseSensitive: @Sendable (URL) -> Bool

    public init(identity: @escaping @Sendable (URL) -> BatchItemIdentity?,
                isCaseSensitive: @escaping @Sendable (URL) -> Bool) {
        self.identity = identity
        self.isCaseSensitive = isCaseSensitive
    }

    public static let system = BatchFileProbe(
        identity: { url in
            FileOperations.info(url.path, followingLinks: false).map {
                BatchItemIdentity(device: $0.identity.device, inode: $0.identity.inode, isDirectory: $0.isDirectory)
            }
        },
        isCaseSensitive: { folder in
            (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames ?? false
        })
}

public struct BatchItemIdentity: Hashable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public var isDirectory: Bool

    public init(device: Int32, inode: UInt64, isDirectory: Bool = false) {
        self.device = device
        self.inode = inode
        self.isDirectory = isDirectory
    }

    /// Two paths name the same item: identity without the kind.
    public func isSameItem(as other: BatchItemIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// Names as the file system compares them. APFS ignores Unicode
/// normalisation ("é" typed two ways is one name) and, on the usual
/// case-insensitive volume, letter case; two names with one key can't
/// both exist in a folder.
public enum BatchNameKey {
    public static func key(_ name: String, caseSensitive: Bool) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The key of a name in a folder, so files of different folders never clash.
    public static func key(folder: URL, name: String, caseSensitive: Bool) -> String {
        folder.standardizedFileURL.path + "\u{0}" + key(name, caseSensitive: caseSensitive)
    }

    /// Why a name can't be used in any folder (empty, "/" or ":", a leading
    /// dot, too long), or nil: the rules of `FileOperations.validateName`.
    public static func problem(with name: String) -> String? {
        FileOperations.nameProblem(name)
    }

    /// "photo.jpg" → "photo 2.jpg", "photo 3.jpg"… the first name neither on
    /// disk nor `isTaken` (names already promised to other outputs of the
    /// same batch). Numbered the way Finder and `FileOperations.uniqueName`
    /// number duplicates.
    public static func uniqueName(for name: String, in folder: URL, probe: BatchFileProbe = .system,
                                  isTaken: (String) -> Bool) -> String {
        func free(_ candidate: String) -> Bool {
            !isTaken(candidate) && probe.identity(folder.appendingPathComponent(candidate)) == nil
        }
        if free(name) { return name }
        var (base, ext) = RenameNamer.split(name)
        var n = 2
        if let (stem, counter) = FileOperations.trailingCounter(base) { base = stem; n = counter + 1 }
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if free(candidate) { return candidate }
            n += 1
        }
    }
}

/// What renaming a batch would do, worked out before anything changes: the
/// new name of every file, and each reason a name can't be used.
public struct RenamePlan: Sendable {
    public enum Problem: Hashable, Sendable {
        /// The name breaks a rule of its own (empty, "/", too long…).
        case invalidName(String)
        /// Another file of the batch gets the same name.
        case duplicate
        /// An item that isn't being renamed already has the name.
        case taken
        /// The file has gone since it was listed.
        case missing

        public var message: String {
            switch self {
            case .invalidName(let reason): reason
            case .duplicate: "Another file would get the same name."
            case .taken: "An item with this name already exists."
            case .missing: "The file can’t be found."
            }
        }
    }

    public struct Item: Hashable, Sendable {
        public var source: URL
        public var newName: String
        public var problem: Problem?

        public init(source: URL, newName: String, problem: Problem? = nil) {
            self.source = source
            self.newName = newName
            self.problem = problem
        }

        /// Exactly the same name: nothing to do. A change of letter case
        /// alone is a change.
        public var isUnchanged: Bool { newName == source.lastPathComponent }
        public var destination: URL { source.deletingLastPathComponent().appendingPathComponent(newName) }
    }

    public var items: [Item]
    /// Tokens the pattern doesn't know, such as "{nmae}".
    public var unknownTokens: [String]

    public var problemCount: Int { items.lazy.filter { $0.problem != nil }.count }
    public var changes: [Item] { items.filter { !$0.isUnchanged && $0.problem == nil } }
    public var changeCount: Int { items.lazy.filter { !$0.isUnchanged }.count }
    public var canRename: Bool { unknownTokens.isEmpty && problemCount == 0 && changeCount > 0 }

    public init(items: [Item], unknownTokens: [String] = []) {
        self.items = items
        self.unknownTokens = unknownTokens
    }
}

public enum RenamePlanner {
    /// The plan for renaming `sources` (in batch order: the counter follows
    /// it) with `pattern`. Reads the file system (one `lstat` per file and
    /// per new name) but changes nothing; call it off the main thread for
    /// large batches.
    ///
    /// Problems found, every one before anything is renamed: invalid names;
    /// two files of the batch getting one name (as the volume compares names,
    /// so "A.jpg" and "a.jpg" clash on a case-insensitive disk); a new name
    /// held by an item outside the batch; a source that has gone. A new name
    /// held by another file of the batch is fine as long as that file is
    /// renamed too: `BatchRenamer` orders the renames, and swaps go through a
    /// temporary name.
    public static func plan(_ sources: [RenameSource], pattern: RenamePattern, newExtension: String? = nil,
                            probe: BatchFileProbe = .system) -> RenamePlan {
        let namer = RenameNamer(pattern: pattern)
        var items = sources.enumerated().map { index, source in
            RenamePlan.Item(source: source.url, newName: namer.name(for: source, index: index, newExtension: newExtension))
        }

        var caseSensitivity: [String: Bool] = [:]
        func isCaseSensitive(_ folder: URL) -> Bool {
            let path = folder.standardizedFileURL.path
            if let known = caseSensitivity[path] { return known }
            let value = probe.isCaseSensitive(folder)
            caseSensitivity[path] = value
            return value
        }

        // Each source's identity: a new name held by one of these is freed
        // by the batch itself.
        var batchIdentities: [BatchItemIdentity: Int] = [:]
        for (i, item) in items.enumerated() {
            guard let identity = probe.identity(item.source) else {
                items[i].problem = .missing
                continue
            }
            batchIdentities[BatchItemIdentity(device: identity.device, inode: identity.inode)] = i
        }

        for i in items.indices where items[i].problem == nil && !items[i].isUnchanged {
            if let reason = FileOperations.nameProblem(items[i].newName) { items[i].problem = .invalidName(reason) }
        }

        // Every file ends up with a name, changed or not, so every name counts.
        var byKey: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            let folder = item.source.deletingLastPathComponent()
            byKey[BatchNameKey.key(folder: folder, name: item.newName, caseSensitive: isCaseSensitive(folder)), default: []]
                .append(i)
        }
        for indices in byKey.values where indices.count > 1 {
            for i in indices where items[i].problem == nil { items[i].problem = .duplicate }
        }

        for i in items.indices where items[i].problem == nil && !items[i].isUnchanged {
            guard let existing = probe.identity(items[i].destination) else { continue }
            let key = BatchItemIdentity(device: existing.device, inode: existing.inode)
            if batchIdentities[key] == nil { items[i].problem = .taken }
        }
        return RenamePlan(items: items, unknownTokens: namer.unknownTokens)
    }
}
