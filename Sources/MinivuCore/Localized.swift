import Foundation

/// User-facing text from this module's Localizable.xcstrings. Write
/// `localized("Open Folder…")`, or `localized(.init("Tag", comment: "Verb"))`
/// when a translator needs a hint; see docs/feature-notes/l10n.md.
nonisolated func localized(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
    Bundle.module.localizedText(resource, locale: locale)
}

extension Bundle {
    /// `resource` looked up in this bundle, whatever bundle the resource
    /// names: a literal's `LocalizedStringResource` means the main bundle,
    /// and in the .app each target's strings are in its own bundle.
    ///
    /// Without `locale`, in the language the app shows (this bundle's first
    /// preferred localization, which follows the main bundle's
    /// CFBundleLocalizations), with the user's region for numbers. The
    /// locale also picks the plural rule, so it must be that language's.
    /// With `locale`, in that locale's language: for tests.
    public nonisolated func localizedText(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
        guard let locale else {
            return String(localized: resource.defaultValue, table: resource.table, bundle: self, locale: interfaceLocale)
        }
        return String(localized: LocalizedStringResource(resource.defaultValue, table: resource.table, locale: locale,
                                                         bundle: .atURL(bundleURL)))
    }

    private nonisolated var interfaceLocale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: preferredLocalizations.first ?? "en")
        return Locale(components: components)
    }
}
