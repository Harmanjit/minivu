import Foundation
import CoreGraphics
import MinivuCore

/// Everything Batch Convert asks about (DESIGN.md 5, "Tools"): the output
/// format and its options, where the files go and what they are called,
/// what to do about names already taken, and the resize, rotate and flip
/// applied on the way.
///
/// `Codable`, and remembered between launches; decoding fills anything
/// missing from the defaults, so settings saved by an older minivu still
/// load rather than reset.
public struct BatchConvertSettings: Codable, Hashable, Sendable {
    public enum Destination: Codable, Hashable, Sendable {
        /// Each output in its original's folder.
        case besideOriginals
        /// A folder chosen in an open panel, kept as a security-scoped
        /// bookmark: under the sandbox a path alone couldn't be written to
        /// in a later session.
        case chosenFolder(bookmark: Data)
    }

    public enum Naming: Codable, Hashable, Sendable {
        /// The original's name, with the new format's extension.
        case keep
        case pattern(RenamePattern)
    }

    /// Format, quality, colour profile, metadata, 16-bit, TIFF compression:
    /// the Save As options.
    public var options: ExportOptions
    public var destination: Destination
    public var naming: Naming
    public var existingFiles: BatchFileWriter.ExistingFilePolicy
    public var resize: BatchResize
    /// Clockwise quarter turns, 0...3.
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(options: ExportOptions = .defaults(for: .jpeg), destination: Destination = .besideOriginals,
                naming: Naming = .keep, existingFiles: BatchFileWriter.ExistingFilePolicy = .keepBoth,
                resize: BatchResize = BatchResize(), quarterTurns: Int = 0, flipHorizontal: Bool = false,
                flipVertical: Bool = false) {
        self.options = options
        self.destination = destination
        self.naming = naming
        self.existingFiles = existingFiles
        self.resize = resize
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    private enum CodingKeys: String, CodingKey {
        case options, destination, naming, existingFiles, resize, quarterTurns, flipHorizontal, flipVertical
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BatchConvertSettings()
        options = (try? c.decodeIfPresent(ExportOptions.self, forKey: .options)) ?? d.options
        destination = (try? c.decodeIfPresent(Destination.self, forKey: .destination)) ?? d.destination
        naming = (try? c.decodeIfPresent(Naming.self, forKey: .naming)) ?? d.naming
        existingFiles = (try? c.decodeIfPresent(BatchFileWriter.ExistingFilePolicy.self, forKey: .existingFiles))
            ?? d.existingFiles
        resize = (try? c.decodeIfPresent(BatchResize.self, forKey: .resize)) ?? d.resize
        quarterTurns = (try? c.decodeIfPresent(Int.self, forKey: .quarterTurns)) ?? d.quarterTurns
        flipHorizontal = (try? c.decodeIfPresent(Bool.self, forKey: .flipHorizontal)) ?? d.flipHorizontal
        flipVertical = (try? c.decodeIfPresent(Bool.self, forKey: .flipVertical)) ?? d.flipVertical
    }

    /// The edit operations for a source of `sourceSize` (oriented pixels):
    /// turn, then flip, then resize, so a width or long side refers to the
    /// picture as it comes out. Empty when the pixels only change format.
    public func operations(sourceSize: CGSize) -> [EditOperation] {
        var operations: [EditOperation] = []
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 { operations.append(.rotate90(turns: turns)) }
        if flipHorizontal { operations.append(.flip(horizontal: true)) }
        if flipVertical { operations.append(.flip(horizontal: false)) }
        let turned = EditGraph.outputSize(source: sourceSize, operations: operations)
        if let size = resize.targetSize(for: turned) {
            operations.append(.resize(width: size.width, height: size.height, filter: resize.filter))
        }
        return operations
    }

    /// The output name for a source (at `index` in the batch), with the
    /// format's extension.
    public func outputName(for source: RenameSource, index: Int, namer: RenameNamer?) -> String {
        let ext = options.format.fileExtension
        guard let namer else {
            return RenameNamer.split(source.url.lastPathComponent).base + "." + ext
        }
        return namer.name(for: source, index: index, newExtension: ext)
    }

    public var pattern: RenamePattern? {
        if case .pattern(let pattern) = naming { return pattern }
        return nil
    }
}

/// Optional resizing for Batch Convert.
public struct BatchResize: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case none, longSide, width, height, percent

        public var title: String {
            switch self {
            case .none: "Don’t Resize"
            case .longSide: "Long Side"
            case .width: "Width"
            case .height: "Height"
            case .percent: "Percentage"
            }
        }
    }

    public var mode: Mode
    /// The long side, width or height in pixels.
    public var pixels: Int
    public var percent: Double
    public var filter: ResampleFilter
    /// Pictures already smaller than asked are left at their size, so a
    /// batch for the web doesn't blow up small icons into blurry large ones.
    public var doesNotEnlarge: Bool

    public init(mode: Mode = .none, pixels: Int = 2048, percent: Double = 50, filter: ResampleFilter = .lanczos3,
                doesNotEnlarge: Bool = true) {
        self.mode = mode
        self.pixels = pixels
        self.percent = percent
        self.filter = filter
        self.doesNotEnlarge = doesNotEnlarge
    }

    private enum CodingKeys: String, CodingKey { case mode, pixels, percent, filter, doesNotEnlarge }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BatchResize()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        pixels = (try? c.decodeIfPresent(Int.self, forKey: .pixels)) ?? d.pixels
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? d.percent
        filter = (try? c.decodeIfPresent(ResampleFilter.self, forKey: .filter)) ?? d.filter
        doesNotEnlarge = (try? c.decodeIfPresent(Bool.self, forKey: .doesNotEnlarge)) ?? d.doesNotEnlarge
    }

    /// The largest side a batch writes, as the Resize dialog allows.
    public static let maximumSide = 32768

    /// The exact output size for a picture of `size`, proportions kept, or
    /// nil when it stays as it is.
    public func targetSize(for size: CGSize) -> (width: Int, height: Int)? {
        let w = Double(size.width), h = Double(size.height)
        guard w >= 1, h >= 1 else { return nil }
        let scale: Double
        switch mode {
        case .none: return nil
        case .longSide: scale = Double(max(pixels, 1)) / max(w, h)
        case .width: scale = Double(max(pixels, 1)) / w
        case .height: scale = Double(max(pixels, 1)) / h
        case .percent:
            guard percent.isFinite, percent > 0 else { return nil }
            scale = percent / 100
        }
        guard scale.isFinite, scale > 0, !(doesNotEnlarge && scale >= 1) else { return nil }
        let limit = Double(Self.maximumSide)
        let width = Int(min(max((w * scale).rounded(), 1), limit))
        let height = Int(min(max((h * scale).rounded(), 1), limit))
        guard width != Int(w.rounded()) || height != Int(h.rounded()) else { return nil }
        return (width, height)
    }
}
