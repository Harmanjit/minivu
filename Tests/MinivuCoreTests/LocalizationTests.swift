import Testing
import Foundation
@testable import MinivuCore

/// MinivuCore's strings come from its own bundle, in the language asked
/// for. (The catalogs themselves are checked in MinivuTests.)
@Suite struct LocalizationTests {
    @Test func looksUpTheRequestedLanguage() {
        #expect(localized("Red", locale: Locale(identifier: "de")) == "Rot")
        #expect(localized("Red", locale: Locale(identifier: "pt-BR")) == "Vermelho")
        #expect(localized("Red", locale: Locale(identifier: "zh-Hans")) == "红色")
        // A language minivu doesn't ship: English.
        #expect(localized("Red", locale: Locale(identifier: "sv")) == "Red")
        // Tests run in English, the development language.
        #expect(ColorLabel.red.localizedName == "Red")
        #expect(ColorLabel.allCases.map(\.localizedName) == ColorLabel.allCases.map(\.name))
    }

    /// A language with a region that isn't its own (the interface language
    /// with the user's region, as the app looks strings up): still that
    /// language.
    @Test func languageWinsOverRegion() {
        var components = Locale.Components(identifier: "en_US")
        components.languageComponents = Locale.Language.Components(identifier: "pt-BR")
        #expect(localized("Red", locale: Locale(components: components)) == "Vermelho")
        components.languageComponents = Locale.Language.Components(identifier: "zh-Hans")
        #expect(localized("Red", locale: Locale(components: components)) == "红色")
    }

    /// A keyed resource is looked up by its key, so one English word can
    /// have two translations; its default value is the fallback.
    @Test func keyedResourceUsesItsKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for (language, verb) in [("en", "Tag (verb)"), ("de", "Taggen")] {
            let lproj = folder.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let strings = """
                "menu.tag.verb" = "\(verb)";
                "Tag" = "\(language == "de" ? "Schlagwort" : "Tag")";
                "status.count" = "\(language == "de" ? "%lld Bilder" : "%lld pictures")";
                """
            try strings.write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let bundle = try #require(Bundle(url: folder))
        let verb = LocalizedStringResource("menu.tag.verb", defaultValue: "Tag", comment: "Verb")
        #expect(bundle.localizedText(verb, locale: Locale(identifier: "de")) == "Taggen")
        #expect(bundle.localizedText("Tag", locale: Locale(identifier: "de")) == "Schlagwort")
        #expect(bundle.localizedText(verb) == "Tag (verb)")
        let count = 3
        let status = LocalizedStringResource("status.count", defaultValue: "\(count) images")
        #expect(bundle.localizedText(status, locale: Locale(identifier: "de")) == "3 Bilder")
        #expect(bundle.localizedText(status) == "3 pictures")
        #expect(bundle.localizedText(LocalizedStringResource("menu.missing", defaultValue: "Fallback")) == "Fallback")
        #expect(bundle.localizedText(LocalizedStringResource("menu.missing", defaultValue: "Fallback"),
                                     locale: Locale(identifier: "de")) == "Fallback")
    }
}
