import AppIntents
import Foundation
import MinivuCore
import MinivuRender

// minivu's actions in Shortcuts (G12). Each intent is a thin layer: it
// takes the shortcut's files (`AutomationInput`) and settings, and calls
// the engine in `Automation`, which is Batch Convert's, Batch Rename's and
// the catalog's own code.
//
// Shortcuts finds these without launching minivu, from
// Contents/Resources/Metadata.appintents, which scripts/make_app.sh makes
// from the compiler's record of these types (DESIGN.md 2). Titles, defaults
// and display names are read from that record, so they must stay literals:
// a computed title would not reach Shortcuts at all.
//
// Localisation (G13): titles, descriptions and display names are
// `LocalizedStringResource` literals, which the compiler extracts into the
// Minivu catalog and Shortcuts looks up in the app's main bundle. Format
// names (JPEG, HEIC…) are marked not to be translated in the catalog.
// Parameter summaries and App Shortcut phrases are outside the compiler's
// extraction (Xcode reads them from the App Intents metadata), so for now
// they stay English.
//
// The intents run inside minivu's own sandboxed process (launched in the
// background if it isn't running), so a shortcut can do nothing minivu
// itself could not: it opens no connection, and it reads only the files the
// shortcut passed.

/// Image formats minivu writes, for Convert Images. The list is a literal
/// (Shortcuts reads it from the compiler's record), so AVIF is offered
/// everywhere and `Automation.convert` refuses it, before converting
/// anything, on a Mac whose ImageIO can't write it.
enum AutomationFormat: String, AppEnum {
    case jpeg, heic, avif, png, tiff, jpeg2000, gif, bmp, tga, ico

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static let caseDisplayRepresentations: [AutomationFormat: DisplayRepresentation] = [
        .jpeg: "JPEG",
        .heic: "HEIC",
        .avif: "AVIF",
        .png: "PNG",
        .tiff: "TIFF",
        .jpeg2000: "JPEG 2000",
        .gif: "GIF",
        .bmp: "BMP",
        .tga: "TGA",
        .ico: "ICO",
    ]

    /// The same raw values as `ExportFormat`, so this never falls back.
    var exportFormat: ExportFormat { ExportFormat(rawValue: rawValue) ?? .jpeg }
}

/// Which side Resize Images measures, as in Batch Convert.
enum AutomationResizeMode: String, AppEnum {
    case longSide, width, height, percent

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Resize By"
    static let caseDisplayRepresentations: [AutomationResizeMode: DisplayRepresentation] = [
        .longSide: "Long Side",
        .width: "Width",
        .height: "Height",
        .percent: "Percentage",
    ]

    var batchMode: BatchResize.Mode {
        switch self {
        case .longSide: .longSide
        case .width: .width
        case .height: .height
        case .percent: .percent
        }
    }
}

/// Converts images to another format. The originals are left as they are;
/// the converted files go on to the shortcut's next action.
struct ConvertImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Images"
    static let description = IntentDescription(
        "Converts images to another format with minivu, optionally making them smaller and leaving out where they were taken. The originals are not changed; the converted images are passed on.",
        categoryName: "Images")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: AutomationFormat

    @Parameter(title: "Quality", description: "For JPEG, HEIC, AVIF and JPEG 2000: 1 to 100.", default: 90,
               inclusiveRange: (1, 100))
    var quality: Int

    @Parameter(title: "Long Side", description: "The longest side in pixels. Leave empty to keep the size; smaller images are never enlarged.",
               inclusiveRange: (1, 32768))
    var longSide: Int?

    @Parameter(title: "Remove Location", description: "Leave out the GPS position and place names, keeping the rest of the metadata.",
               default: true)
    var removeLocation: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$images) to \(\.$format)") {
            \.$quality
            \.$longSide
            \.$removeLocation
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let settings = Automation.convertSettings(format: format.exportFormat, quality: quality, longSide: longSide,
                                                  removeLocation: removeLocation)
        let input = try await AutomationInput.make(images, originalsOnly: false)
        let converted = try await input.use { try await Automation.convert($0, settings: settings) }
        return .result(value: await AutomationInput.output(converted))
    }
}

/// Resizes images, each in its own format. The originals are left as they
/// are; the resized files go on to the shortcut's next action.
struct ResizeImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Resize Images"
    static let description = IntentDescription(
        "Resizes images with minivu's Lanczos resampling, keeping each one's format where minivu can write it (otherwise JPEG). The originals are not changed; the resized images are passed on.",
        categoryName: "Images")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Resize By", default: .longSide)
    var mode: AutomationResizeMode

    @Parameter(title: "Size", description: "Pixels, or a percentage when resizing by percentage.", default: 2048,
               inclusiveRange: (1, 32768))
    var size: Int

    @Parameter(title: "Enlarge Smaller Images", default: false)
    var enlarges: Bool

    @Parameter(title: "Remove Location", description: "Leave out the GPS position and place names, keeping the rest of the metadata.",
               default: true)
    var removeLocation: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Resize \(\.$images) by \(\.$mode) to \(\.$size)") {
            \.$enlarges
            \.$removeLocation
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let resize = Self.resize(mode: mode, size: size, enlarges: enlarges)
        let input = try await AutomationInput.make(images, originalsOnly: false)
        let resized = try await input.use { try await Automation.resize($0, resize: resize, removeLocation: removeLocation) }
        return .result(value: await AutomationInput.output(resized))
    }

    static func resize(mode: AutomationResizeMode, size: Int, enlarges: Bool) -> BatchResize {
        BatchResize(mode: mode.batchMode, pixels: min(max(size, 1), BatchResize.maximumSide),
                    percent: Double(min(max(size, 1), 1000)), doesNotEnlarge: !enlarges)
    }
}

