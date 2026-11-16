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
}
