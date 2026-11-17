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
        // An Indic language with India's region (Hindi, Punjabi, Bengali,
        // Gujarati and Tamil all ship): not English.
        for language in ["hi", "pa", "bn", "gu", "ta"] {
            var indian = Locale.Components(identifier: "en_IN")
            indian.languageComponents = Locale.Language.Components(identifier: language)
            #expect(localized("Red", locale: Locale(components: indian)) != "Red", "\(language)")
        }
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

    /// The app's own path: no locale, so the text is in the bundle's
    /// interface language, with that language's plural rule. A bundle whose
    /// only language is Polish shows it whatever the test runner's language,
    /// for each kind of string: plain, interpolated plural, keyed and keyed
    /// with arguments (a plural too).
    @Test func noLocaleUsesTheInterfaceLanguage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-pl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lproj = folder.appendingPathComponent("pl.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        // Polish is the development language, so the bundle chooses it even
        // when the user's languages don't include it.
        let info: [String: Any] = ["CFBundleIdentifier": "minivu.tests.l10n-pl", "CFBundleDevelopmentRegion": "pl",
                                   "CFBundleLocalizations": ["pl"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Info.plist"))
        let strings = """
            "Open in Test Viewer" = "Otwórz w przeglądarce testowej";
            "test.fastpath.tag.verb" = "Taguj";
            """
        try strings.write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        func plural(_ one: String, _ few: String, _ many: String, _ other: String) -> [String: Any] {
            ["NSStringLocalizedFormatKey": "%#@count@",
             "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                       "one": one, "few": few, "many": many, "other": other]]
        }
        let stringsdict: [String: Any] = [
            "%lld test pictures": plural("%lld obraz testowy", "%lld obrazy testowe", "%lld obrazów testowych",
                                         "%lld obrazu testowego"),
            "test.fastpath.files": plural("%lld plik", "%lld pliki", "%lld plików", "%lld pliku"),
        ]
        try PropertyListSerialization.data(fromPropertyList: stringsdict, format: .xml, options: 0)
            .write(to: lproj.appendingPathComponent("Localizable.stringsdict"))

        let bundle = try #require(Bundle(url: folder))
        try #require(bundle.preferredLocalizations.first == "pl")
        #expect(bundle.interfaceLocale.language.languageCode == .polish)

        // Plain.
        #expect(bundle.localizedText("Open in Test Viewer") == "Otwórz w przeglądarce testowej")
        // Interpolated, with Polish's one, few and many.
        func pictures(_ count: Int) -> String {
            bundle.localizedText(.init("\(count) test pictures", comment: "Test"))
        }
        #expect(pictures(1) == "1 obraz testowy")
        #expect(pictures(3) == "3 obrazy testowe")
        #expect(pictures(5) == "5 obrazów testowych")
        #expect(pictures(22) == "22 obrazy testowe")
        // Keyed.
        let verb = LocalizedStringResource("test.fastpath.tag.verb", defaultValue: "Tag", comment: "Verb")
        #expect(bundle.localizedText(verb) == "Taguj")
        // Keyed with arguments.
        func files(_ count: Int) -> String {
            bundle.localizedText(.init("test.fastpath.files", defaultValue: "\(count) files", comment: "Test"))
        }
        #expect(files(1) == "1 plik")
        #expect(files(4) == "4 pliki")
        #expect(files(12) == "12 plików")
        // A key the bundle lacks falls back to its English, in the fast path too.
        #expect(bundle.localizedText(.init("test.fastpath.missing", defaultValue: "Fallback")) == "Fallback")
        // Looked up again, from the key-kind cache: the same text.
        #expect(bundle.localizedText(verb) == "Taguj")
        #expect(files(2) == "2 pliki")
    }

    /// The key-kind cache is keyed by the key alone, so a key's kind must be
    /// the same wherever it is used; `keyedValueKind` tells them apart (a
    /// debug build asserts on a clash).
    @Test func keyKindsAreTellable() {
        let count = 2
        #expect(LocalizedStringResource("Open in Test Viewer").keyedValueKind.kind == .english)
        #expect(LocalizedStringResource("\(count) test pictures").keyedValueKind.kind == .english)
        #expect(LocalizedStringResource("test.kind.a", defaultValue: "Plain").keyedValueKind.kind == .key)
        #expect(LocalizedStringResource("test.kind.a", defaultValue: "\(count) files").keyedValueKind.kind
                    == .keyWithArguments)
    }

    #if DEBUG
    /// One key used with two kinds of default value stops a debug build.
    @Test func keyUsedWithTwoKindsAsserts() async {
        await #expect(processExitsWith: .failure) {
            let count = 3
            _ = Bundle.main.localizedText(.init("test.kind.clash", defaultValue: "\(count) files"))
            _ = Bundle.main.localizedText(.init("test.kind.clash", defaultValue: "No files"))
        }
    }
    #endif
}
