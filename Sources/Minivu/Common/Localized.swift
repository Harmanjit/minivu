import Foundation
import MinivuCore

/// User-facing text from this module's Localizable.xcstrings, which is in
/// the app target's resource bundle beside the help pages. Write
/// `localized("Open Folder…")`, or `localized(.init("Tag", comment: "Verb"))`
/// when a translator needs a hint; see docs/feature-notes/l10n.md.
nonisolated func localized(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
    Bundle.minivuHelp.localizedText(resource, locale: locale)
}

/// A percentage in the user's style ("12%", "12 %" in French); `percent` runs
/// from 0 to 100.
nonisolated func percentText(_ percent: Double, decimals: Int = 0, locale: Locale = .current) -> String {
    (percent / 100).formatted(.percent.precision(.fractionLength(decimals)).locale(locale))
}

/// A number and its unit symbol, with the number in the user's style: "2.5 px",
/// "0.50 EV", "40 %" in French. Degrees and "×" touch the number everywhere.
nonisolated func unitText(_ value: Double, decimals: Int, unit: String) -> String {
    let number = value.formatted(.number.precision(.fractionLength(decimals)))
    switch unit.trimmingCharacters(in: .whitespaces) {
    case "": return number
    case "%": return percentText(value, decimals: decimals)
    case "°", "×": return number + unit
    case let symbol:
        return localized(.init("unit.value", defaultValue: "\(number) \(symbol)",
                               comment: "A number and its unit symbol, such as “2.5 px”, “0.50 EV” or “5500 K”"))
    }
}

/// Names as a list in the user's language ("A, B, and C"), at most `limit` of
/// them and then how many more.
nonisolated func listText(_ names: [String], limit: Int = .max) -> String {
    var shown = Array(names.prefix(limit))
    if names.count > limit {
        shown.append(localized(.init("\(names.count - limit) more", comment: "End of a list of names: how many more")))
    }
    return shown.formatted(.list(type: .and))
}
