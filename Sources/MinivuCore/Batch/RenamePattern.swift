import Foundation

/// A Batch Rename pattern: text with tokens, a counter, find and replace,
/// and letter case (DESIGN.md 5, "Tools").
///
/// Pure values and functions, so what a pattern makes of a file can be
/// tested without touching the disk, and the same pattern names the files
/// of Batch Rename and the outputs of Batch Convert.
///
/// **Tokens** (the keyword in any letter case):
///
/// | Token | Becomes |
/// |---|---|
/// | `{name}` | the original name without its extension |
/// | `{#}`, `{###}` | the counter; each `#` is a digit, zero-padded |
/// | `{date}`, `{date:yyyy-MM-dd}` | the date taken (EXIF DateTimeOriginal), else the file's modification date |
/// | `{modified}`, `{modified:HH.mm}` | the modification date |
/// | `{width}`, `{height}` | the picture's pixel size as displayed |
/// | `{ext}` | the original extension, without the dot |
///
/// A date format is a Unicode date pattern (`DateFormatter.dateFormat`),
/// `yyyy-MM-dd` when left out. Names are made in this order: tokens, then
/// find and replace, then the letter case of the name; the extension
/// (the original's, or the converter's new one) is added last in its own case.
public struct RenamePattern: Codable, Hashable, Sendable {
    public enum LetterCase: String, Codable, CaseIterable, Sendable {
        case unchanged, lower, upper, title

        public var title: String {
            switch self {
            case .unchanged: "Unchanged"
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            case .title: "Title Case"
            }
        }
    }

    public enum ExtensionCase: String, Codable, CaseIterable, Sendable {
        case unchanged, lower, upper

        public var title: String {
            switch self {
            case .unchanged: "Unchanged"
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            }
        }
    }

    public var text: String
    /// The counter's first value, and what each file adds to it.
    public var counterStart: Int
    public var counterStep: Int
    /// The fewest digits a counter shows. `{###}` asks for three itself;
    /// the larger of the two wins, so `{#}` with 4 digits gives "0001".
    public var counterDigits: Int
    /// Plain text (not a regular expression) replaced everywhere in the name
    /// the tokens made. Empty: nothing is replaced.
    public var find: String
    public var replacement: String
    public var matchesCase: Bool
    public var nameCase: LetterCase
    public var extensionCase: ExtensionCase

    public static let defaultDateFormat = "yyyy-MM-dd"

    public init(text: String = "{name}", counterStart: Int = 1, counterStep: Int = 1, counterDigits: Int = 1,
                find: String = "", replacement: String = "", matchesCase: Bool = false,
                nameCase: LetterCase = .unchanged, extensionCase: ExtensionCase = .unchanged) {
        self.text = text
        self.counterStart = counterStart
        self.counterStep = counterStep
        self.counterDigits = counterDigits
        self.find = find
        self.replacement = replacement
        self.matchesCase = matchesCase
        self.nameCase = nameCase
        self.extensionCase = extensionCase
    }

    private enum CodingKeys: String, CodingKey {
        case text, counterStart, counterStep, counterDigits, find, replacement, matchesCase, nameCase, extensionCase
    }

