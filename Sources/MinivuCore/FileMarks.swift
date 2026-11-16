import Foundation
import ImageIO

/// A colour label: one of Finder's seven standard colour tags (G4).
///
/// minivu keeps colour labels as Finder tags, the Mac's own colour label,
/// so Finder, Spotlight and every app that reads tags see them. With
/// "Write ratings into files (XMP)" on, the label is also written as
/// `xmp:Label` (see `MarksXMP`), one way: a Finder tag is what minivu shows
/// and filters by.
///
/// The cases are in the order Finder lists its colour tags, which is also
/// the order of the Label menu and its ⌥⌘0–⌥⌘7 shortcuts.
public enum ColorLabel: Int, CaseIterable, Sendable {
    case none, red, orange, yellow, green, blue, purple, gray

    /// The English name: the standard tag's name on an English system, and
    /// the label `xmp:Label` gets.
    public var name: String {
        switch self {
        case .none: "None"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    /// Finder's label number for the colour, as it stores it beside a tag's
    /// name: 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    public var finderColorIndex: Int {
        switch self {
        case .none: 0
        case .gray: 1
        case .green: 2
        case .purple: 3
        case .blue: 4
        case .yellow: 5
        case .red: 6
        case .orange: 7
        }
    }

    public init?(finderColorIndex index: Int) {
        guard let label = Self.allCases.first(where: { $0.finderColorIndex == index }) else { return nil }
        self = label
    }

    /// The label for an `xmp:Label` value that names a colour ("Red", "red",
    /// "Grey"), the way Lightroom's default label set and XnView MP write
    /// them; nil for anything else, such as Bridge's "Approved" or "To Do".
    public init?(xmpLabel text: String) {
        let folded = text.trimmingCharacters(in: .whitespaces).lowercased()
        if folded == "grey" { self = .gray; return }
        guard let label = Self.allCases.first(where: { $0 != .none && $0.name.lowercased() == folded }) else {
            return nil
        }
        self = label
    }
}

/// Ratings, the pick and the colour label as XMP holds them in an image or
/// its sidecar (G2), and the mapping minivu uses for each:
///
/// - **Stars:** `xmp:Rating`, 0 to 5, as Lightroom, Bridge, Capture One,
///   digiKam, XnView MP and Windows all read and write it. -1 is
///   Bridge's (and digiKam's) "Rejected"; minivu shows it as no stars and
///   never writes it, and clearing a rating in minivu leaves a reject alone.
/// - **The tag** (FastStone's culling flag): `digiKam:PickLabel` 3,
///   "Accepted". Of the four applications compared, digiKam is the only one
///   that keeps a pick in XMP: Lightroom keeps its Pick and Reject flags in
///   its catalog only, Bridge has no pick, and XnView MP keeps its tag in
///   its own database. `xmp:Label` was not used for the tag, because it is
///   where Lightroom, Bridge and XnView MP keep the colour label, and
///   borrowing it would fight the colour labels. Untagging removes a
///   PickLabel of 3 only; digiKam's "Rejected" (1) and "Pending" (2) stay.
/// - **The colour label:** `xmp:Label` with the colour's English name
///   ("Red"), the names of Lightroom's default label set, which XnView MP
///   writes too. A label minivu didn't write in those words (Bridge's
///   "Approved") is replaced when a colour is chosen, and kept when None is.
public enum MarksXMP {
    public static let digiKamNamespace = "http://www.digikam.org/ns/1.0/"
    static let ratingPath = "xmp:Rating"
    static let labelPath = "xmp:Label"
    static let pickPath = "digiKam:PickLabel"
    /// digiKam's PickLabel for "Accepted".
    static let accepted = 3

    /// `xmp:Rating` as written: an integer, or a decimal some writers use
    /// ("3.0"). Nil when absent or not a number.
    static func rating(in metadata: CGImageMetadata?) -> Int? {
        guard let text = MetadataFields.xmpText(metadata, ratingPath), let value = Double(text), value.isFinite else {
            return nil
        }
        return Int(value.rounded())
    }

    static func pickLabel(in metadata: CGImageMetadata?) -> Int? {
        guard let metadata, hasPrefix("digiKam", in: metadata),
              let text = MetadataFields.xmpText(metadata, pickPath) else { return nil }
        return Int(text)
    }

    static func label(in metadata: CGImageMetadata?) -> String? {
        MetadataFields.xmpText(metadata, labelPath)
    }

    /// Whether a path with `prefix` can be looked up: ImageIO knows the
    /// prefixes of standard namespaces, and a document's own only when it
    /// declares them. Asking for an unknown one logs an error.
    static func hasPrefix(_ prefix: String, in metadata: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if (CGImageMetadataTagCopyPrefix(tag) as String?) == prefix { found = true }
            return !found
        }
        return found
    }

    /// Sets the stars. 0 removes a positive rating and keeps a reject.
    static func setRating(_ rating: Int, in metadata: CGMutableImageMetadata) {
        let stars = min(max(rating, 0), 5)
        if stars == 0 {
            if let old = Self.rating(in: metadata), old > 0 {
                CGImageMetadataRemoveTagWithPath(metadata, nil, ratingPath as CFString)
            }
            return
        }
        CGImageMetadataRemoveTagWithPath(metadata, nil, ratingPath as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, ratingPath as CFString, String(stars) as CFString)
    }

    /// Tags (PickLabel 3) or untags (removes a PickLabel of 3, keeping
    /// digiKam's other picks).
    static func setTagged(_ tagged: Bool, in metadata: CGMutableImageMetadata) {
        if tagged {
            CGImageMetadataRegisterNamespaceForPrefix(metadata, digiKamNamespace as CFString, "digiKam" as CFString, nil)
            CGImageMetadataRemoveTagWithPath(metadata, nil, pickPath as CFString)
            CGImageMetadataSetValueWithPath(metadata, nil, pickPath as CFString, String(accepted) as CFString)
        } else if pickLabel(in: metadata) == accepted {
            CGImageMetadataRemoveTagWithPath(metadata, nil, pickPath as CFString)
        }
    }

