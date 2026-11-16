import Foundation
import MinivuCore

/// User-facing text from this module's Localizable.xcstrings
/// (docs/feature-notes/l10n.md).
nonisolated func localized(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
    Bundle.minivuRender.localizedText(resource, locale: locale)
}
