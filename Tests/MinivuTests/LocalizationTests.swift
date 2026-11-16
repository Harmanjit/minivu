import Testing
import Foundation
@testable import Minivu

/// The String Catalogs (docs/feature-notes/l10n.md): every translation is
/// complete, keeps English's format specifiers and plural forms, and the
/// help pages fall back to English.
@MainActor @Suite struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let targets = ["MinivuCore", "MinivuRender", "Minivu"]

    /// The translations make_app.sh declares in CFBundleLocalizations.
    static func shippedLanguages() throws -> [String] {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make_app.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("for lang in ") })
        let languages = line.dropFirst("for lang in ".count).split(separator: ";")[0].split(separator: " ").map(String.init)
        return languages.filter { $0 != "en" }
    }

    /// Each target's catalog: key to its entry.
    static func catalogs() throws -> [(target: String, strings: [String: [String: Any]])] {
        try targets.map { target in
            let url = root.appendingPathComponent("Sources/\(target)/Localizable.xcstrings")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(json["sourceLanguage"] as? String == "en")
            return (target, try #require(json["strings"] as? [String: [String: Any]]))
        }
    }

    /// One language's text for an entry: plural category ("" when the text
    /// has no plural forms) to value.
    static func forms(_ entry: [String: Any], _ language: String) -> [String: String]? {
        guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else {
            return nil
        }
        func value(_ unit: Any?) -> String? {
            ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            return plural.compactMapValues(value)
        }
        return value(localization).map { ["": $0] }
    }

    /// The format specifiers in `text`, without positions and in order of
    /// type, so a translation may reorder its arguments.
    static func specifiers(_ text: String) -> [String] {
        let pattern = /%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]/
        return text.matches(of: pattern).map { String($0.output).replacing(/\d+\$/, with: "") }
            .filter { $0 != "%%" }.sorted()
    }

    static func isStale(_ entry: [String: Any]) -> Bool { entry["extractionState"] as? String == "stale" }
    static func translatable(_ entry: [String: Any]) -> Bool { entry["shouldTranslate"] as? Bool != false }

    /// A language with any translation in a catalog has them all there, so
    /// no one sees a menu half in English. A language nobody has started
    /// yet is skipped. Only shipped languages appear.
    @Test func translationsAreComplete() throws {
        let languages = try Self.shippedLanguages()
        #expect(languages == ["de", "fr", "es", "it", "pt-BR", "nl", "pl", "ja", "zh-Hans", "ko"])
        for (target, strings) in try Self.catalogs() {
            let live = strings.filter { !Self.isStale($0.value) && Self.translatable($0.value) }
            for (key, entry) in strings {
                let present = Set(((entry["localizations"] as? [String: Any]) ?? [:]).keys)
                #expect(present.isSubset(of: languages + ["en"]), "\(target): \"\(key)\" has \(present)")
            }
            for language in languages {
                let missing = live.filter { Self.forms($0.value, language)?.values.contains("") ?? true }.keys.sorted()
                guard missing.count < live.count else { continue }
                #expect(missing.isEmpty, "\(target) \(language): \(missing.count) untranslated, e.g. \(missing.prefix(5))")
            }
        }
    }

    /// Each language's plural categories (CLDR), besides an optional `zero`.
    static let pluralCategories: [String: Set<String>] = [
        "de": ["one", "other"], "nl": ["one", "other"], "fr": ["one", "many", "other"],
        "es": ["one", "many", "other"], "it": ["one", "many", "other"], "pt-BR": ["one", "many", "other"],
        "pl": ["one", "few", "many", "other"], "ja": ["other"], "zh-Hans": ["other"], "ko": ["other"],
    ]

    /// Every translation has English's format specifiers (any order), and
    /// plural forms exactly when English has them, in exactly its language's
    /// categories. A `zero` form, and a `one` form where `one` means only 1,
    /// may leave the number out; in fr and pt-BR `one` also covers 0.
    @Test func translationsKeepSpecifiersAndPlurals() throws {
        let languages = try Self.shippedLanguages()
        for (target, strings) in try Self.catalogs() {
            for (key, entry) in strings {
                let english = Self.forms(entry, "en") ?? ["": key]
                let isPlural = english[""] == nil
                if isPlural { #expect(english["other"] != nil, "\(target): \"\(key)\" English has no other form") }
                let expected = Self.specifiers(english[isPlural ? "other" : ""] ?? key)
                for language in languages {
                    guard let forms = Self.forms(entry, language) else { continue }
                    let context = "\(target) \(language): \"\(key)\""
                    #expect((forms[""] == nil) == isPlural, "\(context) plural forms differ from English")
                    guard let main = forms[isPlural ? "other" : ""] else {
                        Issue.record("\(context) has no other form")
                        continue
                    }
                    #expect(Self.specifiers(main) == expected, "\(context): \(main)")
                    if isPlural {
                        let categories = Set(forms.keys).subtracting(["zero"])
                        #expect(categories == Self.pluralCategories[language], "\(context) has \(categories.sorted())")
                    }
                    let mayDropNumber: Set = ["fr", "pt-BR"].contains(language) ? ["zero"] : ["zero", "one"]
                    for (category, text) in forms where !["other", ""].contains(category) {
                        let found = Self.specifiers(text)
                        #expect(found.allSatisfy(expected.contains), "\(context) [\(category)]: \(text)")
                        if !mayDropNumber.contains(category) { #expect(found == expected, "\(context) [\(category)]") }
                    }
                }
            }
        }
    }

    /// The menu's plural title comes from the catalog's plural forms.
    @Test func ratingTitleUsesPluralForms() {
        #expect(MenuStateTitles.rating(1) == "Rate 1 Star")
        #expect(MenuStateTitles.rating(3) == "Rate 3 Stars")
        #expect(MenuStateTitles.rating(0) == "Clear Rating")
    }

    /// A help page in the first language that has it, otherwise English.
    @Test func helpPageFallsBackToEnglish() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = folder.appendingPathComponent(HelpLibrary.folder)
        try FileManager.default.createDirectory(at: pages.appendingPathComponent("de"), withIntermediateDirectories: true)
        try "# Browser".write(to: pages.appendingPathComponent("Browser.md"), atomically: true, encoding: .utf8)
        try "# Viewer".write(to: pages.appendingPathComponent("Viewer.md"), atomically: true, encoding: .utf8)
        try "# Browser auf Deutsch".write(to: pages.appendingPathComponent("de/Browser.md"), atomically: true,
                                         encoding: .utf8)
        let bundle = try #require(Bundle(url: folder))

        #expect(HelpLibrary.markdown(for: .browser, bundle: bundle, languages: ["de"]) == "# Browser auf Deutsch")
        #expect(HelpLibrary.markdown(for: .browser, bundle: bundle, languages: ["fr", "de"]) == "# Browser auf Deutsch")
        #expect(HelpLibrary.markdown(for: .viewer, bundle: bundle, languages: ["de"]) == "# Viewer")
        #expect(HelpLibrary.markdown(for: .browser, bundle: bundle, languages: ["fr"]) == "# Browser")
        #expect(HelpLibrary.markdown(for: .browser, bundle: bundle) == "# Browser")
        #expect(HelpLibrary.markdown(for: .editing, bundle: bundle, languages: ["de"]) == nil)
    }
}