    /// Writes the colour's name, or for None removes a label that names a
    /// colour (and keeps any other text).
    static func setLabel(_ label: ColorLabel, in metadata: CGMutableImageMetadata) {
        if label == .none {
            if let old = Self.label(in: metadata), ColorLabel(xmpLabel: old) != nil {
                CGImageMetadataRemoveTagWithPath(metadata, nil, labelPath as CFString)
            }
            return
        }
        CGImageMetadataRemoveTagWithPath(metadata, nil, labelPath as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, labelPath as CFString, label.name as CFString)
    }

    /// The marks `metadata` holds, as the catalog would keep them: nil when
    /// it has neither stars nor the tag.
    static func marks(rating: Int?, pickLabel: Int?) -> Catalog.Marks? {
        let marks = Catalog.Marks(rating: min(max(rating ?? 0, 0), 5), isTagged: pickLabel == accepted)
        return marks == .none ? nil : marks
    }

    /// The stars and tag an image carries, from its sidecar where it uses
    /// one (a camera raw, or a format ImageIO can't rewrite) and otherwise
    /// from its own XMP, as `MetadataFields` reads the other fields. A header
    /// read and at most one small file: never decodes pixels. Nil when the
    /// file has no marks or can't be read.
    public static func readMarks(from url: URL) -> Catalog.Marks? {
        let method = MetadataWriter.method(for: url)
        guard method != .unsupported else { return nil }
        var rating: Int?, pick: Int?
        Perf.count("file.open")
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
            rating = Self.rating(in: metadata)
            pick = pickLabel(in: metadata)
        }
        if method == .sidecar, let data = try? Data(contentsOf: MetadataSidecar.url(for: url)),
           let sidecar = CGImageMetadataCreateFromXMPData(data as CFData) {
            rating = Self.rating(in: sidecar) ?? rating
            pick = pickLabel(in: sidecar) ?? pick
        }
        return marks(rating: rating, pickLabel: pick)
    }
}

/// The marks image files carry (`MarksXMP.readMarks`), remembered per file
/// until the file or its sidecar changes, so browsing a folder again, or a
/// watcher's reload, doesn't read them again.
///
/// Thread-safe. Looking up costs an `lstat` (two for a file with a
/// sidecar) to see the entry is still current; reading costs a header read.
/// Callers read off the main thread, a few files at a time: the visible
/// cells as they appear, or a whole folder in the background when a sort or
/// filter needs every rating.
public final class FileMarksCache: @unchecked Sendable {
    public static let shared = FileMarksCache()

    /// The file's size and date, and its sidecar's date: a change to any of
    /// them means the marks may have changed.
    struct Stamp: Equatable {
        var size: Int64
        var modified: Double
        var sidecarModified: Double?
    }

    /// How many files are remembered before the cache starts again: each
    /// entry is a path and a few numbers, so this is a few megabytes.
    static let capacity = 50_000

    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, marks: Catalog.Marks?)] = [:]
    private let reader: @Sendable (URL) -> Catalog.Marks?

    /// `reader` is for tests, which count the reads.
    public init(reader: @escaping @Sendable (URL) -> Catalog.Marks? = MarksXMP.readMarks) {
        self.reader = reader
    }

    /// The marks remembered for `url` while still current, without reading
    /// the file: `.some(nil)` for a file known to have none, nil when they
    /// aren't known.
    public func cachedMarks(for url: URL) -> Catalog.Marks?? {
        guard let stamp = Self.stamp(of: url) else { return .some(nil) }
        let key = Self.key(url)
        return lock.withLock {
            guard let entry = entries[key], entry.stamp == stamp else { return nil }
            return .some(entry.marks)
        }
    }

    /// The marks `url` carries, read from the file unless remembered. Disk
    /// work: off the main thread.
    public func marks(for url: URL) -> Catalog.Marks? {
        guard let stamp = Self.stamp(of: url) else { return nil }
        let key = Self.key(url)
        if let entry = lock.withLock({ entries[key] }), entry.stamp == stamp { return entry.marks }
        let marks = reader(url)
        lock.withLock {
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = (stamp, marks)
        }
        return marks
    }

    /// What `url` shows without reading it: the catalog's row if it has
    /// one, else the marks remembered for the file (none until read).
    public func shownMarks(for url: URL, in catalog: Catalog) -> Catalog.Marks {
        if let stored = catalog.storedMarks(for: url) { return stored }
        return (cachedMarks(for: url) ?? nil) ?? .none
    }

    /// Whether the marks `url` shows need reading from the file: it has no
    /// row and the cache doesn't know them.
    public func needsRead(_ url: URL, in catalog: Catalog) -> Bool {
        catalog.storedMarks(for: url) == nil && cachedMarks(for: url) == nil
    }

    /// Forgets `url`, after minivu wrote its marks: the next look reads
    /// the file again.
    public func forget(_ url: URL) {
        let key = Self.key(url)
        lock.withLock { _ = entries.removeValue(forKey: key) }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Nil for a file that isn't there.
    static func stamp(of url: URL) -> Stamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        var stamp = Stamp(size: Int64(st.st_size), modified: Self.seconds(st.st_mtimespec))
        if MetadataWriter.method(for: url) == .sidecar {
            var side = stat()
            if lstat(MetadataSidecar.url(for: url).path, &side) == 0 {
                stamp.sidecarModified = Self.seconds(side.st_mtimespec)
            }
        }
        return stamp
    }

    private static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
}
