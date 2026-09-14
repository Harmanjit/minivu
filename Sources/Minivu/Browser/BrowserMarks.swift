import AppKit
import MinivuCore

/// Which images the grid shows beyond the name search: FastStone's rating
/// and tag filters, and one Finder tag.
///
/// Folders always pass. The filters are about photos, and a filter that
/// hid folders would strand the user in the folder they are filtering.
nonisolated struct MarksFilter: Equatable, Sendable {
    /// Images rated at least this many stars; 0 shows every image.
    var minimumRating = 0
    var taggedOnly = false
    /// A Finder tag name the image must carry.
    var finderTag: String?

    var isActive: Bool { minimumRating > 0 || taggedOnly || finderTag != nil }

    func passes(_ entry: FolderEntry, marks: Catalog.Marks, finderTags: [FinderTag]) -> Bool {
        guard !entry.isDirectory else { return true }
        if marks.rating < minimumRating { return false }
        if taggedOnly, !marks.isTagged { return false }
        if let finderTag, !finderTags.contains(where: { $0.name == finderTag }) { return false }
        return true
    }
}

/// The two orders the catalog decides, applied to images FolderListing has
/// already put in name order.
nonisolated enum MarksOrdering {
    /// By stars, most first when descending; ties stay in name order (A to Z)
    /// whichever way the stars run, so equal ratings read like the folder.
    static func byRating(_ images: [FolderEntry], marks: [String: Catalog.Marks], ascending: Bool) -> [FolderEntry] {
        let byName = FolderListing.sorted(images, by: FileSortOrder(key: .name, ascending: true))
        let decorated = byName.enumerated().map { (index: $0.offset, entry: $0.element,
                                                   rating: marks[$0.element.name]?.rating ?? 0) }
        return decorated.sorted { a, b in
            if a.rating != b.rating { return ascending ? a.rating < b.rating : a.rating > b.rating }
            return a.index < b.index
        }.map(\.entry)
    }

    /// The user's arrangement: the names the catalog lists, in its order,
    /// then every image it doesn't list yet (new files) in name order.
    /// Descending shows the whole arrangement back to front.
    static func custom(_ images: [FolderEntry], order: [String], ascending: Bool) -> [FolderEntry] {
        let byName = FolderListing.sorted(images, by: FileSortOrder(key: .name, ascending: true))
        var position: [String: Int] = [:]
        for (index, name) in order.enumerated() where position[name] == nil { position[name] = index }
        let placed = byName.filter { position[$0.name] != nil }.sorted { position[$0.name]! < position[$1.name]! }
        let unplaced = byName.filter { position[$0.name] == nil }
        let result = placed + unplaced
        return ascending ? result : result.reversed()
    }

    /// `names` with `moving` taken out and put back, in their current
    /// relative order, just before `target` (at the end for nil). A target
    /// that is itself moving stands for the first name after it that stays.
    static func reordered(_ names: [String], moving: [String], before target: String?) -> [String] {
        let movingSet = Set(moving)
        let moved = names.filter(movingSet.contains)
        var rest = names.filter { !movingSet.contains($0) }
        var insertAt = rest.count
        if let target, let start = names.firstIndex(of: target),
           let staying = names[start...].first(where: { !movingSet.contains($0) }),
           let index = rest.firstIndex(of: staying) {
            insertAt = index
        }
        rest.insert(contentsOf: moved, at: insertAt)
        return rest
    }
}

/// Finder's rules for what a file drop does.
nonisolated enum DropRules {
    /// Same volume moves and another volume copies; Option forces a copy and
    /// Command a move. AppKit reports a held modifier by narrowing the
    /// source's mask (Option to `.copy`, Command to `.generic`), so the mask
    /// is all this needs. Empty when the source allows neither.
    static func operation(sourceMask: NSDragOperation, sameVolume: Bool) -> NSDragOperation {
        let canCopy = sourceMask.contains(.copy)
        let canMove = sourceMask.contains(.move) || sourceMask.contains(.generic)
        // Option held: the mask is copy alone.
        if canCopy, !canMove { return .copy }
        // Command held: generic (and possibly move) without copy.
        if canMove, !canCopy { return .move }
        if sameVolume { return canMove ? .move : (canCopy ? .copy : []) }
        return canCopy ? .copy : []
    }

    /// The dropped items that would actually go somewhere: not those already
    /// in `destination`, not `destination` itself, and no folder into itself
    /// or a folder inside it.
    static func movableItems(_ urls: [URL], into destination: URL) -> [URL] {
        let destinationParts = SidebarPaths.components(destination)
        return urls.filter { url in
            let parts = SidebarPaths.components(url)
            if parts.dropLast() == destinationParts[...] { return false }
            if destinationParts.count >= parts.count, Array(destinationParts.prefix(parts.count)) == parts { return false }
            return true
        }
    }

    /// Whether two file URLs live on the same volume. Two resource reads;
    /// unknown counts as different, so the drop copies rather than moves.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }
}

