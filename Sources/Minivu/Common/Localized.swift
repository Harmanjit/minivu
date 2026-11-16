import Foundation
import MinivuCore

/// User-facing text from this module's Localizable.xcstrings, which is in
/// the app target's resource bundle beside the help pages. Write
/// `localized("Open Folder…")`, or `localized(.init("Tag", comment: "Verb"))`
/// when a translator needs a hint; see docs/feature-notes/l10n.md.
nonisolated func localized(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
    Bundle.minivuHelp.localizedText(resource, locale: locale)
}