    /// Patterns are remembered between launches; anything missing (a pattern
    /// saved before an option existed) takes its default instead of the
    /// whole pattern being lost.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenamePattern()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        counterStart = try c.decodeIfPresent(Int.self, forKey: .counterStart) ?? d.counterStart
        counterStep = try c.decodeIfPresent(Int.self, forKey: .counterStep) ?? d.counterStep
        counterDigits = try c.decodeIfPresent(Int.self, forKey: .counterDigits) ?? d.counterDigits
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? d.find
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? d.replacement
        matchesCase = try c.decodeIfPresent(Bool.self, forKey: .matchesCase) ?? d.matchesCase
        nameCase = (try? c.decodeIfPresent(LetterCase.self, forKey: .nameCase)) ?? d.nameCase
        extensionCase = (try? c.decodeIfPresent(ExtensionCase.self, forKey: .extensionCase)) ?? d.extensionCase
    }

    // MARK: - Tokens

    public enum Token: Hashable, Sendable {
        case literal(String)
        case name
        case counter(digits: Int)
        case dateTaken(format: String)
        case modified(format: String)
        case width
        case height
        case fileExtension
    }

    /// The pattern's pieces, and the tokens it doesn't know ("{nmae}"),
    /// which are kept as literal text so the preview shows them, and make the
    /// pattern unusable until corrected. A brace without its partner is text.
    public var tokens: (tokens: [Token], unknown: [String]) {
        Self.parse(text)
    }

    static func parse(_ text: String) -> (tokens: [Token], unknown: [String]) {
        var tokens: [Token] = []
        var unknown: [String] = []
        var literal = ""
        var rest = Substring(text)
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)) }
            literal = ""
        }
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let body = rest[afterOpen..<close]
            if let token = token(for: body) {
                flush()
                tokens.append(token)
            } else {
                unknown.append("{\(body)}")
                literal += "{\(body)}"
            }
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        flush()
        return (tokens, unknown)
    }

    private static func token(for body: Substring) -> Token? {
        if !body.isEmpty, body.allSatisfy({ $0 == "#" }) { return .counter(digits: body.count) }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let keyword = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let format = parts.count > 1 ? String(parts[1]) : ""
        let dateFormat = format.isEmpty ? defaultDateFormat : format
        switch keyword {
        case "name" where parts.count == 1: return .name
        case "date": return .dateTaken(format: dateFormat)
        case "modified": return .modified(format: dateFormat)
        case "width" where parts.count == 1: return .width
        case "height" where parts.count == 1: return .height
        case "ext" where parts.count == 1: return .fileExtension
        default: return nil
        }
    }

    /// Whether naming needs the date taken or the pixel size, which means
    /// reading each file's header. Counters and names don't, so the preview
    /// of a plain pattern for 5000 files reads nothing.
    public var needsImageMetadata: Bool {
        tokens.tokens.contains { token in
            switch token {
            case .dateTaken, .width, .height: true
            default: false
            }
        }
    }
}

/// What a pattern may need to know about one file.
public struct RenameSource: Hashable, Sendable {
    public var url: URL
    public var modified: Date?
    public var dateTaken: Date?
    /// The zone the camera recorded the date in (EXIF's offset), so a name
    /// shows the time on the camera's clock wherever the Mac is; nil for
    /// dates without an offset, which are wall-clock times already.
    public var dateTakenTimeZone: TimeZone?
    /// As displayed (EXIF orientation applied).
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(url: URL, modified: Date? = nil, dateTaken: Date? = nil, dateTakenTimeZone: TimeZone? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.url = url
        self.modified = modified
        self.dateTaken = dateTaken
        self.dateTakenTimeZone = dateTakenTimeZone
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Fills in the date taken (EXIF DateTimeOriginal, else DateTimeDigitized)
    /// and the pixel size as displayed from the file's header, and the
    /// modification date if missing. Blocking I/O, a millisecond or two per
    /// file: never on the main thread.
    public func withImageMetadata() -> RenameSource {
        var copy = self
        switch ImageFormats.kind(of: url) {
        case .raster?, .raw?:
            if let properties = MetadataReader.Properties(url: url) {
                if let taken = properties.dateOriginal ?? properties.dateDigitized {
                    copy.dateTaken = taken.date
                    copy.dateTakenTimeZone = taken.hasOffset ? taken.timeZone : nil
                }
                if let size = properties.orientedPixelSize {
                    copy.pixelWidth = Int(size.width.rounded())
                    copy.pixelHeight = Int(size.height.rounded())
                }
            }
        default:
            if let size = ImageDecoder.info(for: url)?.pixelSize {
                copy.pixelWidth = Int(size.width.rounded())
                copy.pixelHeight = Int(size.height.rounded())
            }
        }
        if copy.modified == nil {
            copy.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return copy
    }

    /// `withImageMetadata` for many files, several at a time.
    public static func withImageMetadata(_ sources: [RenameSource]) -> [RenameSource] {
        var result = sources
        result.withUnsafeMutableBufferPointer { buffer in
            let base = UncheckedBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: sources.count) { i in
                base.buffer[i] = sources[i].withImageMetadata()
            }
        }
        return result
    }
}

/// Distinct indices are written from several threads at once, which is
/// safe; the wrapper only tells the compiler so.
private struct UncheckedBuffer<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
    init(_ buffer: UnsafeMutableBufferPointer<T>) { self.buffer = buffer }
}

