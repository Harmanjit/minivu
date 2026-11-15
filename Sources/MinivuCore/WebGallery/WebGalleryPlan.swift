import Foundation

/// One picture of a web gallery: where it comes from, what its captions
/// say, the names it has inside the gallery, and (once written) the sizes
/// of its two pictures.
public struct WebGalleryItem: Hashable, Sendable {
    public var source: URL
    /// The original's file name, as the browser shows it.
    public var fileName: String
    /// From the metadata (`MetadataFields`); empty when there is none.
    public var title: String
    public var caption: String
    /// When the photo was taken, else when the file last changed, ready to show.
    public var dateText: String
    /// The name shared by the picture's page, large picture and thumbnail,
    /// without an extension: safe on any file system, unique in the gallery
    /// whatever the letter case.
    public var stem: String
    /// The copy of the original's name in the originals folder, when
    /// originals are included.
    public var originalName: String?
    public var largeWidth = 0
    public var largeHeight = 0
    public var thumbnailWidth = 0
    public var thumbnailHeight = 0

    public init(source: URL, fileName: String, title: String = "", caption: String = "", dateText: String = "",
                stem: String, originalName: String? = nil) {
        self.source = source
        self.fileName = fileName
        self.title = title
        self.caption = caption
        self.dateText = dateText
        self.stem = stem
        self.originalName = originalName
    }
}

/// Turns the browser's pictures into a gallery's items: sorted, captioned,
/// and named.
///
/// **Names.** Every name in the gallery is made from a file name, which may
/// hold anything a file system allows: quotes, angle brackets, "&", "#",
/// "%", any Unicode, a leading dot. `safeName` keeps what is readable and
/// replaces what isn't safe in a file name anywhere: control characters,
/// "/", ":" and "\" become "-", leading dots go (so no hidden file and no
/// ".."), and the result is shortened to leave room for a counter and an
/// extension. Then the rules of `FileOperations.nameProblem` are checked,
/// with "picture" standing in for a name that can't be used. Names are
/// made unique as Batch Convert makes them (`BatchNameKey`: "photo 2"),
/// compared without letter case or Unicode normalisation, so the gallery
/// can be copied to any volume or web server without two files merging.
/// The HTML percent-encodes every link and escapes every name besides
/// (`WebGalleryHTML`); safe names are the first line, not the only one.
public enum WebGalleryPlanner {
    /// A picture as the browser has it, with its metadata if read.
    public struct Source: Sendable {
        public var url: URL
        public var modified: Date
        public var title: String
        public var caption: String
        public var dateTaken: WallClock?

        public init(url: URL, modified: Date, title: String = "", caption: String = "", dateTaken: WallClock? = nil) {
            self.url = url
            self.modified = modified
            self.title = title
            self.caption = caption
            self.dateTaken = dateTaken
        }

        /// The date sorting by date taken uses: the wall-clock time taken
        /// read as if local, else the modification date.
        var sortDate: Date {
            dateTaken.map { $0.date.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT(for: $0.date))) }
                ?? modified
        }
    }

    /// The items for `sources` (in the browser's order), sorted as
    /// `settings` asks; `formatDate` writes each one's date line.
    public static func items(_ sources: [Source], settings: WebGallerySettings,
                             formatDate: (Source) -> String = { dateText(for: $0) }) -> [WebGalleryItem] {
        var stems: Set<String> = []
        var originals: Set<String> = []
        return sorted(sources, by: settings.sort).map { source in
            let fileName = source.url.lastPathComponent
            let stem = String(unique(stem(for: fileName) + ".html", taken: &stems).dropLast(".html".count))
            let original = settings.includesOriginals ? unique(originalName(for: fileName), taken: &originals) : nil
            return WebGalleryItem(source: source.url, fileName: fileName, title: source.title,
                                  caption: source.caption, dateText: formatDate(source), stem: stem,
                                  originalName: original)
        }
    }

    /// `sources` in the gallery's order. Ties, and names, are compared as
    /// Finder compares them ("IMG 2" before "IMG 10"); the browser's own
    /// order is kept as it is.
    public static func sorted(_ sources: [Source], by sort: WebGallerySettings.Sort) -> [Source] {
        func byName(_ a: Source, _ b: Source) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        switch sort {
        case .asShown:
            return sources
        case .name:
            return sources.sorted(by: byName)
        case .dateTaken:
            return sources.sorted { a, b in a.sortDate == b.sortDate ? byName(a, b) : a.sortDate < b.sortDate }
        case .dateModified:
            return sources.sorted { a, b in a.modified == b.modified ? byName(a, b) : a.modified < b.modified }
        }
    }

    /// The date line: when the photo was taken (a wall-clock time, shown as
    /// recorded), else when the file last changed, in this Mac's time zone.
    public static func dateText(for source: Source, locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        if let taken = source.dateTaken {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: taken.date)
        }
        formatter.timeZone = timeZone
        return formatter.string(from: source.modified)
    }

    // MARK: - Names

    /// The longest safe name, in bytes of UTF-8: room is left under APFS's
    /// 255 for a counter (" 999") and an extension.
    static let maximumNameBytes = 200

    /// `name` with what isn't safe in a file name replaced or removed (see
    /// the type's notes). May be empty.
    public static func safeName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0..<0x20, 0x7F...0x9F, 0x2F, 0x3A, 0x5C: scalars.append("-")   // controls, "/", ":", "\"
            default: scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") || result.hasPrefix(" ") { result.removeFirst() }
        while result.utf8.count > maximumNameBytes { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stem for a picture called `fileName`: its name without the
    /// extension, made safe; "picture" when nothing usable is left.
    public static func stem(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let safe = safeName(base.isEmpty ? fileName : base)
        return FileOperations.nameProblem(safe + ".html") == nil && !safe.isEmpty ? safe : "picture"
    }

    /// The name an original is copied under: its own, made safe.
    public static func originalName(for fileName: String) -> String {
        let safe = safeName(fileName)
        let ext = safeName((fileName as NSString).pathExtension)
        if FileOperations.nameProblem(safe) == nil, !(safe as NSString).deletingPathExtension.isEmpty { return safe }
        return ext.isEmpty ? "picture" : "picture.\(ext)"
    }

    /// The first of `name`, "name 2", "name 3"… not in `taken` (keys
    /// without case or normalisation), which it then joins.
    static func unique(_ name: String, taken: inout Set<String>) -> String {
        let claimed = taken
        let chosen = BatchNameKey.uniqueName(for: name, in: URL(fileURLWithPath: "/", isDirectory: true),
                                             probe: noFiles) { claimed.contains(key($0)) }
        taken.insert(key(chosen))
        return chosen
    }

    /// Names compared as a case-insensitive volume compares them, whatever
    /// the volume the gallery is made on.
    static func key(_ name: String) -> String {
        BatchNameKey.key(name, caseSensitive: false)
    }

    /// The gallery is made in an empty scratch folder: nothing on disk to
    /// step past.
    static let noFiles = BatchFileProbe(identity: { _ in nil }, isCaseSensitive: { _ in false })
}