/// A Finder tag with its colour, as Finder stores it.
///
/// `FinderTags.tags` gives the names only. The colour lives beside each name
/// in the same extended attribute ("Red\n6"), so the attribute is read
/// directly: a tag the user recoloured in Finder shows in its own colour.
nonisolated struct FinderTag: Hashable, Sendable {
    var name: String
    /// Finder's label number: 0 none, 1 gray, 2 green, 3 purple, 4 blue,
    /// 5 yellow, 6 red, 7 orange.
    var colorIndex: Int

    static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// Tags on a file or folder; empty when it has none or can't be read.
    static func read(from url: URL) -> [FinderTag] {
        let path = url.path
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return parse(values)
    }

    /// "Name\nN" entries. A name stored without a colour (as the file
    /// system's own setter stores "Red\n0") shows in the colour Finder gives
    /// its standard tag of that name, or none.
    static func parse(_ values: [String]) -> [FinderTag] {
        values.compactMap { value in
            let parts = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
            var index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if !(1...7).contains(index) { index = standardColors[name.lowercased()] ?? 0 }
            return FinderTag(name: name, colorIndex: index)
        }
    }

    private static let standardColors: [String: Int] = [
        "gray": 1, "grey": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5, "red": 6, "orange": 7,
    ]
}

extension FinderTag {
    /// The dot colour; nil for a tag without one, which Finder draws hollow.
    var color: NSColor? {
        switch colorIndex {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

/// Each sort key's direction, remembered as Finder remembers a column's.
///
/// One direction for every key made Sort by Rating open on the unrated
/// photos (ascending, the default) and left Name running Z to A after a
/// descending sort by date.
nonisolated enum SortDirectionMemory {
    static let defaultsKey = "sortDirectionByKey"

    /// Where a key starts: most stars first; A to Z, oldest and smallest
    /// first for the rest (as minivu always sorted them).
    static func naturalAscending(_ key: SortKey) -> Bool { key != .rating }

    /// The order after choosing `key`: the current key's direction is
    /// remembered and the new key's comes back.
    static func switching(from current: FileSortOrder, to key: SortKey,
                          defaults: UserDefaults = .standard) -> FileSortOrder {
        guard key != current.key else { return current }
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        stored[current.key.rawValue] = current.ascending
        defaults.set(stored, forKey: defaultsKey)
        return FileSortOrder(key: key, ascending: stored[key.rawValue] ?? naturalAscending(key))
    }
}

/// "★★★☆☆" and friends, for menus and accessibility.
nonisolated enum RatingText {
    static func stars(_ rating: Int) -> String {
        let r = min(max(rating, 0), 5)
        return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
    }

    /// The filter menu's titles: "Show All", "★ or More" … "★★★★★".
    static func filterTitle(minimum: Int) -> String {
        switch minimum {
        case ...0: "Show All"
        case 5...: String(repeating: "★", count: 5)
        default: String(repeating: "★", count: minimum) + " or More"
        }
    }
}

/// Seeds ratings and tags from the environment so the snapshot harness can
/// picture a graded folder. DEBUG builds only; release builds ignore it.
///
///     MINIVU_DEBUG_MARKS="a.jpg=3,b.NEF=5T,c.png=T"   stars, then T for tagged
///     MINIVU_DEBUG_SELECT="a.jpg"                      select it once listed
///
/// Names are files in whichever folder the browser lists.
nonisolated enum DebugMarks {
    struct Seed: Equatable {
        var name: String
        var rating: Int
        var tagged: Bool
    }

    static func parse(_ text: String) -> [Seed] {
        text.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            var value = parts[1].uppercased()
            let tagged = value.hasSuffix("T")
            if tagged { value.removeLast() }
            let rating = value.isEmpty ? 0 : Int(value)
            guard let rating, (0...5).contains(rating) else { return nil }
            return Seed(name: parts[0], rating: rating, tagged: tagged)
        }
    }

    /// Writes the seeds for files present in `folder` into `catalog`, once
    /// per folder per launch (a watcher reload must not undo the user's
    /// changes).
    static func seedIfRequested(folder: URL, names: Set<String>, catalog: Catalog) {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["MINIVU_DEBUG_MARKS"], !text.isEmpty,
              seeded.withLock({ $0.insert(folder.standardizedFileURL.path).inserted }) else { return }
        for seed in parse(text) where names.contains(seed.name) {
            let url = folder.appendingPathComponent(seed.name)
            catalog.setRating(seed.rating, for: [url])
            catalog.setTagged(seed.tagged, for: [url])
        }
        #endif
    }

    /// The file MINIVU_DEBUG_SELECT names, in DEBUG builds.
    static var selection: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["MINIVU_DEBUG_SELECT"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    private static let seeded = LockedNameSet()
}

/// A lock-protected set of strings, for the one-time debug seeding.
nonisolated final class LockedNameSet: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func withLock<T>(_ body: (inout Set<String>) -> T) -> T {
        lock.withLock { body(&values) }
    }
}
