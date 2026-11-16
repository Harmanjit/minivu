import Foundation

/// User-facing text from this module's Localizable.xcstrings. Write
/// `localized("Open Folder…")`, `localized(.init("Zoom", comment: "…"))` when
/// a translator needs a hint, or `localized(.init("menu.tag.verb",
/// defaultValue: "Tag", comment: "…"))` when the same English needs a second
/// translation; see docs/feature-notes/l10n.md.
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
        let locale = locale ?? interfaceLocale
        func text(_ value: String.LocalizationValue) -> String {
            String(localized: LocalizedStringResource(value, table: resource.table, locale: locale,
                                                      bundle: .atURL(bundleURL)))
        }
        // A keyed resource (`.init("menu.tag.verb", defaultValue: "Tag")`)
        // is looked up by its key, with its English as the fallback.
        guard let keyed = resource.keyedValue else { return text(resource.defaultValue) }
        let found = text(keyed)
        return found == resource.key ? text(resource.defaultValue) : found
    }

    private nonisolated var interfaceLocale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: preferredLocalizations.first ?? "en")
        return Locale(components: components)
    }
}

extension LocalizedStringResource {
    /// The default value's arguments under the resource's own key, when the
    /// key isn't the English itself. A resource can't be rebuilt for another
    /// bundle with a run-time key, and only its Codable form exposes the
    /// arguments.
    nonisolated var keyedValue: String.LocalizationValue? {
        guard defaultValue != String.LocalizationValue(key),
              var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultValue))) as? [String: Any],
              json["key"] as? String != key else { return nil }
        json["key"] = key
        return try? JSONDecoder().decode(String.LocalizationValue.self,
                                         from: JSONSerialization.data(withJSONObject: json))
    }
}
