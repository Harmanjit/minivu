import Foundation
import Synchronization

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
    ///
    /// The viewer calls this on every zoom step of a pinch, so the common
    /// path stays cheap: the bundle's own lookup in its own language, no
    /// resource built, and the interface locale and each key's kind cached
    /// (LocalizationBenchmark).
    public nonisolated func localizedText(_ resource: LocalizedStringResource, locale: Locale? = nil) -> String {
        func text(_ value: String.LocalizationValue) -> String {
            // `String(localized:bundle:)` looks in the bundle's own language,
            // which is the interface language; only a resource can ask for another.
            guard let locale else {
                return String(localized: value, table: resource.table, bundle: self, locale: interfaceLocale)
            }
            return String(localized: LocalizedStringResource(value, table: resource.table, locale: locale,
                                                             bundle: .atURL(bundleURL)))
        }
        // A keyed resource (`.init("menu.tag.verb", defaultValue: "Tag")`)
        // is looked up by its key, with its English as the fallback.
        guard let keyed = resource.keyedValue else { return text(resource.defaultValue) }
        let found = text(keyed)
        return found == resource.key ? text(resource.defaultValue) : found
    }

    /// The bundle's language with the user's region, rebuilt only when the
    /// user's locale changes: the locale `localizedText` uses. Format numbers
    /// and lists that sit inside localized text with it, so they follow the
    /// interface language (an English list joined with "and" in English
    /// text) rather than the user's first preferred language, which the app
    /// may not have.
    public nonisolated var interfaceLocale: Locale {
        let current = Locale.current
        let region = current.identifier
        if let cached = interfaceLocales.withLock({ $0[bundleURL] }), cached.region == region { return cached.locale }
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(identifier: preferredLocalizations.first ?? "en")
        let locale = Locale(components: components)
        interfaceLocales.withLock { $0[bundleURL] = (region, locale) }
        return locale
    }
}

private nonisolated let interfaceLocales = Mutex<[URL: (region: String, locale: Locale)]>([:])

/// What a key is, found once per key: the English itself (a literal, maybe
/// interpolated), or a key of its own, with or without arguments.
///
/// The cache is keyed by the key alone, so one key must always come with the
/// same kind of default value. `localized(.init("status.images", defaultValue:
/// "\(count) images"))` in one place and `defaultValue: "No images"` in
/// another would make the second (or the first) look the string up with the
/// wrong arguments. A debug build checks every cached lookup against a fresh
/// one and stops on such a clash; give the second use a key of its own.
enum KeyKind: Sendable, Equatable { case english, key, keyWithArguments }
private nonisolated let keyKinds = Mutex<[String: KeyKind]>([:])

extension LocalizedStringResource {
    /// The default value's arguments under the resource's own key, when the
    /// key isn't the English itself. A resource can't be rebuilt for another
    /// bundle with a run-time key, and only its Codable form exposes the
    /// arguments, so that round trip runs only for a key with arguments,
    /// and the first time a key is seen.
    nonisolated var keyedValue: String.LocalizationValue? {
        if let cached = keyKinds.withLock({ $0[key] }) {
            #if DEBUG
            let fresh = keyedValueKind.kind
            assert(fresh == cached, "The localized key “\(key)” is used both as \(cached) and as \(fresh); "
                   + "give one of them a key of its own (docs/feature-notes/l10n.md, Keys)")
            #endif
            switch cached {
            case .english: return nil
            case .key: return String.LocalizationValue(key)
            case .keyWithArguments: break
            }
        }
        let (kind, json) = keyedValueKind
        keyKinds.withLock { $0[key] = kind }
        switch kind {
        case .english: return nil
        case .key: return String.LocalizationValue(key)
        case .keyWithArguments:
            guard var json else { return nil }
            json["key"] = key
            return try? JSONDecoder().decode(String.LocalizationValue.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        }
    }

    /// The key's kind, worked out from the default value (not cached), and
    /// the default value's Codable form when it was needed.
    nonisolated var keyedValueKind: (kind: KeyKind, json: [String: Any]?) {
        guard defaultValue != String.LocalizationValue(key),
              let json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultValue))) as? [String: Any],
              json["key"] as? String != key else {
            return (.english, nil)
        }
        let hasArguments = (json["arguments"] as? [Any])?.isEmpty == false
        return (hasArguments ? .keyWithArguments : .key, json)
    }
}