/// Makes names from a pattern. Parses the pattern and builds its date
/// formatters once, so naming thousands of files costs string work only.
/// Not `Sendable` (formatters): make one per job, on the thread that uses it.
public struct RenameNamer {
    public let pattern: RenamePattern
    private let tokens: [RenamePattern.Token]
    public let unknownTokens: [String]
    private let timeZone: TimeZone
    /// By format and time zone. A class box, so naming (a non-mutating
    /// call) can add the formatter for a camera's zone the first time.
    private let formatters = FormatterCache()

    private final class FormatterCache {
        var byKey: [String: DateFormatter] = [:]
    }

    public init(pattern: RenamePattern, timeZone: TimeZone = .current) {
        self.pattern = pattern
        self.timeZone = timeZone
        (tokens, unknownTokens) = RenamePattern.parse(pattern.text)
    }

    /// The base name (no extension) for the file at `index` in the batch.
    public func baseName(for source: RenameSource, index: Int) -> String {
        let original = source.url.lastPathComponent
        var result = ""
        for token in tokens {
            switch token {
            case .literal(let text): result += text
            case .name: result += Self.split(original).base
            case .counter(let digits): result += counter(index: index, digits: digits)
            case .dateTaken(let format):
                result += source.dateTaken.map { date($0, format, in: source.dateTakenTimeZone) }
                    ?? date(source.modified, format)
            case .modified(let format): result += date(source.modified, format)
            case .width: result += source.pixelWidth.map(String.init) ?? ""
            case .height: result += source.pixelHeight.map(String.init) ?? ""
            case .fileExtension: result += Self.split(original).ext
            }
        }
        if !pattern.find.isEmpty {
            result = result.replacingOccurrences(of: pattern.find, with: pattern.replacement,
                                                 options: pattern.matchesCase ? [.literal] : [.literal, .caseInsensitive])
        }
        return Self.apply(pattern.nameCase, to: result)
    }

    /// The whole new name: the base name, then the extension, which is the
    /// original's unless `newExtension` gives the converter's.
    public func name(for source: RenameSource, index: Int, newExtension: String? = nil) -> String {
        let base = baseName(for: source, index: index)
        let ext = Self.apply(pattern.extensionCase, to: newExtension ?? Self.split(source.url.lastPathComponent).ext)
        return ext.isEmpty ? base : base + "." + ext
    }

    func counter(index: Int, digits tokenDigits: Int) -> String {
        let (product, overflow1) = index.multipliedReportingOverflow(by: pattern.counterStep)
        let (value, overflow2) = pattern.counterStart.addingReportingOverflow(product)
        let number = overflow1 || overflow2 ? 0 : value
        let digits = min(max(tokenDigits, pattern.counterDigits, 1), 20)
        let magnitude = String(number.magnitude)
        let padded = String(repeating: "0", count: max(0, digits - magnitude.count)) + magnitude
        return number < 0 ? "-" + padded : padded
    }

    private func date(_ date: Date?, _ format: String, in zone: TimeZone? = nil) -> String {
        guard let date else { return "" }
        let zone = zone ?? timeZone
        let key = format + "\u{0}" + zone.identifier
        if let formatter = formatters.byKey[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        // Fixed, so a pattern names files the same on every Mac, whatever
        // the user's region (digits, calendar).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        formatters.byKey[key] = formatter
        return formatter.string(from: date)
    }

    /// "photo.jpg" → ("photo", "jpg"); ".profile" and "README" have no
    /// extension, and nor does "photo." (the dot stays in the base).
    public static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    static func apply(_ letterCase: RenamePattern.LetterCase, to text: String) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        switch letterCase {
        case .unchanged: return text
        case .lower: return text.lowercased(with: posix)
        case .upper: return text.uppercased(with: posix)
        case .title: return text.capitalized(with: posix)
        }
    }

    static func apply(_ extensionCase: RenamePattern.ExtensionCase, to text: String) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        switch extensionCase {
        case .unchanged: return text
        case .lower: return text.lowercased(with: posix)
        case .upper: return text.uppercased(with: posix)
        }
    }
}