/// Renames images in place with a Batch Rename pattern.
struct RenameImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Images"
    static let description = IntentDescription(
        "Renames images in place with a pattern: {name}, {#} or {###} for a counter, {date} or {date:yyyyMMdd} for the date taken, {modified}, {width}, {height}, {ext}. Works in Pictures and in folders added to minivu's sidebar. Ratings follow the files.",
        categoryName: "Images")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Pattern", default: "{date}-{###}")
    var pattern: String

    @Parameter(title: "Counter Starts At", default: 1, inclusiveRange: (0, 999_999))
    var counterStart: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$images) to \(\.$pattern)") {
            \.$counterStart
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let pattern = RenamePattern(text: pattern, counterStart: counterStart)
        let input = try await AutomationInput.make(images, originalsOnly: true)
        let renamed = try await input.use { try await Automation.rename($0, pattern: pattern) }
        return .result(value: await AutomationInput.files(renamed))
    }
}

/// Sets the star rating minivu shows and sorts and filters by.
struct SetRatingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Rating"
    static let description = IntentDescription(
        "Gives images 0 to 5 stars in minivu's catalog (0 clears the rating). The files themselves are not changed.",
        categoryName: "Images")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Rating", default: 5, inclusiveRange: (0, 5))
    var rating: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Rate \(\.$images) \(\.$rating) stars")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let rating = min(max(rating, 0), 5)
        let input = try await AutomationInput.make(images, originalsOnly: true)
        let rated = await input.use { urls in
            await Automation.setRating(rating, for: urls)
            return urls
        }
        return .result(value: await AutomationInput.files(rated))
    }
}

/// The colour labels, for Set Colour Label: Finder's seven standard colour
/// tags and None, in the order of Image > Label. The raw values are
/// `ColorLabel`'s, so `colorLabel` never falls back.
enum AutomationColorLabel: Int, AppEnum {
    case none, red, orange, yellow, green, blue, purple, gray

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour Label"
    static let caseDisplayRepresentations: [AutomationColorLabel: DisplayRepresentation] = [
        .none: "None",
        .red: "Red",
        .orange: "Orange",
        .yellow: "Yellow",
        .green: "Green",
        .blue: "Blue",
        .purple: "Purple",
        .gray: "Gray",
    ]

    var colorLabel: ColorLabel { ColorLabel(rawValue: rawValue) ?? .none }
}

/// Sets the colour label minivu shows: the file's standard Finder colour
/// tag, as Image > Label sets it.
struct SetColorLabelIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Colour Label"
    static let description = IntentDescription(
        "Gives images a colour label: the standard Finder colour tag, so Finder and Spotlight see it too. Other tags are kept; None removes the colour label.",
        categoryName: "Images")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Label", default: .red)
    var label: AutomationColorLabel

    static var parameterSummary: some ParameterSummary {
        Summary("Label \(\.$images) \(\.$label)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let label = label.colorLabel
        let input = try await AutomationInput.make(images, originalsOnly: true)
        let labelled = try await input.use { urls in
            try await Automation.setColorLabel(label, for: urls)
            return urls
        }
        return .result(value: await AutomationInput.files(labelled))
    }
}

/// Opens images or a folder in minivu.
struct OpenInMinivuIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in minivu"
    static let description = IntentDescription(
        "Opens an image in minivu's viewer with its folder in the browser, or a folder in the browser.",
        categoryName: "Images")
    static let openAppWhenRun = true

    @Parameter(title: "Images or Folder", supportedContentTypes: [.image, .folder])
    var items: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$items) in minivu")
    }

    func perform() async throws -> some IntentResult {
        let input = try await AutomationInput.make(items, originalsOnly: true)
        await input.use(keepingAccess: true) { await Automation.open($0) }
        return .result()
    }
}

/// Ready-made shortcuts, listed under minivu in the Shortcuts app and in
/// Spotlight without anyone building them; each asks for its images when run.
struct MinivuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertImagesIntent(), phrases: ["Convert images with \(.applicationName)"],
                    shortTitle: "Convert Images", systemImageName: "photo.on.rectangle.angled")
        AppShortcut(intent: ResizeImagesIntent(), phrases: ["Resize images with \(.applicationName)"],
                    shortTitle: "Resize Images", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: OpenInMinivuIntent(), phrases: ["Open in \(.applicationName)"],
                    shortTitle: "Open in minivu", systemImageName: "photo")
    }
}
