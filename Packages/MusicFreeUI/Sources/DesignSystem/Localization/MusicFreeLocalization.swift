import Foundation
import SwiftUI

/// The app-owned language preference. English is intentionally independent of
/// the device language so a fresh install always starts in English.
public enum MusicFreeLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh-Hans"

    public var id: Self { self }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public var title: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// Resolves strings from the language selected inside the app rather than
/// relying on the host device's preferred language list.
public enum MusicFreeLocalization {
    public static let languageStorageKey = "musicfree.language"

    public static var language: MusicFreeLanguage {
        MusicFreeLanguage(
            rawValue: UserDefaults.standard.string(forKey: languageStorageKey) ?? ""
        ) ?? .english
    }

    public static var locale: Locale {
        language.locale
    }

    /// Creates a resource backed by the module's String Catalog.
    ///
    /// The selected locale is attached to the resource so views outside the
    /// module use the app language instead of the device language.
    public static func resource(
        _ key: String,
        language: MusicFreeLanguage? = nil
    ) -> LocalizedStringResource {
        let selectedLanguage = language ?? self.language
        return LocalizedStringResource(
            String.LocalizationValue(key),
            table: "Localizable",
            locale: selectedLanguage.locale,
            bundle: Bundle.module
        )
    }

    public static func localized(_ key: String) -> String {
        String(localized: resource(key))
    }

    public static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments: arguments)
    }

    public static func localized(_ key: String, arguments: [CVarArg]) -> String {
        String(format: localized(key), locale: locale, arguments: arguments)
    }

}

/// Returns a String Catalog-backed resource for SwiftUI APIs that accept
/// `LocalizedStringResource`.
public func LR(_ key: String) -> LocalizedStringResource {
    MusicFreeLocalization.resource(key)
}

/// Returns the selected-language string for model, error, and persistence
/// boundaries that require an eagerly resolved `String`.
public func L(_ key: String) -> String {
    MusicFreeLocalization.localized(key)
}

public func L(_ key: String, _ arguments: CVarArg...) -> String {
    MusicFreeLocalization.localized(key, arguments: arguments)
}

public extension View {
    /// Keeps SwiftUI's LocalizedStringKey lookup aligned with the app language.
    func musicFreeLanguageEnvironment() -> some View {
        environment(\.locale, MusicFreeLocalization.locale)
    }
}
